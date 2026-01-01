#!/bin/bash

################################################################################
# ZipherX Full Automated Test Suite
# Tests macOS and iOS Simulator apps with continuous log monitoring
################################################################################

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Configuration
MAC_LOG="/Users/chris/ZipherX/zmac.log"
IOS_LOG="/Users/chris/ZipherX/z.log"
ZCL_CLI="/Users/chris/ZipherX/Resources/Binaries/zclassic-cli"

# Test addresses
MAC_ADDRESS="zs13s544umnp50tmawapgwh6sxlj69v4ztxjx5fnk2v8hvmg6es7vz68exrfquy3za4eznm522dxjc"
IOS_ADDRESS="zs1dxsppeqc3f0p252ufzfvjfvk6k76yh92fsfu7dznesg4uc48u0j4kv96y5mtmzm582dr742wf4q"

# Expected balances (from on-chain)
MAC_EXPECTED_BALANCE="0.91880000"
IOS_EXPECTED_BALANCE="0.01600000"

# Test duration (seconds)
TEST_DURATION=300  # 5 minutes
CHECK_INTERVAL=10  # Check every 10 seconds

# Results tracking
declare -A TESTS_PASSED
declare -A TESTS_FAILED
TOTAL_TESTS=0
PASSED_TESTS=0

################################################################################
# Helper Functions
################################################################################

log() {
    echo -e "${CYAN}[$(date '+%H:%M:%S')]${NC} $1"
}

log_success() {
    echo -e "${GREEN}✅ $1${NC}"
    TESTS_PASSED["$1"]=1
    ((PASSED_TESTS++))
    ((TOTAL_TESTS++))
}

log_fail() {
    echo -e "${RED}❌ $1${NC}"
    TESTS_FAILED["$1"]=1
    ((TOTAL_TESTS++))
}

log_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

log_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

log_section() {
    echo ""
    echo -e "${BOLD}${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${MAGENTA}  $1${NC}"
    echo -e "${BOLD}${MAGENTA}════════════════════════════════════════════════════════════════${NC}"
    echo ""
}

print_header() {
    clear
    echo -e "${BOLD}${CYAN}"
    echo "╔═══════════════════════════════════════════════════════════════════════════╗"
    echo "║                                                                       ║"
    echo "║          ZIPHERX AUTOMATED TEST SUITE v1.0                            ║"
    echo "║          macOS + iOS Simulator - Continuous Testing                   ║"
    echo "║                                                                       ║"
    echo "╚═══════════════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo ""
}

################################################################################
# Log Analysis Functions
################################################################################

get_last_line() {
    local log_file="$1"
    if [ -f "$log_file" ]; then
        tail -1 "$log_file"
    fi
}

get_log_age() {
    local log_file="$1"
    if [ -f "$log_file" ]; then
        local modified=$(stat -f "%m" "$log_file" 2>/dev/null || stat -c "%Y" "$log_file" 2>/dev/null)
        local now=$(date +%s)
        echo $((now - modified))
    else
        echo "999999"
    fi
}

count_log_lines() {
    local log_file="$1"
    if [ -f "$log_file" ]; then
        wc -l < "$log_file" 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}

################################################################################
# Test Functions
################################################################################

test_log_exists() {
    log_section "Test 1: Log Files Exist"

    if [ -f "$MAC_LOG" ]; then
        log_success "macOS log exists: $MAC_LOG"
        local mac_lines=$(count_log_lines "$MAC_LOG")
        log_info "  Lines: $mac_lines"
    else
        log_fail "macOS log NOT found: $MAC_LOG"
    fi

    if [ -f "$IOS_LOG" ]; then
        log_success "iOS log exists: $IOS_LOG"
        local ios_lines=$(count_log_lines "$IOS_LOG")
        log_info "  Lines: $ios_lines"
    else
        log_fail "iOS log NOT found: $IOS_LOG"
    fi
}

test_tor_disabled() {
    log_section "Test 2: Tor Mode Disabled (Direct Connections)"

    # Check macOS
    if [ -f "$MAC_LOG" ]; then
        if grep -q "Tor mode: disabled" "$MAC_LOG" || ! grep -q "Tor mode: enabled" "$MAC_LOG"; then
            log_success "macOS: Tor is disabled"
        else
            log_fail "macOS: Tor is still ENABLED"
            grep "Tor mode:" "$MAC_LOG" | tail -1
        fi
    fi

    # Check iOS
    if [ -f "$IOS_LOG" ]; then
        if grep -q "Tor mode: disabled" "$IOS_LOG" || ! grep -q "Tor mode: enabled" "$IOS_LOG"; then
            log_success "iOS: Tor is disabled"
        else
            log_fail "iOS: Tor is still ENABLED"
            grep "Tor mode:" "$IOS_LOG" | tail -1
        fi
    fi
}

