#!/bin/bash

# =============================================================================
# ZipherX Log Analyzer - ENHANCED VERSION 2.0
# =============================================================================
# Performs deep, accurate analysis of zmac.log or z.log
# Usage: ./analyze_log.sh [zmac|ios|path/to/logfile]
#
# Version 2.0 Features:
# - Accurate feature detection (checks actual function calls, not just strings)
# - Real-time peer count tracking
# - Connection success rate calculation
# - Peer churn analysis
# - Performance bottleneck identification
# - Actionable recommendations
# =============================================================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# =============================================================================
# Determine log file
# =============================================================================
if [ -z "$1" ]; then
    echo -e "${CYAN}Select log file to analyze:${NC}"
    echo "  1) zmac.log (macOS)"
    echo "  2) z.log (iOS Simulator)"
    read -p "Enter choice [1/2]: " choice
    case $choice in
        1) LOGFILE="/Users/chris/ZipherX/zmac.log" ;;
        2) LOGFILE="/Users/chris/ZipherX/z.log" ;;
        *) echo "Invalid choice"; exit 1 ;;
    esac
elif [ "$1" = "zmac" ]; then
    LOGFILE="/Users/chris/ZipherX/zmac.log"
elif [ "$1" = "ios" ]; then
    LOGFILE="/Users/chris/ZipherX/z.log"
else
    LOGFILE="$1"
fi

if [ ! -f "$LOGFILE" ]; then
    echo -e "${RED}Error: Log file not found: $LOGFILE${NC}"
    exit 1
fi

# =============================================================================
# Header
# =============================================================================
echo ""
echo -e "${BOLD}${MAGENTA}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${MAGENTA}║         ZIPHERX LOG ANALYZER v2.0 - DEEP ANALYSIS              ║${NC}"
echo -e "${BOLD}${MAGENTA}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${CYAN}Analyzing:${NC} $LOGFILE"
echo -e "${CYAN}File size:${NC} $(du -h "$LOGFILE" | cut -f1)"
echo -e "${CYAN}Line count:${NC} $(wc -l < "$LOGFILE")"

# Time range
FIRST_TIME=$(head -1 "$LOGFILE" | grep -oE "\[[0-9]+:[0-9]+:[0-9]+\.[0-9]+\]" | tr -d '[]' || echo "unknown")
LAST_TIME=$(tail -1 "$LOGFILE" | grep -oE "\[[0-9]+:[0-9]+:[0-9]+\.[0-9]+\]" | tr -d '[]' || echo "unknown")
echo -e "${CYAN}Time range:${NC} $FIRST_TIME to $LAST_TIME"

# Calculate duration if possible
if [ "$FIRST_TIME" != "unknown" ] && [ "$LAST_TIME" != "unknown" ]; then
    # Simple duration calculation (same day only)
    FIRST_SEC=$(date -j -f "%H:%M:%S" "$FIRST_TIME" +%s 2>/dev/null || echo "0")
    LAST_SEC=$(date -j -f "%H:%M:%S" "$LAST_TIME" +%s 2>/dev/null || echo "0")
    if [ "$FIRST_SEC" -gt 0 ] && [ "$LAST_SEC" -gt 0 ]; then
        DURATION=$((LAST_SEC - FIRST_SEC))
        if [ "$DURATION" -gt 0 ]; then
            DURATION_MIN=$((DURATION / 60))
            echo -e "${CYAN}Duration:${NC} ${DURATION_MIN} minutes"
        fi
    fi
fi
echo ""

# =============================================================================
# SECTION 1: APP STARTUP & HEALTH CHECKS
# =============================================================================
echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}${BLUE}  1. APP STARTUP & HEALTH CHECKS${NC}"
echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

echo -e "\n${YELLOW}Startup Mode:${NC}"
if grep -q "FAST START" "$LOGFILE"; then
    echo -e "  ${GREEN}✓ FAST START${NC} (cached tree, minimal sync)"
    FAST_START_TIME=$(grep "FAST START" "$LOGFILE" | head -1 | grep -oE "\[[0-9]+:[0-9]+:[0-9]+\.[0-9]+\]" | tr -d '[]')
    echo -e "    Started at: $FAST_START_TIME"
elif grep -q "FULL START" "$LOGFILE"; then
    echo -e "  ${YELLOW}⚠ FULL START${NC} (full tree download/rebuild)"
    FULL_START_TIME=$(grep "FULL START" "$LOGFILE" | head -1 | grep -oE "\[[0-9]+:[0-9]+:[0-9]+\.[0-9]+\]" | tr -d '[]')
    echo -e "    Started at: $FULL_START_TIME"
