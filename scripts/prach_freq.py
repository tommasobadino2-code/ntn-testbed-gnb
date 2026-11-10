#!/usr/bin/env python3
"""prach_freq.py - where in frequency the UE's PRACH preamble arrives at the gNB (Doppler test plan).

Usage: python3 scripts/prach_freq.py <capture> [--ref <capture without Doppler>] [--window T0 T1]

The PRACH (long format, 839 subcarriers at 1.25 kHz, ~1.05 MHz wide) is the strongest burst near the start
of an uplink capture. Its spectrum is measured; with --ref the same is done for a capture where the PRACH is
known to arrive correctly (Doppler off), and the frequency shift between the two spectra is reported.

Why: for this PRACH root, every 1.25 kHz of frequency error moves the correlation peak the gNB uses for
timing by about 12.4 us. A shift of ~40 kHz would therefore look like a ~400 us timing error.
"""
import argparse
import numpy as np

FS = 15.36e6
SLOT = int(1e-3 * FS)
NZP = 1 << 17            # zero-padded FFT: 117 Hz bins


def load(path):
    raw = np.fromfile(path, dtype=np.int16)
    return raw[0::2].astype(np.float32) + 1j * raw[1::2].astype(np.float32)


def find_prach(x, t0=0.0, t1=2.0):
    """Start sample and level of the PRACH burst: the strongest slot between t0 and t1 seconds (the first PRACH
    comes within ~0.5 s of link-up), extended to the slots around it."""
    n = x.size // SLOT
    lv = np.array([np.mean(np.abs(x[k * SLOT:(k + 1) * SLOT]) ** 2) for k in range(n)])
    a0, a1 = int(t0 / 1e-3), min(n, int(t1 / 1e-3))
    k = a0 + int(np.argmax(lv[a0:a1]))
    floor = np.median(lv)
    a = k
    while a > 0 and lv[a - 1] > floor * 4:
        a -= 1
    b = k
    while b < n - 1 and lv[b + 1] > floor * 4:
        b += 1
    return a * SLOT, (b + 1) * SLOT, 10 * np.log10(lv[k] / 32768 ** 2), 10 * np.log10(lv[k] / floor)


def spectrum(seg):
    seg = seg - np.mean(seg)
    X = np.fft.fftshift(np.fft.fft(seg * np.hanning(seg.size), NZP))
    p = np.abs(X) ** 2
    f = (np.arange(NZP) - NZP // 2) * FS / NZP
    return f, p


def band(f, p):
    """Centroid and -6 dB edges of the PRACH band (the widest region near the peak)."""
    sm = np.convolve(p, np.ones(64) / 64, mode="same")      # smooth over ~7.5 kHz
    thr = sm.max() / 4
    on = sm > thr
    i = int(np.argmax(sm))
    lo, hi = i, i
    while lo > 0 and on[lo - 1]:
        lo -= 1
    while hi < on.size - 1 and on[hi + 1]:
        hi += 1
    w = sm[lo:hi + 1]
    return float(np.sum(f[lo:hi + 1] * w) / np.sum(w)), f[lo], f[hi]


def shift_between(f, p, pref, max_hz=80e3):
    a = np.log10(p + 1e-9)
    b = np.log10(pref + 1e-9)
    a -= a.mean()
    b -= b.mean()
    df = f[1] - f[0]
    k = int(max_hz / df)
    lags = np.arange(-k, k + 1)
    cc = np.array([np.dot(a[k:-k], np.roll(b, l)[k:-k]) for l in lags])
    i = int(np.argmax(cc))
    off = 0.0
    if 0 < i < len(cc) - 1:
        y0, y1, y2 = cc[i - 1], cc[i], cc[i + 1]
        den = y0 - 2 * y1 + y2
        off = 0.5 * (y0 - y2) / den if den != 0 else 0.0
    return (lags[i] + off) * df


def report(name, x, t0, t1):
    a, b, lvl, snr = find_prach(x, t0, t1)
    f, p = spectrum(x[a:b])
    c, lo, hi = band(f, p)
    print(f"{name}: PRACH burst at {a / FS:.4f}-{b / FS:.4f} s, level {lvl:.1f} dBFS ({snr:.0f} dB above the floor)")
    print(f"   band {lo / 1e6:+.4f} .. {hi / 1e6:+.4f} MHz (width {(hi - lo) / 1e3:.0f} kHz), centre {c / 1e6:+.5f} MHz")
    return f, p, c


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("capture")
    ap.add_argument("--ref")
    ap.add_argument("--window", nargs=2, type=float, default=[0.0, 2.0], metavar=("T0", "T1"),
                    help="search the PRACH between these times in the capture (s), default 0 2")
    a = ap.parse_args()
    f, p, c = report("capture  ", load(a.capture), *a.window)
    if a.ref:
        _, pr, cr = report("reference", load(a.ref), *a.window)
        s = shift_between(f, p, pr)
        print(f"=> PRACH frequency shift capture - reference: {s:+.0f} Hz (spectrum match), "
              f"{c - cr:+.0f} Hz (band centre)")
        print("   (the band edges above are the most direct reading; check that both widths are ~1050 kHz)")
        print(f"   as a timing error for this root (~12.4 us per 1.25 kHz): about {abs(s) / 1250 * 12.4:.0f} us")


if __name__ == "__main__":
    main()
