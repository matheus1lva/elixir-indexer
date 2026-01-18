defmodule ElixirIndex.Crawler.Pipeline do
  use Broadway
  import Ecto.Query, only: [from: 2]
  alias ElixirIndex.RPC.Client
  alias ElixirIndex.Schema.{Transaction, Event, Abi}
  require Logger

  def start_link(opts) do
    chain_id = opts[:chain_id]

    Broadway.start_link(__MODULE__,
      name: opts[:name],
      producer: [
        module: {ElixirIndex.Crawler.Producer, opts},
        concurrency: 1,
        transformer: {__MODULE__, :transform, []}
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

  def transform(event, _opts) do
    %Broadway.Message{
      data: event,
      acknowledger: {Broadway.NoopAcknowledger, nil, nil}
    }
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

        Logger.debug(
          "Block #{block["number"]} - Transactions: #{length(block["transactions"])} - Logs: #{length(logs)}"
        )

        # Parse timestamp
        timestamp = ElixirIndex.Utils.hex_to_integer(block["timestamp"]) |> DateTime.from_unix!()

        # Process Transactions
        new_txs =
          Enum.map(block["transactions"], fn tx ->
            %{
              chain_id: chain_id,
              block_number: ElixirIndex.Utils.hex_to_integer(tx["blockNumber"]),
              hash: tx["hash"],
              from_address: tx["from"],
              to_address: tx["to"] || "",
              value: ElixirIndex.Utils.hex_to_integer(tx["value"]),
              gas: ElixirIndex.Utils.hex_to_integer(tx["gas"]),
              gas_price: ElixirIndex.Utils.hex_to_integer(tx["gasPrice"]),
              input: tx["input"],
              receipt_status: 0,
              timestamp: timestamp
            }
          end)

        # Prepare ABIs
        addresses = Enum.map(logs, & &1["address"]) |> Enum.uniq()
        abis = get_abis(chain_id, addresses)

        # Process Events
        new_events =
          Enum.map(logs, fn log ->
            address = log["address"]
            abi = Map.get(abis, address)
            topic0 = Enum.at(log["topics"], 0)

            # Decode event params using the fetched ABI
            {event_name, params} =
              if abi do
                ElixirIndex.Decoder.decode(abi, topic0, log["topics"], log["data"])
              else
                {nil, nil}
              end

            # Serialize decoded params for storage
            json_params =
              if params do
                params
                |> Enum.map(fn {k, v} -> {k, serialize(v)} end)
                |> Map.new()
                |> Jason.encode!()
              else
                nil
              end

            %{
              chain_id: chain_id,
              block_number: ElixirIndex.Utils.hex_to_integer(log["blockNumber"]),
              block_hash: log["blockHash"],
              transaction_hash: log["transactionHash"],
              transaction_index: ElixirIndex.Utils.hex_to_integer(log["transactionIndex"]),
              log_index: ElixirIndex.Utils.hex_to_integer(log["logIndex"]),
              address: address,
              topic0: Enum.at(log["topics"], 0),
              topic1: Enum.at(log["topics"], 1),
              topic2: Enum.at(log["topics"], 2),
              topic3: Enum.at(log["topics"], 3),
              data: log["data"],
              event_name: event_name,
              params: json_params
            }
          end)

        {tx_acc ++ new_txs, event_acc ++ new_events}
      end)

    # Insert into ClickHouse
    if length(transactions_rows) > 0 do
      Logger.debug("Inserting #{length(transactions_rows)} transactions")
      ElixirIndex.Repo.insert_all(Transaction, transactions_rows)
    end

    if length(events_rows) > 0 do
      Logger.debug("Inserting #{length(events_rows)} events")
      ElixirIndex.Repo.insert_all(Event, events_rows)
    end

    messages
  end

  defp serialize(val) when is_tuple(val), do: val |> Tuple.to_list() |> Enum.map(&serialize/1)
  defp serialize(val) when is_list(val), do: Enum.map(val, &serialize/1)

  defp serialize(val) when is_binary(val) do
    if String.valid?(val), do: val, else: "0x" <> Base.encode16(val, case: :lower)
  end

  defp serialize(val), do: val

  defp get_abis(chain_id, addresses) do
    # 1. Fetch existing
    existing = fetch_existing_abis(chain_id, addresses)
    existing_addresses = Map.keys(existing)

    # 2. Identify missing
    missing = addresses -- existing_addresses

    # 3. Fetch missing from Sourcify
    Logger.debug("Checking ABIs for #{length(addresses)} addresses. Missing: #{length(missing)}")

    new_abis =
      missing
      |> Task.async_stream(
        fn address ->
          case ElixirIndex.Sourcify.get_abi(chain_id, address) do
            {:ok, abi} ->
              Logger.debug("Sourcify found ABI for #{address}")
              {address, Jason.encode!(abi)}

            {:error, reason} ->
              Logger.warning("Sourcify failed for #{address}: #{inspect(reason)}")
              {address, nil}
          end
        end,
        max_concurrency: 1,
        timeout: 15_000
      )
      |> Enum.reduce(%{}, fn {:ok, {addr, abi}}, acc ->
        if abi, do: Map.put(acc, addr, abi), else: acc
      end)

    # 4. Insert new
    if map_size(new_abis) > 0 do
      Logger.info("Inserting #{map_size(new_abis)} new ABIs to DB")

      rows =
        Enum.map(new_abis, fn {addr, abi} ->
          %{
            chain_id: chain_id,
            address: addr,
            abi: abi,
            created_at: DateTime.utc_now() |> DateTime.truncate(:second)
          }
        end)

      ElixirIndex.Repo.insert_all(Abi, rows)
    end

    Map.merge(existing, new_abis)
  end

  defp fetch_existing_abis(_chain_id, []), do: %{}

  defp fetch_existing_abis(chain_id, addresses) do
    q =
      from(a in Abi,
        where: a.chain_id == ^chain_id,
        where: a.address in ^addresses,
        select: [:address, :abi]
      )

    ElixirIndex.Repo.all(q)
    |> Enum.into(%{}, fn %{address: addr, abi: abi} -> {addr, abi} end)
  end
end