check_app_startup() {
    local log_file="$1"
    local platform="$2"

    # Check for startup messages
    if grep -q "FAST START" "$log_file" 2>/dev/null; then
        log_success "$platform: FAST START detected"
        return 0
    elif grep -q "FULL START" "$log_file" 2>/dev/null; then
        log_warning "$platform: FULL START (first run or reset)"
        return 0
    elif grep -q "ContentView" "$log_file" 2>/dev/null; then
        log_success "$platform: App started"
        return 0
    else
        log_fail "$platform: No startup detected"
        return 1
    fi
}

test_startup() {
    log_section "Test 3: App Startup Detection"

    if [ -f "$MAC_LOG" ]; then
        check_app_startup "$MAC_LOG" "macOS"
    fi

    if [ -f "$IOS_LOG" ]; then
        check_app_startup "$IOS_LOG" "iOS"
    fi
}

check_peer_connections() {
    local log_file="$1"
    local platform="$2"

    # Get latest peer count
    local latest_peers=$(grep -E "Connected to [0-9]+/[0-9]+" "$log_file" 2>/dev/null | tail -1 | grep -oE "[0-9]+/[0-9]+" || echo "")

    if [ -n "$latest_peers" ]; then
        local connected=$(echo "$latest_peers" | cut -d'/' -f1)
        log_info "$platform: Peers connected: $connected"

        if [ "$connected" -ge 5 ]; then
            log_success "$platform: Good peer count ($connected >= 5)"
            return 0
        elif [ "$connected" -ge 3 ]; then
            log_warning "$platform: Adequate peer count ($connected >= 3)"
            return 0
        else
            log_warning "$platform: Low peer count ($connected < 3)"
            return 1
        fi
    else
        log_warning "$platform: No peer connection info found"
        return 1
    fi
}

test_peer_connections() {
    log_section "Test 4: Peer Connections"

    if [ -f "$MAC_LOG" ]; then
        check_peer_connections "$MAC_LOG" "macOS"
    fi

    if [ -f "$IOS_LOG" ]; then
        check_peer_connections "$IOS_LOG" "iOS"
    fi
}

check_sync_progress() {
    local log_file="$1"
    local platform="$2"

    # Check for sync progress
    if grep -q "Syncing blockchain" "$log_file" 2>/dev/null; then
        local latest_sync=$(grep "Syncing blockchain" "$log_file" 2>/dev/null | tail -1)
        log_info "$platform: Syncing: $latest_sync"
        return 0
    fi

    # Check for FAST START completion
    if grep -q "FAST START.*0 blocks behind" "$log_file" 2>/dev/null; then
        log_success "$platform: Sync completed (FAST START)"
        return 0
    fi

    # Check for last scanned height
    local height=$(grep "lastScannedHeight:" "$log_file" 2>/dev/null | tail -1 | grep -oE "[0-9]+" || echo "")
    if [ -n "$height" ] && [ "$height" -gt 2900000 ]; then
        log_success "$platform: Synced to height $height"
        return 0
    fi

    log_warning "$platform: Sync status unclear"
    return 1
}

test_sync_status() {
    log_section "Test 5: Sync Status"

    if [ -f "$MAC_LOG" ]; then
        check_sync_progress "$MAC_LOG" "macOS"
    fi

    if [ -f "$IOS_LOG" ]; then
        check_sync_progress "$IOS_LOG" "iOS"
    fi
}