else
    echo -e "  ${CYAN}Unknown startup mode${NC}"
fi

echo -e "\n${YELLOW}Health Check Results:${NC}"
# Check for health check completion
HEALTH_CHECKS=$(grep -c "checkConnectionHealth() called" "$LOGFILE" 2>/dev/null || echo "0")
HEALTH_CHECKS=$(echo "$HEALTH_CHECKS" | tr -d '[:space:]')
echo -e "  Health checks performed: ${GREEN}$HEALTH_CHECKS${NC}"

# Check for wallet health issues
WALLET_ISSUES=$(grep -E "WALLET HEALTH.*issue|health check.*issue" "$LOGFILE" 2>/dev/null | wc -l | tr -d '[:space:]')
WALLET_ISSUES=${WALLET_ISSUES:-0}
if [ "$WALLET_ISSUES" -gt 0 ]; then
    echo -e "  ${RED}✗ $WALLET_ISSUES wallet health issue(s) detected${NC}"
    echo -e "    Issues:"
    grep -E "WALLET HEALTH.*issue|health check.*issue" "$LOGFILE" 2>/dev/null | head -3 | sed 's/^/    /'
else
    echo -e "  ${GREEN}✓ No wallet health issues${NC}"
fi

# =============================================================================
# SECTION 2: TOR & SOCKS5 STATUS
# =============================================================================
echo -e "\n${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}${BLUE}  2. TOR & SOCKS5 PROXY STATUS${NC}"
echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

echo -e "\n${YELLOW}Tor Mode:${NC}"
TOR_MODE=$(grep "Tor mode:" "$LOGFILE" 2>/dev/null | tail -1 | grep -oE "enabled|disabled" || echo "unknown")
case "$TOR_MODE" in
    enabled)
        echo -e "  ${GREEN}✓ Tor mode: ENABLED${NC}"
        ;;
    disabled)
        echo -e "  ${CYAN}○ Tor mode: DISABLED (Direct connection)${NC}"
        ;;
    *)
        echo -e "  ${YELLOW}? Tor mode: Unknown${NC}"
        ;;
esac

echo -e "\n${YELLOW}SOCKS5 Proxy Health:${NC}"
# Check for SOCKS5 health check function calls
SOCKS5_CHECKS=$(grep -c "checkSOCKS5Health\|SOCKS5 health check" "$LOGFILE" 2>/dev/null || echo "0")
SOCKS5_CHECKS=$(echo "$SOCKS5_CHECKS" | tr -d '[:space:]')
SOCKS5_HEALTHY=$(grep -c "Tor SOCKS5 health check PASSED\|SOCKS5 health.*PASSED\|Tor SOCKS5.*healthy" "$LOGFILE" 2>/dev/null || echo "0")
SOCKS5_HEALTHY=$(echo "$SOCKS5_HEALTHY" | tr -d '[:space:]')
SOCKS5_FAILED=$(grep -c "Tor SOCKS5 health check failed\|SOCKS5 health.*failed" "$LOGFILE" 2>/dev/null || echo "0")
SOCKS5_FAILED=$(echo "$SOCKS5_FAILED" | tr -d '[:space:]')

if [ "$SOCKS5_CHECKS" -gt 0 ]; then
    echo -e "  ${GREEN}✓ SOCKS5 health monitoring: ACTIVE${NC} ($SOCKS5_CHECKS checks performed)"
    if [ "$SOCKS5_HEALTHY" -gt 0 ]; then
        echo -e "    ${GREEN}✓ $SOCKS5_HEALTHY healthy checks${NC}"
    fi
    if [ "$SOCKS5_FAILED" -gt 0 ]; then
        echo -e "    ${YELLOW}⚠ $SOCKS5_FAILED failed checks${NC}"
    fi
else
    echo -e "  ${YELLOW}○ SOCKS5 health monitoring: Not detected${NC}"
fi

# SOCKS5 connection errors
SOCKS5_REFUSED=$(grep -c "SOCKS5 error: Connection refused" "$LOGFILE" 2>/dev/null || echo "0")
SOCKS5_REFUSED=$(echo "$SOCKS5_REFUSED" | tr -d '[:space:]')
echo -e "  SOCKS5 'Connection refused' errors: ${SOCKS5_REFUSED}"

if [ "$SOCKS5_REFUSED" -gt 10 ]; then
    echo -e "    ${RED}✗ CRITICAL: Many SOCKS5 errors - Tor proxy may be down${NC}"
