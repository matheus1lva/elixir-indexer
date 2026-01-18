defmodule ElixirIndex.Sourcify.Client do
  @moduledoc """
  Sourcify API client with proxy rotation support.

  This client can route requests through multiple Cloudflare Worker proxies
  to avoid rate limiting. It supports:

  - Round-robin proxy rotation
  - Automatic retry with backoff on rate limits
  - ABI caching via ETS
  - Direct Sourcify access as fallback

  ## Configuration

  Configure in your config files:

      config :elixir_index, ElixirIndex.Sourcify.Client,
        proxy_urls: ["https://proxy1.workers.dev", "https://proxy2.workers.dev"],
        direct_url: "https://sourcify.dev/server",
        timeout: 30_000,
        max_retries: 3,
        cache_ttl: :timer.hours(24)

  Or via environment variables:

      SOURCIFY_PROXY_URLS=https://proxy1.workers.dev,https://proxy2.workers.dev
      SOURCIFY_DIRECT_URL=https://sourcify.dev/server
  """

  use GenServer
  require Logger

  @default_direct_url "https://sourcify.dev/server"
  @default_timeout 30_000
  @default_max_retries 3
  @default_cache_ttl :timer.hours(24)

  # ETS table for caching ABIs
  @cache_table :sourcify_abi_cache

  # State
  defstruct [
    :proxy_urls,
    :direct_url,
    :timeout,
    :max_retries,
    :cache_ttl,
    :current_proxy_index
  ]

  # ============================================================================
  # Client API
  # ============================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Fetches the ABI for a contract address on a given chain.

  Returns `{:ok, abi}` where abi is a list of ABI entries, or `{:error, reason}`.

  ## Examples

      {:ok, abi} = ElixirIndex.Sourcify.Client.get_abi(1, "0x1234...")
  """
  def get_abi(chain_id, address) do
    GenServer.call(__MODULE__, {:get_abi, chain_id, address}, 60_000)
  end

  @doc """
  Fetches contract metadata including ABI and source files.

  Returns full match first, then partial match if available.
  """
  def get_contract_files(chain_id, address) do
    GenServer.call(__MODULE__, {:get_contract_files, chain_id, address}, 60_000)
  end

  @doc """
  Checks if a contract is verified on Sourcify.

  Returns `{:ok, :full | :partial}` or `{:error, :not_verified}`.
  """
  def check_verified(chain_id, address) do
    GenServer.call(__MODULE__, {:check_verified, chain_id, address}, 30_000)
  end

  @doc """
  Clears the ABI cache for a specific contract or all contracts.
  """
  def clear_cache(chain_id \\ nil, address \\ nil) do
    GenServer.cast(__MODULE__, {:clear_cache, chain_id, address})
  end

  @doc """
  Returns statistics about the client (proxy count, cache size, etc).
  """
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    # Create ETS cache table
    :ets.new(@cache_table, [:named_table, :public, read_concurrency: true])

    config = Application.get_env(:elixir_index, __MODULE__, [])

    proxy_urls =
      opts[:proxy_urls] ||
        config[:proxy_urls] ||
        parse_proxy_urls(System.get_env("SOURCIFY_PROXY_URLS"))

    state = %__MODULE__{
      proxy_urls: proxy_urls || [],
      direct_url:
        opts[:direct_url] ||
          config[:direct_url] ||
          System.get_env("SOURCIFY_DIRECT_URL") ||
          @default_direct_url,
      timeout: opts[:timeout] || config[:timeout] || @default_timeout,
      max_retries: opts[:max_retries] || config[:max_retries] || @default_max_retries,
      cache_ttl: opts[:cache_ttl] || config[:cache_ttl] || @default_cache_ttl,
      current_proxy_index: 0
    }

    Logger.info(
      "Sourcify client started with #{length(state.proxy_urls)} proxies, " <>
        "direct_url=#{state.direct_url}"
    )

    {:ok, state}
  end

  @impl true
  def handle_call({:get_abi, chain_id, address}, _from, state) do
    address = normalize_address(address)
    cache_key = {chain_id, address, :abi}

    case get_cached(cache_key, state.cache_ttl) do
      {:ok, abi} ->
        {:reply, {:ok, abi}, state}

      :miss ->
        {result, new_state} = fetch_abi_with_retry(chain_id, address, state)

        case result do
          {:ok, abi} ->
            cache_put(cache_key, abi)
            {:reply, {:ok, abi}, new_state}

          error ->
            {:reply, error, new_state}
        end
    end
  end

  @impl true
  def handle_call({:get_contract_files, chain_id, address}, _from, state) do
    address = normalize_address(address)
    {result, new_state} = fetch_contract_files_with_retry(chain_id, address, state)
    {:reply, result, new_state}
  end

  @impl true
  def handle_call({:check_verified, chain_id, address}, _from, state) do
    address = normalize_address(address)
    {result, new_state} = check_verified_with_retry(chain_id, address, state)
    {:reply, result, new_state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    cache_size = :ets.info(@cache_table, :size)

    stats = %{
      proxy_count: length(state.proxy_urls),
      proxy_urls: state.proxy_urls,
      direct_url: state.direct_url,
      current_proxy_index: state.current_proxy_index,
      cache_size: cache_size,
      timeout: state.timeout,
      max_retries: state.max_retries
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_cast({:clear_cache, nil, nil}, state) do
    :ets.delete_all_objects(@cache_table)
    Logger.info("Sourcify ABI cache cleared")
    {:noreply, state}
  end

  @impl true
  def handle_cast({:clear_cache, chain_id, address}, state) do
    address = normalize_address(address)
    :ets.delete(@cache_table, {chain_id, address, :abi})
    Logger.info("Sourcify ABI cache cleared for #{chain_id}/#{address}")
    {:noreply, state}
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp parse_proxy_urls(nil), do: nil
  defp parse_proxy_urls(""), do: nil

  defp parse_proxy_urls(urls_string) do
    urls_string
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&(&1 != ""))
  end

  defp normalize_address(address) do
    address
    |> String.downcase()
    |> case do
      "0x" <> _ = addr -> addr
      addr -> "0x" <> addr
    end
  end

  defp get_cached(key, ttl) do
    case :ets.lookup(@cache_table, key) do
      [{^key, value, timestamp}] ->
        if System.monotonic_time(:millisecond) - timestamp < ttl do
          {:ok, value}
        else
          :ets.delete(@cache_table, key)
          :miss
        end

      [] ->
        :miss
    end
  end

  defp cache_put(key, value) do
    timestamp = System.monotonic_time(:millisecond)
    :ets.insert(@cache_table, {key, value, timestamp})
  end

  defp fetch_abi_with_retry(chain_id, address, state) do
    fetch_with_retry(
      fn base_url ->
        # Try full match first
        url = "#{base_url}/files/any/#{chain_id}/#{address}"
        fetch_abi_from_url(url, state.timeout)
      end,
      state
    )
  end

  defp fetch_contract_files_with_retry(chain_id, address, state) do
    fetch_with_retry(
      fn base_url ->
        url = "#{base_url}/files/any/#{chain_id}/#{address}"
        fetch_json(url, state.timeout)
      end,
      state
    )
  end

  defp check_verified_with_retry(chain_id, address, state) do
    fetch_with_retry(
      fn base_url ->
        url = "#{base_url}/check-all-by-addresses?addresses=#{address}&chainIds=#{chain_id}"

        case fetch_json(url, state.timeout) do
          {:ok, [%{"status" => status} | _]} when status in ["full", "partial"] ->
            {:ok, String.to_atom(status)}

          {:ok, _} ->
            {:error, :not_verified}

          error ->
            error
        end
      end,
      state
    )
  end

  defp fetch_with_retry(fetch_fn, state, attempt \\ 1) do
    {base_url, new_state} = get_next_url(state)

    case fetch_fn.(base_url) do
      {:ok, _} = success ->
        {success, new_state}

      {:error, :rate_limited} when attempt < state.max_retries ->
        # Exponential backoff: 1s, 2s, 4s
        backoff = :timer.seconds(round(:math.pow(2, attempt - 1)))
        Logger.warning("Rate limited, retrying in #{backoff}ms (attempt #{attempt})")
        Process.sleep(backoff)
        fetch_with_retry(fetch_fn, new_state, attempt + 1)

      {:error, :timeout} when attempt < state.max_retries ->
        Logger.warning("Timeout, retrying (attempt #{attempt})")
        fetch_with_retry(fetch_fn, new_state, attempt + 1)

      {:error, _} = error when attempt < state.max_retries ->
        # Try next proxy
        fetch_with_retry(fetch_fn, new_state, attempt + 1)

      error ->
        {error, new_state}
    end
  end

  defp get_next_url(%{proxy_urls: []} = state) do
    {state.direct_url, state}
  end

  defp get_next_url(state) do
    index = rem(state.current_proxy_index, length(state.proxy_urls))
    url = Enum.at(state.proxy_urls, index)
    new_state = %{state | current_proxy_index: index + 1}
    {url, new_state}
  end

  defp fetch_abi_from_url(url, timeout) do
    case fetch_json(url, timeout) do
      {:ok, %{"files" => files}} ->
        extract_abi_from_files(files)

      {:ok, files} when is_list(files) ->
        extract_abi_from_files(files)

      error ->
        error
    end
  end

  defp extract_abi_from_files(files) do
    abi_file =
      Enum.find(files, fn file ->
        name = file["name"] || ""
        String.ends_with?(name, "metadata.json") || name == "metadata.json"
      end)

    case abi_file do
      %{"content" => content} when is_binary(content) ->
        case Jason.decode(content) do
          {:ok, %{"output" => %{"abi" => abi}}} -> {:ok, abi}
          {:ok, %{"abi" => abi}} -> {:ok, abi}
          _ -> {:error, :invalid_metadata}
        end

      nil ->
        # Try to find direct ABI file
        direct_abi =
          Enum.find(files, fn file ->
            name = file["name"] || ""
            String.ends_with?(name, ".abi.json") || name == "abi.json"
          end)

        case direct_abi do
          %{"content" => content} when is_binary(content) ->
            Jason.decode(content)

          _ ->
            {:error, :no_abi_found}
        end
    end
  end

  defp fetch_json(url, timeout) do
    case Req.get(url, receive_timeout: timeout) do
      {:ok, %{status: 200, body: body}} when is_map(body) or is_list(body) ->
        {:ok, body}

      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        Jason.decode(body)

      {:ok, %{status: 429}} ->
        {:error, :rate_limited}

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, :timeout}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
