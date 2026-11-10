#!/usr/bin/env bash
# NTN scenario over two USRP B200/B210 connected by cable (with attenuators): OCUDU gNB + OAI UE.
# One script for the three orbits. The satellite channel comes from the gNB's software channel
# emulator (OCUDU_UHD_CHANNEL_EMU) or from a hardware emulator (EMU=off).
# Derived from run_geo_uhd_local.sh (B200 settings) and run_leo_rfsim.sh (LEO/MEO UE settings).
#
#   ORBIT=geo   configs/ntn/geo_uhd_gnb.yml, epoch stamped at "now"
#   ORBIT=leo   configs/ntn/leo_uhd_gnb.yml, epoch stamped EPOCH_LEAD s ahead (default 12).
#               Geometry: BASE=configs/ntn/leo_uhd_gnb.yml scripts/set_leo_pass.sh --single --no-epoch --elev <deg|horizon>
#   ORBIT=meo   configs/ntn/meo_uhd_gnb.yml, epoch stamped EPOCH_LEAD s ahead (default 12).
#               TIME_DRIFT is required: the value set_meo_pass.sh prints as "UE: --ntn-initial-time-drift ..."
#
#   EMU=orbit (default)  delay/Doppler from the gNB NTN manager (same orbit as SIB19)
#   EMU=udp              values from UDP port 41515 (channel_model.py format)
#   EMU=off              nothing applied in software (use with the Kratos)
#
#   TA_CHECK=1 (default)  restart gNB and UE (up to TA_RETRIES=3 times) when the UE's first timing correction
#                         is more than TA_TOL=10 steps from 0 - the first-PRACH problem of Doppler runs.
#                         Failed attempts keep their UE log as <UE_LOG>_tryN.log. The core is not restarted.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

ORBIT=${ORBIT:-geo}
case $ORBIT in
    geo) DEF_UECFG=ue.ntn.geo.rfsim.conf; DEF_LEAD=0;  DEF_DRIFT="";  RTT_HINT="B200 GEO: ~285 / ~565 ms" ;;
    leo) DEF_UECFG=ue.ntn.leo.rfsim.conf; DEF_LEAD=12; DEF_DRIFT=-40; RTT_HINT="rfsim LEO 1 on the workstation: 158-310 ms" ;;
    meo) DEF_UECFG=ue.ntn.leo.rfsim.conf; DEF_LEAD=12; DEF_DRIFT="";  RTT_HINT="rfsim MEO: ~280-340 ms" ;;
    *)   echo "ORBIT must be geo, leo or meo (got '$ORBIT')" >&2; exit 1 ;;
esac

GNB=${GNB:-$HERE/build_ntn/apps/gnb/gnb}
CFG=${CFG:-$HERE/configs/ntn/${ORBIT}_uhd_gnb.yml}
# Core network overlay (AMF address, NG-U bind address), passed as the last -c like TOSSI's own commands.
# Set CORE_CFG= (empty) to use only $CFG.
CORE_CFG=${CORE_CFG-$HERE/configs/ntn/sdcore.yml}
OAI=${OAI:-$HERE/../OAI_RAN}
UE=${UE:-$OAI/cmake_targets/ran_build/build/nr-uesoftmodem}
UECFG=${UECFG:-$OAI/targets/PROJECTS/GENERIC-NR-5GC/CONF/$DEF_UECFG}

EMU=${EMU:-orbit}
EPOCH_LEAD=${EPOCH_LEAD:-$DEF_LEAD}
TIME_DRIFT=${TIME_DRIFT:-$DEF_DRIFT}

UE_SERIAL=${UE_SERIAL:-328A309}
UE_TX_ATT=${UE_TX_ATT:-25}      # OAI: TX gain = max gain - this value (higher = weaker)
UE_RX_GAIN=${UE_RX_GAIN:-110}   # OAI default
UE_SAMPLE_ADVANCE=${UE_SAMPLE_ADVANCE:-216}  # B200 pair TX/RX latency (14.06 us at 15.36 Msps), measured on PRACH

BAND=${BAND:-256}
DL_FREQ=${DL_FREQ:-2185000000}
UL_OFFSET=${UL_OFFSET:--190000000}
PRB=${PRB:-52}
SSB=${SSB:-62}

PING_TARGET=${PING_TARGET:-10.100.200.32}   # the UPF; re-check after a core restart
PING_COUNT=${PING_COUNT:-20}

