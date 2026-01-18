import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# Load .env file
if File.exists?(".env") do
  Dotenvy.source!(".env")
  |> Enum.each(fn {k, v} -> System.put_env(k, v) end)
end

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

# Chains Configuration
# Format: SUPPORTED_CHAINS="1,56"
# RPCs: RPC_URL_1=..., RPC_URL_56=...
if supported_chains = System.get_env("SUPPORTED_CHAINS") do
  rpc_endpoints =
    supported_chains
    |> String.split(",", trim: true)
    |> Map.new(fn chain_id_str ->
      chain_id = String.to_integer(chain_id_str)
      url = System.get_env("RPC_URL_#{chain_id}")

      if is_nil(url) do
        raise "Missing RPC URL for chain #{chain_id}. Please set RPC_URL_#{chain_id}"
      end

      {chain_id, url}
    end)

  start_block = System.get_env("START_BLOCK", "0") |> String.to_integer()

  IO.puts(
    "Configuring Chain #{System.get_env("SUPPORTED_CHAINS")} with START_BLOCK: #{start_block}"
  )

  config :elixir_index, rpc_endpoints: rpc_endpoints, start_block: start_block
end