elif [ "$SOCKS5_REFUSED" -gt 3 ]; then
    echo -e "    ${YELLOW}⚠ Some SOCKS5 errors - Tor may be unstable${NC}"
else
    echo -e "    ${GREEN}✓ SOCKS5 connection healthy${NC}"
fi

# =============================================================================
# SECTION 3: PEER CONNECTION ANALYSIS
# =============================================================================
echo -e "\n${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}${BLUE}  3. PEER CONNECTION ANALYSIS${NC}"
echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

echo -e "\n${YELLOW}Connection Success Rate:${NC}"

# Count successful connections
SUCCESS_COUNT=$(grep -c "Handshake complete\|✅ FIX #246.*Reconnected successfully" "$LOGFILE" 2>/dev/null || echo "0")
SUCCESS_COUNT=$(echo "$SUCCESS_COUNT" | tr -d '[:space:]')

# Count failed connections
FAILED_COUNT=$(grep -c "❌ Failed:\|Connection failed\|Timed out" "$LOGFILE" 2>/dev/null || echo "0")
FAILED_COUNT=$(echo "$FAILED_COUNT" | tr -d '[:space:]')

TOTAL_ATTEMPTS=$((SUCCESS_COUNT + FAILED_COUNT))
if [ "$TOTAL_ATTEMPTS" -gt 0 ]; then
    SUCCESS_RATE=$((SUCCESS_COUNT * 100 / TOTAL_ATTEMPTS))
    echo -e "  Successful: ${GREEN}$SUCCESS_COUNT${NC}"
    echo -e "  Failed: ${RED}$FAILED_COUNT${NC}"
    echo -e "  Success rate: ${CYAN}$SUCCESS_RATE%${NC}"

    if [ "$SUCCESS_RATE" -ge 80 ]; then
        echo -e "    ${GREEN}✓ Excellent connection rate${NC}"
    elif [ "$SUCCESS_RATE" -ge 50 ]; then
        echo -e "    ${YELLOW}⚠ Moderate connection rate${NC}"
    else
        echo -e "    ${RED}✗ Poor connection rate${NC}"
    fi
else
    echo -e "  ${YELLOW}No connection attempts detected${NC}"
fi

echo -e "\n${YELLOW}Current Peer Status:${NC}"

# Get the most recent peer count from logs
FINAL_PEER_LINE=$(grep -E "Connected to [0-9]+/[0-9]+ target peers|Final: Connected to [0-9]+/[0-9]+" "$LOGFILE" 2>/dev/null | tail -1)
if [ -n "$FINAL_PEER_LINE" ]; then
    echo -e "  $FINAL_PEER_LINE"

    # Extract current and target
    CURRENT_PEERS=$(echo "$FINAL_PEER_LINE" | grep -oE "Connected to [0-9]+" | grep -oE "[0-9]+")
    TARGET_PEERS=$(echo "$FINAL_PEER_LINE" | grep -oE "/[0-9]+ target" | grep -oE "[0-9]+")

    if [ -n "$CURRENT_PEERS" ] && [ -n "$TARGET_PEERS" ]; then
        if [ "$CURRENT_PEERS" -ge "$TARGET_PEERS" ]; then
            echo -e "    ${GREEN}✓ Target achieved ($CURRENT_PEERS/$TARGET_PEERS)${NC}"
        elif [ "$CURRENT_PEERS" -ge 3 ]; then
            echo -e "    ${YELLOW}⚠ Below target but above minimum ($CURRENT_PEERS/$TARGET_PEERS)${NC}"
        else
            echo -e "    ${RED}✗ Below minimum threshold ($CURRENT_PEERS/$TARGET_PEERS)${NC}"
        fi
    fi
else
    echo -e "  ${YELLOW}Could not determine current peer count${NC}"
fi

echo -e "\n${YELLOW}Peer Churn (connects/disconnects):${NC}"

# Count peer churn events
PEER_CONNECT=$(grep -c "Block listener started\|Handshake complete" "$LOGFILE" 2>/dev/null || echo "0")
PEER_CONNECT=$(echo "$PEER_CONNECT" | tr -d '[:space:]')
PEER_DISCONNECT=$(grep -c "Block listener ended\|peer.*disconnected\|Removing peer" "$LOGFILE" 2>/dev/null || echo "0")
PEER_DISCONNECT=$(echo "$PEER_DISCONNECT" | tr -d '[:space:]')

echo -e "  Peers connected: $PEER_CONNECT"
echo -e "  Peers disconnected: $PEER_DISCONNECT"

