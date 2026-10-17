defmodule PhoenixAssetPipeline.Files do
  @moduledoc false

  def reduce_regular_files(root, acc, fun, mode \\ :sources) when is_function(fun, 2) do
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
    |> reduce_regular_files([], &[&1 | &2], mode)
    |> Enum.sort()
  end

  def relative_path(path, root) do
    path
    |> Path.relative_to(root)
    |> String.replace("\\", "/")
  end

  defp excluded?("node_modules", _, :sources), do: true
  defp excluded?("." <> _, _, :sources), do: true
  defp excluded?(".well-known", root, {:static, root}), do: false
  defp excluded?("." <> _, _, {:static, _}), do: true
  defp excluded?(_, _, _), do: false

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

      case File.lstat(path) do
        {:ok, %{type: :directory}} -> reduce_dir(path, acc, fun, mode)
        {:ok, %{type: :regular}} -> fun.(path, acc)
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
