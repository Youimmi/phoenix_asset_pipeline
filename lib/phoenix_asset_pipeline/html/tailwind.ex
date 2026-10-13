defmodule PhoenixAssetPipeline.HTML.Tailwind do
  @moduledoc false
  use GenServer

  alias PhoenixAssetPipeline.Bun

  @script ~S"""
  import {readFileSync, statSync} from "node:fs";
  import {createRequire} from "node:module";
  import {dirname} from "node:path";
  import {createInterface} from "node:readline";

  let current;
  let design;
  let dependencies = new Map();

  for await (const line of createInterface({input: process.stdin})) {
    const [stylesheet, candidates] = JSON.parse(line);

    if (current !== stylesheet || [...dependencies].some(([file, modified]) => statSync(file).mtimeMs !== modified)) {
      const {__unstable__loadDesignSystem, compile} = createRequire(stylesheet)("@tailwindcss/node");
      const css = readFileSync(stylesheet, "utf8");
      const base = dirname(stylesheet);
      const files = new Set([stylesheet]);
      await compile(css, {base, onDependency: (file) => files.add(file)});
      design = await __unstable__loadDesignSystem(css, {base});
      dependencies = new Map([...files].map((file) => [file, statSync(file).mtimeMs]));
      current = stylesheet;
    }

    console.log(JSON.stringify(candidates.flatMap(candidate => design.canonicalizeCandidates([candidate], {rem: 16}))));
  }
  """

  def canonicalize(classes, nil), do: classes
  def canonicalize([], _), do: []

  def canonicalize(classes, stylesheet) when is_binary(stylesheet) do
    if !Process.whereis(__MODULE__) do
      case GenServer.start(__MODULE__, [], name: __MODULE__) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
      end
    end

    GenServer.call(__MODULE__, {Path.expand(stylesheet), classes}, 30_000)
  end

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_) do
    Bun.ensure!()

    port =
      Port.open({:spawn_executable, Bun.bin_path()}, [
        :binary,
        :exit_status,
        {:line, 1_048_576},
        {:args, ["--no-orphans", "--eval", @script]}
      ])

    {:ok, port}
  end

  @impl true
  def handle_call({stylesheet, classes}, _, port) do
    Port.command(port, [JSON.encode!([stylesheet, classes]), "\n"])
    {:reply, read_response(port, []), port}
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, port) do
    {:stop, {:tailwind_exit, status}, port}
  end

  defp read_response(port, parts) do
    receive do
      {^port, {:data, {:noeol, part}}} ->
        read_response(port, [part | parts])

      {^port, {:data, {:eol, part}}} ->
        [part | parts] |> Enum.reverse() |> IO.iodata_to_binary() |> JSON.decode!()

      {^port, {:exit_status, status}} ->
        raise "Tailwind formatter exited with status #{status}"
    after
      15_000 -> raise "Tailwind formatter timed out"
    end
  end
end
