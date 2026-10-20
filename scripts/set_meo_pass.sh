#!/usr/bin/env bash
# set_meo_pass.sh - MEO (default 8000 km) counterpart of TOSSI's set_leo_pass.sh.
#
# Same geometry model as set_leo_pass.sh: circular polar orbit, UE / reference location at the
# north pole on the WGS84 polar radius, ECEF state vector propagated by the gNB's Keplerian
# propagator from epoch_timestamp. Only the altitude is a parameter instead of a constant.
#
#   --init                          create the MEO configs from YOUR current LEO configs (keeps your
#                                   free5GC addresses, slice, PLMN): meo_rfsim_gnb.yml, meo_satswitch.yml,
#                                   meo_sattrain.yml, meo_ho_sat1.yml, meo_ho_sat2.yml
#   --single --elev E [--setting]   scenario 1 / 4: place the satellite of meo_rfsim_gnb.yml
#   --switch --at S [--cross E]     scenario 3: sat 0 setting and sat 1 rising cross at E deg at T+S s
#   --ho --at S [--elev1 E1 --elev2 E2]
#                                   scenario 2: at T+S sat 1 is setting through E1, sat 2 rising through E2
#   --show                          print what the configs currently contain
# Common: --alt <km> (8000), --lead <s> (20, epoch stamped this far ahead), --no-epoch
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
D=$HERE/configs/ntn
BASE=$D/meo_rfsim_gnb.yml; SW=$D/meo_satswitch.yml; TRAIN=$D/meo_sattrain.yml
HO1=$D/meo_ho_sat1.yml;    HO2=$D/meo_ho_sat2.yml

usage() { sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

MODE=; ALT_KM=8000; ELEV=; SETTING=0; AT=; CROSS=30; E1=18; E2=34; LEAD=20; STAMP=1; KOFFSET=100
while (( $# )); do
    case $1 in
        --init)    MODE=init; shift ;;
        --single)  MODE=single; shift ;;
        --switch)  MODE=switch; shift ;;
        --ho)      MODE=ho; shift ;;
        --show)    MODE=show; shift ;;
        --alt)     ALT_KM=${2:?}; shift 2 ;;
        --elev)    ELEV=${2:?}; shift 2 ;;
        --setting) SETTING=1; shift ;;
        --at)      AT=${2:?}; shift 2 ;;
        --cross)   CROSS=${2:?}; shift 2 ;;
        --elev1)   E1=${2:?}; shift 2 ;;
        --elev2)   E2=${2:?}; shift 2 ;;
        --koffset) KOFFSET=${2:?}; shift 2 ;;
        --lead)    LEAD=${2:?}; shift 2 ;;
        --no-epoch) STAMP=0; shift ;;
        -h|--help) usage ;;
        *) echo "unknown argument: $1" >&2; usage 1 ;;
    esac
done
[[ -n $MODE ]] || usage 1
case $ELEV in horizon) ELEV=0 ;; zenith) ELEV=90 ;; esac

# ---------------------------------------------------------------- --init
if [[ $MODE == init ]]; then
    for f in leo_rfsim_gnb leo_satswitch leo_sattrain leo_ho_sat1 leo_ho_sat2; do
        [[ -f $D/$f.yml ]] || { echo "missing $D/$f.yml" >&2; exit 1; }
    done
    for f in "$BASE" "$SW" "$TRAIN" "$HO1" "$HO2"; do
        [[ -e $f ]] && { echo "$f exists - remove it first if you really want to re-init" >&2; exit 1; }
    done
    cp "$D/leo_rfsim_gnb.yml" "$BASE"
    sed -i -E "s/^( *cell_specific_koffset:).*/\1 $KOFFSET/; s#/tmp/gnb_leo\.log#/tmp/gnb_meo.log#; s#/tmp/ntn_leo_#/tmp/ntn_meo_#g" "$BASE"
    cp "$D/leo_satswitch.yml" "$SW";  sed -i 's#/tmp/gnb_leo_satswitch\.log#/tmp/gnb_meo_satswitch.log#' "$SW"
    cp "$D/leo_sattrain.yml" "$TRAIN"
    sed -i -E 's#/tmp/gnb_leo_sattrain\.log#/tmp/gnb_meo_sattrain.log#; s/^( *num_satellites:).*/\1 36/' "$TRAIN"
    # run_leo_ho_rfsim.sh hardcodes /tmp/gnb_leo_sat{1,2}.log, so the HO overlays keep those log names.
    cp "$D/leo_ho_sat1.yml" "$HO1";  cp "$D/leo_ho_sat2.yml" "$HO2"
    echo "created: $(cd "$D" && ls meo_*.yml | tr '\n' ' ')"
    echo "base: cell_specific_koffset $KOFFSET, log /tmp/gnb_meo.log; train: 36 satellites"
    echo "next: $0 --single --elev horizon    (then check the output)"
    exit 0
