defmodule ElixirIndex.Schema.Transaction do
  use Ecto.Schema

  @primary_key false
  schema "transactions" do
    field(:chain_id, Ch, type: "UInt32")
    field(:block_number, Ch, type: "UInt64")
    field(:hash, :string)
    field(:from_address, :string)
    field(:to_address, :string)
    # UInt256 is huge, Ecto may treat as integer. Ch handles it.
    field(:value, Ch, type: "UInt256")
    field(:gas, Ch, type: "UInt64")
    field(:gas_price, Ch, type: "UInt256")
    field(:input, :string)
    field(:receipt_status, Ch, type: "UInt8")
    field(:timestamp, :utc_datetime)
  end
end