GNB_STDOUT=${GNB_STDOUT:-/tmp/gnb_${ORBIT}_uhd_stdout.log}
UE_LOG=${UE_LOG:-/tmp/ue_${ORBIT}_uhd.log}
UE_RUNDIR=${UE_RUNDIR:-/tmp/ue_${ORBIT}_uhd_run}

for f in "$GNB" "$CFG" "$UE" "$UECFG" ${CORE_CFG:+"$CORE_CFG"}; do
    [[ -e $f ]] || { echo "missing: $f" >&2; exit 1; }
done

# Absolute paths: the script changes directory (UE run dir), and restarts reuse these names.
CFG=$(realpath "$CFG")
[[ -n ${CORE_CFG:-} ]] && CORE_CFG=$(realpath "$CORE_CFG")
UE_LOG=$(realpath -m "$UE_LOG")
GNB_STDOUT=$(realpath -m "$GNB_STDOUT")

# The gNB writes its log to the file named in the config (log: filename:), so take the name from there.
GNB_LOG=$(sed -n 's/^  filename: *//p' "$CFG" | head -n 1)
[[ -n $GNB_LOG ]] || { echo "no 'filename:' under log: in $CFG" >&2; exit 1; }

# LEO/MEO: same UE timing flags as TOSSI's run_leo_rfsim.sh (the emulator reproduces the rfsim channel placement).
UE_NTN_ARGS=()
if [[ $ORBIT != geo ]]; then
    [[ -n $TIME_DRIFT ]] || { echo "ORBIT=$ORBIT needs TIME_DRIFT=<us/s> (printed by set_meo_pass.sh)" >&2; exit 1; }
    UE_NTN_ARGS=(--time-sync-I 0.1 --ntn-initial-time-drift "$TIME_DRIFT")
fi

sudo -v

# One attempt = fresh epoch + gNB + UE. Called again by the TA check below.
start_attempt() {
    echo "== killing stale processes"
    sudo pkill -9 -x nr-uesoftmodem || true
    sudo pkill -9 -x gnb || true
    sleep 2

    if [[ ${KEEP_EPOCH:-0} == 1 ]]; then
        echo "== KEEP_EPOCH=1, using the epoch already in $CFG"
    else
        echo "== stamping epoch ${EPOCH_LEAD}s ahead"
        EPOCH=$(date -u -d "+${EPOCH_LEAD} seconds" '+%Y-%m-%dT%H:%M:%S')
        sed -i "s/epoch_timestamp: '[^']*'/epoch_timestamp: '$EPOCH'/" "$CFG"
        date -d "$EPOCH UTC" +%s > "/tmp/${ORBIT}_uhd_epoch"
    fi
    grep -m1 '^ *epoch_timestamp:' "$CFG"
    if [[ $ORBIT == leo ]]; then
        GEOM=$(BASE="$CFG" "$HERE/scripts/set_leo_pass.sh" --show 2>/dev/null || true)
        echo "   geometry at epoch: ${GEOM%%$'\n'*}"
    fi

    sudo rm -f "$GNB_LOG"
    rm -f "$GNB_STDOUT"

    echo "== starting gNB  (orbit: $ORBIT, channel emulator: $EMU, config: $(basename "$CFG")${CORE_CFG:+ + $(basename "$CORE_CFG")}, log: $GNB_LOG)"
    sudo env OCUDU_UHD_CHANNEL_EMU="$EMU" ${GNB_ENV:-} stdbuf -oL -eL "$GNB" -c "$CFG" ${CORE_CFG:+-c "$CORE_CFG"} < /dev/null > "$GNB_STDOUT" 2>&1 &
    GNB_PID=$!
    trap 'sudo pkill -9 -x gnb 2>/dev/null || true; stty sane' EXIT INT TERM

    echo "== waiting for NG setup"
    ng_up() { sudo grep -qaiE "NG Setup Procedure.*(finished successfully|succeeded)" "$GNB_LOG" 2>/dev/null; }
    for _ in $(seq 60); do
        ng_up && break
        kill -0 "$GNB_PID" 2>/dev/null || { echo "gNB died:"; cat "$GNB_STDOUT"; exit 1; }
        sleep 1
    done
    ng_up || { echo "no NG setup after 60s:"; cat "$GNB_STDOUT"; sudo tail -20 "$GNB_LOG" 2>/dev/null; exit 1; }
    echo "   NG setup done"
    grep -m2 "UHD channel emulator" "$GNB_STDOUT" | sed 's/^/   /' || true

    mkdir -p "$UE_RUNDIR"
    echo "== starting UE   (B200 serial $UE_SERIAL, tx att $UE_TX_ATT, NTN args: ${UE_NTN_ARGS[*]:-none}, log: $UE_LOG)"
    cd "$UE_RUNDIR"
    sudo "$UE" -O "$UECFG" \
        --band "$BAND" -C "$DL_FREQ" --CO "$UL_OFFSET" -r "$PRB" --numerology 0 --ssb "$SSB" \
        --usrp-args "type=b200,serial=$UE_SERIAL" \
        --ue-txgain "$UE_TX_ATT" --ue-rxgain "$UE_RX_GAIN" \
        --ue-fo-compensation -A "$UE_SAMPLE_ADVANCE" \
        "${UE_NTN_ARGS[@]}" ${UE_EXTRA_ARGS:-} \
        < /dev/null > "$UE_LOG" 2>&1 &
    UE_PID=$!
    trap 'sudo pkill -9 -x nr-uesoftmodem 2>/dev/null || true; sudo pkill -9 -x gnb 2>/dev/null || true; stty sane' EXIT INT TERM
}

