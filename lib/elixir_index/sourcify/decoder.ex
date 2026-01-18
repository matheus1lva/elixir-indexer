defmodule ElixirIndex.Sourcify.Decoder do
  @moduledoc """
  Decodes EVM event logs using ABIs fetched from Sourcify.

  ## Example

      # Decode a single log
      {:ok, decoded} = Decoder.decode_log(log, chain_id)

      # Decode multiple logs (batches ABI fetches)
      {:ok, decoded_logs} = Decoder.decode_logs(logs, chain_id)
  """

  alias ElixirIndex.Sourcify.Client
  require Logger

  # Common event signatures (topic0) for quick decoding without ABI fetch
  @known_events %{
    # ERC20 Transfer(address,address,uint256)
    "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef" => %{
      name: "Transfer",
      inputs: [
        %{name: "from", type: "address", indexed: true},
        %{name: "to", type: "address", indexed: true},
        %{name: "value", type: "uint256", indexed: false}
      ]
    },
    # ERC20 Approval(address,address,uint256)
    "0x8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925" => %{
      name: "Approval",
      inputs: [
        %{name: "owner", type: "address", indexed: true},
        %{name: "spender", type: "address", indexed: true},
        %{name: "value", type: "uint256", indexed: false}
      ]
    },
    # ERC721 Transfer(address,address,uint256) - same sig as ERC20 but different semantics
    # WETH Deposit(address,uint256)
    "0xe1fffcc4923d04b559f4d29a8bfc6cda04eb5b0d3c460751c2402c5c5cc9109c" => %{
      name: "Deposit",
      inputs: [
        %{name: "dst", type: "address", indexed: true},
        %{name: "wad", type: "uint256", indexed: false}
      ]
    },
    # WETH Withdrawal(address,uint256)
    "0x7fcf532c15f0a6db0bd6d0e038bea71d30d808c7d98cb3bf7268a95bf5081b65" => %{
      name: "Withdrawal",
      inputs: [
        %{name: "src", type: "address", indexed: true},
        %{name: "wad", type: "uint256", indexed: false}
      ]
    },
    # Uniswap V2 Swap
    "0xd78ad95fa46c994b6551d0da85fc275fe613ce37657fb8d5e3d130840159d822" => %{
      name: "Swap",
      inputs: [
        %{name: "sender", type: "address", indexed: true},
        %{name: "amount0In", type: "uint256", indexed: false},
        %{name: "amount1In", type: "uint256", indexed: false},
        %{name: "amount0Out", type: "uint256", indexed: false},
        %{name: "amount1Out", type: "uint256", indexed: false},
        %{name: "to", type: "address", indexed: true}
      ]
    }
  }

  @doc """
  Decodes a single event log.

  Returns `{:ok, decoded_log}` or `{:error, reason}`.

  The decoded_log includes:
  - event_name: The name of the event (e.g., "Transfer")
  - params: A map of decoded parameters

  ## Options
  - `:use_known_events` - Use built-in event signatures (default: true)
  - `:fetch_abi` - Fetch ABI from Sourcify if needed (default: true)
  """
  def decode_log(log, chain_id, opts \\ []) do
    use_known = Keyword.get(opts, :use_known_events, true)
    fetch_abi = Keyword.get(opts, :fetch_abi, true)

    topic0 = get_topic(log, 0)

    cond do
      is_nil(topic0) ->
        {:error, :anonymous_event}

      use_known && Map.has_key?(@known_events, topic0) ->
        decode_with_event_def(@known_events[topic0], log)

      fetch_abi ->
        decode_with_sourcify(log, chain_id)

      true ->
        {:error, :unknown_event}
    end
  end

  @doc """
  Decodes multiple event logs efficiently.

  Groups logs by contract address and fetches ABIs in batches.
  """
  def decode_logs(logs, chain_id, opts \\ []) do
    use_known = Keyword.get(opts, :use_known_events, true)
    fetch_abi = Keyword.get(opts, :fetch_abi, true)

    # Group logs by address for efficient ABI fetching
    logs_by_address =
      logs
      |> Enum.with_index()
      |> Enum.group_by(fn {log, _idx} -> get_address(log) end)

    # Process each address group
    results =
      logs_by_address
      |> Enum.flat_map(fn {address, indexed_logs} ->
        decode_address_logs(address, indexed_logs, chain_id, use_known, fetch_abi)
      end)
      |> Enum.sort_by(fn {idx, _result} -> idx end)
      |> Enum.map(fn {_idx, result} -> result end)

    {:ok, results}
  end

  @doc """
  Computes the event signature (topic0) for an event name and input types.

  ## Example

      iex> Decoder.event_signature("Transfer", ["address", "address", "uint256"])
      "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
  """
  def event_signature(name, input_types) do
    signature = "#{name}(#{Enum.join(input_types, ",")})"
    hash = :crypto.hash(:keccak_256, signature)
    "0x" <> Base.encode16(hash, case: :lower)
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp decode_address_logs(address, indexed_logs, chain_id, use_known, fetch_abi) do
    # First try known events
    {known_decoded, unknown_logs} =
      if use_known do
        partition_known_events(indexed_logs)
      else
        {[], indexed_logs}
      end

    # Then fetch ABI for remaining logs if needed
    abi_decoded =
      if fetch_abi && length(unknown_logs) > 0 do
        case Client.get_abi(chain_id, address) do
          {:ok, abi} ->
            event_map = build_event_map(abi)
            decode_logs_with_abi(unknown_logs, event_map)

          {:error, _reason} ->
            # Return raw logs with error
            Enum.map(unknown_logs, fn {log, idx} ->
              {idx, {:error, :abi_not_found, raw_log(log)}}
            end)
        end
      else
        Enum.map(unknown_logs, fn {log, idx} ->
          {idx, {:error, :unknown_event, raw_log(log)}}
        end)
      end

    known_decoded ++ abi_decoded
  end

  defp partition_known_events(indexed_logs) do
    Enum.split_with(indexed_logs, fn {log, _idx} ->
      topic0 = get_topic(log, 0)
      topic0 && Map.has_key?(@known_events, topic0)
    end)
    |> case do
      {known, unknown} ->
        decoded =
          Enum.map(known, fn {log, idx} ->
            topic0 = get_topic(log, 0)
            result = decode_with_event_def(@known_events[topic0], log)
            {idx, result}
          end)

        {decoded, unknown}
    end
  end

  defp decode_with_event_def(event_def, log) do
    try do
      {indexed_inputs, data_inputs} =
        event_def.inputs
        |> Enum.with_index()
        |> Enum.split_with(fn {input, _} -> input.indexed end)

      # Decode indexed params from topics
      indexed_params =
        indexed_inputs
        |> Enum.with_index()
        |> Enum.map(fn {{input, _}, topic_idx} ->
          # topic_idx + 1 because topic0 is the event signature
          topic = get_topic(log, topic_idx + 1)
          value = decode_indexed_param(topic, input.type)
          {input.name, value}
        end)
        |> Map.new()

      # Decode non-indexed params from data
      data = get_data(log)

      data_params =
        if data && data != "0x" && length(data_inputs) > 0 do
          types = Enum.map(data_inputs, fn {input, _} -> input.type end)
          names = Enum.map(data_inputs, fn {input, _} -> input.name end)

          case decode_data(data, types) do
            {:ok, values} ->
              Enum.zip(names, values) |> Map.new()

            {:error, _} ->
              %{}
          end
        else
          %{}
        end

      params = Map.merge(indexed_params, data_params)

      {:ok,
       %{
         event_name: event_def.name,
         params: params,
         address: get_address(log),
         topics: get_topics(log),
         data: data
       }}
    rescue
      e ->
        Logger.warning("Failed to decode event: #{inspect(e)}")
        {:error, :decode_failed, raw_log(log)}
    end
  end

  defp decode_with_sourcify(log, chain_id) do
    address = get_address(log)

    case Client.get_abi(chain_id, address) do
      {:ok, abi} ->
        event_map = build_event_map(abi)
        topic0 = get_topic(log, 0)

        case Map.get(event_map, topic0) do
          nil -> {:error, :event_not_in_abi, raw_log(log)}
          event_def -> decode_with_event_def(event_def, log)
        end

      {:error, reason} ->
        {:error, reason, raw_log(log)}
    end
  end

  defp build_event_map(abi) do
    abi
    |> Enum.filter(&(&1["type"] == "event"))
    |> Enum.map(fn event ->
      inputs =
        Enum.map(event["inputs"] || [], fn input ->
          %{
            name: input["name"],
            type: input["type"],
            indexed: input["indexed"] || false
          }
        end)

      types = Enum.map(inputs, & &1.type)
      topic0 = event_signature(event["name"], types)

      {topic0,
       %{
         name: event["name"],
         inputs: inputs
       }}
    end)
    |> Map.new()
  end

  defp decode_logs_with_abi(indexed_logs, event_map) do
    Enum.map(indexed_logs, fn {log, idx} ->
      topic0 = get_topic(log, 0)

      result =
        case Map.get(event_map, topic0) do
          nil -> {:error, :event_not_in_abi, raw_log(log)}
          event_def -> decode_with_event_def(event_def, log)
        end

      {idx, result}
    end)
  end

  defp decode_indexed_param(nil, _type), do: nil

  defp decode_indexed_param(topic, "address") do
    # Address is the last 20 bytes of the 32-byte topic
    "0x" <> hex = topic
    "0x" <> String.slice(hex, 24, 40)
  end

  defp decode_indexed_param(topic, type) when type in ["uint256", "int256", "uint", "int"] do
    "0x" <> hex = topic
    {value, _} = Integer.parse(hex, 16)
    value
  end

  defp decode_indexed_param(topic, "bool") do
    "0x" <> hex = topic
    hex != String.duplicate("0", 64)
  end

  defp decode_indexed_param(topic, "bytes32") do
    topic
  end

  defp decode_indexed_param(topic, _type) do
    # For other types, return the raw topic (could be a hash for dynamic types)
    topic
  end

  defp decode_data(data, types) do
    "0x" <> hex = data

    try do
      values = decode_abi_params(hex, types)
      {:ok, values}
    rescue
      e ->
        Logger.warning("Failed to decode data: #{inspect(e)}")
        {:error, :decode_failed}
    end
  end

  defp decode_abi_params(hex, types) do
    # Simple ABI decoding for common types
    # Each param is 32 bytes (64 hex chars)
    chunk_size = 64

    types
    |> Enum.with_index()
    |> Enum.map(fn {type, idx} ->
      start = idx * chunk_size
      chunk = String.slice(hex, start, chunk_size)
      decode_abi_value(chunk, type)
    end)
  end

  defp decode_abi_value(hex, "address") do
    "0x" <> String.slice(hex, 24, 40)
  end

  defp decode_abi_value(hex, type)
       when type in ["uint256", "uint", "uint128", "uint64", "uint32", "uint16", "uint8"] do
    {value, _} = Integer.parse(hex, 16)
    value
  end

  defp decode_abi_value(hex, type)
       when type in ["int256", "int", "int128", "int64", "int32", "int16", "int8"] do
    {value, _} = Integer.parse(hex, 16)

    # Handle two's complement for negative numbers
    bit_size =
      case type do
        "int256" -> 256
        "int" -> 256
        "int128" -> 128
        "int64" -> 64
        "int32" -> 32
        "int16" -> 16
        "int8" -> 8
      end

    max_positive = :math.pow(2, bit_size - 1) |> round()

    if value >= max_positive do
      value - round(:math.pow(2, bit_size))
    else
      value
    end
  end

  defp decode_abi_value(hex, "bool") do
    hex != String.duplicate("0", 64)
  end

  defp decode_abi_value(hex, "bytes32") do
    "0x" <> hex
  end

  defp decode_abi_value(hex, _type) do
    # Return raw hex for unknown types
    "0x" <> hex
  end

  # Helper functions to handle both map and keyword log formats
  defp get_topic(log, idx) when is_map(log) do
    topics = log["topics"] || log[:topics] || []
    Enum.at(topics, idx)
  end

  defp get_topics(log) when is_map(log) do
    log["topics"] || log[:topics] || []
  end

  defp get_data(log) when is_map(log) do
    log["data"] || log[:data]
  end

  defp get_address(log) when is_map(log) do
    addr = log["address"] || log[:address]
    if addr, do: String.downcase(addr), else: nil
  end

  defp raw_log(log) do
    %{
      address: get_address(log),
      topics: get_topics(log),
      data: get_data(log)
    }
  end
end
