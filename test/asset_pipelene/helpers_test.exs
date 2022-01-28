defmodule PhoenixAssetPipeline.HelpersTest do
  use ExUnit.Case, async: true
  use PhoenixAssetPipeline.Helpers
  doctest PhoenixAssetPipeline

  alias PhoenixAssetPipeline.Exceptions.SassCompilerError

  describe "style_tag" do
    test "success compile" do
      assert {:safe, _} = style_tag("app")
    end

    test "fail compile" do
      code = """
      defmodule NotCompiled do
        use PhoenixAssetPipeline.Helpers

        defp view do
          style_tag("error")
        end
      end
      """

      expected =
        "Error: Can't find stylesheet to import.\n  ╷\n1 │ @use 'no_file'\n  │ ^^^^^^^^^^^^^^\n  ╵\n  priv/css/error.sass 1:1  root stylesheet\n"

      assert_raise SassCompilerError, expected, fn ->
        Code.compile_string(code)
      end
    end
  end
end
