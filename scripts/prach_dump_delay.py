#!/usr/bin/env python3
"""prach_dump_delay.py - signed arrival offset of every PRACH preamble in an OCUDU PRACH receive dump.

Usage:
  python3 scripts/prach_dump_delay.py <gnb log> <dump file> [--scs-khz 15] [--os 16] [--min-snr-db 10]
  python3 scripts/prach_dump_delay.py --selftest

The dump comes from the gNB config (log section):
    phy_rx_symbols_filename: /tmp/gnb_prach_dump.bin
    phy_rx_symbols_prach: true
Each PRACH window is written as complex64 (sequence length L x nof repetitions x ports) and logged as
    [sfn.slot] RX_PRACH: sector=0 offset=<complex floats> size=<complex floats>
(lib/phy/upper/upper_phy_rx_symbol_handler_printer_decorator.h:97-138). PUSCH grids are in the same file
(RX_SYMBOL lines) and are skipped.

For each window with energy, the script searches all ZC roots u (zeroCorrelationZoneConfig 0: one root per
preamble, no cyclic shift), correlates exactly like OCUDU's detector
(prach_detector_generic_impl.cpp: Y x conj(root), centred IDFT) but with oversampling, and reports the peak
position as a SIGNED delay: negative = the preamble arrived before the detector's zero, which the detector
cannot see (it searches delays >= 0 only). Compare 'delay_us' with the gNB's own 'ta=' for detected preambles:
they must agree within ~0.1 us, which validates the convention on your data.

For repeated preambles (B4: 12 repetitions, format 1: 2) it also estimates the residual frequency offset
from the phase between repetitions (B4: +/-7.5 kHz unambiguous; format 1: +/-625 Hz).
"""
import argparse
import re
import sys
import numpy as np

LOG_RE = re.compile(r"\[\s*(\d+)\.(\d+)\]\s+RX_PRACH: sector=(\d+) offset=(\d+) size=(\d+)")
DET_RE = re.compile(r"\[\s*(\d+)\.(\d+)\]\s+PRACH:.*?idx=(\d+) ta=([-0-9.]+)us detection_metric=([0-9.]+)")


def zc_matrix(L):
    """OCUDU's reference sequences, row u-1 for physical root u = 1..L-1.

    OCUDU's PRACH buffer and detector use the DFT of the Zadoff-Chu sequence, FFT(x_u)/sqrt(L) with
    x_u(n) = exp(-j pi u n (n+1) / L) (prach_generator_impl.cpp "sequence transform"; verified equal to
    ~1e-15). Correlating against x_u itself finds root -1/u and a root-dependent fake delay.
    """
    n = np.arange(L)
    u = np.arange(1, L)[:, None]
    x = np.exp(-1j * np.pi * ((u * n * (n + 1)) % (2 * L)) / L)
    return (np.fft.fft(x, axis=-1) / np.sqrt(L)).astype(np.complex64)


def logical_root(u, L):
    """Logical root index (TS 38.211 Tables 6.3.3.1-3/-4) of physical root u; None if unknown."""
    if L == 139:
        return 2 * (u - 1) if u <= 69 else 2 * (138 - u) + 1
    try:
        import os
        src = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib", "phy", "upper",
                                "channel_processors", "prach", "prach_generator_impl.cpp")).read()
        i = src.index("get_sequence_number_long")
        body = src[src.index("{", i):src.index("};", i)]
        lut = [int(v) for v in body[body.index("{", 1) + 1:].replace("\n", " ").split(",") if v.strip()]
        return lut.index(u) if u in lut else None
    except (OSError, ValueError):
        return None


def centred_idft_input(z, N):
    """Same index mapping as OCUDU's detector: upper half (incl. index L/2) at the start, lower half at the end."""
    L = z.shape[-1]
    h = L // 2
    out = np.zeros(z.shape[:-1] + (N,), dtype=np.complex64)
    out[..., : h + 1] = z[..., h:]
    out[..., N - h:] = z[..., :h]
    return out


def analyse_window(Y, X, scs_hz, os_factor):
    """Y: (reps, L). Returns u, signed delay (s), peak/mean ratio (dB), residual CFO (Hz) or None."""
    reps, L = Y.shape
    N = L * os_factor
    comb = Y.sum(axis=0)
    corr = np.fft.ifft(centred_idft_input(X.conj() * comb[None, :], N), axis=-1)
    p = np.abs(corr) ** 2
    iu, ipk = np.unravel_index(int(np.argmax(p)), p.shape)
    metric = 10 * np.log10(p[iu, ipk] / np.mean(p[iu]))
    k = ipk if ipk < N // 2 else ipk - N
    delay = k / (N * scs_hz)
    cfo = None
    if reps > 1:
        c = np.fft.ifft(centred_idft_input(X[iu].conj()[None, :] * Y, N), axis=-1)[:, ipk]
        dphi = np.angle(np.sum(c[1:] * np.conj(c[:-1])))
        cfo = dphi / (2 * np.pi) * scs_hz  # one repetition lasts 1/scs
    return iu + 1, delay, metric, cfo


