defmodule ElixirIndex.Chain.Supervisor do
  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  def init(_init_arg) do
    config = Application.get_env(:elixir_index, :rpc_endpoints, %{})
    start_block = Application.get_env(:elixir_index, :start_block, 0)

    children =
      Enum.map(config, fn {chain_id, _url} ->
        Supervisor.child_spec(
          {ElixirIndex.Crawler.Pipeline,
           [
             chain_id: chain_id,
             name: Module.concat(ElixirIndex.Crawler.Pipeline, "Chain#{chain_id}"),
             start_block: start_block
           ]},
          id: {ElixirIndex.Crawler.Pipeline, chain_id}
        )
      end)

    Supervisor.init(children, strategy: :one_for_one)
  end
end
