import Config

config :elixir_index,
  rpc_endpoints: %{
    # Example: chain_id => url
    1 => System.get_env("ETH_RPC_URL", "https://rpc.ankr.com/eth")
  }

config :ch,
  default: [
    scheme: "http",
    hostname: System.get_env("CLICKHOUSE_HOST", "localhost"),
    port: System.get_env("CLICKHOUSE_PORT", "8123") |> String.to_integer(),
    database: System.get_env("CLICKHOUSE_DATABASE", "default")
  ]

import_config "#{config_env()}.exs"
