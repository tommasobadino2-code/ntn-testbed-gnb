#!/usr/bin/env python3
"""ul_burst_timing.py - absolute timing of uplink bursts in a v4 channel-emulator capture.

Usage:
  python3 scripts/ul_burst_timing.py <capture.bin> --gnb-stdout <gnb stdout log>   [--fs 15.36e6]
  python3 scripts/ul_burst_timing.py <capture.bin> --start-ts <N>
  python3 scripts/ul_burst_timing.py --selftest

The capture comes from OCUDU_UHD_CHANNEL_EMU_CAPTURE (interleaved int16 I/Q of channel 0, after Doppler
and delay, i.e. exactly what the PHY receives). The first sample's absolute radio timestamp is printed by
the gNB as "uplink capture started at ... (timestamp N)"; pass the stdout log (parsed automatically) or the
number itself. OCUDU's lower PHY puts slot k at timestamps [k*spslot, (k+1)*spslot), so

    position_in_slot = (start_ts + burst_start_sample) mod samples_per_slot

is the burst's arrival position within its slot, convention-free and without the modulo-symbol ambiguity of
the frequency-domain PRACH dump. For B4 bursts, compare positions across RA attempts: the spread is the true
UE timing scatter; the absolute value (minus the PRACH CP) is the arrival offset that time_alignment_
calibration moves (cal of -N samples makes arrivals N samples later).
"""
import argparse
import re
import sys
import numpy as np

BLOCK = 64  # power averaging block, samples


