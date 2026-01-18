# Sourcify Proxy Workers

Cloudflare Workers that proxy requests to Sourcify API, enabling IP rotation to avoid rate limits.

## Architecture

```
Elixir Indexer → Local Sourcify (if available)
                      ↓ (not found)
              → [Proxy 1, Proxy 2, ..., Proxy N] → Sourcify API
                      ↓ (round-robin rotation)
                 Different IPs per worker
```

## Quick Start

### 1. Install Wrangler CLI

```bash
npm install -g wrangler
```

### 2. Authenticate

```bash
wrangler login
```

### 3. Deploy Workers

```bash
cd infra/cloudflare-worker

# Single worker
wrangler deploy

# Or multiple workers
./deploy.sh --count 3
```

### 4. Configure Your App

Add worker URLs to your `.env`:

```bash
SOURCIFY_PROXY_URLS=https://sourcify-proxy-1.yoursubdomain.workers.dev,https://sourcify-proxy-2.yoursubdomain.workers.dev
```

## Multi-Account Deployment (True IP Rotation)

For true IP rotation, deploy workers across multiple Cloudflare accounts:

1. Create multiple free Cloudflare accounts
2. Generate API tokens (Profile → API Tokens → "Edit Cloudflare Workers")
3. Create `accounts.json`:

```json
{
  "accounts": [
    {"account_id": "abc123", "api_token": "token1"},
    {"account_id": "def456", "api_token": "token2"}
  ]
}
```

4. Deploy:

```bash
./deploy.sh --account-file accounts.json
```

## How It Works

1. **Local First**: The indexer tries your local Sourcify instance
2. **Proxy Rotation**: If not found locally, requests go through proxies in round-robin
3. **Rate Limit Handling**: On 429 errors, waits with exponential backoff and tries next proxy
4. **Automatic Retry**: Failed requests automatically try the next proxy

## Cost

- Cloudflare Workers free tier: **100,000 requests/day per account**
- No bandwidth charges
- Multiple free accounts = more capacity

## Files

- `src/index.js` - Worker code (transparent proxy)
- `wrangler.toml` - Wrangler configuration
- `deploy.sh` - Multi-worker deployment script
- `accounts.example.json` - Template for multi-account setup

## Checking Proxy Stats

In IEx:

```elixir
ElixirIndex.Sourcify.stats()
# => %{proxy_count: 3, proxy_urls: [...], current_index: 5}
```
