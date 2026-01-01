#!/bin/bash

# ZipherX Import PK Monitor Script
# Watches the app in real-time and provides continuous analysis

LOG_FILE="/Users/chris/ZipherX/zmac.log"
LAST_SIZE=0
CHECK_COUNT=0

echo "========================================"
echo "IMPORT PK MONITORING STARTED"
echo "========================================"
echo "Watching for: boost download, witness creation, txids, errors"
echo ""

while true; do
    if [ ! -f "$LOG_FILE" ]; then
        echo "⏳ Waiting for log file to be created..."
        sleep 2
        continue
    fi

    CURRENT_SIZE=$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)

    if [ "$CURRENT_SIZE" -gt "$LAST_SIZE" ]; then
        # Get new lines only
        NEW_CONTENT=$(tail -c +"$((LAST_SIZE + 1))" "$LOG_FILE" 2>/dev/null)
        LAST_SIZE=$CURRENT_SIZE

        # Analyze new content
        CHECK_COUNT=$((CHECK_COUNT + 1))

        # Check for boost download progress
        if echo "$NEW_CONTENT" | grep -q "boost\|Boost\|download\|Download\|Progress"; then
            echo ""
            echo "📥 [$CHECK_COUNT] BOOST DOWNLOAD:"
            echo "$NEW_CONTENT" | grep -E "(boost|Boost|download|Download|Progress|MB|%)"
        fi

        # Check for witness creation
        if echo "$NEW_CONTENT" | grep -q "witness\|Witness\|merkle\|tree"; then
            echo ""
            echo "🌳 [$CHECK_COUNT] WITNESS/TREE:"
            echo "$NEW_CONTENT" | grep -E "(witness|Witness|merkle|Merkle|tree|Tree|path|Path)"
        fi

        # Check for txid/placeholder issues
        if echo "$NEW_CONTENT" | grep -q "txid\|placeholder\|boost_"; then
            echo ""
            echo "🔍 [$CHECK_COUNT] TXID CHECK:"
            echo "$NEW_CONTENT" | grep -E "(txid|placeholder|boost_|boos_)"

            # ALERT: If placeholder found
            if echo "$NEW_CONTENT" | grep -q "boos_\|boost_"; then
                echo "⚠️ WARNING: PLACEHOLDER DETECTED!"
            fi
        fi

        # Check for errors
        if echo "$NEW_CONTENT" | grep -qi "error\|failed\|Failed\|ERROR"; then
            echo ""
            echo "❌ [$CHECK_COUNT] ERROR DETECTED:"
            echo "$NEW_CONTENT" | grep -Ei "(error|failed|ERROR|Failed)"
        fi

        # Check for witness merkle path issues (FIX #458)
        if echo "$NEW_CONTENT" | grep -q "merkle path\|witness.path"; then
            echo ""
            echo "🔑 [$CHECK_COUNT] MERKLE PATH (FIX #458):"
            echo "$NEW_CONTENT" | grep -E "(merkle path|witness.path)"

            # Check if path() returned None
            if echo "$NEW_CONTENT" | grep -q "path.*None\|Failed to get merkle path"; then
                echo "❌ FIX #458 FAILED: Witness has no merkle path!"
            fi
        fi

        # Check for success/completion
        if echo "$NEW_CONTENT" | grep -qi "success\|complete\|finished\|done\|Imported"; then
            echo ""
            echo "✅ [$CHECK_COUNT] PROGRESS:"
            echo "$NEW_CONTENT" | grep -Ei "(success|complete|finished|done|Imported|% complete)"
        fi

        # Show headers loaded
        if echo "$NEW_CONTENT" | grep -q "headers\|Headers\|Loaded.*headers"; then
            echo ""
            echo "📊 [$CHECK_COUNT] HEADERS:"
            echo "$NEW_CONTENT" | grep -E "(headers|Headers|Loaded)"
        fi

        # Check for notes found
        if echo "$NEW_CONTENT" | grep -q "notes found\|Notes found\|scan complete"; then
            echo ""
            echo "📝 [$CHECK_COUNT] SCAN RESULTS:"
            echo "$NEW_CONTENT" | grep -E "(notes found|Notes found|scan complete|shielded)"
        fi
    fi

    sleep 1
done
