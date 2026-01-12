CREATE DATABASE IF NOT EXISTS elixir_index;

-- Transactions Table
CREATE TABLE IF NOT EXISTS elixir_index.transactions (
    chain_id UInt32,
    block_number UInt64,
    hash FixedString(66),
    from_address FixedString(42),
    to_address FixedString(42),
    value UInt256,
    gas UInt64,
    gas_price UInt256,
    input String,
    receipt_status UInt8,
    timestamp DateTime
) ENGINE = MergeTree()
ORDER BY (chain_id, block_number, hash);

-- Events Table
CREATE TABLE IF NOT EXISTS elixir_index.events (
    chain_id UInt32,
    block_number UInt64,
    block_hash FixedString(66),
    transaction_hash FixedString(66),
    transaction_index UInt32,
    log_index UInt32,
    address FixedString(42),
    topic0 Nullable(FixedString(66)),
    topic1 Nullable(FixedString(66)),
    topic2 Nullable(FixedString(66)),
    topic3 Nullable(FixedString(66)),
    data String,
    event_name Nullable(String),
    params Nullable(String) -- JSON string
) ENGINE = MergeTree()
ORDER BY (chain_id, block_number, transaction_hash, log_index);
