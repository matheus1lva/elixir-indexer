defmodule ElixirIndex.Schema.Event do
  use Ecto.Schema

  @primary_key false
  schema "events" do
    field(:chain_id, Ch, type: "UInt32")
    field(:block_number, Ch, type: "UInt64")
    field(:block_hash, :string)
    field(:transaction_hash, :string)
    field(:transaction_index, Ch, type: "UInt32")
    field(:log_index, Ch, type: "UInt32")
    field(:address, :string)
    field(:topic0, :string)
    field(:topic1, :string)
    field(:topic2, :string)
    field(:topic3, :string)
    field(:data, :string)
    field(:event_name, :string)
    field(:params, :string)
  end
end