if [ "$PEER_DISCONNECT" -gt "$PEER_CONNECT" ]; then
    CHURN_RATE=$((PEER_DISCONNECT - PEER_CONNECT))
    echo -e "    ${YELLOW}⚠ Net loss: $CHURN_RATE more disconnects than connects${NC}"
elif [ "$PEER_CONNECT" -gt 0 ]; then
    echo -e "    ${GREEN}✓ Healthy peer turnover${NC}"
fi

echo -e "\n${YELLOW}Handshake Failures:${NC}"
HANDSHAKE_FAIL=$(grep -c "handshake.*failed\|Handshake failed\|performHandshake.*error" "$LOGFILE" 2>/dev/null || echo "0")
HANDSHAKE_FAIL=$(echo "$HANDSHAKE_FAIL" | tr -d '[:space:]')
echo -e "  Handshake failures: $HANDSHAKE_FAIL"

if [ "$HANDSHAKE_FAIL" -gt 10 ]; then
    echo -e "    ${RED}✗ Many handshake failures - incompatible peers?${NC}"
elif [ "$HANDSHAKE_FAIL" -gt 3 ]; then
    echo -e "    ${YELLOW}⚠ Some handshake failures${NC}"
else
    echo -e "    ${GREEN}✓ Handshake failures normal${NC}"
fi

echo -e "\n${YELLOW}Connection Health Monitoring:${NC}"

# Check for connection health monitoring
HEALTH_MONITOR=$(grep -c "checkConnectionHealth()\|💓 Connection health\|countAlivePeers" "$LOGFILE" 2>/dev/null || echo "0")
HEALTH_MONITOR=$(echo "$HEALTH_MONITOR" | tr -d '[:space:]')
if [ "$HEALTH_MONITOR" -gt 0 ]; then
    echo -e "  ${GREEN}✓ Connection health monitoring: ACTIVE${NC} ($HEALTH_MONITOR checks)"

    # Get latest health status
    LATEST_HEALTH=$(grep "💓 Connection health:" "$LOGFILE" 2>/dev/null | tail -1)
    if [ -n "$LATEST_HEALTH" ]; then
        echo -e "    Latest: $LATEST_HEALTH"
    fi
else
    echo -e "  ${YELLOW}○ Connection health monitoring: Not detected${NC}"
fi

# =============================================================================
# SECTION 4: CHAIN SYNC STATUS
# =============================================================================
echo -e "\n${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}${BLUE}  4. CHAIN SYNC STATUS${NC}"
echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

echo -e "\n${YELLOW}Chain Height:${NC}"

# Get latest chain height
CHAIN_HEIGHT=$(grep -E "chainHeight.*29[0-9]{6}|Using P2P consensus: [0-9]+" "$LOGFILE" 2>/dev/null | tail -1 | grep -oE "29[0-9]{6}" || echo "unknown")
if [ "$CHAIN_HEIGHT" != "unknown" ]; then
    echo -e "  Current chain height: ${GREEN}$CHAIN_HEIGHT${NC}"
else
    echo -e "  ${YELLOW}Chain height: Unknown${NC}"
fi

# Get wallet height
WALLET_HEIGHT=$(grep -E "walletHeight.*29[0-9]{6}|last_scanned_height.*29[0-9]{6}" "$LOGFILE" 2>/dev/null | tail -1 | grep -oE "29[0-9]{6}" || echo "unknown")
if [ "$WALLET_HEIGHT" != "unknown" ]; then
    echo -e "  Wallet height: ${CYAN}$WALLET_HEIGHT${NC}"

    # Calculate blocks behind
    if [ "$CHAIN_HEIGHT" != "unknown" ]; then
        BLOCKS_BEHIND=$((CHAIN_HEIGHT - WALLET_HEIGHT))
        if [ "$BLOCKS_BEHIND" -le 100 ]; then
            echo -e "    ${GREEN}✓ Synced (within 100 blocks)${NC}"
        elif [ "$BLOCKS_BEHIND" -le 1000 ]; then
            echo -e "    ${YELLOW}⚠ $BLOCKS_BEHIND blocks behind${NC}"
        else
            echo -e "    ${RED}✗ $BLOCKS_BEHIND blocks behind (needs sync)${NC}"
        fi
    fi
else
    echo -e "  ${YELLOW}Wallet height: Unknown${NC}"
fi

echo -e "\n${YELLOW}Header Sync Status:${NC}"

