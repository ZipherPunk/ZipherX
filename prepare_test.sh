#!/bin/bash

################################################################################
# ZipherX - Fresh Start Guide
# Prepares apps for testing with Tor disabled
################################################################################

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

clear
echo -e "${BOLD}${CYAN}"
echo "╔═══════════════════════════════════════════════════════════════════════════╗"
echo "║                                                                           ║"
echo "║              ZIPHERX - TESTING PREPARATION                               ║"
echo "║              Tor Disabled - Fresh Start Guide                            ║"
echo "║                                                                           ║"
echo "╚═══════════════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo ""

################################################################################
# Instructions
################################################################################

echo -e "${BOLD}STEP 1: Clear Old Logs${NC}"
echo ""
echo "Running: rm zmac.log z.log"
rm -f zmac.log z.log 2>/dev/null || true
echo -e "${GREEN}✅ Old logs cleared${NC}"
echo ""

echo -e "${BOLD}STEP 2: Backup Current State (Optional)${NC}"
echo ""
echo "If you want to preserve current databases:"
echo "  cp -r ~/Library/Application\ Support/ZipherX ~/ZipherX_Backup_\$(date +%Y%m%d)"
echo "  cp -r ~/Library/Developer/CoreSimulator/Devices/*/data/Containers/Data/Application/*/Documents/ZipherX ~/iOS_Backup_\$(date +%Y%m%d) 2>/dev/null || true"
echo ""

echo -e "${BOLD}STEP 3: Disable Tor in Both Apps${NC}"
echo ""
echo -e "${YELLOW}macOS App:${NC}"
echo "  1. Open ZipherX macOS app"
echo "  2. Go to Settings"
echo "  3. Find 'Tor Mode'"
echo "  4. Set to 'Disabled' or 'Direct'"
echo "  5. Quit the app completely"
echo ""

echo -e "${YELLOW}iOS Simulator:${NC}"
echo "  1. Open ZipherX iOS Simulator app"
echo "  2. Go to Settings"
echo "  3. Find 'Tor Mode'"
echo "  4. Set to 'Disabled' or 'Direct'"
echo "  5. Quit the app completely"
echo ""

echo -e "${BOLD}STEP 4: Start Apps and Wait${NC}"
echo ""
echo -e "${CYAN}Instructions:${NC}"
echo "  1. Start macOS app first"
echo "  2. Wait for it to fully sync (watch for 'Synced' status)"
echo "  3. Start iOS Simulator app"
echo "  4. Wait for it to fully sync"
echo "  5. Let both apps run for 2-3 minutes"
echo "  6. Then run: ./run_all_tests.sh"
echo ""

echo -e "${BOLD}STEP 5: Verify Tor is Disabled${NC}"
echo ""
echo "After starting apps, check the logs show:"
echo -e "  ${GREEN}✓ 'Tor mode: disabled'${NC}"
echo -e "  ${GREEN}✓ 'Direct connection'${NC}"
echo -e "  ${RED}✗ NOT 'Tor mode: enabled'${NC}"
echo ""

################################################################################
# Quick Log Check Function
################################################################################

check_logs() {
    echo ""
    echo -e "${BOLD}Checking for fresh logs...${NC}"
    echo ""

    if [ -f "zmac.log" ]; then
        local mac_lines=$(wc -l < zmac.log)
        echo "  zmac.log: $mac_lines lines"

        if grep -q "Tor mode: disabled" zmac.log; then
            echo -e "    ${GREEN}✓ Tor is DISABLED${NC}"
        elif grep -q "Tor mode: enabled" zmac.log; then
            echo -e "    ${RED}✗ Tor is still ENABLED - please disable in settings${NC}"
        else
            echo "    ? Tor mode unknown (app still starting)"
        fi
    else
        echo "  zmac.log: NOT FOUND (app not started yet)"
    fi

    echo ""

    if [ -f "z.log" ]; then
        local ios_lines=$(wc -l < z.log)
        echo "  z.log: $ios_lines lines"

        if grep -q "Tor mode: disabled" z.log; then
            echo -e "    ${GREEN}✓ Tor is DISABLED${NC}"
        elif grep -q "Tor mode: enabled" z.log; then
            echo -e "    ${RED}✗ Tor is still ENABLED - please disable in settings${NC}"
        else
            echo "    ? Tor mode unknown (app still starting)"
        fi
    else
        echo "  z.log: NOT FOUND (app not started yet)"
    fi
}

