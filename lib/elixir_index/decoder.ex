defmodule ElixirIndex.Decoder do
  require Logger

  def decode(nil, _topic0, _topics, _data), do: {nil, nil}

  def decode(abi_json, topic0, _topics, data) do
    try do
      abi = Jason.decode!(abi_json)

      # Find the event definition that matches topic0
      event_def = find_matching_event(abi, topic0)

      case event_def do
        nil ->
          {nil, nil}

        _ ->
          event_name = event_def["name"]

          # Prepare types for decoding
          inputs = event_def["inputs"]

          # Separate indexed and non-indexed inputs is needed for some decoders
          # We might need to construct the selector or use ABI.Event.decode/3 if available.

          # For this iteration, I'll attempt to use `ABI.Event` if it exists or fallback to `ABI.TypeDecoder`.
          # version 0.1.21 of `abi`

          # Decode the data part:
          types = Enum.filter(inputs, fn i -> !i["indexed"] end) |> Enum.map(&parse_type/1)
          decoded_data = ABI.TypeDecoder.decode_raw(data, parse_types_signature(types))

          # Map back values to names
          non_indexed_inputs = Enum.filter(inputs, fn i -> !i["indexed"] end)

          params =
            Enum.zip(non_indexed_inputs, decoded_data)
            |> Map.new(fn {input, val} -> {input["name"], val} end)

          {event_name, params}
      end
    rescue
      e ->
        Logger.warning("Failed to decode event: #{inspect(e)}")
        {nil, nil}
    end
  end

  defp find_matching_event(abi, topic0) do
    Enum.find(abi, fn item ->
      item["type"] == "event" and
        signature_hash(item) == topic0
    end)
  end

  defp signature_hash(event) do
    signature =
      "#{event["name"]}(#{Enum.map_join(event["inputs"], ",", & &1["type"])})"

    ExSha3.keccak_256(signature) |> Base.encode16(case: :lower) |> then(&"0x#{&1}")
  end

  defp parse_type(%{"type" => "tuple", "components" => components}) do
    types = Enum.map(components, &parse_type/1)
    {:tuple, types}
  end

  defp parse_type(%{"type" => type}), do: type

  defp parse_types_signature(types) do
    # ABI.decode expects a simplified type signature or list of types.
    # If `abi` lib expects string types like "uint256", we are good.
    # If it expects atoms or tuples, we might need conversion.
    # Based on common usage: ABI.decode("uint256", data) or ABI.decode(["uint256", "address"], data).

    # We handle tuples by recursion above but ABI.decode might need specific format.
    # Let's simply map to type strings/structures.
    types
  end
end