HEADER_SYNC_COMPLETE=$(grep -c "Header sync complete\|Synced [0-9]+ headers.*100%" "$LOGFILE" 2>/dev/null || echo "0")
HEADER_SYNC_COMPLETE=$(echo "$HEADER_SYNC_COMPLETE" | tr -d '[:space:]')
HEADER_SYNC_TIMEOUT=$(grep -c "Header sync.*timeout\|FIX #444: Header sync timeout" "$LOGFILE" 2>/dev/null || echo "0")
HEADER_SYNC_TIMEOUT=$(echo "$HEADER_SYNC_TIMEOUT" | tr -d '[:space:]')

echo -e "  Successful syncs: ${GREEN}$HEADER_SYNC_COMPLETE${NC}"
echo -e "  Timeouts: ${YELLOW}$HEADER_SYNC_TIMEOUT${NC}"

if [ "$HEADER_SYNC_COMPLETE" -gt 0 ]; then
    # Get latest sync details
    LATEST_SYNC=$(grep -E "Synced [0-9]+ headers" "$LOGFILE" 2>/dev/null | tail -1)
    if [ -n "$LATEST_SYNC" ]; then
        echo -e "    Latest: $LATEST_SYNC"
    fi
fi

if [ "$HEADER_SYNC_TIMEOUT" -gt 2 ]; then
    echo -e "    ${RED}✗ Multiple header sync timeouts - may be stuck${NC}"
fi

echo -e "\n${YELLOW}Header Sync Timing Diagnostics:${NC}"

TIMING_DIAG=$(grep -c "⏱️ Header sync timing summary\|measureStep\|timing diagnostics" "$LOGFILE" 2>/dev/null || echo "0")
TIMING_DIAG=$(echo "$TIMING_DIAG" | tr -d '[:space:]')
if [ "$TIMING_DIAG" -gt 0 ]; then
    echo -e "  ${GREEN}✓ Header sync timing diagnostics: ACTIVE${NC}"

    # Show timing summary if available
    TIMING_SUMMARY=$(grep -A 10 "⏱️ Header sync timing summary" "$LOGFILE" 2>/dev/null | head -11)
    if [ -n "$TIMING_SUMMARY" ]; then
        echo -e "$TIMING_SUMMARY" | sed 's/^/    /'
    fi
else
    echo -e "  ${YELLOW}○ Header sync timing diagnostics: Not detected${NC}"
fi

# =============================================================================
# SECTION 5: BLOCK & TRANSACTION SCANNING
# =============================================================================
echo -e "\n${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}${BLUE}  5. BLOCK & TRANSACTION SCANNING${NC}"
echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

echo -e "\n${YELLOW}Block Scanning (PHASE 2):${NC}"

# Check for PHASE 2 scanning
PHASE2_START=$(grep -c "🔄 Starting PHASE 2\|PHASE 2: Scanning blocks" "$LOGFILE" 2>/dev/null || echo "0")
PHASE2_START=$(echo "$PHASE2_START" | tr -d '[:space:]')
PHASE2_COMPLETE=$(grep -c "PHASE 2 complete\|✅ PHASE 2.*complete" "$LOGFILE" 2>/dev/null || echo "0")
PHASE2_COMPLETE=$(echo "$PHASE2_COMPLETE" | tr -d '[:space:]')

if [ "$PHASE2_START" -gt 0 ]; then
    echo -e "  PHASE 2 scans started: ${GREEN}$PHASE2_START${NC}"
    echo -e "  PHASE 2 scans completed: ${GREEN}$PHASE2_COMPLETE${NC}"

    if [ "$PHASE2_COMPLETE" -lt "$PHASE2_START" ]; then
        echo -e "    ${YELLOW}⚠ Scan in progress or interrupted${NC}"
    fi
else
    echo -e "  ${CYAN}No PHASE 2 scanning detected${NC}"
fi

echo -e "\n${YELLOW}Background Sync Events:${NC}"

BG_SYNC=$(grep -c "Background sync:" "$LOGFILE" 2>/dev/null || echo "0")
BG_SYNC=$(echo "$BG_SYNC" | tr -d '[:space:]')
echo -e "  Background syncs: ${GREEN}$BG_SYNC${NC}"

if [ "$BG_SYNC" -gt 0 ]; then
    # Show latest sync
    LATEST_BG=$(grep "Background sync:" "$LOGFILE" 2>/dev/null | tail -1)
    echo -e "    Latest: $LATEST_BG"
fi

echo -e "\n${YELLOW}Mempool Scanning:${NC}"

