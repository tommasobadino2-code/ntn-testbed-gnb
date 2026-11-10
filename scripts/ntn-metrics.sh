#!/usr/bin/env bash
# ntn-metrics.sh - one-page summary of a B200 NTN run (Doppler test plan, Section 3).
# Usage: scripts/ntn-metrics.sh <gnb log> <ue log>
#   e.g. scripts/ntn-metrics.sh /tmp/gnb_leo_uhd.log /tmp/ue_leo_uhd.log
# Read-only: it only reads the two logs.
set -uo pipefail

GNB_LOG=${1:?usage: $0 <gnb log> <ue log>}
UE_LOG=${2:?usage: $0 <gnb log> <ue log>}
DL_HZ=${DL_HZ:-2185e6}
UL_HZ=${UL_HZ:-1995e6}
for f in "$GNB_LOG" "$UE_LOG"; do [[ -r $f ]] || { echo "cannot read $f" >&2; exit 1; }; done

# UE log without colour codes (OAI writes ANSI escapes).
UE_CLEAN=$(mktemp); trap 'rm -f "$UE_CLEAN"' EXIT
sed 's/\x1b\[[0-9;]*m//g' "$UE_LOG" > "$UE_CLEAN"

median_of() { sort -n | awk '{a[NR]=$1} END {if (NR==0) print "-"; else printf "%.1f", a[int(NR/2)+1]}'; }

echo "== run: $GNB_LOG + $UE_LOG"

echo "-- emulated channel (gNB NTN manager)"
grep -a "Emulated NTN channel updated" "$GNB_LOG" | sed -n '1p;$p' | \
  awk -v dl="$DL_HZ" -v ul="$UL_HZ" '{
      t=substr($1,12,12); d=""; dr=""; dop="";
      for (i=1;i<=NF;i++) { if ($i~/^rx_delay=/) d=$i; if ($i~/^drift=/) dr=$i; if ($i~/^doppler=/) dop=$i }
      x=dr; gsub(/drift=|us\/s/,"",x); r=-0.5*x*1e-6;
      printf "   %s %s %s %s -> Doppler from drift: DL %+.0f Hz, UL %+.0f Hz\n", t, d, dr, dop, r*dl, r*ul }'
n_upd=$(grep -ac "Emulated NTN channel updated" "$GNB_LOG")
echo "   updates logged: $n_upd"

echo "-- UE frequency"
grep -a -m1 "Got synch" "$UE_CLEAN" | sed 's/^/   /'
grep -a "Measured Carrier Frequency offset" "$UE_CLEAN" | tail -n 1 | sed 's/^/   last: /'
grep -a "DL Doppler shift" "$UE_CLEAN" | sed -n '1p;$p' | grep -o "timing_advance_ntn.*" | sed 's/^/   SIB19: /'

echo "-- PRACH (real detections, detection_metric >= 3)"
grep -a "PRACH:" "$GNB_LOG" | grep -o "ta=[0-9.]*us detection_metric=[0-9.]* power_dB=[-0-9.]*" | \
  awk '{ split($2,m,"="); if (m[2]+0 >= 3) { n++; print "   " $0 } } END { if (n==0) print "   none" }' | head -n 10

echo "-- PUSCH"
ok=$(grep -a "PUSCH:" "$GNB_LOG" | grep -c "crc=OK")
ko=$(grep -a "PUSCH:" "$GNB_LOG" | grep -c "crc=KO")
tot=$((ok + ko))
pct=$(awk -v k="$ko" -v t="$tot" 'BEGIN { if (t>0) printf "%.1f", 100*k/t; else print "-" }')
echo "   CRC OK $ok, KO $ko of $tot ($pct % KO)"
echo "   SINR median OK: $(grep -a 'PUSCH:.*crc=OK' "$GNB_LOG" | grep -o 'sinr=[-0-9.]*' | cut -d= -f2 | median_of) dB"
grep -a "PUSCH:.*crc=KO" "$GNB_LOG" | grep -o "sinr=[-0-9.]*" | cut -d= -f2 | \
  awk '{ if ($1>8) h++; else if ($1>-5) m++; else l++ } END { printf "   KO by SINR: >8 dB %d, -5..8 dB %d, < -5 dB %d\n", h, m, l }'

echo "-- PUCCH format 1 with HARQ-ACK"
n_ack=$(grep -a "PUCCH:.*format=1.*ack=" "$GNB_LOG" | wc -l)
echo "   n=$n_ack, SINR median $(grep -a 'PUCCH:.*format=1.*ack=' "$GNB_LOG" | grep -o 'sinr=[-0-9.]*' | cut -d= -f2 | median_of) dB"

echo "-- procedure problems"
echo "   UE 'SR not served':            $(grep -aic 'sr not served' "$UE_CLEAN")"
echo "   UE new RA while connected:     $(grep -ac 'Triggering new RA procedure' "$UE_CLEAN")"
echo "   gNB InitialContextSetupFailure: $(grep -ac 'InitialContextSetupFailure' "$GNB_LOG")"
echo "   gNB real-time failures:        $(grep -ac 'Real-time failure' "$GNB_LOG")"
