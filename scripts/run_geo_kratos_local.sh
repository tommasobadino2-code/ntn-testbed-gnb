#!/usr/bin/env bash
# GEO scenario over two USRP B200/B210 connected by cable (with attenuators), OCUDU gNB + OAI UE.
# The satellite channel comes from the gNB's software channel emulator (OCUDU_UHD_CHANNEL_EMU), or from
# a hardware emulator (EMU=off). Derived from run_geo_rfsim_local.sh.
#
#   EMU=orbit (default)  delay/Doppler from the gNB NTN manager (same orbit as SIB19)
#   EMU=udp              values from channel_model.py on UDP port 41515
#   EMU=off              nothing applied in software (use with the Kratos)
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

GNB=${GNB:-$HERE/build_ntn/apps/gnb/gnb}
CFG=${CFG:-$HERE/configs/ntn/geo_kratos_gnb.yml}
OAI=${OAI:-$HERE/../OAI_RAN}
UE=${UE:-$OAI/cmake_targets/ran_build/build/nr-uesoftmodem}
UECFG=${UECFG:-$OAI/targets/PROJECTS/GENERIC-NR-5GC/CONF/ue.ntn.geo.rfsim.conf}

EMU=${EMU:-orbit}
UE_SERIAL=${UE_SERIAL:-328A309}
UE_TX_ATT=${UE_TX_ATT:-40}      # OAI: TX gain = max gain - this value (higher = weaker)
UE_RX_GAIN=${UE_RX_GAIN:-110}   # OAI default
UE_SAMPLE_ADVANCE=${UE_SAMPLE_ADVANCE:-216}  # B200 pair TX/RX latency (14.06 us at 15.36 Msps), measured on PRACH

BAND=${BAND:-256}
DL_FREQ=${DL_FREQ:-2185000000}
UL_OFFSET=${UL_OFFSET:--190000000}
PRB=${PRB:-52}
SSB=${SSB:-62}

GNB_LOG=${GNB_LOG:-/tmp/gnb_geo_kratos.log}
GNB_STDOUT=${GNB_STDOUT:-/tmp/gnb_geo_kratos_stdout.log}
UE_LOG=${UE_LOG:-/tmp/ue_geo_kratos.log}
UE_RUNDIR=${UE_RUNDIR:-/tmp/ue_geo_kratos_run}

for f in "$GNB" "$CFG" "$UE" "$UECFG"; do
    [[ -e $f ]] || { echo "missing: $f" >&2; exit 1; }
done

sudo -v

echo "== killing stale processes"
sudo pkill -9 -f nr-uesoftmodem || true
sudo pkill -9 -f 'apps/gnb/gnb' || true
sleep 2

echo "== refreshing epoch_timestamp"
sed -i "s/epoch_timestamp: '[^']*'/epoch_timestamp: '$(date -u '+%Y-%m-%dT%H:%M:%S')'/" "$CFG"
grep -m1 '^ *epoch_timestamp:' "$CFG"

sudo rm -f "$GNB_LOG"
rm -f "$GNB_STDOUT"

echo "== starting gNB  (channel emulator: $EMU, log: $GNB_LOG)"
sudo env OCUDU_UHD_CHANNEL_EMU="$EMU" stdbuf -oL -eL "$GNB" -c "$CFG" < /dev/null > "$GNB_STDOUT" 2>&1 &
trap 'sudo pkill -9 -f apps/gnb/gnb 2>/dev/null || true; stty sane' EXIT INT TERM

echo "== waiting for NG setup"
ng_up() { sudo grep -qaiE "NG Setup Procedure.*(finished successfully|succeeded)" "$GNB_LOG" 2>/dev/null; }
for _ in $(seq 60); do
    ng_up && break
    pgrep -f "apps/gnb/gnb" >/dev/null || { echo "gNB died:"; cat "$GNB_STDOUT"; exit 1; }
    sleep 1
done
ng_up || { echo "no NG setup after 60s:"; cat "$GNB_STDOUT"; sudo tail -20 "$GNB_LOG" 2>/dev/null; exit 1; }
echo "   NG setup done"
grep -m2 "UHD channel emulator" "$GNB_STDOUT" | sed 's/^/   /' || true

mkdir -p "$UE_RUNDIR"
echo "== starting UE   (B210 serial $UE_SERIAL, log: $UE_LOG)"
cd "$UE_RUNDIR"
sudo "$UE" -O "$UECFG" \
    --band "$BAND" -C "$DL_FREQ" --CO "$UL_OFFSET" -r "$PRB" --numerology 0 --ssb "$SSB" \
    --usrp-args "type=b200,serial=$UE_SERIAL" \
    --ue-txgain "$UE_TX_ATT" --ue-rxgain "$UE_RX_GAIN" \
    --if_freq 1598000000 --if_freq_off 15000000 --ue-fo-compensation -A "$UE_SAMPLE_ADVANCE" ${UE_EXTRA_ARGS:-} \
    < /dev/null > "$UE_LOG" 2>&1 &
UE_PID=$!
trap 'sudo pkill -9 -f nr-uesoftmodem 2>/dev/null || true; sudo pkill -9 -f apps/gnb/gnb 2>/dev/null || true; stty sane' EXIT INT TERM

echo "== waiting for the PDU session"
for _ in $(seq 180); do
    sudo grep -qai 'Interface oaitun_ue1 successfully configured' "$UE_LOG" 2>/dev/null && break
    pgrep -f nr-uesoftmodem >/dev/null || { echo "UE died. UE log tail:" >&2; sudo tail -40 "$UE_LOG" >&2; exit 1; }
    sleep 1
done

echo "== emulated channel (gNB log):"
sudo grep -a "Emulated NTN channel updated" "$GNB_LOG" | tail -1 | sed 's/^/   /' || echo "   (no update logged)"

if ip addr show oaitun_ue1 &>/dev/null; then
    echo "== attached"
    ip -4 addr show oaitun_ue1 | sed -n 's/.*inet \([0-9.]*\).*/   UE IP: \1/p'
    echo "== ping over the GEO link (expect ~500 ms RTT)"
    ping -I oaitun_ue1 -c 4 -W 5 "${PING_TARGET:-10.0.0.1}" || true
else
    echo "== NOT attached. UE log tail:" >&2
    sudo tail -40 "$UE_LOG" >&2
    exit 1
fi

echo
echo "gNB log: $GNB_LOG   gNB stdout: $GNB_STDOUT   UE log: $UE_LOG"
echo "Ctrl-C to stop both."
wait $UE_PID
