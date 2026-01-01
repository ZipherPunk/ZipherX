#!/bin/bash

# Direct database monitoring for Import PK
# Checks the actual database state without needing log files

DB_PATH="$HOME/Library/Containers/com.zipherpunk.zipherx/Data/Documents/wallet.db"
ALT_DB_PATH="$HOME/Library/Containers/com.zipherpunk.zipherx/Data/Documents/wallet-wallet.dat.db"

echo "========================================"
echo "IMPORT PK DATABASE MONITOR"
echo "========================================"
echo ""

find_db() {
    if [ -f "$DB_PATH" ]; then
        echo "$DB_PATH"
    elif [ -f "$ALT_DB_PATH" ]; then
        echo "$ALT_DB_PATH"
    else
        # Try to find any wallet database
        find "$HOME/Library/Containers" -name "wallet*.db" -type f 2>/dev/null | head -1
    fi
}

DB=$(find_db)

if [ -z "$DB" ] || [ ! -f "$DB" ]; then
    echo "⏳ Waiting for database to be created..."
    echo "   (Start Import PK in the app)"
    sleep 3
    exec "$0"  # Restart
fi

echo "📂 Database: $DB"
echo ""

CHECK_COUNT=0
while true; do
    CHECK_COUNT=$((CHECK_COUNT + 1))
    clear
    echo "========================================"
    echo "IMPORT PK MONITOR - CHECK #$CHECK_COUNT"
    echo "Time: $(date '+%H:%M:%S')"
    echo "========================================"
    echo ""

    # Count notes
    NOTE_COUNT=$(sqlite3 "$DB" "SELECT COUNT(*) FROM notes;" 2>/dev/null || echo 0)
    echo "📝 Notes found: $NOTE_COUNT"

    # Count unspent notes
    UNSPENT_COUNT=$(sqlite3 "$DB" "SELECT COUNT(*) FROM notes WHERE is_spent = 0;" 2>/dev/null || echo 0)
    echo "💰 Unspent notes: $UNSPENT_COUNT"

    # Get balance
    BALANCE=$(sqlite3 "$DB" "SELECT SUM(value) FROM notes WHERE is_spent = 0;" 2>/dev/null || echo 0)
    if [ "$BALANCE" -gt 0 ]; then
        BALANCE_ZCL=$(echo "scale=8; $BALANCE / 100000000" | bc)
        echo "   Balance: ${BALANCE_ZCL} ZCL"
    fi

    echo ""

    # Check for placeholder txids
    PLACEHOLDER_COUNT=$(sqlite3 "$DB" "SELECT COUNT(*) FROM notes WHERE spent_in_tx LIKE 'boos_%' OR received_in_tx LIKE 'boos_%';" 2>/dev/null || echo 0)
    if [ "$PLACEHOLDER_COUNT" -gt 0 ]; then
        echo "⚠️  PLACEHOLDER TXIDS: $PLACEHOLDER_COUNT"
        echo "   This indicates OLD database or OLD boost file!"
    else
        echo "✅ No placeholder txids found"
    fi

    echo ""

    # Check real txids
    REAL_TXID_COUNT=$(sqlite3 "$DB" "SELECT COUNT(*) FROM notes WHERE length(spent_in_tx) = 32 OR length(received_in_tx) = 32;" 2>/dev/null || echo 0)
    echo "🔑 Notes with real txids: $REAL_TXID_COUNT"

    echo ""

    # Show latest notes
    echo "📋 Latest 5 notes:"
    sqlite3 -column -header "$DB" "SELECT value, is_spent, substr(hex(received_in_tx), 1, 16) as txid FROM notes ORDER BY rowid DESC LIMIT 5;" 2>/dev/null || echo "   No notes yet"

    echo ""
    echo "Press Ctrl+C to stop monitoring"
    echo "========================================"

    sleep 2
done