################################################################################
# Monitor Function
################################################################################

monitor_logs() {
    echo ""
    echo -e "${BOLD}Starting log monitor...${NC}"
    echo -e "${YELLOW}Press Ctrl+C to stop${NC}"
    echo ""

    local iteration=0

    while true; do
        ((iteration++))
        clear
        echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${BOLD}${CYAN}  ZipherX Log Monitor - Cycle #$iteration${NC}"
        echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        echo -e "${BOLD}$(date)${NC}"
        echo ""

        # macOS
        if [ -f "zmac.log" ]; then
            echo -e "${BOLD}macOS App:${NC}"
            local mac_latest=$(tail -3 zmac.log 2>/dev/null | grep -v "^$" | head -5)
            if [ -n "$mac_latest" ]; then
                echo "$mac_latest"
            fi

            # Check Tor
            if grep -q "Tor mode: disabled" zmac.log; then
                echo -e "  ${GREEN}✓ Tor: DISABLED${NC}"
            elif grep -q "Tor mode: enabled" zmac.log; then
                echo -e "  ${RED}✗ Tor: ENABLED (should be disabled)${NC}"
            fi

            # Check peers
            local mac_peers=$(grep -E "Connected to [0-9]+/[0-9]+" zmac.log 2>/dev/null | tail -1 | grep -oE "[0-9]+/[0-9]+" || echo "?")
            echo "  Peers: $mac_peers"
        else
            echo -e "${YELLOW}macOS: Waiting for log file...${NC}"
        fi

        echo ""

        # iOS
        if [ -f "z.log" ]; then
            echo -e "${BOLD}iOS Simulator:${NC}"
            local ios_latest=$(tail -3 z.log 2>/dev/null | grep -v "^$" | head -5)
            if [ -n "$ios_latest" ]; then
                echo "$ios_latest"
            fi

            # Check Tor
            if grep -q "Tor mode: disabled" z.log; then
                echo -e "  ${GREEN}✓ Tor: DISABLED${NC}"
            elif grep -q "Tor mode: enabled" z.log; then
                echo -e "  ${RED}✗ Tor: ENABLED (should be disabled)${NC}"
            fi

            # Check peers
            local ios_peers=$(grep -E "Connected to [0-9]+/[0-9]+" z.log 2>/dev/null | tail -1 | grep -oE "[0-9]+/[0-9]+" || echo "?")
            echo "  Peers: $ios_peers"
        else
            echo -e "${YELLOW}iOS: Waiting for log file...${NC}"
        fi

        echo ""
        echo -e "${CYAN}Next check in 10 seconds... (Ctrl+C to stop)${NC}"

        sleep 10
    done
}

################################################################################
# Main Menu
################################################################################

show_menu() {
    echo ""
    echo -e "${BOLD}${CYAN}What would you like to do?${NC}"
    echo ""
    echo "  1. Check current log status"
    echo "  2. Monitor logs in real-time"
    echo "  3. View instructions again"
    echo "  4. Exit"
    echo ""
    echo -ne "${YELLOW}Enter choice [1-4]: ${NC}"
    read -r choice

    case "$choice" in
        1)
            check_logs
            show_menu
            ;;
        2)
            monitor_logs
            ;;
        3)
            clear
            exec "$0"
            ;;
        4)
            echo ""
            echo -e "${CYAN}Good luck with testing!${NC}"
            echo ""
            exit 0
            ;;
        *)
            echo -e "${RED}Invalid choice${NC}"
            show_menu
            ;;
    esac
}

# Start
if [ "$1" = "--check" ]; then
    check_logs
elif [ "$1" = "--monitor" ]; then
    monitor_logs
else
    show_menu
fi
