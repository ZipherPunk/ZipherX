#!/bin/bash

################################################################################
# ZipherX COMPLETE Automated Test Suite
# Fully automated - can run standalone or with guidance
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
NC='\033[0m'

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAC_LOG="$SCRIPT_DIR/zmac.log"
IOS_LOG="$SCRIPT_DIR/z.log"
ZCL_CLI="$SCRIPT_DIR/Resources/Binaries/zclassic-cli"
MAC_DB="$HOME/Library/Application Support/ZipherX/zipherx_wallet.db"
IOS_DB_PATTERN="$HOME/Library/Developer/CoreSimulator/Devices/*/data/Containers/Data/Application/*/Documents/zipherx_wallet.db"

# Addresses
MAC_ADDRESS="zs13s544umnp50tmawapgwh6sxlj69v4ztxjx5fnk2v8hvmg6es7vz68exrfquy3za4eznm522dxjc"
IOS_ADDRESS="zs1dxsppeqc3f0p252ufzfvjfvk6k76yh92fsfu7dznesg4uc48u0j4kv96y5mtmzm582dr742wf4q"

# Test tracking
declare -a RESULTS=()
TEST_NUM=0

################################################################################
# UI Functions
################################################################################

clear_screen() {
    clear
    echo -e "${BOLD}${CYAN}"
    cat <<'EOF'
╔═══════════════════════════════════════════════════════════════════════════╗
║                                                                           ║
║          ███████╗██╗   ██╗████████╗████████╗███████╗██████╗ ███████╗      ║
║          ██╔════╝██║   ██║╚══██╔══╝╚══██╔══╝██╔════╝██╔══██╗██╔════╝      ║
║          ███████╗██║   ██║   ██║      ██║   █████╗  ██║  ██║█████╗        ║
║          ╚════██║██║   ██║   ██║      ██║   ██╔══╝  ██║  ██║██╔══╝        ║
║          ███████║╚██████╔╝   ██║      ██║   ███████╗██████╔╝███████╗      ║
║          ╚══════╝ ╚═════╝    ╚═╝      ╚═╝   ╚══════╝╚═════╝ ╚══════╝      ║
║                                                                           ║
║                    Automated Test Suite v2.0                               ║
║                   macOS + iOS Simulator - Full Testing                    ║
║                                                                           ║
╚═══════════════════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
    echo ""
}

print_section() {
    echo ""
    echo -e "${BOLD}${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}${MAGENTA}  $1${NC}"
    echo -e "${BOLD}${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

log_test() {
    ((TEST_NUM++))
    local status="$1"
    local message="$2"

    if [ "$status" = "PASS" ]; then
        echo -e "${GREEN}[${TEST_NUM}] ✅ PASS${NC}: $message"
        RESULTS+=("PASS: $message")
    elif [ "$status" = "FAIL" ]; then
        echo -e "${RED}[${TEST_NUM}] ❌ FAIL${NC}: $message"
        RESULTS+=("FAIL: $message")
    elif [ "$status" = "WARN" ]; then
        echo -e "${YELLOW}[${TEST_NUM}] ⚠️  WARN${NC}: $message"
        RESULTS+=("WARN: $message")
    else
        echo -e "${CYAN}[${TEST_NUM}] ℹ️  INFO${NC}: $message"
        RESULTS+=("INFO: $message")
    fi
}

log_info() {
    echo -e "${CYAN}▸ $1${NC}"
}

log_success() {
    echo -e "${GREEN}▸ $1${NC}"
}

log_error() {
    echo -e "${RED}▸ $1${NC}"
}

log_warning() {
    echo -e "${YELLOW}▸ $1${NC}"
}

prompt_user() {
    local prompt="$1"
    local default="${2:-}"

    if [ -n "$default" ]; then
        echo -ne "${YELLOW}▸ ${prompt} [${default}]: ${NC}"
        read -r response
        echo "${response:-$default}"
    else
        echo -ne "${YELLOW}▸ ${prompt}: ${NC}"
        read -r response
        echo "$response"
    fi
}

prompt_yes_no() {
    local prompt="$1"
    local default="${2:-n}"

    while true; do
        local response
        if [ "$default" = "y" ]; then
            echo -ne "${YELLOW}▸ ${prompt} [Y/n]: ${NC}"
        else
            echo -ne "${YELLOW}▸ ${prompt} [y/N]: ${NC}"
        fi
        read -r response
        response=${response:-$default}
        echo "$response"

        case "$response" in
            [Yy]|[Yy][Ee][Ss]) return 0 ;;
            [Nn]|[Nn][Oo]) return 1 ;;
        esac
    done
}

