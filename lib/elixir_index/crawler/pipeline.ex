defmodule ElixirIndex.Crawler.Pipeline do
  use Broadway
  alias ElixirIndex.RPC.Client

  def start_link(opts) do
    chain_id = opts[:chain_id]

    Broadway.start_link(__MODULE__,
      name: opts[:name],
      producer: [
        module: {ElixirIndex.Crawler.Producer, opts},
        concurrency: 1
      ],
      processors: [
        default: [concurrency: 10]
      ],
      batchers: [
        default: [batch_size: 100, batch_timeout: 1000, concurrency: 5]
      ],
      context: %{chain_id: chain_id}
    )
  end

  def handle_message(:default, message, %{chain_id: chain_id}) do
    block_number = message.data

    # Fetch block and logs in parallel (Task.async could be used, or sequential for simplicity)
    with {:ok, block} <- Client.get_block_by_number(chain_id, block_number),
         {:ok, logs} <- Client.get_logs(chain_id, block_number, block_number) do
      message
      |> Broadway.Message.put_data(%{
        block: block,
        logs: logs,
        chain_id: chain_id,
        block_number: block_number
      })
    else
      {:error, reason} ->
        Broadway.Message.failed(message, reason)
    end
  end

  def handle_batch(:default, messages, _batch_info, _context) do
    # Prepare data for insertion
    {transactions_rows, events_rows} =
      Enum.reduce(messages, {[], []}, fn message, {tx_acc, event_acc} ->
        data = message.data
        block = data.block
        logs = data.logs
        chain_id = data.chain_id

        # Parse timestamp
        timestamp = Utils.hex_to_integer(block["timestamp"]) |> DateTime.from_unix!()

        # Process Transactions
        new_txs =
          Enum.map(block["transactions"], fn tx ->
            [
              chain_id,
              Utils.hex_to_integer(tx["blockNumber"]),
              tx["hash"],
              tx["from"],
              # Contract creation has null 'to'
              tx["to"] || "",
              Utils.hex_to_integer(tx["value"]),
              Utils.hex_to_integer(tx["gas"]),
              Utils.hex_to_integer(tx["gasPrice"]),
              tx["input"],
              # status - missing in getBlockByNumber tx objects usually (need receipt), defaulting 0 or need fetch
              0,
              timestamp
            ]
          end)

        # Process Events
        new_events =
          Enum.map(logs, fn log ->
            [
              chain_id,
              Utils.hex_to_integer(log["blockNumber"]),
              log["blockHash"],
              log["transactionHash"],
              Utils.hex_to_integer(log["transactionIndex"]),
              Utils.hex_to_integer(log["logIndex"]),
              log["address"],
              Enum.at(log["topics"], 0),
              Enum.at(log["topics"], 1),
              Enum.at(log["topics"], 2),
              Enum.at(log["topics"], 3),
              log["data"],
              # event_name
              nil,
              # params
              nil
            ]
          end)

        {tx_acc ++ new_txs, event_acc ++ new_events}
      end)

    # Insert into ClickHouse
    if length(transactions_rows) > 0 do
      Ch.query!(:default, "INSERT INTO elixir_index.transactions VALUES", transactions_rows)
    end

    if length(events_rows) > 0 do
      Ch.query!(:default, "INSERT INTO elixir_index.events VALUES", events_rows)
    end

    messages
  end
end
