defmodule PhoenixAssetPipeline.LiveViewTest do
  use ExUnit.Case, async: true

  alias Phoenix.LiveView.Socket
  alias PhoenixAssetPipeline.LiveView
  alias PhoenixAssetPipeline.Manifest

  setup do
    previous_snapshot = Manifest.put_snapshot(%{digest: "current"})

    on_exit(fn -> Manifest.restore_snapshot(previous_snapshot) end)
  end

  test "continues disconnected mounts" do
    assert {:cont, %Socket{}} = LiveView.on_mount([fallback_path: "/o"], %{}, %{}, socket(nil, %{}))
  end

  test "continues when client digest matches current manifest digest" do
    assert {:cont, %Socket{}} =
             LiveView.on_mount([fallback_path: "/o"], %{}, %{}, socket(self(), %{"_digest" => "current"}))
  end

  test "redirects stale clients back to their safe current uri" do
    assert {:halt, %Socket{redirected: {:redirect, %{status: 302, to: "/s/account?m=change-email"}}}} =
             LiveView.on_mount(
               [fallback_path: "/o"],
               %{},
               %{},
               socket(self(), %{"_digest" => "stale", "_uri" => "/s/account?m=change-email"})
             )
  end

  test "redirects stale clients with unsafe uri to fallback path" do
    assert {:halt, %Socket{redirected: {:redirect, %{status: 302, to: "/o"}}}} =
             LiveView.on_mount(
               [fallback_path: "/o"],
               %{},
               %{},
               socket(self(), %{"_digest" => "stale", "_uri" => "//evil.example"})
             )
  end

  test "redirects stale clients without uri to fallback path" do
    assert {:halt, %Socket{redirected: {:redirect, %{status: 302, to: "/o"}}}} =
             LiveView.on_mount([fallback_path: "/o"], %{}, %{}, socket(self(), %{"_digest" => "stale"}))
  end

  defp socket(transport_pid, connect_params) do
    %Socket{
      private: %{connect_params: connect_params},
      transport_pid: transport_pid
    }
  end
end