################################################################################
# System Checks
################################################################################

check_zclassic_node() {
    print_section "Step 1: Zclassic Node Verification"

    if [ ! -f "$ZCL_CLI" ]; then
        log_error "zclassic-cli not found at: $ZCL_CLI"
        return 1
    fi

    log_success "zclassic-cli found"

    # Check if node is running
    if $ZCL_CLI getblockchaininfo >/dev/null 2>&1; then
        log_success "Zclassic node is running"

        # Get block count
        local blocks=$($ZCL_CLI getblockcount 2>/dev/null || echo "0")
        log_info "Current block height: $blocks"

        return 0
    else
        log_error "Zclassic node is NOT responding"
        log_info "Please start zclassicd first"
        return 1
    fi
}

get_on_chain_balance() {
    local address="$1"

    local balance=$($ZCL_CLI z_getbalance "$address" 2>/dev/null || echo "0")
    echo "$balance"
}

################################################################################
# Test Categories
################################################################################

test_prerequisites() {
    print_section "Step 2: Prerequisites Check"

    # Check zclassic node
    if check_zclassic_node; then
        log_test "PASS" "Zclassic node running"
    else
        log_test "FAIL" "Zclassic node not running"
        return 1
    fi

    # Get on-chain balances
    echo ""
    log_info "Verifying on-chain balances..."

    local mac_balance=$(get_on_chain_balance "$MAC_ADDRESS")
    local ios_balance=$(get_on_chain_balance "$IOS_ADDRESS")

    log_info "macOS address balance: $mac_balance ZCL"
    log_info "iOS address balance: $ios_balance ZCL"

    if [ "$mac_balance" != "0" ]; then
        log_test "PASS" "macOS address has balance on-chain"
    else
        log_test "WARN" "macOS address shows 0 balance"
    fi

    if [ "$ios_balance" != "0" ]; then
        log_test "PASS" "iOS address has balance on-chain"
    else
        log_test "WARN" "iOS address shows 0 balance"
    fi

    return 0
}

test_log_files() {
    print_section "Step 3: Log File Verification"

    # Check macOS log
    if [ -f "$MAC_LOG" ]; then
        local mac_lines=$(wc -l < "$MAC_LOG" 2>/dev/null || echo "0")
        local mac_size=$(du -h "$MAC_LOG" | cut -f1)
        log_success "macOS log exists: $mac_lines lines, $mac_size"
        log_test "PASS" "macOS log file present"
    else
        log_error "macOS log NOT found: $MAC_LOG"
        log_test "FAIL" "macOS log file missing"
    fi

    # Check iOS log
    if [ -f "$IOS_LOG" ]; then
        local ios_lines=$(wc -l < "$IOS_LOG" 2>/dev/null || echo "0")
        local ios_size=$(du -h "$IOS_LOG" | cut -f1)
        log_success "iOS log exists: $ios_lines lines, $ios_size"
        log_test "PASS" "iOS log file present"
    else
        log_error "iOS log NOT found: $IOS_LOG"
        log_test "FAIL" "iOS log file missing"
    fi
}

analyze_app_log() {
    local log_file="$1"
    local platform="$2"

    if [ ! -f "$log_file" ]; then
        echo "N/A"
        return
    fi

    local issues=0

    # Check Tor mode
    if grep -q "Tor mode: enabled" "$log_file"; then
        echo "Tor: ENABLED (should be disabled)"
        ((issues++))
    elif grep -q "Tor mode: disabled" "$log_file"; then
        echo "Tor: DISABLED ✓"
    else
        echo "Tor: Unknown"
    fi

    # Check startup
    if grep -q "FAST START" "$log_file"; then
        echo "Startup: FAST START ✓"
    elif grep -q "FULL START" "$log_file"; then
        echo "Startup: FULL START"
    else
        echo "Startup: Unknown"
        ((issues++))
    fi

    # Check peers
    local peers=$(grep -E "Connected to [0-9]+/[0-9]+" "$log_file" 2>/dev/null | tail -1 | grep -oE "[0-9]+/[0-9]+" || echo "?/?")
    echo "Peers: $peers"

    # Check errors
    local errors=$(grep -c "❌ Failed:" "$log_file" 2>/dev/null || echo "0")
    local socks5=$(grep -c "SOCKS5 error" "$log_file" 2>/dev/null || echo "0")
    echo "Errors: $errors, SOCKS5: $socks5"

    if [ "$socks5" -gt 0 ]; then
        ((issues++))
    fi

    return $issues
}

