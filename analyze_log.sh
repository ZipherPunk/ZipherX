#!/bin/bash

# ZipherX Log Analyzer
# Performs deep analysis of zmac.log or z.log
# Usage: ./analyze_log.sh [zmac|ios|path/to/logfile]

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Determine log file
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

echo ""
echo -e "${BOLD}${PURPLE}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${PURPLE}║           ZIPHERX LOG ANALYZER - DEEP ANALYSIS                ║${NC}"
echo -e "${BOLD}${PURPLE}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${CYAN}Analyzing:${NC} $LOGFILE"
echo -e "${CYAN}File size:${NC} $(du -h "$LOGFILE" | cut -f1)"
echo -e "${CYAN}Line count:${NC} $(wc -l < "$LOGFILE")"
echo -e "${CYAN}Time range:${NC} $(head -1 "$LOGFILE" | cut -d']' -f1 | tr -d '[') to $(tail -1 "$LOGFILE" | cut -d']' -f1 | tr -d '[')"
echo ""

# ============================================================================
# SECTION 1: APP STARTUP
# ============================================================================
echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}${BLUE}  1. APP STARTUP & INITIALIZATION${NC}"
echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

echo -e "\n${YELLOW}Startup Mode:${NC}"
if grep -q "FAST START" "$LOGFILE"; then
    echo -e "  ${GREEN}FAST START${NC} detected (cached tree, minimal sync)"
    grep "FAST START" "$LOGFILE" | head -2
elif grep -q "FULL START" "$LOGFILE"; then
    echo -e "  ${YELLOW}FULL START${NC} detected (full tree download/rebuild)"
    grep "FULL START" "$LOGFILE" | head -2
fi

echo -e "\n${YELLOW}Database State:${NC}"
grep -E "lastScannedHeight|cachedChainHeight|blocksBehind|walletHeight" "$LOGFILE" | head -5

echo -e "\n${YELLOW}Health Checks:${NC}"
health_issues=$(grep -E "health check.*issue|health check.*failed|WALLET HEALTH.*issue" "$LOGFILE" 2>/dev/null | wc -l | tr -d ' ')
health_issues=${health_issues:-0}
if [ "$health_issues" -gt 0 ]; then
    echo -e "  ${RED}Found $health_issues health issue(s):${NC}"
    grep -E "health check.*issue|health check.*failed|WALLET HEALTH.*issue" "$LOGFILE" | head -5
else
    echo -e "  ${GREEN}No health issues detected${NC}"
fi

# ============================================================================
# SECTION 2: PEER CONNECTIONS
# ============================================================================
echo -e "\n${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}${BLUE}  2. PEER CONNECTIONS${NC}"
echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

echo -e "\n${YELLOW}Connection Summary:${NC}"
connected=$(grep -E "Connected to.*peer|✅ Connected to" "$LOGFILE" 2>/dev/null | wc -l | tr -d ' ')
failed=$(grep -E "Failed to connect|Connection failed|Connection refused" "$LOGFILE" 2>/dev/null | wc -l | tr -d ' ')
echo -e "  Connected: ${GREEN}$connected${NC}"
echo -e "  Failed: ${RED}$failed${NC}"

echo -e "\n${YELLOW}Hardcoded Seeds Status (FIX #421):${NC}"
if grep -q "FIX #421" "$LOGFILE"; then
    grep "FIX #421" "$LOGFILE" | head -3
else
    echo -e "  ${YELLOW}FIX #421 not detected in log${NC}"
fi

echo -e "\n${YELLOW}Successful Peer Connections:${NC}"
grep -E "✅ Connected to.*[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" "$LOGFILE" | \
    sed 's/.*Connected to/Connected to/' | sort | uniq -c | sort -rn | head -10

echo -e "\n${YELLOW}Peer Versions Seen:${NC}"
grep -oE "version [0-9]+" "$LOGFILE" | sort | uniq -c | sort -rn

echo -e "\n${YELLOW}Block Listeners:${NC}"
listeners=$(grep -E "Block listener started|Started block listener" "$LOGFILE" 2>/dev/null | wc -l | tr -d ' ')
echo -e "  Started: ${GREEN}$listeners${NC} block listeners"

# ============================================================================
# SECTION 3: BANS & SYBIL ATTACKS
# ============================================================================
echo -e "\n${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}${BLUE}  3. BANS & SYBIL ATTACKS${NC}"
echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