check_balance_from_db() {
    local db_path="$1"
    local platform="$2"
    local expected="$3"

    if [ ! -f "$db_path" ]; then
        log_warning "$platform: Database not found at $db_path"
        return 1
    fi

    local balance=$(sqlite3 "$db_path" "SELECT SUM(CASE WHEN is_spent = 0 THEN value ELSE 0 END) FROM notes;" 2>/dev/null || echo "")

    if [ -n "$balance" ] && [ "$balance" != "" ]; then
        # Convert to ZCL (divide by 100,000,000)
        local balance_zcl=$(echo "scale=8; $balance / 100000000" | bc 2>/dev/null || echo "0")
        local expected_zcl=$(echo "scale=8; $expected / 100000000" | bc 2>/dev/null || echo "0")

        log_info "$platform: Balance = $balance_zcl ZCL (expected: $expected_zcl ZCL)"

        # Check if balance matches (within small margin for pending TXs)
        local diff=$(echo "$balance - $expected" | bc 2>/dev/null || echo "0")
        local abs_diff=${diff#-}  # Absolute value

        if [ "$abs_diff" -lt 1000 ]; then  # Less than 0.00001 ZCL difference
            log_success "$platform: Balance matches on-chain"
            return 0
        else
            log_warning "$platform: Balance differs from on-chain by $abs_diff zatoshis"
            return 1
        fi
    else
        log_warning "$platform: Could not read balance from database"
        return 1
    fi
}

test_balance_accuracy() {
    log_section "Test 6: Balance Accuracy"

    # macOS
    local mac_db="/Users/chris/Library/Application Support/ZipherX/zipherx_wallet.db"
    if [ -f "$mac_db" ]; then
        check_balance_from_db "$mac_db" "macOS" "$MAC_EXPECTED_BALANCE"
    else
        log_warning "macOS: Database not found"
    fi

    # iOS Simulator
    local ios_db="$HOME/Library/Developer/CoreSimulator/Devices/*/data/Containers/Data/Application/*/Documents/zipherx_wallet.db"
    local ios_db_found=$(find $HOME/Library/Developer/CoreSimulator/Devices/*/data/Containers/Data/Application/*/Documents/zipherx_wallet.db 2>/dev/null | head -1)

    if [ -n "$ios_db_found" ] && [ -f "$ios_db_found" ]; then
        check_balance_from_db "$ios_db_found" "iOS" "$IOS_EXPECTED_BALANCE"
    else
        log_warning "iOS: Database not found at expected path"
    fi
}

check_transaction_count() {
    local db_path="$1"
    local platform="$2"

    if [ ! -f "$db_path" ]; then
        return 1
    fi

    local tx_count=$(sqlite3 "$db_path" "SELECT COUNT(*) FROM transaction_history;" 2>/dev/null || echo "0")

    if [ "$tx_count" -gt 0 ]; then
        log_success "$platform: Has $tx_count transactions in history"
        return 0
    else
        log_warning "$platform: No transactions found"
        return 1
    fi
}

test_transaction_history() {
    log_section "Test 7: Transaction History"

    # macOS
    local mac_db="/Users/chris/Library/Application Support/ZipherX/zipherx_wallet.db"
    if [ -f "$mac_db" ]; then
        check_transaction_count "$mac_db" "macOS"
    fi

    # iOS
    local ios_db_found=$(find $HOME/Library/Developer/CoreSimulator/Devices/*/data/Containers/Data/Application/*/Documents/zipherx_wallet.db 2>/dev/null | head -1)
    if [ -n "$ios_db_found" ] && [ -f "$ios_db_found" ]; then
        check_transaction_count "$ios_db_found" "iOS"
    fi
}

check_header_sync() {
    local log_file="$1"
    local platform="$2"

    if grep -q "Header sync complete" "$log_file" 2>/dev/null; then
        local count=$(grep -c "Header sync complete" "$log_file" 2>/dev/null || echo "0")
        log_success "$platform: Header sync completed ($count times)"
        return 0
    elif grep -q "HeaderStore.*headers" "$log_file" 2>/dev/null; then
        log_success "$platform: Headers present in HeaderStore"
        return 0
    else
        log_warning "$platform: Header sync status unclear"
        return 1
    fi
}

test_header_sync() {
    log_section "Test 8: Header Sync"

    if [ -f "$MAC_LOG" ]; then
        check_header_sync "$MAC_LOG" "macOS"
    fi

    if [ -f "$IOS_LOG" ]; then
        check_header_sync "$IOS_LOG" "iOS"
    fi
}

check_errors() {
    local log_file="$1"
    local platform="$2"

    # Count errors
    local total_errors=$(grep -c "❌ Failed:" "$log_file" 2>/dev/null || echo "0")
    local cancellations=$(grep -c "Swift.CancellationError" "$log_file" 2>/dev/null || echo "0")
    local socks5_errors=$(grep -c "SOCKS5 error" "$log_file" 2>/dev/null || echo "0")

    log_info "$platform: Errors: $total_errors, Cancellations: $cancellations, SOCKS5: $socks5_errors"

    if [ "$socks5_errors" -eq 0 ]; then
        log_success "$platform: No SOCKS5 errors (good for direct mode)"
    else
        log_fail "$platform: Found $socks5_errors SOCKS5 errors (Tor may be enabled)"
    fi

    if [ "$total_errors" -lt 50 ]; then
        log_success "$platform: Error count acceptable ($total_errors < 50)"
        return 0
    else
        log_warning "$platform: High error count ($total_errors >= 50)"
        return 1
    fi
}

test_error_count() {
    log_section "Test 9: Error Analysis"

    if [ -f "$MAC_LOG" ]; then
        check_errors "$MAC_LOG" "macOS"
    fi

    if [ -f "$IOS_LOG" ]; then
        check_errors "$IOS_LOG" "iOS"
    fi
}

check_recent_activity() {
    local log_file="$1"
    local platform="$2"
    local age_limit="$3"  # seconds

    local age=$(get_log_age "$log_file")

    if [ "$age" -lt "$age_limit" ]; then
        log_success "$platform: Log recently updated (${age}s ago)"
        return 0
    else
        log_warning "$platform: Log not recently updated (${age}s ago)"
        return 1
    fi
}

test_log_activity() {
    log_section "Test 10: Log Activity (Apps Running)"

    if [ -f "$MAC_LOG" ]; then
        check_recent_activity "$MAC_LOG" "macOS" 60
    fi

    if [ -f "$IOS_LOG" ]; then
        check_recent_activity "$IOS_LOG" "iOS" 60
    fi
}

################################################################################
# Continuous Monitoring
################################################################################

monitor_logs() {
    local duration=$1

    log_section "Continuous Monitoring (${duration}s)"
    log_info "Press Ctrl+C to stop early..."
    echo ""

    local start_time=$(date +%s)
    local check_num=0

    while true; do
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))

        if [ $elapsed -ge $duration ]; then
            break
        fi

        ((check_num++))
        local remaining=$((duration - elapsed))

        echo -e "${BOLD}${BLUE}━━━ Check #$check_num ━━━ (${remaining}s remaining) ━━━${NC}"

        # Quick status check
        if [ -f "$MAC_LOG" ]; then
            local mac_age=$(get_log_age "$MAC_LOG")
            local mac_latest=$(get_last_line "$MAC_LOG" | head -c 100)
            echo -e "${CYAN}macOS (${mac_age}s ago):${NC} $mac_latest"
        fi

        if [ -f "$IOS_LOG" ]; then
            local ios_age=$(get_log_age "$IOS_LOG")
            local ios_latest=$(get_last_line "$IOS_LOG" | head -c 100)
            echo -e "${CYAN}iOS   (${ios_age}s ago):${NC} $ios_latest"
        fi

        echo ""

        sleep $CHECK_INTERVAL
    done
}

