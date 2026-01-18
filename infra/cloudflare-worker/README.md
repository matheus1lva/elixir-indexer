# Sourcify Proxy Workers

This directory contains infrastructure for deploying Cloudflare Workers that proxy requests to Sourcify API, enabling IP rotation to avoid rate limits.

## Architecture

```
Your Elixir App → [Worker 1, Worker 2, ..., Worker N] → Sourcify API
                        ↓ (round-robin)
                   Different IPs per worker
```

Each Cloudflare Worker has a unique egress IP. By deploying multiple workers (especially across multiple Cloudflare accounts), you can distribute requests and avoid rate limiting.

## Quick Start

### Prerequisites

1. **Node.js** (v16 or later)
2. **Cloudflare Account** - Free tier is fine (100k requests/day per account)
3. **Wrangler CLI** - Cloudflare's deployment tool

### Step 1: Install Wrangler

```bash
npm install -g wrangler
```

### Step 2: Authenticate

```bash
wrangler login
```

This opens a browser to authenticate with your Cloudflare account.

### Step 3: Deploy a Single Worker

```bash
cd infra/cloudflare-worker
wrangler deploy
```

Your worker will be available at:
```
https://sourcify-proxy.<your-subdomain>.workers.dev
```

### Step 4: Configure Your App

Set the environment variable:

```bash
export SOURCIFY_PROXY_URLS="https://sourcify-proxy.<your-subdomain>.workers.dev"
```

## Deploying Multiple Workers

### Option A: Multiple Workers on Same Account

Deploy multiple workers with different names:

```bash
./deploy.sh --count 5
```

This creates:
- `sourcify-proxy-1.workers.dev`
- `sourcify-proxy-2.workers.dev`
- `sourcify-proxy-3.workers.dev`
- `sourcify-proxy-4.workers.dev`
- `sourcify-proxy-5.workers.dev`

**Note**: Multiple workers on the same account may share IPs, so this provides redundancy but not true IP rotation.

### Option B: Multiple Cloudflare Accounts (Recommended)

For true IP rotation, deploy workers across multiple Cloudflare accounts:

1. **Create multiple free Cloudflare accounts**
2. **Generate API tokens for each account**:
   - Go to Cloudflare Dashboard → Profile → API Tokens
   - Create token with "Edit Cloudflare Workers" permission
   - Note the Account ID from the dashboard sidebar

3. **Create accounts.json** (copy from accounts.example.json):
   ```json
   {
     "accounts": [
       {
         "account_id": "abc123...",
         "api_token": "token1...",
         "comment": "Account 1"
       },
       {
         "account_id": "def456...",
         "api_token": "token2...",
         "comment": "Account 2"
       }
     ]
   }
   ```

4. **Deploy to all accounts**:
   ```bash
   ./deploy.sh --account-file accounts.json
   ```

5. **Configure your app with all worker URLs**:
   ```bash
   export SOURCIFY_PROXY_URLS="https://sourcify-proxy.acc1.workers.dev,https://sourcify-proxy.acc2.workers.dev"
   ```

## Configuration Options

### Worker Configuration (wrangler.toml)

```toml
name = "sourcify-proxy"        # Worker name
main = "src/index.js"          # Entry point

[vars]
WORKER_ID = "worker-1"         # Identifier for debugging
```

### Application Configuration

Environment variables:

| Variable | Description | Default |
|----------|-------------|---------|
| `SOURCIFY_PROXY_URLS` | Comma-separated list of proxy URLs | (none - uses direct) |
| `SOURCIFY_DIRECT_URL` | Direct Sourcify URL (fallback) | `https://sourcify.dev/server` |
| `SOURCIFY_TIMEOUT` | Request timeout in ms | `30000` |
| `SOURCIFY_MAX_RETRIES` | Max retry attempts | `3` |
| `SOURCIFY_CACHE_TTL` | ABI cache TTL in ms | `86400000` (24h) |

## Usage in Elixir

```elixir
# Get ABI for a contract
{:ok, abi} = ElixirIndex.Sourcify.Client.get_abi(1, "0x1234...")

# Check if contract is verified
{:ok, :full} = ElixirIndex.Sourcify.Client.check_verified(1, "0x1234...")

# Decode event logs
{:ok, decoded} = ElixirIndex.Sourcify.Decoder.decode_log(log, chain_id)

# Get client stats
stats = ElixirIndex.Sourcify.Client.stats()
# => %{proxy_count: 5, cache_size: 100, ...}
```

## Rate Limiting Strategy

1. **Round-Robin Rotation**: Each request goes to the next worker in sequence
2. **Automatic Retry**: On 429 (rate limit), waits with exponential backoff
3. **ABI Caching**: ABIs are cached for 24 hours to minimize repeat requests
4. **Known Events**: Common events (ERC20 Transfer, etc.) are decoded without ABI fetch

## Troubleshooting

### "Error: No workers deployed"
Run `wrangler deploy` first.

### "Error: Rate limited"
Add more proxy workers or wait for rate limit to reset.

### "Error: ABI not found"
The contract may not be verified on Sourcify. Check at https://sourcify.dev

### Checking Worker Logs
```bash
wrangler tail sourcify-proxy
```

## Security Notes

- Workers only proxy to allowed Sourcify API paths
- No credentials or sensitive data are logged
- Workers don't store any data (stateless)

## Cost

- Cloudflare Workers free tier: 100,000 requests/day per account
- No bandwidth charges for worker execution
- Multiple free accounts can be created for more capacity
