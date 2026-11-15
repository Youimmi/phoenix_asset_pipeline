defmodule PhoenixAssetPipeline.Bun do
  @moduledoc false

  alias PhoenixAssetPipeline.Config

  @ensured_key {__MODULE__, :ensured}
  @execute_mask if(match?({:win32, _}, :os.type()), do: 0, else: 0o111)
  @fingerprint_chunk_size 1024 * 1024
  @fingerprint_key {__MODULE__, :fingerprint}
  @install_lock {__MODULE__, :install}
  @version "1.4.4"

  @checksums Map.new(
               [
                 {"darwin-aarch64",
                  {"c240d7f0ccb90c263a849fcdb09b7ee62630d921348ed6aafda86b9d577bc510",
                   "0a2237cdcfa0d16ef501d9acca9f0026309ef348bea7393a64e8d1e3609565cc"}},
                 {"darwin-x64",
                  {"50a3491f73abc2fe81673171a85762d3bc2cc1680ccecadd983de99adf77977e",
                   "c35307c7d45d65c5a385a58c4a6cb0bb9499e4e626abdee207c177a77ba666ab"}},
                 {"linux-aarch64",
                  {"baa6bb36f51d6e58561e02bbea825038a9df454f673d6d776e8bbf86f8c7850e",
                   "354c2b049c716aca07b2e5cddb887928ac58950675d1258bb6312083917793b6"}},
                 {"linux-aarch64-musl",
                  {"57f01b02ac7113c61c935f28f38c2eab849e3c970dab21f8b640a87b1ef65009",
                   "a6a3d99a48600b59597070d2d2ff8d37b65975b8aab247ee3479b1eb33d000a6"}},
                 {"linux-x64",
                  {"bf8ccbfb2b0b80159e0f9a6d15c55317add8077534dbc6130a3edb52fccb395c",
                   "10702245766b225e70bbf6235fd6b47214fd94b4760d00ffaed8ab0df57ac235"}},
                 {"linux-x64-musl",
                  {"a5a8ccc5e74dcb883fe974f125a7bdb3b41e5195ed1b870e73f17effd3eb2b2d",
                   "29a31375a72f97c7e3fc25dd57d7dde88da5907aa8970808f57f91e0711bdad2"}},
                 {"windows-x64",
                  {"cd2c0fccc78f3ede1f50ca827a15f063eda13d4d150a3d0674f4f6e323d864a5",
                   "cb1d8e6564e655e49d30cead359750a1cbbd12f42651caa4b62244d7bd93c244"}}
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

  def ensure_fingerprint! do
    fingerprint = fingerprint()

    if ensured?(fingerprint) do
      fingerprint
    else
      :global.trans({@install_lock, self()}, &ensure_once!/0, [node()], :infinity)
    end
  end

  def fingerprint do
    path = bin_path()
    {path, @version, executable_fingerprint(path)}
  end

  def run(args, opts) when is_list(args) and is_list(opts) do
    ensure!()
    run_ready(args, opts)
  end

  def run_ready(args, opts) when is_list(args) and is_list(opts) do
    path = bin_path()
    System.cmd(path, ["--no-orphans", "--eval", @wrapper_script, path, "--no-orphans" | args], opts)
  end

  defp archive_binary! do
    target = target()
    url = "https://github.com/oven-sh/bun/releases/download/bun-v#{@version}/bun-#{target}.zip"
    proxy = proxy()

    {:ok, _} = Application.ensure_all_started([:inets, :ssl])
    configure_proxy(proxy)

    case :httpc.request(:get, {String.to_charlist(url), []}, http_options(proxy),
           body_format: :binary,
           max_header_size: 65_536
         ) do
      {:ok, {{_, 200, _}, _, body}} ->
        {archive_checksum, _} = Map.fetch!(@checksums, target)
        verify_checksum!(body, archive_checksum, "Bun archive #{url}")

      {:ok, {{_, status, _}, _, body}} ->
        raise "could not download Bun #{@version}: #{url} returned #{status}\n#{body}"

      {:error, reason} ->
        raise "could not download Bun #{@version}: #{inspect(reason)}"
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

  defp configure_proxy(nil), do: :ok

  defp configure_proxy(%{host: host, port: port}) do
    :httpc.set_options(https_proxy: {{to_charlist(host), port || 443}, []})
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

  defp ensure_unlocked!(install? \\ true) do
    {_, expected} = Map.fetch!(@checksums, target())

    case executable_fingerprint(bin_path()) do
      {:sha256, mode, ^expected}
      when @execute_mask == 0 or Bitwise.band(mode, @execute_mask) != 0 ->
        :ok

      {:sha256, _, ^expected} when install? ->
        File.chmod!(bin_path(), 0o755)

      _ when install? ->
        :ok = install!()
        ensure_unlocked!(false)

      fingerprint ->
        raise "installed Bun executable has an invalid checksum or mode: #{inspect(fingerprint)}"
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

  defp http_options(proxy) do
    proxy_auth(proxy) ++
      [
        ssl:
          [
            verify: :verify_peer,
            depth: 4,
            customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
          ] ++ ca_options()
      ]
  end

  defp install! do
    bin_path = bin_path()
    dir = Path.dirname(bin_path)
    tmp_dir = Path.join(dir, ".bun-#{System.pid()}-#{System.unique_integer([:monotonic, :positive])}")

    File.mkdir_p!(dir)
    File.mkdir!(tmp_dir)

    try do
      tmp_path = unzip!(archive_binary!(), tmp_dir)

      File.chmod!(tmp_path, 0o755)
      File.rename!(tmp_path, bin_path)
    after
      File.rm_rf(tmp_dir)
    end
  end

  defp linux_target(target, parts) do
    if "musl" in parts, do: target <> "-musl", else: target
  end

  defp proxy do
    with proxy when is_binary(proxy) <- System.get_env("HTTPS_PROXY") || System.get_env("https_proxy"),
         %{host: host} = uri when is_binary(host) <- URI.parse(proxy) do
      uri
    else
      _ -> nil
    end
  end

  defp proxy_auth(%{userinfo: userinfo}) when is_binary(userinfo) do
    case String.split(userinfo, ":", parts: 2) do
      [username, password] -> [proxy_auth: {to_charlist(username), to_charlist(password)}]
      _ -> []
    end
  end

  defp proxy_auth(_), do: []

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
    file = ~c"bun-#{target()}/#{executable_name()}"

    case :zip.unzip(binary, cwd: to_charlist(tmp_dir), file_list: [file]) do
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
