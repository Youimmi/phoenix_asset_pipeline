defmodule PhoenixAssetPipeline.Plug do
  @moduledoc """
  Endpoint and router plugs for PhoenixAssetPipeline.

  This module provides plugs for early hints, CSP reporting, secure CSP
  augmentation, private URL assigns, reporting endpoints, and manifest snapshots
  during code reloading.
  """

  import Plug.Conn,
    only: [
      get_resp_header: 2,
      halt: 1,
      inform!: 3,
      put_private: 3,
      put_resp_header: 3,
      register_before_send: 2,
      read_body: 2,
      send_resp: 3
    ]

  alias PhoenixAssetPipeline.Manifest

  require Logger

  @content_security_policy_directives [
    {"base-uri", ["'none'"]},
    {"default-src", ["'self'"]},
    {"form-action", ["'self'"]},
    {"frame-ancestors", ["'self'"]},
    {"img-src", ["'self'", "data:"]},
    {"object-src", ["'none'"]},
    {"report-to", ["default"]},
    {"require-trusted-types-for", ["'script'"]},
    {"script-src", ["'strict-dynamic'"]},
    {"trusted-types", ["decodeHTMLEntitiesPolicy", "default"]}
  ]
  @content_security_policy_map Map.new(@content_security_policy_directives)
  @content_security_policy Enum.map_join(@content_security_policy_directives, "; ", fn {directive, values} ->
                             directive <> " " <> Enum.join(values, " ")
                           end)
  @content_security_policy_before_img_src "base-uri 'none'; default-src 'self'; form-action 'self'; frame-ancestors 'self'; img-src 'self' data: "
  @content_security_policy_before_script_src "; object-src 'none'; report-to default; require-trusted-types-for 'script'; script-src 'strict-dynamic'"
  @content_security_policy_style_src "; style-src"
  @content_security_policy_trusted_types "; trusted-types decodeHTMLEntitiesPolicy default"
  @csp_skip_path_prefixes Application.compile_env(:phoenix_asset_pipeline, :csp_skip_path_prefixes, [["dev"]])
  @csp_skip_statuses :phoenix_asset_pipeline
                     |> Application.compile_env(:csp_skip_statuses, [])
                     |> List.wrap()
  @permission_policy_rules [
    "fullscreen=(self)",
    "geolocation=(self)"
  ]
  @early_hints_preconnect_suffix ">; rel=preconnect; crossorigin"
  @early_hints_preload_prefix ", <"

  def init(action), do: action

  def call(conn, action) when is_atom(action) do
    apply(__MODULE__, action, [conn, []])
  end

  @doc """
  Returns the base Content Security Policy used by `secure_browser_headers/1`.
  """
  def content_security_policy, do: @content_security_policy

  @doc """
  Handles CSP violation reports posted to `/csp-report`.
  """
  def csp_report(%{method: "POST", path_info: ["csp-report"]} = conn, opts) do
    json_library = Keyword.get_lazy(opts, :json_library, &json_library/0)
    length = Keyword.get(opts, :length, 64_000)

    with {:ok, body, conn} <- read_body(conn, length: length),
         {:ok, %{} = report} <- decode_json(json_library, body) do
      Logger.info("CSP Violation Report: #{inspect(report, pretty: true)}")

      conn
      |> send_resp(:no_content, "")
      |> halt()
    else
      _ ->
        conn
        |> send_resp(:bad_request, "Invalid CSP report")
        |> halt()
    end
  end

  def csp_report(conn, _), do: conn

  @doc """
  Sends 103 early hints for the static origin, manifest-backed scripts, and configured links.
  """
  def early_hints(%{private: %{phoenix_static_url: static_url}} = conn, opts) do
    link =
      :early_hints_preloads
      |> Manifest.get([])
      |> Enum.concat(early_hints_links(opts))
      |> Enum.reduce(["<", static_url, @early_hints_preconnect_suffix], fn preload, acc ->
        [acc, @early_hints_preload_prefix, static_url, preload]
      end)
      |> IO.iodata_to_binary()

    inform!(conn, :early_hints, [{"link", link}])

    conn
  end

  def early_hints(conn, _), do: conn

  @doc """
  Captures the current manifest for the lifetime of a request.

  Use this around Phoenix code reloading so a request sees a consistent
  manifest even when templates trigger a rebuild during rendering.
  """
  def put_asset_manifest_snapshot(conn, _) do
    previous_snapshot = Manifest.put_snapshot(Manifest.get(:manifest, nil))

    register_before_send(conn, fn conn ->
      Manifest.restore_snapshot(previous_snapshot)
      conn
    end)
  end

  @doc """
  Registers a before-send callback that merges manifest asset sources into CSP.
  """
  def put_content_security_policy(%{path_info: path_info} = conn, _) do
    if csp_skipped?(path_info),
      do: conn,
      else: register_before_send(conn, &content_security_policy/1)
  end

  @doc """
  Stores router/static URL and host values in `conn.private`.
  """
  def put_private_phoenix_assigns(%{private: %{phoenix_endpoint: endpoint}} = conn, _) do
    static_url = endpoint.static_url()
    static_uri = URI.parse(static_url)
    endpoint_host = endpoint.host()

    {url, static_url, router_host, static_host} =
      if endpoint_host == "localhost" and static_uri.host == "localhost" do
        uri = URI.to_string(%{endpoint.struct_url() | host: conn.host})
        {uri, uri, conn.host, conn.host}
      else
        url = endpoint.url()
        {url, static_url, URI.parse(url).host, static_uri.host}
      end

    conn
    |> put_private(:phoenix_router_host, router_host)
    |> put_private(:phoenix_router_url, url)
    |> put_private(:phoenix_static_host, static_host)
    |> put_private(:phoenix_static_url, static_url)
  end

  @doc """
  Adds a `Reporting-Endpoints` header for CSP reports.
  """
  def put_reporting_endpoints(%{private: %{phoenix_router_url: url}} = conn, opts) do
    report_uri =
      opts
      |> Keyword.get(:path, "/csp-report")
      |> then(&URI.merge(url, &1))

    put_resp_header(conn, "reporting-endpoints", ~s(default="#{report_uri}"))
  end

  def put_reporting_endpoints(conn, _), do: conn

  @doc """
  Returns secure browser headers suitable for Phoenix router pipelines.
  """
  def secure_browser_headers(opts \\ []) do
    headers = %{
      "content-security-policy" => content_security_policy(),
      "permissions-policy" => permission_policy()
    }

    case Keyword.get(opts, :cross_origin_opener_policy) do
      true -> Map.put(headers, "cross-origin-opener-policy", "same-origin")
      value when is_binary(value) -> Map.put(headers, "cross-origin-opener-policy", value)
      _ -> headers
    end
  end

  defp content_security_policy(conn) do
    if html_response?(conn) and not csp_status_skipped?(conn.status),
      do: put_content_security_policy_header(conn),
      else: conn
  end

  defp csp_map([@content_security_policy | _]), do: @content_security_policy_map
  defp csp_map([csp | _]), do: parse_csp(csp)
  defp csp_map(_), do: %{}

  defp csp_skipped?(path_info) do
    Enum.any?(@csp_skip_path_prefixes, &List.starts_with?(path_info, &1))
  end

  defp csp_status_skipped?(status) when is_integer(status) do
    Enum.any?(@csp_skip_statuses, &status_skipped?(&1, status))
  end

  defp csp_status_skipped?(_), do: false

  defp decode_json(nil, _), do: :error

  defp decode_json(json_library, body) do
    if Code.ensure_loaded?(json_library) and function_exported?(json_library, :try_decode, 2) do
      json_library.try_decode(body, [:use_nil])
    else
      {:ok, json_library.decode!(body)}
    end
  rescue
    _ -> :error
  end

  defp early_hint_attr({_, false}), do: []
  defp early_hint_attr({_, nil}), do: []
  defp early_hint_attr({name, true}), do: ["; ", to_string(name)]
  defp early_hint_attr({name, value}), do: ["; ", to_string(name), "=", to_string(value)]

  defp early_hint_attrs(attrs), do: Enum.map(attrs, &early_hint_attr/1)

  defp early_hint_link({link, attrs}) when is_binary(link) and is_list(attrs) do
    [IO.iodata_to_binary([link, ?>, early_hint_attrs(attrs)])]
  end

  defp early_hint_link(_), do: []

  defp early_hints_links(opts) do
    opts
    |> Keyword.get(:links, [])
    |> List.wrap()
    |> Enum.flat_map(&early_hint_link/1)
  end

  defp html_response?(conn) do
    conn
    |> get_resp_header("content-type")
    |> Enum.any?(&String.starts_with?(&1, "text/html"))
  end

  defp parse_csp(value) do
    value
    |> String.split(";", trim: true)
    |> Map.new(fn directive ->
      case String.split(String.trim(directive), " ", parts: 2) do
        [name, rest] -> {name, String.split(rest, " ", trim: true)}
        [name] -> {name, []}
      end
    end)
  end

  defp json_library do
    Application.get_env(:phoenix, :json_library)
  end

  defp permission_policy, do: Enum.join(@permission_policy_rules, ",")

  defp status_skipped?(%Range{} = range, status), do: status in range
  defp status_skipped?(statuses, status) when is_list(statuses), do: status in statuses
  defp status_skipped?(status, status), do: true
  defp status_skipped?(_, _), do: false

  defp put_content_security_policy_header(conn) do
    directives = Manifest.get(:csp_directives, %{})
    static_url = conn.private.phoenix_static_url

    value =
      case get_resp_header(conn, "content-security-policy") do
        [@content_security_policy | _] ->
          standard_content_security_policy(static_url, directives)

        headers ->
          generic_content_security_policy(headers, static_url, directives)
      end

    put_resp_header(conn, "content-security-policy", value)
  end

  defp standard_content_security_policy(static_url, directives) do
    IO.iodata_to_binary([
      @content_security_policy_before_img_src,
      static_url,
      @content_security_policy_before_script_src,
      csp_values(:maps.get("script-src", directives, [])),
      csp_style_src(:maps.get("style-src", directives, [])),
      @content_security_policy_trusted_types
    ])
  end

  defp generic_content_security_policy(headers, static_url, directives) do
    directives =
      Map.put(directives, "img-src", [static_url])

    headers
    |> csp_map()
    |> Map.merge(directives, fn _, v1, v2 -> v1 ++ v2 end)
    |> Enum.reduce([], fn
      {directive, values}, acc -> [directive <> " " <> Enum.join(values, " ") | acc]
      _, acc -> acc
    end)
    |> Enum.sort()
    |> Enum.join("; ")
  end

  defp csp_style_src([]), do: []
  defp csp_style_src(values), do: [@content_security_policy_style_src, csp_values(values)]

  defp csp_values([value | values]), do: [?\s, value | csp_values(values)]
  defp csp_values([]), do: []
end
