# PRD: Multi-Chain EVM Indexer & Analytics Pipeline

## 1. Project Overview
A high-throughput, horizontally scalable blockchain crawler designed to index every transaction and event across multiple EVM-compatible networks (e.g., Ethereum, Polygon, BSC, Arbitrum). The system transforms raw hex logs into structured, human-readable data using contract ABIs and stores them for sub-second analytical retrieval.

## 2. Core Objectives
* **Near Real-Time Ingestion:** Track the "head" of multiple chains with minimal latency.
* **Comprehensive Coverage:** Store every transaction, receipt, and event log.
* **Structured Decoding:** Use Sourcify and stored ABIs to decode logs on-the-fly.
* **High-Performance Querying:** Enable complex analytical queries (e.g., "Total volume for X contract in the last 24h") across billions of rows.

## 3. Technical Stack
* **Language:** Elixir (BEAM) for the crawler (GenStage/Broadway for backpressure).
* **Database:** ClickHouse (Columnar storage for OLAP performance).
* **ABI Provider:** Sourcify (Contract metadata/ABI fetching).
* **Interface:** JSON-RPC (standard EVM nodes).

## 4. Functional Requirements

### 4.1. Multi-Chain Crawler (Elixir)
* **Provider Management:** Maintain a registry of RPC endpoints for different chains.
* **Backfill Mode:** High-concurrency historical indexing using worker pools.
* **Real-time Mode:** Listen for new blocks and handle chain reorganizations (reorgs).
* **Backpressure:** Use `Broadway` to ensure the database isn't overwhelmed during spikes.

### 4.2. Decoding Engine
* **ABI Fetching:** Check Sourcify for contract ABIs by address.
* **Schema Transformation:** Convert hex topics and data into structured JSON objects.
* **Fallback:** Store undecoded logs in a raw format if no ABI is found.

### 4.3. Data Storage (ClickHouse)
* **Columnar Schema:** Optimized for event filtering (e.g., by `address`, `topic0`, or `timestamp`).
* **TTL Policies:** Automated data retention policies to manage storage costs.
* **Materialized Views:** Pre-calculate aggregates (e.g., daily transaction counts) for instant dashboarding.

## 5. Technical Specifications & Data Schema

### 5.1. Transaction Table (Suggested)
| Column | Type | Description |
| :--- | :--- | :--- |
| `chain_id` | UInt32 | ID of the network |
| `block_number` | UInt64 | Height of the block |
| `hash` | FixedString(64) | Transaction hash |
| `from_address` | FixedString(42) | Sender address |
| `to_address` | FixedString(42) | Receiver address |
| `value` | UInt256 | Native token amount |
| `timestamp` | DateTime | Block timestamp |

### 5.2. Events Table (Suggested)
| Column | Type | Description |
| :--- | :--- | :--- |
| `address` | FixedString(42) | Emitting contract |
| `event_name` | String | Decoded name (e.g., Transfer) |
| `params` | JSON | Decoded parameters |
| `topic0` | FixedString(64) | Hex signature of event |

## 6. Performance Metrics (SLAs)
* **Ingestion Lag:** < 2 blocks from the chain head.
* **Query Latency:** < 500ms for filters on indexed columns across 1B+ records.
* **Write Throughput:** Capable of handling 10,000+ events/second per chain.

## 7. Future Scope
* **Trace Indexing:** Adding support for internal transactions (Geth/Erigon debug traces).
* **Webhook Subscriptions:** Allowing external apps to subscribe to filtered event streams.
* **Cross-Chain Analytics:** Correlating data across different bridge contracts.