echo -e "\n${YELLOW}Sybil Attack Detection:${NC}"
sybil=$(grep -E "SYBIL|Sybil|sybil|wrong chain|Wrong chain" "$LOGFILE" 2>/dev/null | wc -l | tr -d ' ')
if [ "$sybil" -gt 0 ]; then
    echo -e "  ${RED}$sybil Sybil-related events detected!${NC}"
    grep -E "SYBIL|Sybil|wrong chain|Wrong chain" "$LOGFILE" | head -5
else
    echo -e "  ${GREEN}No Sybil attacks detected${NC}"
fi

echo -e "\n${YELLOW}Permanently Banned Peers:${NC}"
grep -E "Banned.*permanently|PERMANENT.*ban|banPeerPermanently" "$LOGFILE" | \
    grep -oE "[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" | sort | uniq -c | sort -rn | head -10

echo -e "\n${YELLOW}Zcash Nodes Rejected (version >= 170020):${NC}"
zcash_rejects=$(grep -E "170020|170021|170022|170023|170100" "$LOGFILE" 2>/dev/null | wc -l | tr -d ' ')
echo -e "  ${RED}$zcash_rejects${NC} Zcash node rejection(s)"

echo -e "\n${YELLOW}Persisted Bans (FIX #424):${NC}"
if grep -q "FIX #424" "$LOGFILE"; then
    grep "FIX #424" "$LOGFILE" | head -3
else
    echo -e "  ${YELLOW}FIX #424 ban persistence not detected${NC}"
fi

# ============================================================================
# SECTION 4: HEADER SYNC
# ============================================================================
echo -e "\n${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}${BLUE}  4. HEADER SYNC${NC}"
echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

echo -e "\n${YELLOW}Header Sync Status:${NC}"
if grep -q "Header sync complete|Header sync.*complete" "$LOGFILE"; then
    echo -e "  ${GREEN}Header sync completed${NC}"
    grep -E "Header sync complete|Synced.*headers" "$LOGFILE" | tail -3
elif grep -q "Header sync.*failed|Insufficient peers|No headers received" "$LOGFILE"; then
    echo -e "  ${RED}Header sync FAILED${NC}"
    grep -E "Header sync.*failed|Insufficient peers|No headers received" "$LOGFILE" | tail -5
else
    echo -e "  ${YELLOW}Header sync status unknown${NC}"
fi

echo -e "\n${YELLOW}PeerManager Sync (FIX #425):${NC}"
if grep -q "syncPeers|FIX #425" "$LOGFILE"; then
    grep -E "syncPeers|FIX #425" "$LOGFILE" | head -3
else
    echo -e "  ${YELLOW}PeerManager sync not detected (FIX #425 may not be in this log)${NC}"
fi

echo -e "\n${YELLOW}Header Sync Timeouts:${NC}"
timeouts=$(grep -E "Header sync.*timeout|timeout.*header|No headers received" "$LOGFILE" 2>/dev/null | wc -l | tr -d ' ')
echo -e "  ${YELLOW}$timeouts${NC} timeout(s)"

# ============================================================================
# SECTION 5: BLOCK SYNC (PHASE 1 & 2)
# ============================================================================
echo -e "\n${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}${BLUE}  5. BLOCK SYNC (PHASE 1 & 2)${NC}"
echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

echo -e "\n${YELLOW}PHASE 1 (Bundled Tree Scan):${NC}"
if grep -q "PHASE 1" "$LOGFILE"; then
    grep "PHASE 1" "$LOGFILE" | head -5
else
    echo -e "  ${YELLOW}PHASE 1 not detected${NC}"
fi

echo -e "\n${YELLOW}PHASE 2 (P2P Block Sync):${NC}"
if grep -q "PHASE 2" "$LOGFILE"; then
    grep "PHASE 2" "$LOGFILE" | tail -5
else
    echo -e "  ${YELLOW}PHASE 2 not detected${NC}"
fi