fi

need() { for f; do [[ -f $f ]] || { echo "missing $f - run $0 --init first" >&2; exit 1; }; done; }
need "$BASE"

EPOCH=
if (( STAMP )) && [[ $MODE != show ]]; then
    EPOCH=$(date -u -d "+${LEAD} seconds" '+%Y-%m-%dT%H:%M:%S')
    sed -i "s/epoch_timestamp: '[^']*'/epoch_timestamp: '$EPOCH'/" "$BASE"
    date -d "$EPOCH UTC" +%s > /tmp/meo_epoch
fi
[[ $MODE == switch ]] && need "$SW"
[[ $MODE == ho ]] && need "$HO1" "$HO2"
[[ $MODE =~ ^(switch|ho)$ && -z $AT ]] && { echo "--$MODE needs --at <seconds after the epoch>" >&2; exit 1; }
[[ $MODE == single && -z $ELEV ]] && { echo "--single needs --elev" >&2; exit 1; }

MODE=$MODE ALT_KM=$ALT_KM ELEV=${ELEV:-90} SETTING=$SETTING AT=${AT:-0} CROSS=$CROSS E1=$E1 E2=$E2 \
EPOCH=${EPOCH:-} BASE=$BASE SW=$SW HO1=$HO1 HO2=$HO2 python3 - <<'PY'
import math, os, re, datetime as dt
MU, B, C = 3.986004418e14, 6356752.314, 299792458.0      # MU as in the gNB propagator
E = os.environ
R  = B + float(E['ALT_KM'])*1e3
V  = math.sqrt(MU/R)
W  = math.degrees(V/R)                                    # deg of orbit per second
G0 = math.degrees(math.acos(B/R))                         # phase at 0 deg elevation

# phase p: 0 at zenith over the pole, negative = rising, positive = setting, grows by W per second
def gamma(el):
    if not 0 <= el <= 90: raise SystemExit(f'elevation {el} out of 0..90')
    e = math.radians(el); return math.degrees(math.acos(B*math.cos(e)/R) - e)
def elev(p):
    g = math.radians(abs(p))
    return 90.0 if g < 1e-12 else math.degrees(math.atan2(R*math.cos(g) - B, R*math.sin(g)))
def rng(p):   return math.sqrt(R*R + B*B - 2*R*B*math.cos(math.radians(p)))
def rtt(p):   return 2*rng(p)/C*1e3
def drift(p): # d(RTT)/dt [us/s], negative while rising
    return 2*(R*B*math.sin(math.radians(p))/rng(p))*math.radians(W)/C*1e6
def vis(p):   return abs(p) <= G0

def write(path, p, key_block=None):
    r = math.radians(p)
    vals = {'pos_x': '0', 'pos_y': f'{R*math.sin(r)+0.0:.1f}', 'pos_z': f'{R*math.cos(r):.1f}',
            'vel_x': '0', 'vel_y': f'{V*math.cos(r):.2f}',   'vel_z': f'{-V*math.sin(r)+0.0:.2f}'}
    s = open(path).read()
    for k, v in vals.items():
        s, n = re.subn(rf'^(\s*{k}:)\s*\S+', rf'\g<1> {v}', s, count=1, flags=re.M)
        if n != 1: raise SystemExit(f'{path}: expected one "{k}:" key, found {n}')
    open(path, 'w').write(s)

def state(p):
    return (f'{elev(p)+0.0:6.2f} deg {"rising " if p < 0 else "setting"}  RTT {rtt(p):6.2f} ms  '
            f'drift {drift(p):+6.2f} us/s') if vis(p) else '   below the horizon (link muted)'

