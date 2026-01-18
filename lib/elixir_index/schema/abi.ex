defmodule ElixirIndex.Schema.Abi do
  use Ecto.Schema

  @primary_key false
  schema "abis" do
    field(:chain_id, Ch, type: "UInt32")
    field(:address, :string)
    field(:abi, :string)
    # "now()" defaults handled by DB, but schema must know type
    field(:created_at, :utc_datetime)
  end
end
