#!/usr/bin/env bash
# prach_loop.sh - N back-to-back B200 NTN runs, one summary line per run (docs/b200_prach_b4_plan.md).
# Runs on the HOST: restarts the core, waits for the AMF, starts scripts/run_ntn_uhd_local.sh inside the
# container, stops it after the pings, copies the logs per run and prints prach_run_summary.sh's line.
#
# Required:
#   REPO=<path of this repository INSIDE the container>   CORE_DIR=<host dir containing core-up.sh>
#   CFG=<config path relative to REPO>                     ORBIT=leo|meo
#   TIME_DRIFT=<us/s>                                      UE_EXTRA_ARGS="--cont-fo-comp 3 --initial-fo <Hz>"
# Optional (defaults):
#   N=10  TAG=<config name>  OUT=$HOME/prach_runs/<TAG>_<date>  PING_COUNT=20  CONTAINER=ntn-ran
#   CORE_DOWN=""  (e.g. "sudo ./core-down.sh", run in CORE_DIR before CORE_UP)  CORE_UP="sudo ./core-up.sh"
#   AMF_CONTAINER=amf  AMF_LISTEN="Listen on 10.100.200.16:38412"  AMF_WAIT=180  AMF_SETTLE=8
#   NG_RETRIES=2 (core restarts if the gNB fails NG setup)  RUN_MAX=<s> (default 240 + 1.5 x PING_COUNT)
#   EXTRA_COPY="<container paths copied into each run dir>"  GNB_ENV="<extra env for the gNB>"
#   RUN_ENV="VAR=value ..."  extra variables for run_ntn_uhd_local.sh (e.g. OAI=/path/to/OAI_RAN)
#
# Harness traps handled: AMF readiness from `docker logs --since` (old lines don't count), NG-setup failure
# retried with a fresh core, processes killed INSIDE the container with pkill -x, the run script's final
# `wait` never reached (we stop it), logs copied per run, sudo kept alive, terminal restored.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
: "${REPO:?set REPO=<repository path inside the container>}"
: "${CORE_DIR:?set CORE_DIR=<host directory with core-up.sh>}"
: "${CFG:?set CFG=<config relative to REPO>}"
: "${ORBIT:?set ORBIT=leo or meo}"
: "${TIME_DRIFT:?set TIME_DRIFT=<us/s>}"
: "${UE_EXTRA_ARGS:?set UE_EXTRA_ARGS}"
N=${N:-10}
PING_COUNT=${PING_COUNT:-20}
CONTAINER=${CONTAINER:-ntn-ran}
CORE_DOWN=${CORE_DOWN:-}
CORE_UP=${CORE_UP:-sudo ./core-up.sh}
AMF_CONTAINER=${AMF_CONTAINER:-amf}
AMF_LISTEN=${AMF_LISTEN:-Listen on 10.100.200.16:38412}
AMF_WAIT=${AMF_WAIT:-180}
AMF_SETTLE=${AMF_SETTLE:-8}
NG_RETRIES=${NG_RETRIES:-2}
RUN_MAX=${RUN_MAX:-$(( 240 + PING_COUNT * 3 / 2 ))}
TAG=${TAG:-$(basename "$CFG" .yml)}
OUT=${OUT:-$HOME/prach_runs/${TAG}_$(date +%Y%m%d_%H%M%S)}
EXTRA_COPY=${EXTRA_COPY:-}
GNB_ENV=${GNB_ENV:-}
RUN_ENV=${RUN_ENV:-}

mkdir -p "$OUT"
SUMMARY=$OUT/summary.txt
echo "# $(date -Is) CFG=$CFG ORBIT=$ORBIT TIME_DRIFT=$TIME_DRIFT UE_EXTRA_ARGS='$UE_EXTRA_ARGS' PING_COUNT=$PING_COUNT" | tee "$SUMMARY"

# Keep sudo alive for the whole loop (it times out after 15 min otherwise).
sudo -v || exit 1
( while kill -0 $$ 2>/dev/null; do sudo -n true 2>/dev/null; sleep 60; done ) &
KEEPALIVE=$!
cleanup() {
    kill "$KEEPALIVE" 2>/dev/null
    docker exec "$CONTAINER" bash -c 'pkill -9 -x nr-uesoftmodem; pkill -9 -x gnb; pkill -9 -x run_ntn_uhd_loc' >/dev/null 2>&1
    stty sane 2>/dev/null
}
trap cleanup EXIT
trap 'echo "interrupted"; exit 130' INT TERM