def timeline(sats, t_end, marks=()):
    ts = sorted(set([0] + [int(t) for t in range(0, int(t_end)+1, max(60, int(t_end/12)//60*60 or 60))]
                     + [int(m) for m in marks]))
    print('\n   T+     ' + ''.join(f'{n:<48}' for n, _ in sats))
    for t in ts:
        print(f'  {t:5d}s  ' + ''.join(f'{state(p0 + W*t):<48}' for _, p0 in sats)
              + ('  <==' if t in marks else ''))

base = open(E['BASE']).read()
kof = int(re.search(r'cell_specific_koffset:\s*(\d+)', base).group(1))
max_rtt = rtt(G0)
epoch = E['EPOCH']
print(f"orbit   : alt {(R-B)/1e3:.0f} km, radius {R:.1f} m, v {V:.2f} m/s, {W:.6f} deg/s, period {360/W/3600:.2f} h")
print(f"pass    : {2*G0/W/60:.1f} min horizon to horizon; RTT {rtt(0):.2f} ms at zenith, {max_rtt:.2f} ms at the horizon;"
      f" |drift| <= {drift(G0):.2f} us/s")
print(f"koffset : {kof} ms in {os.path.basename(E['BASE'])} "
      + ("OK" if kof >= math.ceil(max_rtt) else f"TOO SMALL - must be >= {math.ceil(max_rtt)} (max RTT)"))
print(f"epoch   : {epoch + ' UTC (also /tmp/meo_epoch)' if epoch else '(unchanged)'}")
mode = E['MODE']

if mode == 'show':
    for f in (E['BASE'], E['SW'], E['HO1'], E['HO2']):
        if not os.path.exists(f): continue
        s = open(f).read(); m = re.search(r'^\s*pos_y:\s*(\S+)\s*\n\s*pos_z:\s*(\S+)', s, re.M)
        if not m: continue
        py, pz = float(m.group(1)), float(m.group(2))
        p = math.degrees(math.atan2(py, pz))
        print(f"{os.path.basename(f):20s} radius {math.hypot(py,pz):.0f} m  at epoch: {state(p)}")
    raise SystemExit

if mode == 'single':
    el = float(E['ELEV'])
    p = gamma(el) if el < 90 else 0.0
    p = p if E['SETTING'] == '1' else -p
    write(E['BASE'], p)
    print(f"\nmeo_rfsim_gnb.yml at epoch: {state(p)}")
    print(f"UE: --ntn-initial-time-drift {drift(p):.1f}")
    t_set = (G0 - p)/W
    if E['SETTING'] == '1' or p > -gamma(4.5):
        t_sw = (gamma(4.5) - p)/W
        print(f"satellite train (switch elevation 4.5 deg): first switch at about T+{t_sw:.0f} s")
    timeline([('satellite', p)], t_set)

elif mode == 'switch':
    at, ce = float(E['AT']), float(E['CROSS'])
    gc = gamma(ce)
    p0, p1 = gc - W*at, -gc - W*at          # sat 0 setting through ce at T+at, sat 1 rising through ce
    if not vis(p0): raise SystemExit(f'sat 0 would be below the horizon at the epoch - use a smaller --at')
    write(E['BASE'], p0); write(E['SW'], p1)
    s = open(E['SW']).read()
    if epoch:
        t = (dt.datetime.fromisoformat(epoch) + dt.timedelta(seconds=at)).strftime('%Y-%m-%dT%H:%M:%S')
        s = re.sub(r"epoch_timestamp: '[^']*'", f"epoch_timestamp: '{epoch}'", s)
        s = re.sub(r"t_service: '[^']*'", f"t_service: '{t}'", s)
        s = re.sub(r"t_service_start: '[^']*'", f"t_service_start: '{t}'", s)
        open(E['SW'], 'w').write(s)
        print(f"switch  : t_service = t_service_start = {t} UTC (T+{at:.0f} s)")
    print(f"crossing: both satellites at {ce:.1f} deg, RTT {rtt(gc):.2f} ms, drift {drift(-gc):+.2f} -> {drift(gc):+.2f} us/s")
    print(f"UE: --ntn-initial-time-drift {drift(p0):.1f};  run script: SWITCH_AT={at:.0f} DUR={int(at + 300)}")
    timeline([('sat 0 (meo_rfsim_gnb.yml)', p0), ('sat 1 (meo_satswitch.yml)', p1)], at + 600, [at])

elif mode == 'ho':
    at, e1, e2 = float(E['AT']), float(E['E1']), float(E['E2'])
    p1, p2 = gamma(e1) - W*at, -gamma(e2) - W*at
    if not vis(p1): raise SystemExit('sat 1 would be below the horizon at the epoch - use a smaller --at')
    if e2 <= e1: print('WARNING: --elev2 <= --elev1: the target is not the higher satellite at the handover')
    write(E['HO1'], p1); write(E['HO2'], p2)
    rise2 = max(0.0, (-G0 - p2)/W)
    set1 = (G0 - p1)/W
    sat2_at = max(rise2, min(120.0, at/2))
    print(f"sat 2 trails sat 1 by {p1 - p2:.2f} deg of orbit ({(p1-p2)/W:.0f} s)")
    print(f"sat 2 rises at T+{rise2:.0f} s, sat 1 sets at T+{set1:.0f} s")
    print(f"UE: --ntn-initial-time-drift {drift(p1):.1f};  run script: HO_AT={at:.0f} SAT2_AT={sat2_at:.0f} "
          f"DUR={int(min(set1, at + 300))}")
    timeline([('sat 1 (meo_ho_sat1.yml)', p1), ('sat 2 (meo_ho_sat2.yml)', p2)], min(set1, at + 900), [sat2_at, at])
PY