MEMPOOL_SCAN=$(grep -c "scanMempoolForIncoming\|🔮 scanMempoolForIncoming" "$LOGFILE" 2>/dev/null || echo "0")
MEMPOOL_SCAN=$(echo "$MEMPOOL_SCAN" | tr -d '[:space:]')
if [ "$MEMPOOL_SCAN" -gt 0 ]; then
    echo -e "  ${GREEN}✓ Mempool scanning: ACTIVE${NC} ($MEMPOOL_SCAN scans)"
else
    echo -e "  ${YELLOW}○ Mempool scanning: Not detected${NC}"
fi

# =============================================================================
# SECTION 6: TRANSACTIONS
# =============================================================================
echo -e "\n${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}${BLUE}  6. TRANSACTIONS${NC}"
echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

echo -e "\n${YELLOW}Outgoing Transactions:${NC}"

SENT_TX=$(grep -c "Starting broadcast\|Broadcasting transaction\|📤 Broadcasting" "$LOGFILE" 2>/dev/null || echo "0")
SENT_TX=$(echo "$SENT_TX" | tr -d '[:space:]')
echo -e "  Broadcast attempts: ${GREEN}$SENT_TX${NC}"

if [ "$SENT_TX" -gt 0 ]; then
    # Check for confirmations
    CONFIRMED=$(grep -c "Confirmed\|confirmOutgoingTx\|✅ Confirmed outgoing" "$LOGFILE" 2>/dev/null || echo "0")
    CONFIRMED=$(echo "$CONFIRMED" | tr -d '[:space:]')
    echo -e "  Confirmations: ${GREEN}$CONFIRMED${NC}"

    # Check for broadcast issues
    BROADCAST_FAIL=$(grep -c "Broadcast to.*0/.*peers\|❌.*Broadcast.*failed\|Timed out.*waiting" "$LOGFILE" 2>/dev/null || echo "0")
    BROADCAST_FAIL=$(echo "$BROADCAST_FAIL" | tr -d '[:space:]')
    if [ "$BROADCAST_FAIL" -gt 0 ]; then
        echo -e "    ${YELLOW}⚠ $BROADCAST_FAIL broadcast issue(s) detected${NC}"
    fi
fi

echo -e "\n${YELLOW}Incoming Transactions (Mempool):${NC}"

MEMPOOL_TX=$(grep -c "Found.*mempool tx\|Incoming.*mempool\|🔍.*mempool.*incoming" "$LOGFILE" 2>/dev/null || echo "0")
MEMPOOL_TX=$(echo "$MEMPOOL_TX" | tr -d '[:space:]')
echo -e "  Mempool TXs found: ${GREEN}$MEMPOOL_TX${NC}"

# =============================================================================
# SECTION 7: ERROR ANALYSIS
# =============================================================================
echo -e "\n${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}${BLUE}  7. ERROR ANALYSIS${NC}"
echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

echo -e "\n${YELLOW}Error Summary:${NC}"

CANCELLATION_ERRORS=$(grep -c "Swift.CancellationError" "$LOGFILE" 2>/dev/null || echo "0")
CANCELLATION_ERRORS=$(echo "$CANCELLATION_ERRORS" | tr -d '[:space:]')
echo -e "  Task cancellations: ${YELLOW}$CANCELLATION_ERRORS${NC}"

TIMEOUT_ERRORS=$(grep -c "Request timed out\|Connection timed out\|Timed out" "$LOGFILE" 2>/dev/null || echo "0")
TIMEOUT_ERRORS=$(echo "$TIMEOUT_ERRORS" | tr -d '[:space:]')
echo -e "  Timeout errors: ${YELLOW}$TIMEOUT_ERRORS${NC}"

CONN_FAILED=$(grep -c "Connection failed\|NWConnection.*failed" "$LOGFILE" 2>/dev/null || echo "0")
CONN_FAILED=$(echo "$CONN_FAILED" | tr -d '[:space:]')
echo -e "  Connection failures: ${YELLOW}$CONN_FAILED${NC}"

# Total errors
TOTAL_ERR=$((CANCELLATION_ERRORS + TIMEOUT_ERRORS + CONN_FAILED))
echo -e "  ${BOLD}Total errors: ${RED}$TOTAL_ERR${NC}"

echo -e "\n${YELLOW}Top Error Patterns:${NC}"
grep -E "❌ Failed:|ERROR|Error:|error:" "$LOGFILE" 2>/dev/null | \
    sed 's/.*Failed: //' | \
    sort | uniq -c | sort -rn | head -10 | \
    awk '{printf "    %3d × %s\n", $1, substr($0, 6)}'

# =============================================================================
# SECTION 8: TCP KEEPALIVE STATUS
# =============================================================================
echo -e "\n${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}${BLUE}  8. TCP KEEPALIVE & NETWORK SETTINGS${NC}"
echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

