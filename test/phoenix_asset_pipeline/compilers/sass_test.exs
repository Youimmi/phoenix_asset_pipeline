defmodule PhoenixAssetPipeline.Compilers.SassTest do
  use ExUnit.Case
  use TestHelper

  alias PhoenixAssetPipeline.Compilers.Sass

  doctest PhoenixAssetPipeline

  if @application_started? do
    describe "runtime" do
      test "compile! returns css" do
        assert {"body{background:red}" <> _source_map, _integrity} = Sass.compile!("app")
      end

      test "compile! returns empty string with error message in STDOUT" do
        import ExUnit.CaptureLog

        for {file_name, msg} <- [
              {"no_file", "Error: Can't find stylesheet to import."},
              {"no_selector", "This selector doesn't have any properties and won't be rendered."}
            ] do
          assert capture_log(fn -> Sass.compile!("invalid/" <> file_name) end) =~ msg
        end
      end
    end
  else
    describe "compile-time" do
      test "compile! returns css" do
        assert {"body{background:red}" <> _source_map, _integrity} = Sass.compile!("app")
      end

      test "compile! raise SassCompilerError" do
        alias PhoenixAssetPipeline.Exceptions.SassCompilerError

        expected =
          "Error: Can't find stylesheet to import.\n\e[34m  ╷\e[0m\n\e[34m1 │\e[0m \e[31m@use 'missing'\e[0m\n\e[34m  │\e[0m \e[31m^^^^^^^^^^^^^^\e[0m\n\e[34m  ╵\e[0m\n  priv/css/invalid/no_file.sass 1:1  root stylesheet\n"

        assert_raise SassCompilerError, expected, fn ->
          Sass.compile!("invalid/no_file")
        end

        expected =
          "\e[33m\e[1mWarning\e[0m on line 1, column 1 of priv/css/invalid/no_selector.sass: \nThis selector doesn't have any properties and won't be rendered.\n\e[34m  ╷\e[0m\n\e[34m1 │\e[0m \e[31mbackground: red\e[0m\n\e[34m  │\e[0m \e[31m^^^^^^^^^^^^^^^\e[0m\n\e[34m  ╵\e[0m\n\nError: Expected identifier.\n\e[34m  ╷\e[0m\n\e[34m1 │\e[0m background:\e[31m\e[0m red\n\e[34m  │\e[0m \e[31m           ^\e[0m\n\e[34m  ╵\e[0m\n  priv/css/invalid/no_selector.sass 1:12  root stylesheet\n"

        assert_raise SassCompilerError, expected, fn ->
          Sass.compile!("invalid/no_selector")
        end
      end
    end
  end
end