echo -e "\n${YELLOW}Equihash Verification:${NC}"
equihash_fails=$(grep -E "Equihash.*FAILED|Equihash solution length mismatch" "$LOGFILE" 2>/dev/null | wc -l | tr -d ' ')
if [ "$equihash_fails" -gt 0 ]; then
    echo -e "  ${RED}$equihash_fails Equihash failure(s) detected!${NC}"
    echo -e "  ${RED}CRITICAL: PHASE 2 likely stuck due to pre-Bubbles header mismatch${NC}"
    grep -E "Equihash.*FAILED|Equihash solution length mismatch" "$LOGFILE" | head -3
    # Check if locator at height 0
    if grep -q "locator at height 0" "$LOGFILE"; then
        echo -e "  ${RED}⚠️ FIX #440: Header sync starting from height 0 (pre-Bubbles)!${NC}"
        echo -e "  ${RED}   BundledBlockHashes not loaded - need FIX #440${NC}"
    fi
else
    echo -e "  ${GREEN}No Equihash verification failures${NC}"
fi

echo -e "\n${YELLOW}Sync Progress:${NC}"
grep -E "[0-9]+%|blocks/sec|progress" "$LOGFILE" | tail -5

echo -e "\n${YELLOW}Last Scanned Height:${NC}"
grep -E "lastScannedHeight saved|updateLastScannedHeight|Scan complete.*height" "$LOGFILE" | tail -3

echo -e "\n${YELLOW}Background Sync:${NC}"
bg_syncs=$(grep -E "Background sync" "$LOGFILE" 2>/dev/null | wc -l | tr -d ' ')
echo -e "  ${GREEN}$bg_syncs${NC} background sync event(s)"
grep "Background sync" "$LOGFILE" | tail -3

# ============================================================================
# SECTION 6: NOTES & BALANCE
# ============================================================================
echo -e "\n${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}${BLUE}  6. NOTES & BALANCE${NC}"
echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

echo -e "\n${YELLOW}Notes Found:${NC}"
notes=$(grep -E "Note found|Found note|Unspent note" "$LOGFILE" 2>/dev/null | wc -l | tr -d ' ')
echo -e "  ${GREEN}$notes${NC} note(s) found/logged"

echo -e "\n${YELLOW}Balance Updates:${NC}"
grep -E "Balance|balance|zatoshis|ZCL" "$LOGFILE" | grep -v "unbalanced" | tail -5

echo -e "\n${YELLOW}Spent Notes:${NC}"
spent=$(grep -E "Note spent|markNoteSpent|NULLIFIER" "$LOGFILE" 2>/dev/null | wc -l | tr -d ' ')
echo -e "  ${YELLOW}$spent${NC} spent note event(s)"

# ============================================================================
# SECTION 7: TRANSACTIONS
# ============================================================================
echo -e "\n${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}${BLUE}  7. TRANSACTIONS${NC}"
echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

echo -e "\n${YELLOW}Transaction Building:${NC}"
txbuilds=$(grep -E "buildShielded|Building transaction|prepareTransaction|Groth16|zk-SNARK" "$LOGFILE" 2>/dev/null | wc -l | tr -d ' ')
echo -e "  ${GREEN}$txbuilds${NC} transaction build event(s)"

echo -e "\n${YELLOW}Broadcasts:${NC}"
broadcasts=$(grep -E "broadcast|Broadcast|Propagat" "$LOGFILE" 2>/dev/null | wc -l | tr -d ' ')
echo -e "  ${GREEN}$broadcasts${NC} broadcast event(s)"
grep -E "Pre-computed txid|Starting broadcast|Propagat" "$LOGFILE" | tail -5

echo -e "\n${YELLOW}Confirmations:${NC}"
confirmed=$(grep -E "Confirmed|confirmIncoming|confirmOutgoing" "$LOGFILE" 2>/dev/null | wc -l | tr -d ' ')
echo -e "  ${GREEN}$confirmed${NC} confirmation event(s)"
grep -E "Confirmed|confirmIncoming|confirmOutgoing" "$LOGFILE" | tail -5

echo -e "\n${YELLOW}Mempool Activity:${NC}"
mempool=$(grep -E "mempool|MEMPOOL|Mempool" "$LOGFILE" 2>/dev/null | wc -l | tr -d ' ')
echo -e "  ${GREEN}$mempool${NC} mempool event(s)"

echo -e "\n${YELLOW}Transaction Rejections:${NC}"
rejects=$(grep -E "reject|Reject|REJECT|bad-txns" "$LOGFILE" 2>/dev/null | wc -l | tr -d ' ')
if [ "$rejects" -gt 0 ]; then
    echo -e "  ${RED}$rejects rejection(s) detected!${NC}"
    grep -E "reject|Reject|REJECT|bad-txns" "$LOGFILE" | tail -5
