defmodule ElixirIndex.RPC.Client do
  @moduledoc """
  Handles JSON-RPC requests to EVM nodes.
  """
  require Logger

  @default_timeout 15_000

  def get_block_by_number(chain_id, block_number) do
    url = get_rpc_url(chain_id)
    params = ["0x" <> Integer.to_string(block_number, 16), true]

    case json_rpc_call(url, "eth_getBlockByNumber", params) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, block} -> {:ok, block}
      {:error, reason} -> {:error, reason}
    end
  end

  def get_logs(chain_id, from_block, to_block) do
    url = get_rpc_url(chain_id)

    params = [
      %{
        fromBlock: "0x" <> Integer.to_string(from_block, 16),
        toBlock: "0x" <> Integer.to_string(to_block, 16)
      }
    ]

    json_rpc_call(url, "eth_getLogs", params)
  end

  defp json_rpc_call(url, method, params) do
    body = %{
      jsonrpc: "2.0",
      method: method,
      params: params,
      id: System.unique_integer([:positive])
    }

    case Req.post(url, json: body, receive_timeout: @default_timeout) do
      {:ok, %{status: 200, body: %{"result" => result}}} ->
        {:ok, result}

      {:ok, %{status: 200, body: %{"error" => error}}} ->
        Logger.error("RPC Error: #{inspect(error)}")
        {:error, error}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_rpc_url(chain_id) do
    config = Application.get_env(:elixir_index, :rpc_endpoints, %{})
    Map.get(config, chain_id) || raise "No RPC endpoint configured for chain #{chain_id}"
  end
end