echo -e "\n${YELLOW}TCP Keepalive Settings:${NC}"

# Check for improved keepalive settings
IMPROVED_KEEPALIVE=$(grep -c "keepaliveInterval.*15\|keepaliveCount.*2\|enableKeepalive.*true" "$LOGFILE" 2>/dev/null || echo "0")
IMPROVED_KEEPALIVE=$(echo "$IMPROVED_KEEPALIVE" | tr -d '[:space:]')
if [ "$IMPROVED_KEEPALIVE" -gt 0 ]; then
    echo -e "  ${GREEN}✓ TCP keepalive improvements: DETECTED${NC}"
    echo -e "    Using 15s interval × 2 probes = 30s timeout"
else
    echo -e "  ${YELLOW}○ TCP keepalive status: Unknown (may need improvement)${NC}"
fi

# Check for path monitoring (FIX #268)
PATH_MONITOR=$(grep -c "NWPathMonitor\|handleNetworkPathChange\|📶.*network path" "$LOGFILE" 2>/dev/null || echo "0")
PATH_MONITOR=$(echo "$PATH_MONITOR" | tr -d '[:space:]')
if [ "$PATH_MONITOR" -gt 0 ]; then
    echo -e "  ${GREEN}✓ Network path monitoring: ACTIVE${NC} (FIX #268)"
else
    echo -e "  ${YELLOW}○ Network path monitoring: Not detected${NC}"
fi

# =============================================================================
# SECTION 9: BANS & SECURITY
# =============================================================================
echo -e "\n${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}${BLUE}  9. BANS & SECURITY${NC}"
echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

echo -e "\n${YELLOW}Peer Bans:${NC}"

BANNED_PEERS=$(grep -c "🚫.*Banning\|Banning peer\|banPeerForSybilAttack" "$LOGFILE" 2>/dev/null || echo "0")
BANNED_PEERS=$(echo "$BANNED_PEERS" | tr -d '[:space:]')
echo -e "  Peers banned: ${RED}$BANNED_PEERS${NC}"

if [ "$BANNED_PEERS" -gt 0 ]; then
    # Show recent bans
    echo -e "    Recent bans:"
    grep -E "🚫.*Banning|Banning peer|banPeerForSybilAttack" "$LOGFILE" 2>/dev/null | tail -3 | sed 's/^/      /'
fi

echo -e "\n${YELLOW}Sybil Attack Detection:${NC}"

SYBIL_EVENTS=$(grep -c "SYBIL\|Sybil.*attack\|wrong chain\|fakeHeight" "$LOGFILE" 2>/dev/null || echo "0")
SYBIL_EVENTS=$(echo "$SYBIL_EVENTS" | tr -d '[:space:]')
if [ "$SYBIL_EVENTS" -gt 0 ]; then
    echo -e "  ${RED}✗ $SYBIL_EVENTS Sybil-related event(s)${NC}"
else
    echo -e "  ${GREEN}✓ No Sybil attacks detected${NC}"
fi

# =============================================================================
# SECTION 10: FIX TRACKING
# =============================================================================
echo -e "\n${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}${BLUE} 10. ACTIVE FIXES (Top 15)${NC}"
echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

echo -e "\n${YELLOW}Most Active Bug Fixes:${NC}"
grep -oE "FIX #[0-9]+" "$LOGFILE" 2>/dev/null | sort | uniq -c | sort -rn | head -15 | \
    awk '{printf "    %3d × %s %s\n", $1, $2, $3}'

