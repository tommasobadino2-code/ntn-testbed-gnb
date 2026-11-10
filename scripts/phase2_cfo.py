#!/usr/bin/env python3
"""phase2_cfo.py - frequency offset of a recorded downlink (Doppler test plan, Phase 2).

Usage:
  python3 scripts/phase2_cfo.py <recording> [--ref <reference recording>] [--expect <Hz>]

Recordings: interleaved int16 I/Q at 15.36 Msps, as written by
  rx_samples_to_file --type short --rate 15.36e6 ...

Method:
  fine   - cyclic-prefix correlation: every OFDM symbol starts with a copy of its last 72 samples, so
           r[n] * conj(r[n + 1024]) has the phase 2*pi*f*1024/fs on those samples. Summed over the whole
           recording this gives f to a few Hz, but only modulo 15 kHz (the subcarrier spacing).
  coarse - shift of the power spectrum against a reference recording (same gNB, Doppler off): about 1 kHz,
           enough to pick the right multiple of 15 kHz.
Prints the offset of the recording; with --ref also the reference's offset and the difference, which is the
emulated Doppler (the B200 oscillator offset cancels).
"""
import argparse
import numpy as np

FS = 15.36e6
NFFT = 1024          # 15 kHz subcarrier spacing at 15.36 Msps
SCS = FS / NFFT      # 15 000 Hz


def load(path):
    raw = np.fromfile(path, dtype=np.int16)
    if raw.size < 2 * 200000:
        raise SystemExit(f"{path}: only {raw.size // 2} samples")
    x = raw[0::2].astype(np.float32) + 1j * raw[1::2].astype(np.float32)
    clip = np.mean((np.abs(raw[0::2]) >= 32760) | (np.abs(raw[1::2]) >= 32760))
    return remove_near_dc(x), clip


def remove_near_dc(x, n=4096):
    """Subtract a 4096-sample moving average: removes the receiver's DC offset and the gNB transmitter's LO leakage
    (both sit within ~2 kHz of 0 Hz and are NOT Doppler-shifted, so they would pull both estimates towards 0).
    The average is exactly zero for every multiple of 3.75 kHz, so OFDM subcarriers (15 kHz grid) pass unchanged."""
    c = np.concatenate(([0], np.cumsum(x, dtype=np.complex128)))
    avg = np.empty_like(x)
    h = n // 2
    idx = np.arange(x.size)
    lo = np.clip(idx - h, 0, x.size)
    hi = np.clip(idx + h, 0, x.size)
    avg[:] = (c[hi] - c[lo]) / np.maximum(hi - lo, 1)
    return (x - avg).astype(np.complex64)


def level_dbfs(x):
    return 20 * np.log10(np.sqrt(np.mean(np.abs(x) ** 2)) / 32768 + 1e-12)


def fine_offset(x):
    """Frequency offset modulo 15 kHz, in (-7500, 7500] Hz, and a quality figure (0..1)."""
    c = x[:-NFFT] * np.conj(x[NFFT:])
    # Sum over 72-sample windows: large where a window sits on a cyclic prefix, small elsewhere. Weighting each
    # window by its own magnitude keeps the CP positions and suppresses the noise-only ones (no symbol timing needed).
    p = np.convolve(c, np.ones(72, dtype=np.float32), mode="valid")
    s = np.sum(p * np.abs(p))
    quality = np.abs(np.sum(p)) / np.sum(np.abs(p))
    # x[n+N] = x[n] * exp(j 2 pi f N / fs) on the cyclic prefix  ->  angle(conj) = -2 pi f N / fs
    f = -np.angle(s) * FS / (2 * np.pi * NFFT)
    return f, quality


def psd(x, nfft=8192):
    n = (x.size // nfft) * nfft
    seg = x[:n].reshape(-1, nfft) * np.hanning(nfft)
    p = np.mean(np.abs(np.fft.fftshift(np.fft.fft(seg, axis=1), axes=1)) ** 2, axis=0)
    p = np.minimum(p, 10 * np.median(p))  # cap narrow spurs so the wideband OFDM shape decides the shift
    return p / np.max(p)


def coarse_shift(x, ref, nfft=8192, max_hz=60e3):
    """Spectrum shift of x against ref, Hz (positive = x is higher in frequency)."""
    a, b = psd(x, nfft), psd(ref, nfft)
    a, b = a - a.mean(), b - b.mean()
    bin_hz = FS / nfft
    k = int(max_hz / bin_hz)
    lags = np.arange(-k, k + 1)
    cc = np.array([np.sum(a * np.roll(b, l)) for l in lags])
    i = int(np.argmax(cc))
    off = 0.0
    if 0 < i < len(cc) - 1:  # parabolic refinement
        y0, y1, y2 = cc[i - 1], cc[i], cc[i + 1]
        den = y0 - 2 * y1 + y2
        off = 0.5 * (y0 - y2) / den if den != 0 else 0.0
    return (lags[i] + off) * bin_hz


def print_segments(x, n):
    """Fine offset of n equal parts: shows whether the estimate (and the radios) are stable within the file."""
    if n <= 1:
        return
    vals = [fine_offset(part)[0] for part in np.array_split(x, n)]
    print(f"   per {x.size / FS / n * 1e3:.0f} ms: " + " ".join(f"{v:+.1f}" for v in vals)
          + f"   (spread {max(vals) - min(vals):.1f} Hz)")


def resolve(fine, coarse):
    """fine + k * 15 kHz closest to the coarse estimate."""
    k = np.round((coarse - fine) / SCS)
    return fine + k * SCS


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("recording")
    ap.add_argument("--ref", help="reference recording, same gNB with Doppler off")
    ap.add_argument("--expect", type=float, help="expected Doppler (difference to the reference), Hz")
    ap.add_argument("--segments", type=int, default=0, help="also print the fine offset of N equal parts of each file")
    a = ap.parse_args()

    x, clip = load(a.recording)
    f_x, q_x = fine_offset(x)
    print(f"recording : {a.recording}: {x.size} samples ({x.size / FS:.2f} s), level {level_dbfs(x):.1f} dBFS, "
          f"clipped {100 * clip:.3f} %")
    print(f"   fine offset (modulo 15 kHz): {f_x:+.1f} Hz, quality {q_x:.2f}")
    print_segments(x, a.segments)
    if q_x < 0.05:
        print("   WARNING: almost no OFDM signal found (quality < 0.05): wrong antenna port, gain or link silent?")

    if not a.ref:
        return
    r, clip_r = load(a.ref)
    f_r, q_r = fine_offset(r)
    print(f"reference : {a.ref}: level {level_dbfs(r):.1f} dBFS, clipped {100 * clip_r:.3f} %")
    print(f"   fine offset (modulo 15 kHz): {f_r:+.1f} Hz, quality {q_r:.2f}  (= B200 oscillator offset)")
    print_segments(r, a.segments)

    coarse = coarse_shift(x, r)
    diff = resolve(f_x - f_r, coarse)
    print(f"coarse spectrum shift recording - reference: {coarse:+.0f} Hz")
    print(f"=> measured Doppler (recording - reference): {diff:+.1f} Hz")
    if a.expect is not None:
        err = diff - a.expect
        verdict = "PASS" if abs(err) <= 20 else "FAIL"
        print(f"   expected {a.expect:+.1f} Hz, error {err:+.1f} Hz -> {verdict} (criterion +-20 Hz)")


if __name__ == "__main__":
    main()
