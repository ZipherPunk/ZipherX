#!/bin/bash
export LC_ALL=C
set -eu
set -o pipefail
###COLORS######################
NC=`echo -e "\e[39m"`
RED=`echo -e "\e[31m"`
GREEN=`echo -e "\e[32m"`
BLUE=`echo -e "\e[34m"`
YELLOW=`echo -e "\e[33m"`
###############################
###SERVERS#####################
RSERVER="http://zclassic.info.gf/"
###############################
WGETCMD="$(command -v wget || echo '${RED}You do not have wget. Install wget and continue.${NC}')"
uname_S=$(uname -s 2>/dev/null || echo not)

if [ "$uname_S" = "Darwin" ]; then
    PARAMS_DIR="$HOME/Library/Application Support/ZcashParams"
else
    PARAMS_DIR="$HOME/.zcash-params"
fi

sync() {
#CHECK FOR WGET
echo "[${GREEN}*${NC}] Checking for wget ..."
echo "${GREEN}${WGETCMD}${NC} ... [${GREEN}ok!${NC}]"
#PARAMS_DIR CHECK
echo "[${GREEN}*${NC}] Checking for clean params directory ..."
if [ -d "${PARAMS_DIR}" ]; then
echo "${RED} Directory ${PARAMS_DIR} exists, please delete this directory or run with the clean directive and try again!${NC}"; exit
else
mkdir -p ${PARAMS_DIR} && cd $_
#SYNC PARAMS & KEYS
echo "[${GREEN}*${NC}] Syncing params ..."
wget -q -r -l1 -nd -N --no-parent -A "*.params" -P ${PARAMS_DIR} $RSERVER/zclassic-params/
echo "[${GREEN}*${NC}] Syncing keys ..."
wget -q -r -l1 -nd -N --no-parent -A "*.key" -P ${PARAMS_DIR} $RSERVER/zclassic-params/
echo "[${GREEN}*${NC}] Syncing SHASUM and USAGE files ..."
wget -q -r -l1 -nd -N --no-parent -A "*.txt" -P ${PARAMS_DIR} $RSERVER/zclassic-params/
fi
}

verify(){
#VERIFY
echo "[${GREEN}*${NC}] Verifying params ..."
sha256sum --check ${PARAMS_DIR}/SHASUMS.txt || echo 'S{RED}Checksums do not match!${NC}';exit
}

doclean(){
rm -rf "${PARAMS_DIR}"
}

helpbanner () {
echo "Li0tLS0tLi0tLS0tLi0tLi0tLi0tLS0tLi0tLS0uCnwtLSBfX3xfXyAtLXwgIHwgIHwgICAgIHwg
IF9ffAp8X19fX198X19fX198X19fICB8X198X198X19fX3wKICAgICAgICAgICAgfF9fX19ffCAg
ICAgICAgICAgCgo=" | base64 -d 
echo $RED "ZSYNC: Choose an option: $0 {sv|so|clean|help}" $NC
echo $RED "sv: sync and verify keys" $NC
echo $RED "so: sync only, do not verify" $NC
echo $RED "clean: clean the ${PARAMS_DIR} and remove all keys" $NC
echo $RED "help: this help banner" $NC
}

############################################################
while [ ! $# -eq 0 ]
do
    case "$1" in
        -help | -?)
            helpbanner
            exit
            ;;
        sv)
           #SYNCS FILES AND VERIFIES CHECKSUMS
            sync && verify
            exit
            ;;
        so)
            #JUST SYNC FILES, DOES NOT VERIFY!
            sync
            exit
            ;;
        clean)
             #CLEAN THE ZCASH_PARAMS DIR
            doclean
            exit
            ;;
    esac
    shift
done


