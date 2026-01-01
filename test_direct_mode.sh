#!/bin/bash

# ZipherX Direct Connection Mode Test Script
# Tests core functionality without Tor

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

LOGFILE="/Users/chris/ZipherX/zmac.log"

echo ""
echo -e "${BOLD}${CYAN}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}║     ZIPHERX DIRECT CONNECTION MODE - TEST SUITE               ║${NC}"
echo -e "${BOLD}${CYAN}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Check if log exists
if [ ! -f "$LOGFILE" ]; then
    echo -e "${RED}Error: Log file not found: $LOGFILE${NC}"
    echo "Please start the app first."
    exit 1
fi

echo -e "${CYAN}Log file:${NC} $LOGFILE"
echo -e "${CYAN}File size:${NC} $(du -h "$LOGFILE" | cut -f1)"
echo -e "${CYAN}Line count:${NC} $(wc -l < "$LOGFILE")"
echo ""

# ============================================================================
# TEST 1: TOR DISABLED CHECK
# ============================================================================
echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}${BLUE}  TEST 1: TOR MODE CHECK${NC}"
echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

if grep -q "Tor mode: disabled" "$LOGFILE"; then
    echo -e "${GREEN}✅ PASS: Tor is DISABLED (direct connection mode)${NC}"
    grep "Tor mode" "$LOGFILE" | tail -1
elif grep -q "Tor mode: enabled" "$LOGFILE"; then
    echo -e "${RED}❌ FAIL: Tor is still ENABLED${NC}"
    echo "Please disable Tor in settings first."
    exit 1
else
    echo -e "${YELLOW}⚠️  WARNING: Could not determine Tor mode${NC}"
fi

echo ""

# ============================================================================
# TEST 2: STARTUP & SYNC
# ============================================================================
echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}${BLUE}  TEST 2: STARTUP & SYNC${NC}"
echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

echo -e "${YELLOW}Startup Mode:${NC}"
if grep -q "FAST START" "$LOGFILE"; then
    echo -e "${GREEN}✅ FAST START${NC} detected"
    startup_time=$(grep "FAST START" "$LOGFILE" | head -1 | grep -oE "\[[0-9]+:[0-9]+:[0-9]+\.[0-9]+\]")
    echo "   Time: $startup_time"
elif grep -q "FULL START" "$LOGFILE"; then
    echo -e "${YELLOW}⚠️  FULL START${NC} (first run or reset)"
else
    echo -e "${RED}❌ Could not detect startup mode${NC}"
fi

echo ""
echo -e "${YELLOW}Header Sync:${NC}"
if grep -q "Header sync complete" "$LOGFILE"; then
    echo -e "${GREEN}✅ Header sync completed${NC}"
    grep "Header sync complete" "$LOGFILE" | tail -1
else
    echo -e "${YELLOW}⚠️  No header sync completion found${NC}"
fi

sync_timeouts=$(grep -c "Header sync.*timeout" "$LOGFILE" 2>/dev/null || echo "0")
if [ "$sync_timeouts" -gt 0 ]; then
    echo -e "${YELLOW}⚠️  Header sync timeouts: $sync_timeouts${NC}"
else
    echo -e "${GREEN}✅ No header sync timeouts${NC}"
fi

echo ""
echo -e "${YELLOW}Background Sync:${NC}"
bg_syncs=$(grep -c "Background sync:" "$LOGFILE" 2>/dev/null || echo "0")
if [ "$bg_syncs" -gt 0 ]; then
    echo -e "${GREEN}✅ Background sync events: $bg_syncs${NC}"
    grep "Background sync:" "$LOGFILE" | tail -3
else
    echo -e "${YELLOW}⚠️  No background sync events yet${NC}"
fi

echo ""

# ============================================================================
# TEST 3: PEER CONNECTIONS
# ============================================================================
echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}${BLUE}  TEST 3: PEER CONNECTIONS (Direct Mode)${NC}"
echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

connected=$(grep -E "Connected to [0-9]+/[0-9]+" "$LOGFILE" 2>/dev/null | wc -l | tr -d ' ')
failed=$(grep -E "❌ Failed:|Connection failed" "$LOGFILE" 2>/dev/null | wc -l | tr -d ' ')

echo -e "${YELLOW}Connection Summary:${NC}"
echo "   Connected: $connected"
echo "   Failed: $failed"

final_peers=$(grep -E "Connected to [0-9]+/[0-9]+" "$LOGFILE" 2>/dev/null | tail -1 | grep -oE "[0-9]+/[0-9]+" || echo "?/?")
echo "   Final peer count: $final_peers"

if [ "$connected" -gt 0 ]; then
    echo -e "${GREEN}✅ Direct connections working${NC}"
else
    echo -e "${RED}❌ No successful connections${NC}"
fi

# Check for SOCKS5 errors (should be 0 in direct mode)
socks5_errors=$(grep -c "SOCKS5 error: Connection refused" "$LOGFILE" 2>/dev/null || echo "0")
if [ "$socks5_errors" -eq 0 ]; then
    echo -e "${GREEN}✅ No SOCKS5 errors (expected in direct mode)${NC}"
else
    echo -e "${YELLOW}⚠️  Found $socks5_errors SOCKS5 errors (Tor may not be fully disabled)${NC}"
fi

echo ""

# ============================================================================
# TEST 4: DATABASE & BALANCE
# ============================================================================
echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}${BLUE}  TEST 4: DATABASE & BALANCE${NC}"
echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

