#!/usr/bin/env python3
"""Derive scripts/meo_tracker.py from TOSSI's scripts/leo_tracker.py for another orbit altitude.

leo_tracker.py turns each logged rx_delay into elevation/range assuming a 600 km orbit (constant R),
and its sky view is scaled for LEO. This rewrites exactly those parts and the default log names,
leaving the upstream file untouched, so it can be re-run after every `git pull`.

  python3 scripts/make_meo_tracker.py [--alt 8000]
"""
import argparse, math, pathlib, re, sys

ap = argparse.ArgumentParser()
ap.add_argument('--alt', type=float, default=8000.0, help='orbit altitude above the polar radius [km]')
a = ap.parse_args()

here = pathlib.Path(__file__).resolve().parent
src, dst = here / 'leo_tracker.py', here / 'meo_tracker.py'
s = src.read_text()
B = 6356752.314
R = B + a.alt * 1e3

def sub(pattern, repl, text, what):
    new, n = re.subn(pattern, repl, text, count=1, flags=re.M)
    if n != 1:
        sys.exit(f'could not patch {what} in {src.name} - upstream changed, patch by hand')
    return new

# 1. orbit radius used to turn rx_delay into elevation / range / phase
s = sub(r'^B, R = .*$', f'B, R = {B}, {R:.3f}', s, 'orbit radius')

# 2. sky view: LEO draws the Earth wider than the canvas; at MEO the orbit is ~2.3x the Earth radius,
#    so shrink the Earth and draw it as a disc that fits the 1300x280 view with the whole visible arc.
ratio = R / B
g0 = math.acos(B / R)
re_px = int(min(250 / (ratio - 1 + 0.15), 600 / (ratio * math.sin(g0) + 0.05)))   # fit height and width
rv_px = round(re_px * ratio)
s = sub(r'^const CX=650,CY=1620,RE=1400,RV=1532,GSY=CY-RE;$',
        f'const CX=650,GSY=262,RE={re_px},CY=GSY+{re_px},RV={rv_px};', s, 'sky constants')
s = sub(r'^const yEdge=.*$', 'const yEdge=0;', s, 'earth edge')
s = sub(r'^\$\("earth"\)\.setAttribute\("d",.*$',
        '$("earth").setAttribute("d",`M ${CX-RE} ${CY} A ${RE} ${RE} 0 1 1 ${CX+RE} ${CY} Z`);', s, 'earth path')

# 3. default log names
s = s.replace('/tmp/gnb_leo_satswitch.log', '/tmp/gnb_meo_satswitch.log') \
     .replace('/tmp/gnb_leo_sattrain.log', '/tmp/gnb_meo_sattrain.log') \
     .replace('"/tmp/gnb_leo.log"', '"/tmp/gnb_meo.log"') \
     .replace('/tmp/ue_leo_sattrain.log', '/tmp/ue_meo_sattrain.log') \
     .replace('/tmp/ue_leo_satswitch.log', '/tmp/ue_meo_satswitch.log') \
     .replace('"/tmp/ue_leo.log"', '"/tmp/ue_meo.log"')

dst.write_text(s)
dst.chmod(0o755)
print(f'wrote {dst.name}: R = {R:.1f} m (alt {a.alt:.0f} km), sky view Earth {re_px}px / orbit {rv_px}px')
