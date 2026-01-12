defmodule ElixirIndex.Chain.Supervisor do
  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  def init(_init_arg) do
    config = Application.get_env(:elixir_index, :rpc_endpoints, %{})

    children =
      Enum.map(config, fn {chain_id, _url} ->
        {ElixirIndex.Crawler.Pipeline,
         [
           chain_id: chain_id,
           name: Module.concat(ElixirIndex.Crawler.Pipeline, "Chain#{chain_id}"),
           # Default start block, should ideally be persisted/configurable
           start_block: 0
         ]}
      end)

    Supervisor.init(children, strategy: :one_for_one)
  end
end
