defmodule PhoenixAssetPipeline.HTML.Tailwind do
  @moduledoc false
  use GenServer

  alias PhoenixAssetPipeline.Bun

  @script ~S"""
  import {readFileSync, statSync} from "node:fs";
  import {createRequire} from "node:module";
  import {dirname} from "node:path";
  import {createInterface} from "node:readline";

  const nonce = process.env.PHOENIX_ASSET_PIPELINE_NONCE;
  const write = process.stdout.write.bind(process.stdout);
  const respond = (reply) => write(`\n${nonce}${JSON.stringify(reply)}\n`);
  process.stdout.write = process.stderr.write.bind(process.stderr);
  console.debug = console.info = console.log = console.error;

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

    respond(candidates.flatMap(candidate => design.canonicalizeCandidates([candidate])));
  }
  """

  def canonicalize(classes, nil), do: classes
  def canonicalize([], _), do: []

  def canonicalize(classes, stylesheet) when is_binary(stylesheet) do
    if is_nil(Process.whereis(__MODULE__)) do
      case GenServer.start(__MODULE__, [], name: __MODULE__) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
      end
    end

    GenServer.call(__MODULE__, {Path.expand(stylesheet), classes}, 30_000)
  end

  @impl true
  def handle_call({stylesheet, classes}, _, {port, nonce} = state) do
    Port.command(port, [JSON.encode!([stylesheet, classes]), "\n"])
    {:reply, read_response(port, nonce, []), state}
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, {port, _} = state) do
    {:stop, {:tailwind_exit, status}, state}
  end

  @impl true
  def init(_) do
    Bun.ensure!()
    nonce = 16 |> :crypto.strong_rand_bytes() |> Base.encode16()

    port =
      Port.open({:spawn_executable, Bun.bin_path()}, [
        :binary,
        :exit_status,
        {:line, 1_048_576},
        {:args, ["--no-orphans", "--eval", @script]},
        {:env, [{~c"PHOENIX_ASSET_PIPELINE_NONCE", String.to_charlist(nonce)}]}
      ])

    {:ok, {port, nonce}}
  end

  defp read_response(port, nonce, parts) do
    receive do
      {^port, {:data, {:noeol, part}}} ->
        read_response(port, nonce, [part | parts])

      {^port, {:data, {:eol, part}}} ->
        case [part | parts] |> Enum.reverse() |> IO.iodata_to_binary() do
          <<^nonce::binary-size(32), reply::binary>> -> JSON.decode!(reply)
          _ -> read_response(port, nonce, [])
        end

      {^port, {:exit_status, status}} ->
        raise "Tailwind formatter exited with status #{status}"
    after
      15_000 -> raise "Tailwind formatter timed out"
    end
  end
end