# Count unique fixes
UNIQUE_FIXES=$(grep -oE "FIX #[0-9]+" "$LOGFILE" 2>/dev/null | awk -F# '{print $2}' | sort -u | wc -l | tr -d ' ')
echo -e "\n  Total unique FIX numbers: ${CYAN}$UNIQUE_FIXES${NC}"

# =============================================================================
# SUMMARY & RECOMMENDATIONS
# =============================================================================
echo -e "\n${BOLD}${MAGENTA}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${MAGENTA}║                    ANALYSIS SUMMARY                            ║${NC}"
echo -e "${BOLD}${MAGENTA}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Calculate key metrics
echo -e "${BOLD}Key Metrics:${NC}"
echo -e "  Connections: ${GREEN}Success: $SUCCESS_COUNT${NC} | ${RED}Failed: $FAILED_COUNT${NC}"
echo -e "  Errors: ${YELLOW}Cancellations: $CANCELLATION_ERRORS${NC} | ${YELLOW}Timeouts: $TIMEOUT_ERRORS${NC}"
echo -e "  Health Checks: ${CYAN}$HEALTH_CHECKS${NC} | SOCKS5 Checks: ${CYAN}${SOCKS5_CHECKS:-0}${NC}"
echo ""

# Verdict
echo -e "${BOLD}VERDICT:${NC}"

# Priority order for verdict
CRITICAL=false

if [ "$HEADER_SYNC_TIMEOUT" -gt 2 ]; then
    echo -e "  ${RED}${BOLD}⚠ CRITICAL: Header Sync Loop Detected${NC}"
    echo -e "     ${YELLOW}→ Header sync timing out repeatedly${NC}"
    echo -e "     ${YELLOW}→ May need to check header storage logic${NC}"
    echo -e "     ${YELLOW}→ See Section 4 for details${NC}"
    CRITICAL=true

elif [ "$SOCKS5_REFUSED" -gt 20 ]; then
    echo -e "  ${RED}${BOLD}⚠ CRITICAL: Tor SOCKS5 Proxy Failure${NC}"
    echo -e "     ${YELLOW}→ $SOCKS5_REFUSED SOCKS5 connection refused errors${NC}"
    echo -e "     ${YELLOW}→ Tor proxy is not accepting connections${NC}"
    echo -e "     ${YELLOW}→ FIX: Restart Tor or check Tor status${NC}"
    echo -e "     ${YELLOW}→ See Section 2 for details${NC}"
    CRITICAL=true

elif [ -n "$SUCCESS_RATE" ] && [ "$SUCCESS_RATE" -lt 30 ]; then
    echo -e "  ${RED}${BOLD}⚠ CRITICAL: Poor Connection Success Rate${NC}"
    echo -e "     ${YELLOW}→ Only $SUCCESS_RATE% of connections succeeding${NC}"
    echo -e "     ${YELLOW}→ Check network connectivity and Tor status${NC}"
    echo -e "     ${YELLOW}→ See Section 3 for details${NC}"
    CRITICAL=true
fi

if [ "$CRITICAL" = "false" ]; then
    # Warnings
    WARNING_COUNT=0

    if [ "$SOCKS5_REFUSED" -gt 5 ]; then
        echo -e "  ${YELLOW}${BOLD}⚠ WARNING: SOCKS5 Connection Issues${NC}"
        echo -e "     ${YELLOW}→ $SOCKS5_REFUSED SOCKS5 errors detected${NC}"
        echo -e "     ${YELLOW}→ Tor proxy may be unstable${NC}"
        WARNING_COUNT=$((WARNING_COUNT + 1))
    fi

    if [ "$CANCELLATION_ERRORS" -gt 10 ]; then
        echo -e "  ${YELLOW}${BOLD}⚠ WARNING: High Task Cancellation Rate${NC}"
        echo -e "     ${YELLOW}→ $CANCELLATION_ERRORS tasks cancelled${NC}"
        echo -e "     ${YELLOW}→ May indicate timeout issues${NC}"
        WARNING_COUNT=$((WARNING_COUNT + 1))
    fi

    if [ "$HANDSHAKE_FAIL" -gt 10 ]; then
        echo -e "  ${YELLOW}${BOLD}⚠ WARNING: Many Handshake Failures${NC}"
        echo -e "     ${YELLOW}→ $HANDSHAKE_FAIL handshake failures${NC}"
        echo -e "     ${YELLOW}→ Could be incompatible peer versions${NC}"
        WARNING_COUNT=$((WARNING_COUNT + 1))
    fi

    if [ "$BLOCKS_BEHIND" != "" ] && [ "$BLOCKS_BEHIND" -gt 1000 ]; then
        echo -e "  ${YELLOW}${BOLD}⚠ WARNING: Wallet Behind Network${NC}"
        echo -e "     ${YELLOW}→ $BLOCKS_BEHIND blocks behind chain tip${NC}"
        echo -e "     ${YELLOW}→ Sync may be in progress or stuck${NC}"
        WARNING_COUNT=$((WARNING_COUNT + 1))
    fi

    if [ "$WARNING_COUNT" -eq 0 ]; then
        echo -e "  ${GREEN}${BOLD}✓ HEALTHY: No Major Issues${NC}"
        echo -e "     ${CYAN}→ All systems functioning normally${NC}"
        echo -e "     ${CYAN}→ $SUCCESS_COUNT successful connections${NC}"
        echo -e "     ${CYAN}→ $HEALTH_CHECKS health checks performed${NC}"
    fi
fi

echo ""
echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}Analysis complete. See detailed sections above for specifics.${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
echo ""
