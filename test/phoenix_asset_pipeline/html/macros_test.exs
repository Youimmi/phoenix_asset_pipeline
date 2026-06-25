defmodule PhoenixAssetPipeline.HTML.MacrosTest do
  use ExUnit.Case, async: true

  alias PhoenixAssetPipeline.Helpers
  alias PhoenixAssetPipeline.HTML.Macros
  alias PhoenixAssetPipeline.Manifest

  defmodule ChoiceClass do
    @moduledoc false
    use Macros

    def class_value(ready?, open?) do
      class([
        "base",
        {"mt-2", "mb-2", ready?},
        {["opacity-100", "scale-100"], ["opacity-0", "scale-95"], open?}
      ])
    end
  end

  defmodule HeexChoiceClass do
    @moduledoc false
    use Macros

    def render(assigns) do
      ~H"""
      <div class={[
        "base",
        {"mt-2", "mb-2", @ready?},
        {["opacity-100", "scale-100"], ["opacity-0", "scale-95"], @open?}
      ]} />
      """
    end
  end

  test "records choice class descriptors" do
    assert [
             {0, _, {["base"], [{:choice, ["mt-2"], ["mb-2"]}, {:choice, truthy, falsy}]}}
           ] = ChoiceClass.__class_descriptors__()

    assert truthy == ["opacity-100", "scale-100"]
    assert falsy == ["opacity-0", "scale-95"]

    class_names = ChoiceClass.class_names()

    for class_name <- [
          "base",
          "mt-2",
          "mb-2",
          "opacity-100",
          "scale-100",
          "opacity-0",
          "scale-95"
        ] do
      assert class_name in class_names
    end
  end

  test "builds choice class variants with one mask bit per choice" do
    [{0, _, descriptor}] = ChoiceClass.__class_descriptors__()

    classes = %{
      "base" => "a",
      "mb-2" => "b",
      "mt-2" => "m",
      "opacity-0" => "o0",
      "opacity-100" => "o1",
      "scale-95" => "s0",
      "scale-100" => "s1"
    }

    {strings, lists} = Helpers.build_class_descriptor(descriptor, classes)

    assert elem(strings, 0) == "a b o0 s0"
    assert elem(strings, 1) == "a m o0 s0"
    assert elem(strings, 2) == "a b o1 s1"
    assert elem(strings, 3) == "a m o1 s1"

    assert elem(lists, 0) == ["a", "b", "o0", "s0"]
    assert elem(lists, 3) == ["a", "m", "o1", "s1"]
  end

  test "resolves class descriptors from binary module manifest keys" do
    [{id, descriptor_hash, _}] = ChoiceClass.__class_descriptors__()

    previous_snapshot =
      Manifest.put_snapshot(%{
        class_descriptors: %{
          {Atom.to_string(ChoiceClass), id, descriptor_hash} => {{"cached"}, {["cached"]}}
        },
        classes: %{}
      })

    on_exit(fn -> Manifest.restore_snapshot(previous_snapshot) end)

    assert ChoiceClass.class_value(false, false) == [class: ["cached"]]
  end

  test "rewrites HEEx class attributes with choice tuples" do
    assert [
             {0, _, {["base"], [{:choice, ["mt-2"], ["mb-2"]}, {:choice, truthy, falsy}]}}
           ] = HeexChoiceClass.__class_descriptors__()

    assert truthy == ["opacity-100", "scale-100"]
    assert falsy == ["opacity-0", "scale-95"]
  end
end
