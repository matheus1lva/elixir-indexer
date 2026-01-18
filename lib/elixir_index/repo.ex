defmodule ElixirIndex.Repo do
  use Ecto.Repo,
    otp_app: :elixir_index,
    adapter: Ecto.Adapters.ClickHouse
end