else
    echo -e "  ${GREEN}No rejections${NC}"
fi

# ============================================================================
# SECTION 8: TOR STATUS
# ============================================================================
echo -e "\n${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}${BLUE}  8. TOR STATUS${NC}"
echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

echo -e "\n${YELLOW}Tor Connection State:${NC}"
# Check for Tor mode enabled but not connected (FIX #427 issue)
if grep -q "Tor mode: enabled" "$LOGFILE"; then
    echo -e "  Tor mode: ${GREEN}enabled${NC}"
    # Check if Tor is actually connected
    if grep -E "Tor connected: true|SOCKS port: [1-9]" "$LOGFILE" | tail -1 | grep -q "true\|[1-9]"; then
        echo -e "  Tor status: ${GREEN}connected${NC}"
    else
        if grep -E "Tor connected: false|SOCKS port: 0" "$LOGFILE" | tail -1 | grep -q "false\|: 0"; then
            echo -e "  Tor status: ${RED}NOT CONNECTED (mode enabled but SOCKS=0)${NC}"
            echo -e "  ${YELLOW}This causes peer recovery to fail - peers can't connect!${NC}"
        fi
    fi
else
    echo -e "  ${YELLOW}Tor mode status unknown${NC}"
fi

echo -e "\n${YELLOW}Tor Bypass Events (FIX #286):${NC}"
tor_bypass=$(grep -E "FIX #286.*bypass|Tor bypassed|bypassTorForMassiveOperation" "$LOGFILE" 2>/dev/null | wc -l | tr -d ' ')
if [ "$tor_bypass" -gt 0 ]; then
    echo -e "  ${YELLOW}$tor_bypass Tor bypass event(s)${NC}"
    grep -E "FIX #286.*bypass|Tor bypassed" "$LOGFILE" | tail -3
    # Check if peers reconnected after bypass
    if grep -A 20 "Tor bypassed" "$LOGFILE" | grep -q "0 peers connected\|0 direct peer"; then
        echo -e "  ${RED}WARNING: Tor bypass left 0 peers connected!${NC}"
    fi
fi

echo -e "\n${YELLOW}FIX #427 (Peer Recovery with Hardcoded Seeds):${NC}"
if grep -q "FIX #427" "$LOGFILE"; then
    grep "FIX #427" "$LOGFILE" | head -5
else
    echo -e "  ${YELLOW}FIX #427 not detected (may need upgrade)${NC}"
fi

echo -e "\n${YELLOW}Reserved/Invalid IP Attempts:${NC}"
# Check for reserved IP addresses being used (254.x.x.x, 10.x.x.x, etc.)
# Use word boundary to avoid matching 140.174 as 0.174
reserved_ips=$(grep -oE "\b(254|10|127)\.[0-9]+\.[0-9]+\.[0-9]+\b" "$LOGFILE" 2>/dev/null | sort | uniq -c | sort -rn | head -5)
if [ -n "$reserved_ips" ]; then
    echo -e "  ${RED}Found attempts to connect to reserved IPs:${NC}"
    echo "$reserved_ips" | while read line; do echo "    $line"; done
else
    echo -e "  ${GREEN}No reserved IP connection attempts${NC}"
fi

echo -e "\n${YELLOW}Hidden Service (.onion):${NC}"
if grep -q "Hidden service|\.onion|HiddenService" "$LOGFILE"; then
    grep -E "Hidden service.*Running|\.onion|HiddenService" "$LOGFILE" | head -3
else
    echo -e "  ${YELLOW}Hidden service not detected${NC}"
fi

echo -e "\n${YELLOW}Tor Errors:${NC}"
tor_errors=$(grep -E "Tor.*error|Tor.*failed|SOCKS5.*error|circuit.*failed" "$LOGFILE" 2>/dev/null | wc -l | tr -d ' ')
if [ "$tor_errors" -gt 0 ]; then
    echo -e "  ${RED}$tor_errors Tor error(s)${NC}"
    grep -E "Tor.*error|Tor.*failed|SOCKS5.*error|circuit.*failed" "$LOGFILE" | tail -3