test_tor_status() {
    print_section "Step 4: Tor Mode Status"

    echo ""
    echo -e "${BOLD}macOS Status:${NC}"
    analyze_app_log "$MAC_LOG" "macOS"
    local mac_result=$?

    echo ""
    echo -e "${BOLD}iOS Status:${NC}"
    analyze_app_log "$IOS_LOG" "iOS"
    local ios_result=$?

    if [ $mac_result -eq 0 ] && [ $ios_result -eq 0 ]; then
        log_test "PASS" "Tor disabled on both platforms"
    else
        log_test "FAIL" "Tor not properly disabled"
    fi
}

test_databases() {
    print_section "Step 5: Database Verification"

    # macOS database
    if [ -f "$MAC_DB" ]; then
        log_success "macOS database exists"

        local total_notes=$(sqlite3 "$MAC_DB" "SELECT COUNT(*) FROM notes;" 2>/dev/null || echo "0")
        local unspent_notes=$(sqlite3 "$MAC_DB" "SELECT COUNT(*) FROM notes WHERE is_spent = 0;" 2>/dev/null || echo "0")
        local balance=$(sqlite3 "$MAC_DB" "SELECT SUM(CASE WHEN is_spent = 0 THEN value ELSE 0 END) FROM notes;" 2>/dev/null || echo "0")
        local balance_zcl=$(echo "scale=8; $balance / 100000000" | bc 2>/dev/null || echo "0")

        echo ""
        echo "  Total notes: $total_notes"
        echo "  Unspent notes: $unspent_notes"
        echo "  Balance: $balance_zcl ZCL"

        if [ "$unspent_notes" -gt 0 ]; then
            log_test "PASS" "macOS has notes ($unspent_notes unspent)"
        else
            log_test "WARN" "macOS has no unspent notes"
        fi

        # Compare with on-chain
        local onchain=$(get_on_chain_balance "$MAC_ADDRESS")
        local balance_int=$(echo "$balance / 1" | bc 2>/dev/null || echo "0")
        local onchain_int=$(echo "$onchain * 100000000 / 1" | bc 2>/dev/null || echo "0")
        local diff=$((balance_int - onchain_int))
        local abs_diff=${diff#-}

        if [ "$abs_diff" -lt 10000 ]; then
            log_test "PASS" "macOS balance matches on-chain"
        else
            log_test "WARN" "macOS balance differs from on-chain"
        fi
    else
        log_error "macOS database NOT found"
        log_test "FAIL" "macOS database missing"
    fi

    # iOS database
    echo ""
    local ios_db=$(find $IOS_DB_PATTERN 2>/dev/null | head -1)
    if [ -n "$ios_db" ] && [ -f "$ios_db" ]; then
        log_success "iOS database exists: $ios_db"

        local total_notes=$(sqlite3 "$ios_db" "SELECT COUNT(*) FROM notes;" 2>/dev/null || echo "0")
        local unspent_notes=$(sqlite3 "$ios_db" "SELECT COUNT(*) FROM notes WHERE is_spent = 0;" 2>/dev/null || echo "0")
        local balance=$(sqlite3 "$ios_db" "SELECT SUM(CASE WHEN is_spent = 0 THEN value ELSE 0 END) FROM notes;" 2>/dev/null || echo "0")
        local balance_zcl=$(echo "scale=8; $balance / 100000000" | bc 2>/dev/null || echo "0")

        echo ""
        echo "  Total notes: $total_notes"
        echo "  Unspent notes: $unspent_notes"
        echo "  Balance: $balance_zcl ZCL"

        if [ "$unspent_notes" -gt 0 ]; then
            log_test "PASS" "iOS has notes ($unspent_notes unspent)"
        else
            log_test "WARN" "iOS has no unspent notes"
        fi

        # Compare with on-chain
        local onchain=$(get_on_chain_balance "$IOS_ADDRESS")
        local balance_int=$(echo "$balance / 1" | bc 2>/dev/null || echo "0")
        local onchain_int=$(echo "$onchain * 100000000 / 1" | bc 2>/dev/null || echo "0")
        local diff=$((balance_int - onchain_int))
        local abs_diff=${diff#-}

        if [ "$abs_diff" -lt 10000 ]; then
            log_test "PASS" "iOS balance matches on-chain"
        else
            log_test "WARN" "iOS balance differs from on-chain"
        fi
    else
        log_error "iOS database NOT found"
        log_test "FAIL" "iOS database missing"
    fi
}

test_transaction_history() {
    print_section "Step 6: Transaction History"

    # macOS
    if [ -f "$MAC_DB" ]; then
        local tx_count=$(sqlite3 "$MAC_DB" "SELECT COUNT(*) FROM transaction_history;" 2>/dev/null || echo "0")
        echo "macOS: $tx_count transactions"

        if [ "$tx_count" -gt 0 ]; then
            echo ""
            sqlite3 -column -header "$MAC_DB" "SELECT type, amount, fee, datetime, confirmations FROM transaction_history ORDER BY datetime DESC LIMIT 5;" 2>/dev/null || true
            log_test "PASS" "macOS has transaction history ($tx_count TXs)"
        else
            log_test "INFO" "macOS has no transaction history yet"
        fi
    fi

    echo ""

    # iOS
    local ios_db=$(find $IOS_DB_PATTERN 2>/dev/null | head -1)
    if [ -n "$ios_db" ] && [ -f "$ios_db" ]; then
        local tx_count=$(sqlite3 "$ios_db" "SELECT COUNT(*) FROM transaction_history;" 2>/dev/null || echo "0")
        echo "iOS: $tx_count transactions"

        if [ "$tx_count" -gt 0 ]; then
            echo ""
            sqlite3 -column -header "$ios_db" "SELECT type, amount, fee, datetime, confirmations FROM transaction_history ORDER BY datetime DESC LIMIT 5;" 2>/dev/null || true
            log_test "PASS" "iOS has transaction history ($tx_count TXs)"
        else
            log_test "INFO" "iOS has no transaction history yet"
        fi
    fi
}

test_sync_status() {
    print_section "Step 7: Sync Status"

    # Check macOS
    if [ -f "$MAC_LOG" ]; then
        echo "macOS:"
        local mac_height=$(grep "lastScannedHeight:" "$MAC_LOG" 2>/dev/null | tail -1 | grep -oE "[0-9]+" || echo "Unknown")
        local mac_sync=$(grep "Background sync:" "$MAC_LOG" 2>/dev/null | tail -1 || echo "No recent sync")
        echo "  Height: $mac_height"
        echo "  Last sync: $mac_sync"

        if [ "$mac_height" != "Unknown" ] && [ "$mac_height" -gt 2900000 ]; then
            log_test "PASS" "macOS is synced (height: $mac_height)"
        else
            log_test "WARN" "macOS sync status unclear"
        fi
    fi

    echo ""

    # Check iOS
    if [ -f "$IOS_LOG" ]; then
        echo "iOS:"
        local ios_height=$(grep "lastScannedHeight:" "$IOS_LOG" 2>/dev/null | tail -1 | grep -oE "[0-9]+" || echo "Unknown")
        local ios_sync=$(grep "Background sync:" "$IOS_LOG" 2>/dev/null | tail -1 || echo "No recent sync")
        echo "  Height: $ios_height"
        echo "  Last sync: $ios_sync"

        if [ "$ios_height" != "Unknown" ] && [ "$ios_height" -gt 2900000 ]; then
            log_test "PASS" "iOS is synced (height: $ios_height)"
        else
            log_test "WARN" "iOS sync status unclear"
        fi
    fi
}

print_summary() {
    print_section "Test Summary"

    local total=${#RESULTS[@]}
    local passed=0
    local failed=0
    local warned=0

    for result in "${RESULTS[@]}"; do
        case "$result" in
            PASS:*) ((passed++)) ;;
            FAIL:*) ((failed++)) ;;
            WARN:*) ((warned++)) ;;
        esac
    done

    echo ""
    echo -e "${BOLD}Results:${NC}"
    echo "  Total Tests: $total"
    echo -e "  ${GREEN}Passed:${NC}    $passed"
    echo -e "  ${YELLOW}Warnings:${NC}  $warned"
    echo -e "  ${RED}Failed:${NC}    $failed"
    echo ""

    # Calculate score
    local score=0
    if [ $total -gt 0 ]; then
        score=$((passed * 100 / total))
    fi

    echo -e "${BOLD}Score: ${score}%${NC}"
    echo ""

    # Verdict
    if [ $failed -eq 0 ] && [ $warned -lt 3 ]; then
        echo -e "${GREEN}${BOLD}✅ EXCELLENT: All systems operational${NC}"
    elif [ $failed -eq 0 ]; then
        echo -e "${YELLOW}${BOLD}⚠️  GOOD: Minor warnings${NC}"
    elif [ $score -ge 70 ]; then
        echo -e "${YELLOW}${BOLD}⚠️  FAIR: Some issues detected${NC}"
    else
        echo -e "${RED}${BOLD}❌ POOR: Major issues${NC}"
    fi

    echo ""
}

