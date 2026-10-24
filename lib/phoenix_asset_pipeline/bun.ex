defmodule PhoenixAssetPipeline.Bun do
  @moduledoc false

  alias PhoenixAssetPipeline.Config

  @ensured_key {__MODULE__, :ensured}
  @execute_mask if(match?({:win32, _}, :os.type()), do: 0, else: 0o111)
  @fingerprint_chunk_size 1024 * 1024
  @fingerprint_key {__MODULE__, :fingerprint}
  @install_lock {__MODULE__, :install}
  @version "1.4.3"

  @checksums Map.new(
               [
                 {"darwin-aarch64",
                  {"80afd4c069b46a6fa8f3ec520bebc750a7843e4a8d5b9583d29ad436c00a3403",
                   "28c7dd0a06916aba284d570ef44a2d70e9c538eaf2ba58dfe0910525563b3f79"}},
                 {"darwin-x64",
                  {"62660e6438eb872278877acca77e1152d5d031324df368d4a81b428211489d2d",
                   "c2a945a9d33f9088b32ac3550d1d1fd485a7fc10d71c66f91ef0d33b41cefa7c"}},
                 {"linux-aarch64",
                  {"efa9813da5ed72423bf847f916e8d2c47c0d776add972354026a75e10da9aa21",
                   "029ece746ac9f970c76d8f48bdd1b1d0c52f3636b74d19f546f5e7c1165c0abe"}},
                 {"linux-aarch64-musl",
                  {"8de8a0003cc2707bb555887e3d450e24e1edf3f605f491393e89ed61a8853420",
                   "94208b02231f5357be00ebd437ae9afb87d406887ba60f5f7a5732e677bde89e"}},
                 {"linux-x64",
                  {"3e730528d89775f03f87f05c06787c4df4099d0a37f3f252e7b829cb23816e18",
                   "7ce7d6b654eddeec20afddf2396317fba6dc19ab52788a27e894e1806bf8f24b"}},
                 {"linux-x64-musl",
                  {"6e9ea98554ea0d05efda5840ae292618aaa3adefd66b0853520c5c86a37eac9c",
                   "2a50a646294a1b5ff817d03313c7354f8ac43b7a37941b89f4d9b17bc5e86611"}},
                 {"windows-x64",
                  {"0bf84e808552beea67bf1202a287a35c6c825d837b287b3f8e9dd513dba35d3d",
                   "095db4abae203d42f29fdec26da4a882fcde6333cdd84e40c0c7828c0cf543f6"}}
               ],
               fn {target, {archive, executable}} ->
                 {target, {Base.decode16!(archive, case: :lower), Base.decode16!(executable, case: :lower)}}
               end
             )

  @wrapper_script ~S"""
  const command = process.argv.slice(1);

  const child = Bun.spawn(command, {
    stdin: "inherit",
    stdout: "inherit",
    stderr: "inherit",
    onExit: (_, code) => process.exit(code ?? 1)
  });

  const kill = () => {
    try {
      child.kill();
    } catch {
    }
  };

  process.stdin.resume();
  process.stdin.on("close", kill);
  process.on("SIGINT", () => {
    kill();
    process.exit(130);
  });
  process.on("SIGTERM", () => {
    kill();
    process.exit(143);
  });
  """

  def bin_path do
    Application.get_env(:phoenix_asset_pipeline, :bun_path) ||
      Path.join(Path.dirname(Config.build_path()), executable_name())
  end

  def ensure! do
    _ = ensure_fingerprint!()
    :ok
  end

  @doc false
  def ensure_fingerprint! do
    fingerprint = fingerprint()

    if ensured?(fingerprint) do
      fingerprint
    else
      :global.trans({@install_lock, self()}, &ensure_once!/0, [node()], :infinity)
    end
  end

  @doc false
  def fingerprint do
    path = bin_path()
    {path, version(), executable_fingerprint(path)}
  end

  def run(args, opts) when is_list(args) and is_list(opts) do
    ensure!()
    run_ready(args, opts)
  end

  @doc false
  def run_ready(args, opts) when is_list(args) and is_list(opts) do
    System.cmd(bin_path(), ["--no-orphans", "--eval", @wrapper_script, bin_path(), "--no-orphans" | args], opts)
  end

  def version, do: @version

  defp archive_binary!(version) do
    target = target()
    url = download_url(version, target)
    scheme = URI.parse(url).scheme

    :ok = ensure_http_started!()
    :ok = configure_proxy(scheme)

    case :httpc.request(:get, {String.to_charlist(url), []}, http_options(scheme),
           body_format: :binary,
           max_header_size: 65_536
         ) do
      {:ok, {{_, 200, _}, _, body}} ->
        {archive_checksum, _} = Map.fetch!(@checksums, target)
        verify_checksum!(body, archive_checksum, "Bun archive #{url}")

      {:ok, {{_, status, _}, _, body}} ->
        raise "could not download Bun #{version}: #{url} returned #{status}\n#{body}"

      {:error, reason} ->
        raise "could not download Bun #{version}: #{inspect(reason)}"
    end
  end

  defp ca_options do
    case Application.get_env(:phoenix_asset_pipeline, :bun_cacertfile) do
      nil ->
        [cacerts: :public_key.cacerts_get()]

      path ->
        [cacertfile: to_charlist(path)]
    end
  end

  defp configure_proxy(scheme) do
    with proxy when is_binary(proxy) <- proxy_for_scheme(scheme),
         %{host: host} = uri when is_binary(host) <- URI.parse(proxy) do
      proxy_option = if scheme == "https", do: :https_proxy, else: :proxy
      :httpc.set_options([{proxy_option, {{to_charlist(host), proxy_port(uri, scheme)}, []}}])
    end

    :ok
  end

  defp download_url(version, target) do
    "https://github.com/oven-sh/bun/releases/download/bun-v#{version}/bun-#{target}.zip"
  end

  defp ensure_http_started! do
    with {:ok, _} <- Application.ensure_all_started(:inets),
         {:ok, _} <- Application.ensure_all_started(:ssl) do
      :ok
    end
  end

  defp ensure_once! do
    fingerprint = fingerprint()

    if ensured?(fingerprint) do
      fingerprint
    else
      :ok = ensure_unlocked!()
      fingerprint = fingerprint()
      :persistent_term.put(@ensured_key, fingerprint)
      fingerprint
    end
  end

  defp ensure_unlocked! do
    {_, expected} = Map.fetch!(@checksums, target())

    case executable_fingerprint(bin_path()) do
      {:sha256, mode, ^expected}
      when @execute_mask == 0 or Bitwise.band(mode, @execute_mask) != 0 ->
        :ok

      {:sha256, _, ^expected} ->
        File.chmod!(bin_path(), 0o755)

      _ ->
        :ok = install!(version())

        case executable_fingerprint(bin_path()) do
          {:sha256, mode, ^expected}
          when @execute_mask == 0 or Bitwise.band(mode, @execute_mask) != 0 ->
            :ok

          fingerprint ->
            raise "installed Bun executable has an invalid checksum or mode: #{inspect(fingerprint)}"
        end
    end
  end

  defp ensured?(fingerprint) do
    :persistent_term.get(@ensured_key, nil) == fingerprint
  end

  defp executable_fingerprint(path) do
    case File.lstat(path, time: :posix) do
      {:ok, %{type: :regular} = stat} ->
        signature = {path, %{stat | atime: 0}}

        case :persistent_term.get(@fingerprint_key, nil) do
          {^signature, fingerprint} ->
            fingerprint

          _ ->
            hash_executable(signature)
        end

      {:ok, %{type: type}} ->
        {:invalid, type}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp executable_name do
    case :os.type() do
      {:win32, _} -> "bun.exe"
      _ -> "bun"
    end
  end

  defp hash_executable({path, stat} = signature) do
    # Cache identifiable files only after their second-precision timestamps have settled.
    cache? = stat.inode != 0 and max(stat.mtime, stat.ctime) < System.os_time(:second)

    with {:ok, result} <- File.open(path, [:read, :binary], &hash_file(&1, :crypto.hash_init(:sha256))),
         {:ok, digest} <- result do
      fingerprint = {:sha256, stat.mode, digest}
      if cache?, do: :persistent_term.put(@fingerprint_key, {signature, fingerprint})
      fingerprint
    end
  end

  defp hash_file(file, hash) do
    case IO.binread(file, @fingerprint_chunk_size) do
      :eof -> {:ok, :crypto.hash_final(hash)}
      {:error, reason} -> {:error, reason}
      content -> hash_file(file, :crypto.hash_update(hash, content))
    end
  end

  defp http_options(scheme) do
    maybe_add_proxy_auth(
      [
        ssl:
          [
            verify: :verify_peer,
            depth: 4,
            customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
          ] ++ ca_options()
      ],
      scheme
    )
  end

  defp install!(version) do
    bin_path = bin_path()
    tmp_dir = Path.join(Path.dirname(bin_path), ".bun-#{System.pid()}-#{System.unique_integer([:monotonic, :positive])}")

    File.mkdir_p!(Path.dirname(bin_path))
    File.mkdir!(tmp_dir)

    try do
      downloaded_path = unzip!(archive_binary!(version), tmp_dir)
      tmp_path = Path.join(tmp_dir, executable_name())

      File.cp!(downloaded_path, tmp_path)
      File.chmod!(tmp_path, 0o755)
      File.rename!(tmp_path, bin_path)
    after
      File.rm_rf(tmp_dir)
    end

    :ok
  end

  defp linux_target(target, parts) do
    if "musl" in parts, do: target <> "-musl", else: target
  end

  defp maybe_add_proxy_auth(http_options, scheme) do
    case proxy_auth(scheme) do
      nil -> http_options
      auth -> [{:proxy_auth, auth} | http_options]
    end
  end

  defp proxy_auth(scheme) do
    with proxy when is_binary(proxy) <- proxy_for_scheme(scheme),
         %{userinfo: userinfo} when is_binary(userinfo) <- URI.parse(proxy),
         [username, password] <- String.split(userinfo, ":", parts: 2) do
      {to_charlist(username), to_charlist(password)}
    else
      _ -> nil
    end
  end

  defp proxy_for_scheme("http"), do: System.get_env("HTTP_PROXY") || System.get_env("http_proxy")
  defp proxy_for_scheme("https"), do: System.get_env("HTTPS_PROXY") || System.get_env("https_proxy")
  defp proxy_for_scheme(_), do: nil

  defp proxy_port(%{port: nil}, "https"), do: 443
  defp proxy_port(%{port: nil}, _), do: 80
  defp proxy_port(%{port: port}, _), do: port

  defp target do
    arch =
      :system_architecture
      |> :erlang.system_info()
      |> List.to_string()
      |> String.split("-")

    case {:os.type(), arch} do
      {{:unix, :darwin}, ["aarch64" | _]} -> "darwin-aarch64"
      {{:unix, :darwin}, [arch | _]} when arch in ["amd64", "x86_64"] -> "darwin-x64"
      {{:unix, :linux}, ["aarch64" | rest]} -> linux_target("linux-aarch64", rest)
      {{:unix, :linux}, [arch | rest]} when arch in ["amd64", "x86_64"] -> linux_target("linux-x64", rest)
      {{:win32, _}, _} -> "windows-x64"
      {_, [arch | _]} -> raise "Bun is not available for architecture: #{arch}"
    end
  end

  defp unzip!(binary, tmp_dir) do
    zipped_target =
      case :os.type() do
        {:win32, _} -> "bun-#{target()}/bun.exe"
        _ -> "bun-#{target()}/bun"
      end

    case :zip.unzip(binary, cwd: to_charlist(tmp_dir), file_list: [to_charlist(zipped_target)]) do
      {:ok, [path]} -> List.to_string(path)
      other -> raise "could not unpack Bun archive: #{inspect(other)}"
    end
  end

  defp verify_checksum!(binary, expected, name) do
    actual = :crypto.hash(:sha256, binary)

    if actual == expected do
      binary
    else
      raise "#{name} checksum mismatch: expected #{Base.encode16(expected, case: :lower)}, " <>
              "got #{Base.encode16(actual, case: :lower)}"
    end
  end
end
