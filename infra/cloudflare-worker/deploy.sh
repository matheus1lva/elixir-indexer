#!/bin/bash
#
# Deploy multiple Sourcify proxy workers to Cloudflare
#
# Usage:
#   ./deploy.sh                    # Deploy single worker
#   ./deploy.sh --count 5          # Deploy 5 workers (sourcify-proxy-1 through 5)
#   ./deploy.sh --account-file accounts.json  # Deploy to multiple accounts
#
# Prerequisites:
#   - Node.js installed
#   - Wrangler CLI: npm install -g wrangler
#   - Authenticated: wrangler login
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Default values
WORKER_COUNT=1
ACCOUNT_FILE=""
BASE_NAME="sourcify-proxy"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --count)
            WORKER_COUNT="$2"
            shift 2
            ;;
        --account-file)
            ACCOUNT_FILE="$2"
            shift 2
            ;;
        --name)
            BASE_NAME="$2"
            shift 2
            ;;
        --help)
            echo "Usage: $0 [--count N] [--account-file FILE] [--name BASE_NAME]"
            echo ""
            echo "Options:"
            echo "  --count N          Deploy N workers (default: 1)"
            echo "  --account-file F   JSON file with account credentials"
            echo "  --name NAME        Base name for workers (default: sourcify-proxy)"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

echo "🚀 Deploying Sourcify Proxy Workers"
echo "===================================="

# Check if wrangler is installed
if ! command -v wrangler &> /dev/null; then
    echo "❌ Wrangler CLI not found. Installing..."
    npm install -g wrangler
fi

# Function to deploy a single worker
deploy_worker() {
    local worker_num=$1
    local account_id=$2
    local api_token=$3

    local worker_name="${BASE_NAME}"
    if [ "$WORKER_COUNT" -gt 1 ]; then
        worker_name="${BASE_NAME}-${worker_num}"
    fi

    echo ""
    echo "📦 Deploying: $worker_name"

    # Create temporary wrangler.toml with custom name
    local temp_config=$(mktemp)
    sed "s/^name = .*/name = \"$worker_name\"/" wrangler.toml > "$temp_config"
    sed -i "s/WORKER_ID = .*/WORKER_ID = \"worker-$worker_num\"/" "$temp_config"

    # Deploy with or without explicit credentials
    if [ -n "$account_id" ] && [ -n "$api_token" ]; then
        CLOUDFLARE_ACCOUNT_ID="$account_id" \
        CLOUDFLARE_API_TOKEN="$api_token" \
        wrangler deploy --config "$temp_config"
    else
        wrangler deploy --config "$temp_config"
    fi

    rm "$temp_config"

    echo "✅ Deployed: $worker_name"
}

# Deploy workers
if [ -n "$ACCOUNT_FILE" ] && [ -f "$ACCOUNT_FILE" ]; then
    # Deploy to multiple accounts from file
    echo "📄 Using accounts from: $ACCOUNT_FILE"

    # Read accounts and deploy
    worker_num=1
    while IFS= read -r line; do
        account_id=$(echo "$line" | jq -r '.account_id')
        api_token=$(echo "$line" | jq -r '.api_token')

        deploy_worker "$worker_num" "$account_id" "$api_token"
        worker_num=$((worker_num + 1))
    done < <(jq -c '.accounts[]' "$ACCOUNT_FILE")
else
    # Deploy multiple workers to current account
    for i in $(seq 1 $WORKER_COUNT); do
        deploy_worker "$i" "" ""
    done
fi

echo ""
echo "===================================="
echo "✅ Deployment complete!"
echo ""
echo "Your worker URLs:"
for i in $(seq 1 $WORKER_COUNT); do
    if [ "$WORKER_COUNT" -gt 1 ]; then
        echo "  - https://${BASE_NAME}-${i}.<your-subdomain>.workers.dev"
    else
        echo "  - https://${BASE_NAME}.<your-subdomain>.workers.dev"
    fi
done
echo ""
echo "Add these URLs to your SOURCIFY_PROXY_URLS environment variable:"
echo "  export SOURCIFY_PROXY_URLS=\"url1,url2,url3\""
