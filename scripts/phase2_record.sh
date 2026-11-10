#!/usr/bin/env bash
# phase2_record.sh - Doppler test plan, Phase 2.
# Starts the gNB alone (no UE), waits until the satellite is above the horizon, records the downlink with the
# UE-side B200, then stops the gNB. The recording is analysed with scripts/phase2_cfo.py.
#
# Usage (core must be up for the NG setup):
#   CFG=configs/ntn/meo_uhd_gnb.yml     OUT=/tmp/p2_meo_ref.dat scripts/phase2_record.sh   # Doppler off (reference)
#   CFG=configs/ntn/meo_uhd_dop_gnb.yml OUT=/tmp/p2_meo_dop.dat scripts/phase2_record.sh   # Doppler on
#
#   PROBE=1 CFG=configs/ntn/meo_uhd_gnb.yml scripts/phase2_record.sh   # level per antenna port and gain, no file
#
# Optional: RX_GAIN (40), RX_ANT ("" = UHD default port; "TX/RX" or "RX2"), DURATION (1 s), EPOCH_LEAD (12 s),
#           WAIT_AFTER_EPOCH (5 s), EMU (orbit), CORE_CFG (configs/ntn/sdcore.yml; empty = none).
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CFG=${CFG:?set CFG=<gNB config>}
OUT=${OUT:-}
[[ ${PROBE:-0} == 1 || -n $OUT ]] || { echo "set OUT=<recording file> (or PROBE=1)" >&2; exit 1; }
CORE_CFG=${CORE_CFG-$HERE/configs/ntn/sdcore.yml}
GNB=${GNB:-$HERE/build_ntn/apps/gnb/gnb}
EMU=${EMU:-orbit}
EPOCH_LEAD=${EPOCH_LEAD:-12}
WAIT_AFTER_EPOCH=${WAIT_AFTER_EPOCH:-5}
UE_SERIAL=${UE_SERIAL:-328A309}
RX_GAIN=${RX_GAIN:-40}
RX_ANT=${RX_ANT:-}
DURATION=${DURATION:-1}
GNB_STDOUT=${GNB_STDOUT:-/tmp/p2_gnb_stdout.log}

for f in "$GNB" "$CFG" "$HERE/scripts/rec_b200.py" "$HERE/scripts/phase2_cfo.py" ${CORE_CFG:+"$CORE_CFG"}; do
    [[ -e $f ]] || { echo "missing: $f" >&2; exit 1; }
done
GNB_LOG=$(sed -n 's/^  filename: *//p' "$CFG" | head -n 1)
[[ -n $GNB_LOG ]] || { echo "no 'filename:' under log: in $CFG" >&2; exit 1; }

doppler_line() {   # latest emulator update, with the Doppler derived from the drift
    sudo grep -a "Emulated NTN channel updated.*sat=" "$GNB_LOG" | tail -n 1 | \
      awk '{ t=substr($1,12,12); d=""; dr=""; dop="";
             for (i=1;i<=NF;i++) { if ($i~/^rx_delay=/) d=$i; if ($i~/^drift=/) dr=$i; if ($i~/^doppler=/) dop=$i }
             x=dr; gsub(/drift=|us\/s/,"",x); r=-0.5*x*1e-6;
             printf "   %s %s %s %s -> DL Doppler from drift %+.1f Hz\n", t, d, dr, dop, r*2185e6 }'
}

sudo -v
echo "== killing stale processes"
sudo pkill -9 -x nr-uesoftmodem || true
sudo pkill -9 -x gnb || true
sleep 2

EPOCH=$(date -u -d "+${EPOCH_LEAD} seconds" '+%Y-%m-%dT%H:%M:%S')
sed -i "s/epoch_timestamp: '[^']*'/epoch_timestamp: '$EPOCH'/" "$CFG"
EPOCH_S=$(date -u -d "$EPOCH" +%s)
echo "== epoch $EPOCH (UTC) in $(basename "$CFG")"

sudo rm -f "$GNB_LOG"
echo "== starting gNB  (emulator: $EMU, config: $(basename "$CFG")${CORE_CFG:+ + $(basename "$CORE_CFG")}, log: $GNB_LOG)"
sudo env OCUDU_UHD_CHANNEL_EMU="$EMU" stdbuf -oL -eL "$GNB" -c "$CFG" ${CORE_CFG:+-c "$CORE_CFG"} < /dev/null > "$GNB_STDOUT" 2>&1 &
GNB_PID=$!
trap 'sudo pkill -9 -x gnb 2>/dev/null || true; stty sane 2>/dev/null || true' EXIT INT TERM

echo "== waiting for NG setup"
ng_up() { sudo grep -qaiE "NG Setup Procedure.*(finished successfully|succeeded)" "$GNB_LOG" 2>/dev/null; }
for _ in $(seq 60); do
    ng_up && break
    kill -0 "$GNB_PID" 2>/dev/null || { echo "gNB died:"; cat "$GNB_STDOUT"; exit 1; }
    sleep 1
done
ng_up || { echo "no NG setup after 60s:"; cat "$GNB_STDOUT"; exit 1; }
echo "   NG setup done"
grep -m2 "UHD channel emulator" "$GNB_STDOUT" | sed 's/^/   /' || true

echo "== waiting until ${WAIT_AFTER_EPOCH} s after the epoch (satellite above the horizon)"
while (( $(date +%s) < EPOCH_S + WAIT_AFTER_EPOCH )); do sleep 1; done
echo "   emulator before recording:"
doppler_line

if [[ ${PROBE:-0} == 1 ]]; then
    echo "== probe on B200 $UE_SERIAL: level and OFDM quality per antenna port and gain"
    python3 "$HERE/scripts/rec_b200.py" --serial "$UE_SERIAL" --probe
else
    REC_START=$(date '+%H:%M:%S.%3N')
    echo "== recording ${DURATION} s on B200 $UE_SERIAL (2185 MHz, 15.36 Msps, gain $RX_GAIN${RX_ANT:+, port $RX_ANT}) -> $OUT"
    python3 "$HERE/scripts/rec_b200.py" --serial "$UE_SERIAL" --gain "$RX_GAIN" ${RX_ANT:+--ant "$RX_ANT"} \
            --duration "$DURATION" --out "$OUT"
    ls -l "$OUT" | sed 's/^/   /'
    REC_END=$(date '+%H:%M:%S.%3N')
    # A recording is only valid if the gNB kept its radio fed while it was made.
    N_RT=$( { sudo grep -a "Real-time failure in RF" "$GNB_LOG" || true; } | \
           awk -v a="$REC_START" -v b="$REC_END" '{ t=substr($1,12,12); if (t>=a && t<=b) n++ } END { print n+0 }')
    if (( N_RT > 0 )); then
        echo "   WARNING: $N_RT gNB RF real-time failures (underflow/late/overflow) during the recording -> recording NOT valid"
    else
        echo "   gNB RF real-time failures during the recording: 0 (valid)"
    fi
    grep -a "Operating over" "$GNB_STDOUT" | sed 's/^/   gNB radio: /' || true
fi
echo "   emulator after recording:"
doppler_line
echo "== stopping gNB"
