#!/usr/bin/env python3
"""ul_cfo.py - residual uplink frequency offset as the gNB PHY sees it (Doppler test plan).

Usage: python3 scripts/ul_cfo.py <capture file> [--min-db 10] [--min-quality 4]

The capture (interleaved int16 I/Q at 15.36 Msps) is written by the patched gNB when
OCUDU_UHD_CHANNEL_EMU_CAPTURE=<file> is set: the uplink after the emulator's Doppler and delay, i.e. what the
PHY decodes. In it, the UE's signal should sit at 0 Hz (pre-compensation and emulated Doppler cancelling);
narrow tones (receiver DC, the UE transmitter's LO leakage shifted by the emulated Doppler) are listed and
removed first.

Per 1 ms slot that is clearly above the noise it prints the level and, where OFDM symbols are present, the frequency offset from the
cyclic-prefix correlation (accurate to a few Hz, but only modulo 15 kHz: values near +-7.5 kHz are ambiguous).
"""
import argparse
import numpy as np

FS = 15.36e6
NFFT = 1024
CP = 72
SCS = FS / NFFT


def remove_lowpass(x, n=4096):
    """x minus its n-sample moving average (removes everything within ~2 kHz of 0 Hz)."""
    c = np.concatenate(([0], np.cumsum(x, dtype=np.complex128)))
    idx = np.arange(x.size)
    lo = np.clip(idx - n // 2, 0, x.size)
    hi = np.clip(idx + n // 2, 0, x.size)
    return (x - (c[hi] - c[lo]) / np.maximum(hi - lo, 1)).astype(np.complex64)


def find_tones(x, nfft=65536, max_tones=4):
    """Strongest narrow lines in the average spectrum: list of (frequency Hz, level dB above the median)."""
    n = (x.size // nfft) * nfft
    seg = x[:n].reshape(-1, nfft) * np.hanning(nfft)
    p = np.mean(np.abs(np.fft.fftshift(np.fft.fft(seg, axis=1), axes=1)) ** 2, axis=0)
    f = (np.arange(nfft) - nfft // 2) * FS / nfft
    med = np.median(p)
    tones = []
    q = p.copy()
    for _ in range(max_tones):
        i = int(np.argmax(q))
        if q[i] < 3000 * med:  # a real narrow line stands ~35 dB or more above the spectrum
            break
        tones.append((f[i], 10 * np.log10(q[i] / med)))
        q[max(0, i - 8):i + 9] = med  # blank this line and its window leakage
    return tones


def remove_tone(x, f0):
    """Remove a narrow line at f0: shift it to 0 Hz, take out the slow part, shift back."""
    n = np.arange(x.size)
    rot = np.exp(-2j * np.pi * f0 * n / FS).astype(np.complex64)
    return (remove_lowpass(x * rot) * np.conj(rot)).astype(np.complex64)


SYM_STARTS = np.cumsum([0] + [NFFT + (80 if k % 7 == 0 else CP) for k in range(13)])  # 14 symbols of one slot


def cp_offset(x):
    """Frequency offset (Hz, modulo 15 kHz) and a structure figure from the cyclic-prefix correlation.

    Uses the slot's symbol grid: for every possible slot start in the first 1 ms of x, the 72-sample cyclic-prefix
    correlations of the 14 symbols are added up; the start with the largest sum is the slot timing, and the phase
    of that sum gives the offset. This also works for narrow signals (PUCCH on 1 PRB), where the correlation alone
    has no clear peaks. The structure figure is that largest sum over the average sum: ~2 for noise, larger for
    a real slot. x must cover at least 2 ms."""
    slot = int(1e-3 * FS)
    if x.size < 2 * slot:
        return np.nan, 0.0
    c = x[:-NFFT] * np.conj(x[NFFT:])
    p = np.convolve(c, np.ones(CP, dtype=np.float32), mode="valid")
    starts = np.arange(slot)
    idx = starts[:, None] + SYM_STARTS[None, :] + (80 - CP) * (np.arange(14)[None, :] % 7 == 0)
    idx = np.minimum(idx, p.size - 1)
    s = p[idx].sum(axis=1)
    m = np.abs(s)
    k = int(np.argmax(m))
    q = float(m[k] / (np.mean(m) + 1e-12))
    return float(-np.angle(s[k]) * FS / (2 * np.pi * NFFT)), q


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("capture")
    ap.add_argument("--min-db", type=float, default=10.0, help="slot must be this far above the noise floor")
    ap.add_argument("--band", nargs=2, type=float, metavar=("CENTER_MHZ", "WIDTH_KHZ"),
                    help="only analyse this part of the band, e.g. 4.5 600 for the PUCCH at the top edge (PRB 49-51)")
    ap.add_argument("--min-quality", type=float, default=4.0, help="structure figure: ~2 noise, >4 a real slot")
    a = ap.parse_args()

    raw = np.fromfile(a.capture, dtype=np.int16)
    x = raw[0::2].astype(np.float32) + 1j * raw[1::2].astype(np.float32)
    print(f"capture: {x.size} samples ({x.size / FS:.2f} s), level "
          f"{20 * np.log10(np.sqrt(np.mean(np.abs(x) ** 2)) / 32768 + 1e-12):.1f} dBFS")

    x = remove_lowpass(x)
    tones = find_tones(x)
    print("narrow lines (after DC removal):",
          ", ".join(f"{f:+.0f} Hz ({lvl:.0f} dB)" for f, lvl in tones) if tones else "none")
    for f0, _ in tones:
        x = remove_tone(x, f0)

    if a.band:
        # Keep only a sub-band: shift its centre (rounded to the 15 kHz grid, so the cyclic-prefix phase is unchanged)
        # to 0 Hz and low-pass it per 1 ms block in the frequency domain.
        fc = round(a.band[0] * 1e6 / SCS) * SCS
        half = a.band[1] * 1e3 / 2
        x = x * np.exp(-2j * np.pi * fc * np.arange(x.size) / FS).astype(np.complex64)
        blk = int(1e-3 * FS)
        f = np.fft.fftfreq(blk, 1 / FS)
        keep = np.abs(f) <= half
        nb = x.size // blk
        X = np.fft.fft(x[:nb * blk].reshape(nb, blk), axis=1)
        X[:, ~keep] = 0
        x = np.fft.ifft(X, axis=1).reshape(-1).astype(np.complex64)
        print(f"band: {fc / 1e6:.3f} MHz +- {half / 1e3:.0f} kHz only")

    # Uplink is bursty: judge each 1 ms slot on its own and keep only slots clearly above the noise.
    slot = int(1e-3 * FS)
    nsl = x.size // slot
    lv = np.array([20 * np.log10(np.sqrt(np.mean(np.abs(x[k * slot:(k + 1) * slot]) ** 2)) / 32768 + 1e-12)
                   for k in range(nsl)])
    floor = np.median(lv)
    print(f"noise floor (median 1 ms slot level): {floor:.1f} dBFS")
    busy = np.where(lv > floor + a.min_db)[0]
    print(f"slots more than {a.min_db:.0f} dB above the floor: {busy.size}")
    print("   t (s)    level dBFS   offset Hz   quality")
    rows = []
    for k in busy:
        f, q = cp_offset(x[k * slot:(k + 2) * slot])
        rows.append((k * slot / FS, lv[k], f, q))
    for t, lvl, f, q in rows[:80]:
        mark = "" if q >= a.min_quality else "   (no OFDM structure: PRACH or noise)"
        print(f"  {t:7.3f}   {lvl:8.1f}   {f:+9.1f}    {q:.2f}{mark}")
    if len(rows) > 80:
        print(f"  ... {len(rows) - 80} more")
    good = np.array([r[2] for r in rows if r[3] >= a.min_quality])
    if good.size:
        print(f"summary: {good.size} OFDM slots, offset median {np.median(good):+.1f} Hz, "
              f"spread (10..90 %) {np.percentile(good, 10):+.1f} .. {np.percentile(good, 90):+.1f} Hz")
    else:
        print("summary: no slot with OFDM structure found")


if __name__ == "__main__":
    main()