MAC_DB="/Users/chris/Library/Application Support/ZipherX/zipherx_wallet.db"
MAC_HEADERS="/Users/chris/Library/Application Support/ZipherX/zipherx_headers.db"

if [ -f "$MAC_DB" ]; then
    echo -e "${GREEN}✅ Wallet database exists${NC}"

    echo ""
    echo -e "${YELLOW}Notes:${NC}"
    sqlite3 "$MAC_DB" "SELECT COUNT(*) as total, SUM(CASE WHEN is_spent = 0 THEN 1 ELSE 0 END) as unspent, SUM(CASE WHEN is_spent = 0 THEN value ELSE 0 END) as unspent_balance FROM notes;" 2>/dev/null || echo "   (query failed)"

    echo ""
    echo -e "${YELLOW}Sync State:${NC}"
    sqlite3 "$MAC_DB" "SELECT last_scanned_height, verified_checkpoint_height, cached_chain_height FROM sync_state;" 2>/dev/null || echo "   (query failed)"

    echo ""
    echo -e "${YELLOW}Unspent notes needing witness:${NC}"
    needs_witness=$(sqlite3 "$MAC_DB" "SELECT COUNT(*) FROM notes WHERE is_spent = 0 AND (witness IS NULL OR witness = X'' OR length(witness) < 100);" 2>/dev/null || echo "0")
    if [ "$needs_witness" -eq 0 ]; then
        echo -e "${GREEN}✅ All unspent notes have witnesses${NC}"
    else
        echo -e "${YELLOW}⚠️  $needs_witness notes need witness rebuild${NC}"
    fi
else
    echo -e "${RED}❌ Wallet database not found${NC}"
fi

if [ -f "$MAC_HEADERS" ]; then
    echo ""
    echo -e "${YELLOW}Headers:${NC}"
    sqlite3 "$MAC_HEADERS" "SELECT MIN(height) as min_h, MAX(height) as max_h, COUNT(*) as count FROM headers;" 2>/dev/null || echo "   (query failed)"
fi

echo ""

# ============================================================================
# TEST 5: ERRORS & WARNINGS
# ============================================================================
echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}${BLUE}  TEST 5: ERRORS & WARNINGS${NC}"
echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

total_errors=$(grep -c "❌ Failed:" "$LOGFILE" 2>/dev/null || echo "0")
cancellations=$(grep -c "Swift.CancellationError" "$LOGFILE" 2>/dev/null || echo "0")
warnings=$(grep -c "⚠️" "$LOGFILE" 2>/dev/null || echo "0")

echo -e "${YELLOW}Error Summary:${NC}"
echo "   Total failures: $total_errors"
echo "   Cancellations: $cancellations"
echo "   Warnings: $warnings"

if [ "$total_errors" -eq 0 ]; then
    echo -e "${GREEN}✅ No errors detected${NC}"
elif [ "$total_errors" -lt 10 ]; then
    echo -e "${YELLOW}⚠️  Minor errors (acceptable)${NC}"
else
    echo -e "${RED}❌ Many errors detected${NC}"
fi

echo ""

# ============================================================================
# TEST 6: HEALTH CHECKS
# ============================================================================
echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}${BLUE}  TEST 6: HEALTH CHECKS${NC}"
echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

health_issues=$(grep -E "health check.*issue|health check.*failed|WALLET HEALTH.*issue" "$LOGFILE" 2>/dev/null | wc -l | tr -d ' ')
if [ "$health_issues" -eq 0 ]; then
    echo -e "${GREEN}✅ No health issues detected${NC}"
else
    echo -e "${YELLOW}⚠️  Health issues found: $health_issues${NC}"
fi

echo ""

# ============================================================================
# OVERALL VERDICT
# ============================================================================
echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}${BLUE}  OVERALL VERDICT${NC}"
echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Calculate score
score=0
max_score=10

# Tor disabled
if grep -q "Tor mode: disabled" "$LOGFILE" || ! grep -q "Tor mode: enabled" "$LOGFILE"; then
    score=$((score + 2))
fi

# Header sync completed
if grep -q "Header sync complete" "$LOGFILE"; then
    score=$((score + 2))
fi

# Peers connected
if [ "$connected" -gt 0 ]; then
    score=$((score + 2))
fi

# Database exists
if [ -f "$MAC_DB" ]; then
    score=$((score + 2))
fi

# Low errors
if [ "$total_errors" -lt 20 ]; then
    score=$((score + 2))
fi

echo -e "${CYAN}Score: ${BOLD}$score/$max_score${NC}"
echo ""

if [ "$score" -eq 10 ]; then
    echo -e "${GREEN}${BOLD}✅ EXCELLENT: All systems operational${NC}"
    echo -e "${GREEN}Direct connection mode is working perfectly!${NC}"
elif [ "$score" -ge 7 ]; then
    echo -e "${YELLOW}${BOLD}⚠️  GOOD: Minor issues detected${NC}"
    echo -e "${YELLOW}Core functionality works, see details above.${NC}"
elif [ "$score" -ge 5 ]; then
    echo -e "${YELLOW}${BOLD}⚠️  FAIR: Some issues need attention${NC}"
    echo -e "${YELLOW}Review the failed tests above.${NC}"
else
    echo -e "${RED}${BOLD}❌ POOR: Major issues detected${NC}"
    echo -e "${RED}Significant problems need investigation.${NC}"
fi

echo ""
echo -e "${CYAN}Test complete.${NC}"
echo ""
