defmodule PhoenixAssetPipeline.HelpersTest do
  use ExUnit.Case
  use PhoenixAssetPipeline.Helpers
  use TestHelper

  doctest PhoenixAssetPipeline

  if @application_started? do
    describe "runtime" do
      test "style_tag/1 returns style tag with css" do
        assert {
                 :safe,
                 [
                   60,
                   "style",
                   [
                     32,
                     "integrity",
                     61,
                     34,
                     "sha512-" <> _integrity,
                     34
                   ],
                   62,
                   "body{background:red}" <> _source_map,
                   60,
                   47,
                   "style",
                   62
                 ]
               } = style_tag("app")
      end

      test "style_tag/1 returns empty style tag" do
        assert {:safe, [60, "style", [], 62, "", 60, 47, "style", 62]} =
                 style_tag("invalid/no_file")

        assert {:safe, [60, "style", [], 62, "", 60, 47, "style", 62]} =
                 style_tag("invalid/no_selector")
      end
    end
  else
    describe "compile-time" do
      test "style_tag/1 returns style tag with css" do
        assert {
                 :safe,
                 [
                   60,
                   "style",
                   [
                     32,
                     "integrity",
                     61,
                     34,
                     "sha512-" <> _integrity,
                     34
                   ],
                   62,
                   "body{background:red}" <> _source_map,
                   60,
                   47,
                   "style",
                   62
                 ]
               } = style_tag("app")
      end

      test "style_tag/1 raise SassCompilerError" do
        alias PhoenixAssetPipeline.Exceptions.SassCompilerError

        for {code, msg} <- [
              {"""
               defmodule NoFile do
                 use PhoenixAssetPipeline.Helpers

                 style_tag("invalid/no_file")
               end
               """,
               "Error: Can't find stylesheet to import.\n\e[34m  ╷\e[0m\n\e[34m1 │\e[0m \e[31m@use 'missing'\e[0m\n\e[34m  │\e[0m \e[31m^^^^^^^^^^^^^^\e[0m\n\e[34m  ╵\e[0m\n  priv/css/invalid/no_file.sass 1:1  root stylesheet\n"},
              {"""
               defmodule NoSelector do
                 use PhoenixAssetPipeline.Helpers

                 style_tag("invalid/no_selector")
               end
               """,
               "\e[33m\e[1mWarning\e[0m on line 1, column 1 of priv/css/invalid/no_selector.sass: \nThis selector doesn't have any properties and won't be rendered.\n\e[34m  ╷\e[0m\n\e[34m1 │\e[0m \e[31mbackground: red\e[0m\n\e[34m  │\e[0m \e[31m^^^^^^^^^^^^^^^\e[0m\n\e[34m  ╵\e[0m\n\nError: Expected identifier.\n\e[34m  ╷\e[0m\n\e[34m1 │\e[0m background:\e[31m\e[0m red\n\e[34m  │\e[0m \e[31m           ^\e[0m\n\e[34m  ╵\e[0m\n  priv/css/invalid/no_selector.sass 1:12  root stylesheet\n"}
            ] do
          assert_raise SassCompilerError, msg, fn ->
            Code.compile_string(code)
          end
        end
      end
    end
  end
end
