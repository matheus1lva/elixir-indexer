import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

if config_env() == :prod do
  # ClickHouse Configuration
  config :ch,
    default: [
      scheme: "http",
      hostname: System.get_env("CLICKHOUSE_HOST", "localhost"),
      port: System.get_env("CLICKHOUSE_PORT", "8123") |> String.to_integer(),
      database: System.get_env("CLICKHOUSE_DATABASE", "default"),
      username: System.get_env("CLICKHOUSE_USER", "default"),
      password: System.get_env("CLICKHOUSE_PASSWORD", "")
    ]
end

# Chains Configuration (Applies to all environments if set)
# Format: CHAINS="1=https://eth.rpc,137=https://poly.rpc"
if chains_env = System.get_env("CHAINS") do
  rpc_endpoints =
    chains_env
    |> String.split(",", trim: true)
    |> Map.new(fn entry ->
      [chain_id, url] = String.split(entry, "=", parts: 2)
      {String.to_integer(chain_id), url}
    end)

  config :elixir_index, rpc_endpoints: rpc_endpoints
end

# Sourcify Configuration
# Format: SOURCIFY_PROXY_URLS="https://proxy1.workers.dev,https://proxy2.workers.dev"
config :elixir_index, ElixirIndex.Sourcify.Client,
  proxy_urls:
    case System.get_env("SOURCIFY_PROXY_URLS") do
      nil -> []
      "" -> []
      urls -> String.split(urls, ",", trim: true) |> Enum.map(&String.trim/1)
    end,
  direct_url: System.get_env("SOURCIFY_DIRECT_URL", "https://sourcify.dev/server"),
  timeout: String.to_integer(System.get_env("SOURCIFY_TIMEOUT", "30000")),
  max_retries: String.to_integer(System.get_env("SOURCIFY_MAX_RETRIES", "3")),
  cache_ttl: String.to_integer(System.get_env("SOURCIFY_CACHE_TTL", "86400000"))
