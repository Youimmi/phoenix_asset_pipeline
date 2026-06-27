defmodule PhoenixAssetPipeline.Bun do
  @moduledoc false

  alias PhoenixAssetPipeline.Config

  @compile {:no_warn_undefined, {CAStore, :file_path, 0}}
  @default_version "latest"
  @install_lock {__MODULE__, :install}
  @wrapper_script ~S"""
  const command = process.argv.slice(1);

  const child = Bun.spawn(command, {
    stdin: Bun.stdin.stream(),
    stdout: "inherit",
    stderr: "inherit",
    onExit: (_, code) => process.exit(code ?? 0)
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
    :global.trans(@install_lock, &ensure_unlocked!/0, [node()], :infinity)
  end

  def run(args, opts) when is_list(args) and is_list(opts) do
    ensure!()

    System.cmd(bin_path(), ["--no-orphans", "--eval", @wrapper_script, bin_path(), "--no-orphans" | args], opts)
  end

  def version, do: Application.get_env(:phoenix_asset_pipeline, :bun_version, @default_version)

  defp archive_binary!(version) do
    url = download_url(version)
    scheme = URI.parse(url).scheme

    :ok = ensure_http_started!()
    :ok = configure_proxy(scheme)

    case :httpc.request(:get, {String.to_charlist(url), []}, http_options(scheme), body_format: :binary) do
      {:ok, {{_, 200, _}, _, body}} ->
        body

      {:ok, {{_, status, _}, _, body}} ->
        raise "could not download Bun #{version}: #{url} returned #{status}\n#{body}"

      {:error, reason} ->
        raise "could not download Bun #{version}: #{inspect(reason)}"
    end
  end

  defp bin_version do
    path = bin_path()

    with true <- File.exists?(path),
         {version, 0} <- System.cmd(path, ["--version"]) do
      {:ok, String.trim(version)}
    else
      _ -> :error
    end
  end

  defp ca_options do
    cond do
      path = Application.get_env(:phoenix_asset_pipeline, :bun_cacertfile) ->
        [cacertfile: to_charlist(path)]

      path = castore_file_path() ->
        [cacertfile: to_charlist(path)]

      certs = otp_cacerts() ->
        [cacerts: certs]

      path = system_cacertfile() ->
        [cacertfile: to_charlist(path)]

      true ->
        raise "could not find CA certificates for Bun download; configure :bun_cacertfile"
    end
  end

  defp castore_file_path do
    if Code.ensure_loaded?(CAStore) and function_exported?(CAStore, :file_path, 0) do
      CAStore.file_path()
    end
  rescue
    _ -> nil
  end

  defp configure_proxy(scheme) do
    with proxy when is_binary(proxy) <- proxy_for_scheme(scheme),
         %{host: host} = uri when is_binary(host) <- URI.parse(proxy) do
      proxy_option = if scheme == "https", do: :https_proxy, else: :proxy
      :httpc.set_options([{proxy_option, {{to_charlist(host), proxy_port(uri, scheme)}, []}}])
    end

    :ok
  end

  defp download_url("latest") do
    "https://github.com/oven-sh/bun/releases/latest/download/bun-#{target()}.zip"
  end

  defp download_url(version) do
    "https://github.com/oven-sh/bun/releases/download/bun-v#{version}/bun-#{target()}.zip"
  end

  defp ensure_http_started! do
    with {:ok, _} <- Application.ensure_all_started(:inets),
         {:ok, _} <- Application.ensure_all_started(:ssl) do
      :ok
    end
  end

  defp ensure_unlocked! do
    version = version()

    case bin_version() do
      {:ok, _} when version == "latest" -> :ok
      {:ok, ^version} -> :ok
      _ -> install!(version)
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
    tmp_dir = Path.join(Path.dirname(bin_path), ".bun-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    try do
      downloaded_path = unzip!(archive_binary!(version), tmp_dir)
      tmp_path = Path.join(tmp_dir, executable_name())

      File.cp!(downloaded_path, tmp_path)
      File.chmod!(tmp_path, 0o755)
      File.mkdir_p!(Path.dirname(bin_path))
      File.rename!(tmp_path, bin_path)
    after
      File.rm_rf(tmp_dir)
    end

    :ok
  end

  defp executable_name do
    case :os.type() do
      {:win32, _} -> "bun.exe"
      _ -> "bun"
    end
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

  defp otp_cacerts do
    case :public_key.cacerts_get() do
      certs when is_list(certs) and certs != [] -> certs
      _ -> nil
    end
  rescue
    _ -> nil
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

  defp system_cacertfile do
    [
      System.get_env("SSL_CERT_FILE"),
      System.get_env("CURL_CA_BUNDLE"),
      "/etc/ssl/cert.pem",
      "/etc/ssl/certs/ca-certificates.crt",
      "/opt/homebrew/etc/ca-certificates/cert.pem",
      "/opt/homebrew/etc/openssl@3/cert.pem",
      "/usr/local/etc/openssl@3/cert.pem"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.find(&File.regular?/1)
  end

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
end