def selftest():
    rng = np.random.default_rng(1)
    ok = True
    for L, scs, reps, u, delay, cfo in [(139, 15e3, 12, 138, -1.2e-6, 200.0), (139, 15e3, 12, 5, 3.4e-6, -900.0),
                                        (839, 1.25e3, 2, 710, 16.0e-6, 100.0), (839, 1.25e3, 2, 129, -0.9e-6, 0.0)]:
        n = np.arange(L)
        x = zc_matrix(L)[u - 1]
        f = n - L // 2  # frequency index relative to DC, as the detector's mapping assumes
        Y = np.array([x * np.exp(-2j * np.pi * f * scs * delay) * np.exp(2j * np.pi * cfo * r / scs)
                      for r in range(reps)])
        Y = Y + (rng.normal(size=Y.shape) + 1j * rng.normal(size=Y.shape)) * 0.3
        uu, d, m, c = analyse_window(Y.astype(np.complex64), zc_matrix(L), scs, 16)
        good = uu == u and abs(d - delay) < 0.05 / scs / L * 16 + 0.05e-6 and (c is None or abs(c - cfo) < 30)
        ok &= good
        print(f"L={L} u={u} delay {delay*1e6:+.2f} us cfo {cfo:+.0f} Hz -> u={uu} delay {d*1e6:+.3f} us "
              f"metric {m:.1f} dB cfo {c:+.0f} Hz  {'OK' if good else 'FAIL'}")
    sys.exit(0 if ok else 1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("log", nargs="?")
    ap.add_argument("dump", nargs="?")
    ap.add_argument("--scs-khz", type=float, default=None,
                    help="PRACH subcarrier spacing; default 15 for L=139, 1.25 for L=839")
    ap.add_argument("--os", type=int, default=16, help="IDFT oversampling (default 16)")
    ap.add_argument("--min-snr-db", type=float, default=10.0,
                    help="skip windows whose power is less than this above the median window power")
    ap.add_argument("--root-seq-idx", type=int, default=1,
                    help="prach_root_sequence_index of the cell (default 1), to print the preamble index")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        selftest()
    if not a.log or not a.dump:
        ap.error("need <gnb log> <dump file> (or --selftest)")

    wins, dets = [], {}
    with open(a.log, errors="replace") as fh:
        for line in fh:
            m = LOG_RE.search(line)
            if m:
                wins.append(tuple(int(v) for v in m.groups()))
                continue
            m = DET_RE.search(line)
            if m and float(m.group(5)) >= 3.0:
                dets.setdefault((int(m.group(1)), int(m.group(2))), []).append((int(m.group(3)), float(m.group(4))))
    if not wins:
        sys.exit("no 'RX_PRACH:' lines in the log (is phy_rx_symbols_prach: true and the PHY log level info?)")

    data = np.memmap(a.dump, dtype=np.complex64, mode="r")
    size = wins[0][4]
    L = 839 if size % 839 == 0 else 139
    reps = size // L
    scs = (a.scs_khz if a.scs_khz else (15.0 if L == 139 else 1.25)) * 1e3
    X = zc_matrix(L)
    print(f"{len(wins)} PRACH windows, L={L}, {reps} repetition(s) x port(s) per window, SCS {scs/1e3:g} kHz, "
          f"delay resolution {1e6/(L*scs):.3f} us (oversampled x{a.os})")

    powers = []
    for sfn, slot, _, off, sz in wins:
        if off + sz > data.size:
            powers.append(np.nan)
            continue
        powers.append(float(np.mean(np.abs(data[off:off + sz]) ** 2)))
    powers = np.array(powers)
    floor = np.nanmedian(powers)
    print("sfn.slot  power_dB(above median)  root_u  preamble  delay_us(signed)  peak_dB  cfo_Hz   gNB detection (idx, ta)")
    found = []
    for (sfn, slot, _, off, sz), pw in zip(wins, powers):
        if not np.isfinite(pw) or pw <= 0 or 10 * np.log10(pw / floor) < a.min_snr_db:
            continue
        Y = np.asarray(data[off:off + sz]).reshape(-1, L)
        u, d, m, c = analyse_window(Y, X, scs, a.os)
        det = dets.get((sfn, slot))
        det_s = ", ".join(f"idx={i} ta={t:.2f}us" for i, t in det) if det else "NOT DETECTED"
        cfo_s = f"{c:+7.0f}" if c is not None else "      -"
        lr = logical_root(u, L)
        pre = (lr - a.root_seq_idx) % (L - 1) if lr is not None else None
        pre_s = f"{pre:4d}" if pre is not None and pre < 64 else "   ?"
        print(f"{sfn:4d}.{slot:<2d}   {10*np.log10(pw/floor):6.1f}               {u:4d}    {pre_s}  {d*1e6:+9.3f}"
              f"        {m:5.1f}   {cfo_s}   {det_s}")
        found.append(d * 1e6)
    if found:
        f = np.array(found)
        print(f"\n{f.size} preamble(s): delay min {f.min():+.3f} us, median {np.median(f):+.3f} us, "
              f"max {f.max():+.3f} us")
        print("time_alignment_calibration moves arrivals by -cal/15.36 us (negative cal = later arrival).")
    else:
        print("no window with energy above the threshold (lower --min-snr-db?)")


if __name__ == "__main__":
    main()
