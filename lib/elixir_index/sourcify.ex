defmodule ElixirIndex.Sourcify do
  @moduledoc """
  Client for Sourcify API to fetch contract ABIs.
  """
  require Logger

  def client(url) do
    Req.new(base_url: url)
  end

  def get_abi(chain_id, address) do
    config = Application.get_env(:elixir_index, :chain)
    local_url = config[:sourcify_url] || "http://localhost:5555"
    public_url = "https://sourcify.dev/server"

    # Try local first
    case fetch_abi(local_url, chain_id, address) do
      {:ok, abi} ->
        {:ok, abi}

      {:error, :not_found} ->
        # Fallback to public with retry
        Logger.info("ABI not found locally for #{address}, trying public Sourcify...")
        fetch_abi_with_retry(public_url, chain_id, address)

      error ->
        error
    end
  end

  defp fetch_abi(base_url, chain_id, address) do
    client = client(base_url)

    case Req.get(client, url: "/files/#{chain_id}/#{address}") do
      %{status: 200, body: body} ->
        parse_response(body)

      %{status: 404} ->
        {:error, :not_found}

      %{status: 429, headers: headers} ->
        retry_after =
          case Enum.find(headers, fn {k, _} -> String.downcase(k) == "retry-after" end) do
            {_, v} -> String.to_integer(v)
            # Default 5s
            nil -> 5
          end

        {:error, {:rate_limited, retry_after}}

      {:ok, %{status: status}} ->
        Logger.warning("Sourcify error #{status} for #{address}")
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_abi_with_retry(base_url, chain_id, address, attempt \\ 1) do
    case fetch_abi(base_url, chain_id, address) do
      {:ok, abi} ->
        {:ok, abi}

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, {:rate_limited, wait_s}} ->
        if attempt <= 5 do
          # Exponential backoff + jitter: wait_s * attempt + random
          sleep_ms = wait_s * 1000 + :rand.uniform(1000)

          Logger.warning(
            "Rate limited on public Sourcify for #{address}. Sleeping #{sleep_ms}ms (Attempt #{attempt})"
          )

          Process.sleep(sleep_ms)
          fetch_abi_with_retry(base_url, chain_id, address, attempt + 1)
        else
          {:error, :rate_limited_max_retries}
        end

      other ->
        other
    end
  end

  defp parse_response(files) when is_list(files) do
    files
    |> Enum.find(fn file -> file["name"] == "metadata.json" end)
    |> case do
      %{"content" => content} ->
        extract_abi(content)

      nil ->
        {:error, :metadata_not_found}
    end
  end

  defp parse_response(_), do: {:error, :invalid_response}

  defp extract_abi(content) do
    with {:ok, metadata} <- Jason.decode(content),
         %{"output" => %{"abi" => abi}} <- metadata do
      {:ok, abi}
    else
      _ -> {:error, :invalid_metadata}
    end
  end
end
