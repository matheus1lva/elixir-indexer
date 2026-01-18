import Config

config :elixir_index,
  rpc_endpoints: %{
    1 => "https://eth.llamarpc.com",
    56 => "https://binance.llamarpc.com"
  }

config :elixir_index, ElixirIndex.Repo,
  database: System.get_env("CLICKHOUSE_DATABASE", "elixir_index"),
  username: System.get_env("CLICKHOUSE_USER", "default"),
  password: System.get_env("CLICKHOUSE_PASSWORD", ""),
  hostname: System.get_env("CLICKHOUSE_HOST", "localhost"),
  port: String.to_integer(System.get_env("CLICKHOUSE_PORT", "8123")),
  scheme: "http"

config :elixir_index, ecto_repos: [ElixirIndex.Repo]
