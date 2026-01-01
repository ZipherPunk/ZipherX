#!/bin/bash

# ZipherX Wallet Verification Script
# Compares node balance & transaction history with app database
# Usage: ./verify_wallet_balance.sh <z_address>

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

ZCLASSIC_CLI="/Users/chris/ZipherX/Resources/Binaries/zclassic-cli"
DB_PATH="$HOME/Library/Application Support/ZipherX/zipherx_wallet.db"

if [ -z "$1" ]; then
    echo -e "${RED}Usage: $0 <z_address>${NC}"
    echo "Example: $0 zs13s544umnp50tmawapgwh6sxlj69v4ztxjx5fnk2v8hvmg6es7vz68exrfquy3za4eznm522dxjc"
    exit 1
fi

Z_ADDRESS="$1"

echo "========================================"
echo "ZIPHERX WALLET VERIFICATION"
echo "========================================"
echo "Address: $Z_ADDRESS"
echo ""

# Check if node is running
echo -e "${BLUE}[1/6] Checking node connection...${NC}"
if ! $ZCLASSIC_CLI getblockchaininfo >/dev/null 2>&1; then
    echo -e "${RED}ERROR: Node not running!${NC}"
    exit 1
fi
echo -e "${GREEN}✅ Node connected${NC}"
echo ""

# Get balance from NODE (reference)
echo -e "${BLUE}[2/6] Getting balance from NODE (reference)...${NC}"
NODE_BALANCE=$($ZCLASSIC_CLI z_getbalance "$Z_ADDRESS")
echo -e "Node Balance: ${GREEN}${NODE_BALANCE} ZCL${NC}"
NODE_BALANCE_ZATOSHIS=$(python3 -c "print(int(float($NODE_BALANCE) * 100000000))")
echo ""

# Get balance from APP DATABASE
echo -e "${BLUE}[3/6] Getting balance from APP DATABASE...${NC}"
APP_BALANCE=$(sqlite3 "$DB_PATH" "SELECT SUM(value) FROM notes WHERE is_spent = 0;")
APP_BALANCE_ZCL=$(python3 -c "print(f'${APP_BALANCE}'[:-6] + '.' + '${APP_BALANCE}'[-6:])")
echo -e "App Balance: ${GREEN}${APP_BALANCE_ZCL} ZCL${NC}"
echo ""

# Compare balances
echo -e "${BLUE}[4/6] Comparing balances...${NC}"
if [ "$NODE_BALANCE_ZATOSHIS" -eq "$APP_BALANCE" ]; then
    echo -e "${GREEN}✅ BALANCES MATCH!${NC}"
else
    DIFF=$((NODE_BALANCE_ZATOSHIS - APP_BALANCE))
    DIFF_ZCL=$(python3 -c "print(f'${DIFF}'[:-6] + '.' + '${DIFF}'[-6:])")
    echo -e "${RED}❌ BALANCE MISMATCH! Difference: ${DIFF_ZCL} ZCL${NC}"
    echo -e "   Node: ${NODE_BALANCE_ZCL} ZCL"
    echo -e "   App:  ${APP_BALANCE_ZCL} ZCL"
fi
echo ""

# Get transaction count from NODE
echo -e "${BLUE}[5/6] Getting transaction history from NODE...${NC}"
NODE_TX_COUNT=$($ZCLASSIC_CLI z_listreceivedbyaddress "$Z_ADDRESS" 0 | python3 -c "import sys, json; print(len(json.load(sys.stdin)))")
echo -e "Node transactions: ${GREEN}${NODE_TX_COUNT}${NC}"
echo ""

# Get transaction count from APP DATABASE
echo -e "${BLUE}[6/6] Getting transaction history from APP DATABASE...${NC}"
APP_TX_COUNT=$(sqlite3 "$DB_PATH" "SELECT COUNT(DISTINCT received_in_tx) FROM notes;")
echo -e "App transactions: ${GREEN}${APP_TX_COUNT}${NC}"
echo ""

# Check for placeholder txids
PLACEHOLDER_COUNT=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM notes WHERE hex(received_in_tx) LIKE '626F6F7374%';")
if [ "$PLACEHOLDER_COUNT" -gt 0 ]; then
    echo -e "${RED}⚠️  FOUND ${PLACEHOLDER_COUNT} PLACEHOLDER TXIDS!${NC}"
    echo -e "   These need to be resolved to real txids"
else
    echo -e "${GREEN}✅ NO PLACEHOLDER TXIDS FOUND${NC}"
fi
echo ""

# Show sample txids from node
echo "========================================"
echo "SAMPLE TRANSACTION IDs (Node vs App)"
echo "========================================"
echo ""
echo "Node txids (first 5):"
$ZCLASSIC_CLI z_listreceivedbyaddress "$Z_ADDRESS" 0 | python3 -c "
import sys, json
txs = json.load(sys.stdin)
for i, tx in enumerate(txs[:5]):
    print(f\"  {i+1}. {tx['txid']}\")
"
echo ""

echo "App txids (first 5):"
sqlite3 "$DB_PATH" "SELECT hex(received_in_tx) FROM notes WHERE received_in_tx IS NOT NULL LIMIT 5;" | while read txid; do
    # Check if it's a placeholder
    if [[ "$txid" == "626F6F73"* ]]; then
        echo -e "  ${RED}$txid (PLACEHOLDER)${NC}"
    else
        # Convert hex to readable txid
        TXIDReadable=$(echo "$txid" | python3 -c "import sys; data=sys.stdin.read().strip(); print(''.join([data[i:i+2] for i in range(0, len(data), 2)][::-1]))")
        echo -e "  ${GREEN}$TXIDReadable${NC}"
    fi
done
echo ""

echo "========================================"
echo "VERIFICATION COMPLETE"
echo "========================================"
