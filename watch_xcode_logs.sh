#!/bin/bash

# Monitor Xcode console output in real-time
# Uses log stream to capture app logs

echo "========================================"
echo "XCODE CONSOLE MONITOR"
echo "========================================"
echo "Waiting for Import PK to start..."
echo ""

# Monitor system logs for ZipherX app
log stream --predicate 'process == "ZipherX" OR processImagePath contains "ZipherX"' --level debug \
  | while read line; do

    # Show only relevant lines
    if echo "$line" | grep -qE "(boost|witness|txid|Import|notes|balance|ERROR|Failed|✅|❌|⚠️|%)"; then
        echo "$line"

        # Alert for placeholders
        if echo "$line" | grep -q "boos_\|boost_"; then
            echo "⚠️ WARNING: PLACEHOLDER DETECTED!"
        fi

        # Alert for witness issues
        if echo "$line" | grep -q "merkle path.*None\|Failed to get merkle"; then
            echo "❌ FIX #458 ISSUE: Witness has no merkle path!"
        fi

        # Alert for errors
        if echo "$line" | grep -qiE "error|failed"; then
            echo "❌ ERROR DETECTED!"
        fi
    fi

done