def block_power(data, fs, t0, t1):
    """Mean |I|+|Q| per BLOCK-sample block between t0 and t1 seconds (memmap-friendly, chunked)."""
    i0 = int(t0 * fs) // BLOCK * BLOCK
    i1 = min(int(t1 * fs), (data.size // 2) // BLOCK * BLOCK * 1)
    n_blocks = (i1 - i0) // BLOCK
    out = np.empty(n_blocks, dtype=np.float32)
    chunk = 1 << 22  # samples per chunk
    done = 0
    while done < n_blocks:
        nb = min(chunk // BLOCK, n_blocks - done)
        s = i0 + done * BLOCK
        seg = data[2 * s: 2 * (s + nb * BLOCK)].astype(np.float32)
        out[done:done + nb] = np.abs(seg).reshape(nb, 2 * BLOCK).mean(axis=1)
        done += nb
    return i0, out


def find_bursts(data, fs, t0, t1, min_ms, gap_ms, thr_factor):
    i0, p = block_power(data, fs, t0, t1)
    floor = np.median(p)
    if floor <= 0:
        floor = np.mean(p) + 1e-9
    on = p > floor * thr_factor
    min_blocks = max(1, int(min_ms * 1e-3 * fs / BLOCK))
    gap_blocks = max(1, int(gap_ms * 1e-3 * fs / BLOCK))
    bursts = []
    k = 0
    while k < on.size:
        if not on[k]:
            k += 1
            continue
        j = k
        quiet = 0
        while j < on.size and quiet < gap_blocks:
            quiet = quiet + 1 if not on[j] else 0
            j += 1
        end = j - quiet
        if end - k >= min_blocks:
            a = i0 + k * BLOCK
            b = i0 + end * BLOCK
            # refine the start: first block (at 1-sample steps over +-2 blocks) above half the burst level
            lvl = np.median(p[k:end])
            lo = max(0, a - 2 * BLOCK)
            seg = np.abs(data[2 * lo: 2 * (a + 2 * BLOCK)].astype(np.float32))
            amp = seg.reshape(-1, 2).sum(axis=1)
            idx = np.flatnonzero(np.convolve(amp, np.ones(16) / 16, mode="same") > lvl)
            start = lo + int(idx[0]) if idx.size else a
            bursts.append((start, b - start, 20 * np.log10(max(lvl, 1e-9) / 32768.0 / 2)))
        k = j
    return bursts, floor


def selftest():
    fs = 15.36e6
    spslot = int(fs // 1000)
    rng = np.random.default_rng(3)
    n = int(2.0 * fs)
    x = (rng.normal(size=2 * n) * 20).astype(np.int16)
    start_ts = 123456
    truth = []
    for t_slot, off in [(300, 1000), (900, 980), (1500, 1021)]:  # slot index, offset in slot
        s = t_slot * spslot + off - start_ts % spslot * 0  # sample index in capture
        s = t_slot * spslot + off
        burst = int(0.86e-3 * fs)
        x[2 * s: 2 * (s + burst)] = (rng.normal(size=2 * burst) * 8000).astype(np.int16)
        truth.append((s, (start_ts + s) % spslot))
    bursts, _ = find_bursts(x, fs, 0.0, 2.0, 0.5, 5.0, 4.0)
    ok = len(bursts) == len(truth)
    for (s, dur, lvl), (ts_true, mod_true) in zip(bursts, truth):
        mod = (start_ts + s) % spslot
        err = s - ts_true
        ok &= abs(err) <= 8
        print(f"burst at sample {s} (true {ts_true}, err {err:+d}), in-slot {mod} (true {mod_true})")
    print("selftest", "OK" if ok else "FAIL")
    sys.exit(0 if ok else 1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("capture", nargs="?")
    ap.add_argument("--gnb-stdout", help="gNB stdout log containing 'uplink capture started ... (timestamp N)'")
    ap.add_argument("--start-ts", type=int, help="absolute timestamp of the capture's first sample")
    ap.add_argument("--fs", type=float, default=15.36e6)
    ap.add_argument("--window", nargs=2, type=float, default=None, metavar=("T0", "T1"),
                    help="only analyse between these times in the capture (s)")
    ap.add_argument("--min-ms", type=float, default=0.5, help="minimum burst length (default 0.5 ms)")
    ap.add_argument("--gap-ms", type=float, default=5.0, help="minimum gap splitting bursts (default 5 ms)")
    ap.add_argument("--thr", type=float, default=4.0, help="burst threshold over the noise floor (default 4x)")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        selftest()
    if not a.capture:
        ap.error("need <capture.bin> (or --selftest)")

    start_ts = a.start_ts
    if start_ts is None:
        if not a.gnb_stdout:
            ap.error("need --start-ts or --gnb-stdout")
        m = re.search(r"uplink capture started at .*timestamp (\d+)", open(a.gnb_stdout, errors="replace").read())
        if not m:
            sys.exit("no 'uplink capture started ... (timestamp N)' line in the stdout log "
                     "(did the capture trigger? look for 'capture armed' instead)")
        start_ts = int(m.group(1))

    data = np.memmap(a.capture, dtype=np.int16, mode="r")
    dur = data.size / 2 / a.fs
    t0, t1 = a.window if a.window else (0.0, dur)
    spslot = int(round(a.fs / 1000))
    print(f"{dur:.1f} s capture at {a.fs/1e6:g} Msps, first-sample timestamp {start_ts}, "
          f"slot = {spslot} samples; analysing {t0:.1f}-{t1:.1f} s")
    bursts, floor = find_bursts(data, a.fs, t0, t1, a.min_ms, a.gap_ms, a.thr)
    if not bursts:
        print(f"no bursts above {a.thr}x the floor; lower --thr or check the window")
        return
    print("  #   t_in_capture   abs_ts          in-slot sample   in-slot us   length_ms  level_dBFS")
    mods = []
    for i, (s, dur_s, lvl) in enumerate(bursts):
        ts = start_ts + s
        mod = ts % spslot
        mods.append(mod)
        print(f"{i:3d}   {s / a.fs:10.4f} s   {ts:13d}   {mod:8d}         {mod / a.fs * 1e6:8.2f}"
              f"     {dur_s / a.fs * 1e3:7.3f}    {lvl:7.1f}")
    mods = np.array(mods, dtype=float)
    us = mods / a.fs * 1e6
    # spread on the circle (slot-periodic)
    ref = us[0]
    rel = (us - ref + 500) % 1000 - 500
    print(f"\n{len(bursts)} burst(s): in-slot position {us.min():.2f}..{us.max():.2f} us; "
          f"spread relative to the first burst {rel.min():+.2f}..{rel.max():+.2f} us")
    print("A PRACH burst should start at (slot boundary + its CP); the spread across attempts is the true "
          "UE timing scatter.")


if __name__ == "__main__":
    main()