else
    echo -e "  ${GREEN}No Tor errors${NC}"
fi

# ============================================================================
# SECTION 9: ERRORS & WARNINGS
# ============================================================================
echo -e "\n${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}${BLUE}  9. ERRORS & WARNINGS${NC}"
echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

echo -e "\n${YELLOW}Critical Errors:${NC}"
errors=$(grep -E "ERROR|Error|error|FATAL|fatal|CRASH|crash" "$LOGFILE" 2>/dev/null | wc -l | tr -d ' ')
echo -e "  ${RED}$errors${NC} error(s) in log"

echo -e "\n${YELLOW}Top Error Types:${NC}"
grep -E "ERROR|Error|error|failed|Failed|FAILED" "$LOGFILE" | \
    sed 's/\[.*\]//' | sort | uniq -c | sort -rn | head -10

echo -e "\n${YELLOW}Warnings:${NC}"
warnings=$(grep -E "Warning|WARNING|warn|WARN" "$LOGFILE" 2>/dev/null | wc -l | tr -d ' ')
echo -e "  ${YELLOW}$warnings${NC} warning(s) in log"

echo -e "\n${YELLOW}Timeouts:${NC}"
timeouts=$(grep -E "timeout|Timeout|TIMEOUT|timed out" "$LOGFILE" 2>/dev/null | wc -l | tr -d ' ')
echo -e "  ${YELLOW}$timeouts${NC} timeout(s)"

# ============================================================================
# SECTION 10: FIX TRACKING
# ============================================================================
echo -e "\n${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}${BLUE}  10. FIX TRACKING (Bug Fixes Active in Log)${NC}"
echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

echo -e "\n${YELLOW}Active Bug Fixes:${NC}"
grep -oE "FIX #[0-9]+" "$LOGFILE" | sort | uniq -c | sort -t'#' -k2 -n

# ============================================================================
# SECTION 11: TIMELINE SUMMARY
# ============================================================================
echo -e "\n${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}${BLUE}  11. TIMELINE SUMMARY (Last 20 Significant Events)${NC}"
echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

echo ""
grep -E "FAST START|FULL START|PHASE|Connected to|Header sync|Background sync|Broadcast|Confirmed|Error|error|Failed|failed|SYBIL|balance|Balance" "$LOGFILE" | tail -20

# ============================================================================
# SECTION 12: DATABASE CHECK
# ============================================================================
echo -e "\n${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}${BLUE}  12. DATABASE STATUS (Live Check)${NC}"
echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

MAC_DB="/Users/chris/Library/Application Support/ZipherX/zipherx_wallet.db"
MAC_HEADERS="/Users/chris/Library/Application Support/ZipherX/zipherx_headers.db"

if [ -f "$MAC_DB" ]; then
    echo -e "\n${YELLOW}Wallet Database:${NC}"
    echo -e "  Notes:"
    sqlite3 "$MAC_DB" "SELECT COUNT(*) as total, SUM(CASE WHEN is_spent = 0 THEN 1 ELSE 0 END) as unspent, SUM(CASE WHEN is_spent = 0 THEN value ELSE 0 END) as unspent_balance FROM notes;" 2>/dev/null || echo "    (query failed)"
    echo -e "\n  Sync State:"
    sqlite3 "$MAC_DB" "SELECT last_scanned_height, verified_checkpoint_height, cached_chain_height FROM sync_state;" 2>/dev/null || echo "    (query failed)"
else
    echo -e "  ${YELLOW}Wallet database not found at: $MAC_DB${NC}"
fi

if [ -f "$MAC_HEADERS" ]; then
    echo -e "\n${YELLOW}Header Database:${NC}"
    sqlite3 "$MAC_HEADERS" "SELECT MIN(height) as min_h, MAX(height) as max_h, COUNT(*) as count FROM headers;" 2>/dev/null || echo "  (query failed)"
else
    echo -e "  ${YELLOW}Header database not found${NC}"
fi

# ============================================================================
# SUMMARY
# ============================================================================
echo -e "\n${BOLD}${PURPLE}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${PURPLE}║                    ANALYSIS SUMMARY                            ║${NC}"
echo -e "${BOLD}${PURPLE}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Calculate summary stats
total_errors=$(grep -E "ERROR|Error|error" "$LOGFILE" 2>/dev/null | wc -l | tr -d ' ')
total_warnings=$(grep -E "Warning|WARN" "$LOGFILE" 2>/dev/null | wc -l | tr -d ' ')
peers_connected=$(grep -E "✅ Connected to" "$LOGFILE" 2>/dev/null | wc -l | tr -d ' ')
sybil_attacks=$sybil
txs_broadcast=$broadcasts

