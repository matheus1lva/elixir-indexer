defmodule ElixirIndex.Crawler.Producer do
  use GenStage
  require Logger

  def start_link(opts) do
    GenStage.start_link(__MODULE__, opts)
  end

  def init(opts) do
    state = %{
      chain_id: opts[:chain_id],
      current_block: opts[:start_block] || 0,
      demand: 0
    }

    {:producer, state}
  end

  def handle_demand(incoming_demand, state) do
    new_demand = state.demand + incoming_demand
    dispatch_events(%{state | demand: new_demand})
  end

  defp dispatch_events(%{demand: 0} = state), do: {:noreply, [], state}

  defp dispatch_events(state) do
    # Simple increment for now. In a real implementation we would check the chain head.
    # Logic:
    # 1. Fetch current head from RPC (cached or periodially).
    # 2. If current_block < head, emit events up to min(demand, head - current_block).
    # 3. If caught up, schedule a check later.

    # Stub: just emit demand
    events = Enum.to_list(state.current_block..(state.current_block + state.demand - 1))
    new_state = %{state | current_block: state.current_block + state.demand, demand: 0}
    {:noreply, events, new_state}
  end
end
