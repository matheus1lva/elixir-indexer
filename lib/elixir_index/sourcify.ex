defmodule ElixirIndex.Sourcify do
  @moduledoc """
  Client for Sourcify API to fetch contract ABIs.

  Supports proxy rotation via Cloudflare Workers to avoid rate limits.
  Configure proxies via SOURCIFY_PROXY_URLS environment variable.

  ## Configuration

      # In .env or runtime config
      SOURCIFY_PROXY_URLS=https://proxy1.workers.dev,https://proxy2.workers.dev

  The client will:
  1. Try local Sourcify first (if configured)
  2. Fall back to public Sourcify via rotating proxies
  3. Retry with exponential backoff on rate limits
  """
  use Agent
  require Logger

  @default_public_url "https://sourcify.dev/server"

  def start_link(_opts) do
    proxy_urls = parse_proxy_urls(System.get_env("SOURCIFY_PROXY_URLS"))
    Agent.start_link(fn -> %{proxy_urls: proxy_urls, current_index: 0} end, name: __MODULE__)
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent
    }
  end

  defp parse_proxy_urls(nil), do: []
  defp parse_proxy_urls(""), do: []

  defp parse_proxy_urls(urls_string) do
    urls_string
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&(&1 != ""))
  end

  def client(url) do
    Req.new(base_url: url)
  end

  @doc """
  Get the next proxy URL using round-robin rotation.
  Falls back to direct public URL if no proxies configured.
  """
  def get_next_public_url do
    Agent.get_and_update(__MODULE__, fn state ->
      case state.proxy_urls do
        [] ->
          {@default_public_url, state}

        proxies ->
          index = rem(state.current_index, length(proxies))
          url = Enum.at(proxies, index)
          {url, %{state | current_index: index + 1}}
      end
    end)
  end

  @doc """
  Returns stats about proxy configuration.
  """
  def stats do
    Agent.get(__MODULE__, fn state ->
      %{
        proxy_count: length(state.proxy_urls),
        proxy_urls: state.proxy_urls,
        current_index: state.current_index
      }
    end)
  end

  def get_abi(chain_id, address) do
    config = Application.get_env(:elixir_index, :chain)
    local_url = config[:sourcify_url] || "http://localhost:5555"

    # Try local first
    case fetch_abi(local_url, chain_id, address) do
      {:ok, abi} ->
        {:ok, abi}

      {:error, :not_found} ->
        # Fallback to public with retry and proxy rotation
        Logger.info("ABI not found locally for #{address}, trying public Sourcify...")
        fetch_abi_with_retry(chain_id, address)

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

  defp fetch_abi_with_retry(chain_id, address, attempt \\ 1) do
    # Get next proxy URL (rotates through configured proxies)
    base_url = get_next_public_url()

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
            "Rate limited on Sourcify (#{base_url}) for #{address}. " <>
              "Rotating proxy and sleeping #{sleep_ms}ms (Attempt #{attempt})"
          )

          Process.sleep(sleep_ms)
          # Next retry will use the next proxy in rotation
          fetch_abi_with_retry(chain_id, address, attempt + 1)
        else
          {:error, :rate_limited_max_retries}
        end

      {:error, reason} = error ->
        if attempt <= 3 do
          Logger.warning(
            "Error fetching from #{base_url}: #{inspect(reason)}. Trying next proxy (Attempt #{attempt})"
          )

          # Try next proxy immediately for non-rate-limit errors
          fetch_abi_with_retry(chain_id, address, attempt + 1)
        else
          error
        end
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
