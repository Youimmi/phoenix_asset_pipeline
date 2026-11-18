defmodule PhoenixAssetPipeline.Files do
  @moduledoc false

  alias PhoenixAssetPipeline.Cache
  alias PhoenixAssetPipeline.Config
  alias PhoenixAssetPipeline.Digest

  def digests(root, cache_file, mode \\ :sources) do
    cache_path = Path.join(Config.manifest_cache_dir(), cache_file)
    fingerprint = Digest.module_info(:md5)
    now = System.os_time(:second)

    cache = Cache.read_map(cache_path, fingerprint)

    {digests, next_cache} =
      reduce_regular_files(
        root,
        {[], %{}},
        fn path, stat, {digests, next_cache} ->
          {digest, record} = cached_digest(path, stat, cache, now)
          {[{path, digest} | digests], if(record, do: Map.put(next_cache, path, record), else: next_cache)}
        end,
        mode
      )

    if next_cache != cache, do: Cache.write_term!(cache_path, {fingerprint, next_cache})
    Enum.sort(digests)
  end

  def read_regular!(path, stat \\ nil) do
    expected = stat || File.lstat!(path)
    if expected.type != :regular, do: raise(File.Error, reason: :eftype, action: "read regular file", path: path)

    case :file.open(path, [:read, :binary, :raw]) do
      {:ok, file} ->
        try do
          read_opened!(file, path, expected)
        after
          :file.close(file)
        end

      {:error, reason} ->
        raise File.Error, reason: reason, action: "open regular file", path: path
    end
  end

  def reduce_regular_files(root, acc, fun, mode \\ :sources) when is_function(fun, 3) do
    root = Path.expand(root)
    mode = if mode == :static, do: {:static, root}, else: mode

    case File.lstat(root) do
      {:ok, %{type: :directory}} -> reduce_dir(root, acc, fun, mode)
      {:ok, %{type: type}} -> raise ArgumentError, "expected a directory, got #{inspect(type)}: #{root}"
      {:error, :enoent} -> acc
      {:error, reason} -> raise File.Error, reason: reason, action: "stat directory", path: root
    end
  end

  def regular_file!(path, root) do
    root = Path.expand(root)
    path = Path.expand(path)

    relative = Path.relative_to(path, root)

    if Path.type(relative) != :relative do
      raise ArgumentError, "file resolves outside its source directory: #{path}"
    end

    case File.lstat(root) do
      {:ok, %{type: :directory}} -> validate_path!(root, Path.split(relative), path)
      {:ok, %{type: type}} -> raise ArgumentError, "invalid source directory type #{inspect(type)}: #{root}"
      {:error, reason} -> raise File.Error, reason: reason, action: "stat source directory", path: root
    end

    path
  end

  def regular_files(root, mode \\ :sources) do
    root
    |> reduce_regular_files([], fn path, _, paths -> [path | paths] end, mode)
    |> Enum.sort()
  end

  defp cached_digest(path, stat, cache, now) do
    signature = {stat.size, stat.mtime, stat.ctime, stat.inode, stat.major_device}

    case cache do
      %{^path => {^signature, digest}} ->
        {digest, {signature, digest}}

      _ ->
        digest = path |> File.read!() |> Digest.binary()
        # Cache identifiable files only after their second-precision timestamps have settled.
        settled? = stat.inode != 0 and max(stat.mtime, stat.ctime) < now

        {digest, if(settled?, do: {signature, digest})}
    end
  end

  defp excluded?("node_modules", _, :sources), do: true
  defp excluded?("." <> _, _, :sources), do: true
  defp excluded?(".well-known", root, {:static, root}), do: false
  defp excluded?("." <> _, _, {:static, _}), do: true
  defp excluded?(_, _, _), do: false

  defp read_opened!(file, path, expected) do
    {:ok, info} = :file.read_file_info(file)

    case File.Stat.from_record(info) do
      %{inode: inode, major_device: device, size: size}
      when inode == expected.inode and device == expected.major_device ->
        if size == 0, do: "", else: file |> :file.read(size) |> elem(1)

      _ ->
        raise File.Error, reason: :eexist, action: "read a file replaced during the build", path: path
    end
  end

  defp reduce_dir(dir, acc, fun, mode) do
    case File.ls(dir) do
      {:ok, entries} -> Enum.reduce(entries, acc, &reduce_entry(dir, &1, &2, fun, mode))
      {:error, reason} -> raise File.Error, reason: reason, action: "list directory", path: dir
    end
  end

  defp reduce_entry(dir, entry, acc, fun, mode) do
    if excluded?(entry, dir, mode) do
      acc
    else
      path = Path.join(dir, entry)

      case File.lstat(path, time: :posix) do
        {:ok, %{type: :directory}} -> reduce_dir(path, acc, fun, mode)
        {:ok, %{type: :regular} = stat} -> fun.(path, stat, acc)
        {:ok, %{type: type}} -> raise ArgumentError, "unsupported file type #{inspect(type)}: #{path}"
        {:error, reason} -> raise File.Error, reason: reason, action: "stat file", path: path
      end
    end
  end

  defp validate_path!(path, [], expected) do
    case File.lstat(path) do
      {:ok, %{type: :regular}} -> :ok
      {:ok, %{type: type}} -> raise ArgumentError, "expected a regular file, got #{inspect(type)}: #{expected}"
      {:error, reason} -> raise File.Error, reason: reason, action: "stat file", path: expected
    end
  end

  defp validate_path!(path, [entry | entries], expected) do
    path = Path.join(path, entry)

    case File.lstat(path) do
      {:ok, %{type: :directory}} when entries != [] -> validate_path!(path, entries, expected)
      {:ok, %{type: :regular}} when entries == [] -> :ok
      {:ok, %{type: type}} -> raise ArgumentError, "invalid source path type #{inspect(type)}: #{path}"
      {:error, reason} -> raise File.Error, reason: reason, action: "stat source path", path: path
    end
  end
end
