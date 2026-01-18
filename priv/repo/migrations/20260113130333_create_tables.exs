defmodule ElixirIndex.Repo.Migrations.CreateTables do
  use Ecto.Migration

  def change do
    create_if_not_exists table("transactions",
                           engine: "MergeTree",
                           primary_key: false,
                           options: "ORDER BY (chain_id, block_number, hash)"
                         ) do
      add(:chain_id, :UInt32)
      add(:block_number, :UInt64)
      add(:hash, :string)
      add(:from_address, :string)
      add(:to_address, :string)
      add(:value, :UInt256)
      add(:gas, :UInt64)
      add(:gas_price, :UInt256)
      add(:input, :String)
      add(:receipt_status, :UInt8)
      add(:timestamp, :DateTime)
    end

    create_if_not_exists table("events",
                           engine: "MergeTree",
                           primary_key: false,
                           options:
                             "ORDER BY (chain_id, block_number, transaction_hash, log_index)"
                         ) do
      add(:chain_id, :UInt32)
      add(:block_number, :UInt64)
      add(:block_hash, :string)
      add(:transaction_hash, :string)
      add(:transaction_index, :UInt32)
      add(:log_index, :UInt32)
      add(:address, :string)
      add(:topic0, :string)
      add(:topic1, :string)
      add(:topic2, :string)
      add(:topic3, :string)
      add(:data, :String)
      add(:event_name, :String)
      add(:params, :String)
    end

    create_if_not_exists table("abis",
                           engine: "MergeTree",
                           primary_key: false,
                           options: "ORDER BY (chain_id, address)"
                         ) do
      add(:chain_id, :UInt32)
      add(:address, :string)
      add(:abi, :String)
      add(:created_at, :DateTime, default: fragment("now()"))
    end
  end
end