echo -e "  ${CYAN}Peers Connected:${NC}  $peers_connected"
echo -e "  ${CYAN}Sybil Events:${NC}     $sybil_attacks"
echo -e "  ${CYAN}TX Broadcasts:${NC}    $txs_broadcast"
echo -e "  ${CYAN}Errors:${NC}           $total_errors"
echo -e "  ${CYAN}Warnings:${NC}         $total_warnings"
echo ""

# Check for stuck sync
stuck_at_percent=$(grep "FAST START progress" "$LOGFILE" 2>/dev/null | tail -1 | grep -oE "[0-9]+%" | tr -d '%')
stuck_count=$(grep "FAST START progress = ${stuck_at_percent:-0}%" "$LOGFILE" 2>/dev/null | wc -l | tr -d ' ')

# Additional checks for verdict
tor_mode_enabled_disconnected=$(grep "Tor mode: enabled" "$LOGFILE" 2>/dev/null | tail -1)
tor_connected_false=$(grep "Tor connected: false" "$LOGFILE" 2>/dev/null | tail -1)
zero_peers_recovery=$(grep -E "0 peers connected|Parallel recovery complete - 0 peers" "$LOGFILE" 2>/dev/null | wc -l | tr -d ' ')
tor_bypass_no_reconnect=$(grep -A 20 "Tor bypassed" "$LOGFILE" 2>/dev/null | grep -c "0 direct peer\|0 peers connected" | tr -d ' ')

# Health verdict
if [ "${stuck_count:-0}" -gt 20 ] && [ "${stuck_at_percent:-100}" -lt 100 ]; then
    echo -e "  ${RED}${BOLD}VERDICT: SYNC STUCK at ${stuck_at_percent}% (${stuck_count} repeated logs)${NC}"
    echo -e "  ${YELLOW}Check: connect() may be hanging in withTaskGroup${NC}"
elif [ "${tor_bypass_no_reconnect:-0}" -gt 0 ]; then
    echo -e "  ${RED}${BOLD}VERDICT: TOR BYPASS FAILED - Peers not reconnected after Tor bypass${NC}"
    echo -e "  ${YELLOW}FIX #427 should resolve this. Upgrade app or retry.${NC}"
elif [ -n "$tor_mode_enabled_disconnected" ] && [ -n "$tor_connected_false" ] && [ "${zero_peers_recovery:-0}" -gt 3 ]; then
    echo -e "  ${RED}${BOLD}VERDICT: TOR STATE MISMATCH - Tor enabled but not connected, 0 peers${NC}"
    echo -e "  ${YELLOW}Check: Tor mode enabled but SOCKS proxy dead. Peer recovery fails.${NC}"
elif [ "$total_errors" -gt 50 ]; then
    echo -e "  ${RED}${BOLD}VERDICT: CRITICAL ISSUES - Many errors detected${NC}"
elif [ "${sybil_attacks:-0}" -gt 10 ]; then
    echo -e "  ${RED}${BOLD}VERDICT: SYBIL ATTACK - Network under attack${NC}"
elif [ "${zero_peers_recovery:-0}" -gt 5 ]; then
    echo -e "  ${RED}${BOLD}VERDICT: PEER RECOVERY FAILING - Multiple 0-peer recovery attempts${NC}"
    echo -e "  ${YELLOW}Check: Hardcoded seeds may not be reachable. Check network/firewall.${NC}"
elif [ "$total_errors" -gt 10 ]; then
    echo -e "  ${YELLOW}${BOLD}VERDICT: ISSUES PRESENT - Review errors above${NC}"
elif [ "${peers_connected:-0}" -lt 3 ]; then
    echo -e "  ${YELLOW}${BOLD}VERDICT: LOW PEERS - Network connectivity issues${NC}"
else
    echo -e "  ${GREEN}${BOLD}VERDICT: HEALTHY - No major issues detected${NC}"
fi

echo ""
echo -e "${CYAN}Analysis complete.${NC}"
