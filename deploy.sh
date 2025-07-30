#!/usr/bin/env bash
set -euo pipefail

NETWORK=${1:-sepolia}
ENV_FILE=".env"

if [[ ! -f $ENV_FILE ]]; then
  echo "Missing $ENV_FILE. Copy .env.testnet → .env and fill in values."
  exit 1
fi
source $ENV_FILE

echo "🚀 Deploying ILInsuranceHook to $NETWORK..."
echo "📡 RPC: $RPC_URL"
echo "💰 Premium: ${FEE_BPS:-2} bps"
echo "📊 IL Threshold: ${THRESHOLD_BPS:-100} bps"

# Build contracts
echo "🔨 Building contracts..."
forge build

# Deploy hook
echo "🚀 Deploying hook..."
forge script script/DeployHook.s.sol \
  --rpc-url $RPC_URL \
  --broadcast \
  --private-key $PRIVATE_KEY \
  --verify \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  --chain $NETWORK

# Extract hook address from broadcast logs
HOOK_ADDR=$(grep 'ILInsuranceHook deployed at:' broadcast/DeployHook.s.sol/*/run-latest.json | jq -r '.logs[] | select(.topics[0] | contains("log_named_address")) | .data' | head -1 || echo "")

if [[ -n $HOOK_ADDR ]]; then
    echo "✅ Hook deployed at: $HOOK_ADDR"
    echo $HOOK_ADDR > deployments/latest.txt
else
    echo "⚠️  Could not extract hook address from logs. Check broadcast/ directory."
fi

# Output summary
cat <<EOF

✅ Deployment complete!
Hook Address: $HOOK_ADDR
Use this address when creating new pools:
  poolManager.createPool(..., hook: $HOOK_ADDR, ...)

🎯 Next Steps:
1. Verify contract on Etherscan (if not auto-verified)
2. Create test pool: forge script script/TestEndToEnd.s.sol --broadcast
3. Monitor events and test IL compensation flow
4. Deploy to mainnet when ready
EOF
