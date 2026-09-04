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
    {"img-src", ["'self'"]},
    {"object-src", ["'none'"]},
    {"report-to", ["default"]},
    {"require-trusted-types-for", ["'script'"]},
    {"script-src", ["'strict-dynamic'"]},
    {"trusted-types",
     Application.compile_env(:phoenix_asset_pipeline, :trusted_types, ~w(decodeHTMLEntitiesPolicy default))}
  ]
  @content_security_policy_map Map.new(@content_security_policy_directives)
  @content_security_policy Enum.map_join(@content_security_policy_directives, "; ", fn {directive, values} ->
                             directive <> " " <> Enum.join(values, " ")
                           end)
  @content_security_policy_before_img_src "base-uri 'none'; default-src 'self'; form-action 'self'; frame-ancestors 'self'; img-src 'self' "
  @content_security_policy_before_script_src "; object-src 'none'; report-to default; require-trusted-types-for 'script'; script-src 'strict-dynamic'"
  @content_security_policy_style_src "; style-src"
  @content_security_policy_trusted_types "; trusted-types " <>
                                           Enum.join(@content_security_policy_map["trusted-types"], " ")
  @csp_skip_path_prefixes Application.compile_env(:phoenix_asset_pipeline, :csp_skip_path_prefixes, [["dev"]])
  @csp_skip_statuses :phoenix_asset_pipeline
                     |> Application.compile_env(:csp_skip_statuses, [])
                     |> List.wrap()
  @permission_policy_rules [
    "fullscreen=(self)",
    "geolocation=(self)"
  ]
  @permission_policy Enum.join(@permission_policy_rules, ",")
  @early_hints_preconnect_suffix ">; rel=preconnect; crossorigin"
  @early_hints_preload_prefix ", <"
  @endpoint_urls_missing :__phoenix_asset_pipeline_endpoint_urls_missing__
  @header_cache_missing :__phoenix_asset_pipeline_header_cache_missing__

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
  def early_hints(%{private: %{phoenix_endpoint: endpoint, phoenix_static_url: static_url}} = conn, opts) do
    preloads = Manifest.get(:early_hints_preloads, [])
    links = Keyword.get(opts, :links, [])
    link = cached_early_hints(endpoint, static_url, preloads, links)

    inform!(conn, :early_hints, [{"link", link}])
  end

  def early_hints(conn, _), do: conn

  @doc """
  Captures the current manifest for the lifetime of a request.

  Use this around Phoenix code reloading so a request sees a consistent
  manifest even when templates trigger a rebuild during rendering.
  """
  def put_asset_manifest_snapshot(conn, _) do
    previous_snapshot = Manifest.put_snapshot()

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
    %{
      endpoint_host: endpoint_host,
      endpoint_uri: endpoint_uri,
      router_host: router_host,
      static_host: static_host,
      static_url: static_url,
      url: url
    } = endpoint_urls(endpoint)

    {url, static_url, router_host, static_host} =
      if endpoint_host == "localhost" and static_host == "localhost" do
        uri = URI.to_string(%{endpoint_uri | host: conn.host})
        {uri, uri, conn.host, conn.host}
      else
        {url, static_url, router_host, static_host}
      end

    private =
      Map.merge(conn.private, %{
        phoenix_router_host: router_host,
        phoenix_router_url: url,
        phoenix_static_host: static_host,
        phoenix_static_url: static_url
      })

    %{conn | private: private}
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

  The `:trusted_types` application setting configures the policy allowlist at compile time.
  """
  def secure_browser_headers(opts \\ []) do
    headers = %{
      "content-security-policy" => content_security_policy(),
      "permissions-policy" => @permission_policy
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

  defp cached_early_hints(endpoint, static_url, preloads, links) do
    key = {__MODULE__, :early_hints, endpoint}
    fingerprint = {static_url, preloads, links}

    case :persistent_term.get(key, @header_cache_missing) do
      {^fingerprint, link} ->
        link

      _ ->
        link =
          preloads
          |> append_early_hints(static_url, ["<", static_url, @early_hints_preconnect_suffix])
          |> append_configured_early_hints(links, static_url)
          |> IO.iodata_to_binary()

        :persistent_term.put(key, {fingerprint, link})
        link
    end
  end

  defp endpoint_urls(endpoint) do
    key = {__MODULE__, :endpoint_urls, endpoint}

    case :persistent_term.get(key, @endpoint_urls_missing) do
      @endpoint_urls_missing ->
        static_url = endpoint.static_url()
        url = endpoint.url()

        urls = %{
          endpoint_host: endpoint.host(),
          endpoint_uri: endpoint.struct_url(),
          router_host: URI.parse(url).host,
          static_host: URI.parse(static_url).host,
          static_url: static_url,
          url: url
        }

        :persistent_term.put(key, urls)
        urls

      urls ->
        urls
    end
  end

  defp early_hint_attr({_, false}), do: []
  defp early_hint_attr({_, nil}), do: []
  defp early_hint_attr({name, true}), do: ["; ", to_string(name)]
  defp early_hint_attr({name, value}), do: ["; ", to_string(name), "=", to_string(value)]

  defp early_hint_attrs(attrs), do: Enum.map(attrs, &early_hint_attr/1)

  defp append_early_hints([preload | rest], static_url, acc) do
    append_early_hints(rest, static_url, [acc, @early_hints_preload_prefix, static_url, preload])
  end

  defp append_early_hints([], _, acc), do: acc

  defp append_configured_early_hints(acc, [link | rest], static_url) do
    acc
    |> append_configured_early_hint(link, static_url)
    |> append_configured_early_hints(rest, static_url)
  end

  defp append_configured_early_hints(acc, [], _), do: acc

  defp append_configured_early_hints(acc, link, static_url) do
    append_configured_early_hint(acc, link, static_url)
  end

  defp append_configured_early_hint(acc, {link, attrs}, static_url) when is_binary(link) and is_list(attrs) do
    [
      acc,
      @early_hints_preload_prefix,
      static_url,
      link,
      ?>,
      early_hint_attrs(attrs)
    ]
  end

  defp append_configured_early_hint(acc, _, _), do: acc

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
          standard_content_security_policy(conn.private.phoenix_endpoint, static_url, directives)

        headers ->
          generic_content_security_policy(headers, static_url, directives)
      end

    put_resp_header(conn, "content-security-policy", value)
  end

  defp standard_content_security_policy(endpoint, static_url, directives) do
    key = {__MODULE__, :content_security_policy, endpoint}
    fingerprint = {static_url, directives, @content_security_policy}

    case :persistent_term.get(key, @header_cache_missing) do
      {^fingerprint, value} ->
        value

      _ ->
        value =
          IO.iodata_to_binary([
            @content_security_policy_before_img_src,
            static_url,
            @content_security_policy_before_script_src,
            csp_values(:maps.get("script-src", directives, [])),
            csp_style_src(:maps.get("style-src", directives, [])),
            @content_security_policy_trusted_types
          ])

        :persistent_term.put(key, {fingerprint, value})
        value
    end
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