# First-PRACH check (Doppler runs): a run only attaches if the UE's first timing correction is ~0
# (OAI logs "received TA command" = 31 + correction, 0.52 us per step). If it is far off, the first PRACH
# missed the Doppler pre-compensation; such a run never attaches, so restart gNB and UE (not the core).
TA_CHECK=${TA_CHECK:-1}      # 0 = off
TA_TOL=${TA_TOL:-10}         # accepted distance from 31, in steps (10 = 5.2 us)
TA_RETRIES=${TA_RETRIES:-3}  # restarts after the first attempt
TA_WAIT=${TA_WAIT:-60}       # seconds after UE start to wait for the first TA command
first_ta() { sudo grep -ao "received TA command [0-9]*" "$UE_LOG" 2>/dev/null | head -n 1 | awk '{print $4}' || true; }

attempt=0
while :; do
    start_attempt
    [[ $TA_CHECK == 1 ]] || break
    TA=""
    for _ in $(seq "$TA_WAIT"); do
        TA=$(first_ta)
        [[ -n $TA ]] && break
        kill -0 "$UE_PID" 2>/dev/null || break
        sleep 1
    done
    if [[ -z $TA ]]; then
        echo "   first TA command: none within ${TA_WAIT}s (no random access yet), continuing"
        break
    fi
    DEV=$(( TA - 31 )); DEV=${DEV#-}
    US=$(awk -v d="$(( TA - 31 ))" 'BEGIN { printf "%.1f", d * 0.5208 }')
    if (( DEV <= TA_TOL )); then
        echo "   first TA command: $TA (${US} us) - clean first random access"
        break
    fi
    if (( attempt >= TA_RETRIES )); then
        echo "   first TA command: $TA (${US} us) - still off after $((attempt + 1)) attempts, continuing anyway" >&2
        break
    fi
    attempt=$(( attempt + 1 ))
    echo "   first TA command: $TA (${US} us) - first PRACH missed the Doppler pre-compensation;" \
         "restarting gNB and UE (retry $attempt of $TA_RETRIES)"
    sudo pkill -9 -x nr-uesoftmodem || true
    sudo pkill -9 -x gnb || true
    sudo mv -f "$UE_LOG" "${UE_LOG%.log}_try${attempt}.log" 2>/dev/null || true
    sleep 3
done

echo "== waiting for the PDU session"
for _ in $(seq 180); do
    sudo grep -qai 'Interface oaitun_ue1 successfully configured' "$UE_LOG" 2>/dev/null && break
    kill -0 "$UE_PID" 2>/dev/null || { echo "UE died. UE log tail:" >&2; sudo tail -40 "$UE_LOG" >&2; exit 1; }
    sleep 1
done

echo "== emulated channel (gNB log, first and latest update):"
sudo grep -a "Emulated NTN channel updated" "$GNB_LOG" | sed -n '1p;$p' | sed 's/^/   /' || echo "   (no update logged)"

if ip addr show oaitun_ue1 &>/dev/null; then
    echo "== attached"
    ip -4 addr show oaitun_ue1 | sed -n 's/.*inet \([0-9.]*\).*/   UE IP: \1/p'
    echo "== ping over the $ORBIT link (reference: $RTT_HINT)"
    ping -I oaitun_ue1 -c "$PING_COUNT" -W 5 "$PING_TARGET" || true
else
    echo "== NOT attached. UE log tail:" >&2
    sudo tail -40 "$UE_LOG" >&2
    exit 1
fi

echo
echo "gNB log: $GNB_LOG   gNB stdout: $GNB_STDOUT   UE log: $UE_LOG"
echo "Ctrl-C to stop both."
wait $UE_PID