GNB_LOG=$(docker exec "$CONTAINER" sed -n 's/^  filename: *//p' "$REPO/$CFG" | head -n 1)
[[ -n $GNB_LOG ]] || { echo "cannot read the log filename from $REPO/$CFG in $CONTAINER" >&2; exit 1; }
UE_LOG=/tmp/ue_${ORBIT}_uhd.log
GNB_STDOUT=/tmp/gnb_${ORBIT}_uhd_stdout.log

kill_ran() {
    docker exec "$CONTAINER" bash -c 'pkill -9 -x nr-uesoftmodem; pkill -9 -x gnb; pkill -9 -x run_ntn_uhd_loc' >/dev/null 2>&1
    sleep 2
}

restart_core() {
    local since
    since=$(date -u +%Y-%m-%dT%H:%M:%S)
    ( cd "$CORE_DIR" && { [[ -z $CORE_DOWN ]] || eval "$CORE_DOWN"; } && eval "$CORE_UP" ) > "$1/core.out" 2>&1
    for _ in $(seq "$AMF_WAIT"); do
        if docker logs --since "$since" "$AMF_CONTAINER" 2>&1 | grep -q "$AMF_LISTEN"; then
            sleep "$AMF_SETTLE"
            return 0
        fi
        sleep 1
    done
    return 1
}

pass=0
for i in $(seq 1 "$N"); do
    RD=$OUT/run$i
    t0=$SECONDS
    mkdir -p "$RD"
    kill_ran
    for try in $(seq 0 "$NG_RETRIES"); do
        if ! restart_core "$RD"; then
            echo "run $i: AMF not listening after ${AMF_WAIT}s (see $RD/core.out)" | tee -a "$SUMMARY"
            continue
        fi
        docker exec "$CONTAINER" bash -c "cd '$REPO' && env ORBIT='$ORBIT' CFG='$CFG' TIME_DRIFT='$TIME_DRIFT' \
            UE_EXTRA_ARGS='$UE_EXTRA_ARGS' PING_COUNT='$PING_COUNT' TA_CHECK=0 GNB_ENV='$GNB_ENV' $RUN_ENV \
            scripts/run_ntn_uhd_local.sh" > "$RD/run.out" 2>&1 &
        RUNPID=$!
        t0=$SECONDS
        while kill -0 "$RUNPID" 2>/dev/null && (( SECONDS - t0 < RUN_MAX )); do
            grep -aqE "Ctrl-C to stop both|NOT attached|UE died|no NG setup|gNB died" "$RD/run.out" && break
            sleep 2
        done
        kill_ran
        kill "$RUNPID" 2>/dev/null; wait "$RUNPID" 2>/dev/null
        if grep -aqE "no NG setup|gNB died" "$RD/run.out"; then
            echo "   run $i: gNB NG setup failed (try $((try + 1))), restarting the core" | tee -a "$SUMMARY"
            continue
        fi
        break
    done
    docker cp "$CONTAINER:$GNB_LOG" "$RD/gnb.log" >/dev/null 2>&1
    docker cp "$CONTAINER:$UE_LOG" "$RD/ue.log" >/dev/null 2>&1
    docker cp "$CONTAINER:$GNB_STDOUT" "$RD/gnb_stdout.log" >/dev/null 2>&1
    for f in $EXTRA_COPY; do docker cp "$CONTAINER:$f" "$RD/" >/dev/null 2>&1; done
    (( SECONDS - t0 >= RUN_MAX )) && echo "   run $i: stopped after RUN_MAX=${RUN_MAX}s" >> "$SUMMARY"
    LINE=$("$HERE/scripts/prach_run_summary.sh" "$RD/gnb.log" "$RD/ue.log" "$RD/run.out")
    echo "run $i: $LINE" | tee -a "$SUMMARY"
    [[ $LINE == *"| PASS" ]] && pass=$(( pass + 1 ))
done

echo "== $pass/$N PASS (first preamble detected, attached, all pings)   logs: $OUT" | tee -a "$SUMMARY"