interactive_mode() {
    clear_screen

    echo -e "${BOLD}${CYAN}Select Test Mode:${NC}"
    echo ""
    echo "  1. Quick Test (basic checks only)"
    echo "  2. Full Test (all functionality)"
    echo "  3. Continuous Monitoring (real-time)"
    echo "  4. Custom Test (select specific tests)"
    echo "  5. Exit"
    echo ""

    local choice=$(prompt_user "Enter choice [1-5]" "2")

    case "$choice" in
        1) quick_test ;;
        2) full_test ;;
        3) continuous_monitoring ;;
        4) custom_test ;;
        5) exit 0 ;;
        *) full_test ;;
    esac
}

quick_test() {
    clear_screen
    echo -e "${BOLD}Running Quick Tests...${NC}"
    echo ""

    test_prerequisites
    test_log_files
    test_tor_status

    print_summary
}

full_test() {
    clear_screen
    echo -e "${BOLD}Running Full Test Suite...${NC}"
    echo ""

    test_prerequisites
    test_log_files
    test_tor_status
    test_databases
    test_transaction_history
    test_sync_status

    print_summary
}

continuous_monitoring() {
    clear_screen
    echo -e "${BOLD}Continuous Monitoring Mode${NC}"
    echo ""
    log_info "Press Ctrl+C to stop"
    echo ""

    local iteration=0

    while true; do
        ((iteration++))
        clear_screen
        echo -e "${BOLD}${CYAN}Monitoring Cycle #$iteration${NC}"
        echo -e "${BOLD}$(date)${NC}"
        echo ""

        # Quick status
        if [ -f "$MAC_LOG" ]; then
            local mac_latest=$(tail -1 "$MAC_LOG" 2>/dev/null || echo "No data")
            echo -e "${CYAN}macOS:${NC} $mac_latest"
        fi

        if [ -f "$IOS_LOG" ]; then
            local ios_latest=$(tail -1 "$IOS_LOG" 2>/dev/null || echo "No data")
            echo -e "${CYAN}iOS:${NC}   $ios_latest"
        fi

        echo ""
        echo "Checking in 10 seconds... (Ctrl+C to stop)"

        sleep 10
    done
}

custom_test() {
    clear_screen
    echo -e "${BOLD}Custom Test Selection${NC}"
    echo ""
    echo "Available tests:"
    echo "  1. Prerequisites (node, addresses)"
    echo "  2. Log files verification"
    echo "  3. Tor status check"
    echo "  4. Database verification"
    echo "  5. Transaction history"
    echo "  6. Sync status"
    echo "  a. All tests"
    echo ""

    local choice=$(prompt_user "Select test(s) [1-6 or a]" "")

    case "$choice" in
        1) test_prerequisites ;;
        2) test_log_files ;;
        3) test_tor_status ;;
        4) test_databases ;;
        5) test_transaction_history ;;
        6) test_sync_status ;;
        a|A) full_test ;;
        *) log_error "Invalid choice" ;;
    esac

    print_summary
}

################################################################################
# Main Entry Point
################################################################################

main() {
    # Check if running interactively
    if [ -t 0 ]; then
        # Interactive mode
        interactive_mode
    else
        # Non-interactive (scripted mode)
        full_test
    fi
}

# Run
main "$@"
