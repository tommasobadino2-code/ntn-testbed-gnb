#!/usr/bin/env bash
# prach_run_summary.sh - one line per B200 NTN run for the PRACH tests (docs/b200_prach_b4_plan.md).
# Usage: scripts/prach_run_summary.sh <gnb log> <ue log> <run_ntn_uhd_local.sh output>
# Read-only. Prints:
#   first TA <raw> (<us>) | Epoch SFN <n> | first RO <sfn.slot> | first det <sfn.slot> ta=<us> |
#   preambles until RAR <k> | attached <yes/no> | pings <rx>/<tx> | PASS/FAIL
# Sources (OAI UE, TOSSI rfsim_ocudu @ 83e7200):
#   "received TA command N"           nr_ue_procedures.c:3209  (N = 31 + RAR TA; 0.52 us per step)
#   "NTN Config Rxd. ... Epoch SFN: N" config_ue.c:388          (last one before the first preamble)
#   "PRACH [UE 0] in frame.slot F.S"  nr_prach.c:180           (one line per transmitted preamble)
# gNB: first "PRACH: ... ta=..us detection_metric=M" with M >= 3 (same filter as ntn-metrics.sh).
# PASS = exactly one preamble before the first RAR, attached, and every ping answered.
set -uo pipefail

GNB_LOG=${1:?usage: $0 <gnb log> <ue log> <run output>}
UE_LOG=${2:?usage: $0 <gnb log> <ue log> <run output>}
RUN_OUT=${3:?usage: $0 <gnb log> <ue log> <run output>}

ue_clean() { sed 's/\x1b\[[0-9;]*m//g' "$UE_LOG" 2>/dev/null; }

UE_SUM=$(ue_clean | awk '
    /received TA command [0-9]+/ && ta == "" {
        for (i = 1; i <= NF; i++) if ($i == "command") ta = $(i + 1); rar_seen = 1 }
    /Epoch SFN: [0-9]+/ && first_ro == "" {
        s = $0; sub(/.*Epoch SFN: /, "", s); sub(/[^0-9].*/, "", s); epoch = s }
    /PRACH \[UE [0-9]+\] in frame\.slot [0-9]+\.[0-9]+/ {
        s = $0; sub(/.*in frame\.slot /, "", s); sub(/,.*/, "", s);
        if (first_ro == "") first_ro = s;
        if (!rar_seen) n_pre++ }
    END { printf "%s|%s|%s|%d", (ta == "" ? "-" : ta), (epoch == "" ? "-" : epoch),
                                (first_ro == "" ? "-" : first_ro), n_pre }')
IFS='|' read -r TA EPOCH FIRST_RO NPRE <<< "$UE_SUM"

if [[ $TA == - ]]; then
    TA_S="first TA none"
else
    TA_S=$(awk -v t="$TA" 'BEGIN { printf "first TA %d (%+.1f us)", t, (t - 31) * 0.5208 }')
fi

DET=$(grep -a "PRACH:" "$GNB_LOG" 2>/dev/null | awk '
    { if (match($0, /detection_metric=[0-9.]+/) == 0) next
      m = substr($0, RSTART + 17, RLENGTH - 17) + 0; if (m < 3) next
      sl = ""; if (match($0, /\[ *[0-9]+\.[0-9]+\] +PRACH:/)) { sl = substr($0, RSTART, RLENGTH); gsub(/[\[\] ]|PRACH:/, "", sl) }
      ta = ""; if (match($0, /ta=[-0-9.]+us/)) ta = substr($0, RSTART, RLENGTH)
      print sl " " ta; exit }')
[[ -n $DET ]] || DET="none"

if grep -aq "^== attached" "$RUN_OUT" 2>/dev/null; then ATT=yes; else ATT=no; fi
PING=$(grep -aoE "[0-9]+ packets transmitted, [0-9]+ received" "$RUN_OUT" 2>/dev/null | tail -n 1 |
       awk '{ print $4 "/" $1 }')
[[ -n $PING ]] || PING="0/0"

VERDICT=FAIL
if [[ $NPRE == 1 && $ATT == yes ]]; then
    RX=${PING%/*}; TX=${PING#*/}
    (( TX > 0 && RX == TX )) && VERDICT=PASS
fi

echo "$TA_S | Epoch SFN $EPOCH | first RO $FIRST_RO | first det $DET | preambles until RAR $NPRE | attached $ATT | pings $PING | $VERDICT"
