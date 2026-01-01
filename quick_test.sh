#!/bin/bash

################################################################################
# ZipherX ONE-TOUCH Test Runner
# Simplest possible - just run and see results
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
echo "║                   ZIPHERX QUICK TEST                                   ║"
echo "║                   One-Touch Full Testing                               ║"
echo "║                                                                           ║"
echo "╚═══════════════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo -e "${BLUE}Running comprehensive tests...${NC}"
echo ""

# Run the full test suite
if [ -f "./run_all_tests.sh" ]; then
    ./run_all_tests.sh
else
    echo -e "${RED}Error: run_all_tests.sh not found${NC}"
    exit 1
fi