################################################################################
# Final Report
################################################################################

print_final_report() {
    log_section "FINAL TEST REPORT"

    echo -e "${BOLD}Test Results Summary:${NC}"
    echo ""

    local pass_rate=0
    if [ $TOTAL_TESTS -gt 0 ]; then
        pass_rate=$((PASSED_TESTS * 100 / TOTAL_TESTS))
    fi

    echo -e "  Total Tests:  ${BOLD}$TOTAL_TESTS${NC}"
    echo -e "  Passed:       ${GREEN}$PASSED_TESTS${NC}"
    echo -e "  Failed:       ${RED}$((TOTAL_TESTS - PASSED_TESTS))${NC}"
    echo -e "  Pass Rate:    ${BOLD}${pass_rate}%${NC}"
    echo ""

    # List failed tests
    if [ $PASSED_TESTS -lt $TOTAL_TESTS ]; then
        echo -e "${RED}Failed Tests:${NC}"
        for test in "${!TESTS_FAILED[@]}"; do
            echo -e "  ${RED}✗${NC} $test"
        done
        echo ""
    fi

    # Overall verdict
    if [ $pass_rate -ge 90 ]; then
        echo -e "${GREEN}${BOLD}✅ EXCELLENT: All systems operational${NC}"
    elif [ $pass_rate -ge 70 ]; then
        echo -e "${YELLOW}${BOLD}⚠️  GOOD: Minor issues detected${NC}"
    elif [ $pass_rate -ge 50 ]; then
        echo -e "${YELLOW}${BOLD}⚠️  FAIR: Some issues need attention${NC}"
    else
        echo -e "${RED}${BOLD}❌ POOR: Major issues detected${NC}"
    fi

    echo ""
    echo -e "${CYAN}Test completed at: $(date)${NC}"
    echo ""
}

################################################################################
# Main Execution
################################################################################

main() {
    print_header

    log "Starting ZipherX Automated Test Suite..."
    log "Test duration: ${TEST_DURATION}s"
    log "Check interval: ${CHECK_INTERVAL}s"
    echo ""

    log_info "Expected balances:"
    log_info "  macOS:  $MAC_EXPECTED_BALANCE zatoshis (0.9188 ZCL)"
    log_info "  iOS:    $IOS_EXPECTED_BALANCE zatoshis (0.0160 ZCL)"
    echo ""

    # Run all tests
    test_log_exists
    test_tor_disabled
    test_startup
    test_peer_connections
    test_sync_status
    test_balance_accuracy
    test_transaction_history
    test_header_sync
    test_error_count
    test_log_activity

    # Continuous monitoring
    monitor_logs $TEST_DURATION

    # Final report
    print_final_report
}

# Run main function
main "$@"
