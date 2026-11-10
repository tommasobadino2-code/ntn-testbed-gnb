#!/usr/bin/env python3
"""rec_b200.py - record I/Q from a B200 with UHD's Python API (Doppler test plan, Phase 2).

Replaces UHD's rx_samples_to_file example, whose gain step fails in this UHD build
("RX channel 18446744073709551615 out of range"). Everything is set on channel 0 explicitly.

  record: python3 scripts/rec_b200.py --serial 328A309 --gain 40 [--ant RX2] --duration 1 --out /tmp/x.dat
  probe : python3 scripts/rec_b200.py --serial 328A309 --probe
          0.1 s per antenna port (RX2, TX/RX) and gain (0, 20, 40, 60 dB); prints level and OFDM quality.

Output file: interleaved int16 I/Q (same format as rx_samples_to_file --type short), read by phase2_cfo.py.
"""
import argparse
import os
import sys

import numpy as np
import uhd

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from phase2_cfo import fine_offset, level_dbfs  # noqa: E402

RATE = 15.36e6
FREQ = 2185e6
CHUNK = 153600  # 10 ms per recv call


def open_usrp(serial):
    usrp = uhd.usrp.MultiUSRP(f"type=b200,serial={serial}")
    usrp.set_rx_rate(RATE, 0)
    usrp.set_rx_freq(uhd.types.TuneRequest(FREQ), 0)
    st_args = uhd.usrp.StreamArgs("fc32", "sc16")
    st_args.channels = [0]
    streamer = usrp.get_rx_stream(st_args)  # one streamer, reused for every capture
    return usrp, streamer


def capture(usrp, streamer, gain, ant, nsamps):
    usrp.set_rx_gain(gain, 0)
    if ant:
        usrp.set_rx_antenna(ant, 0)
    md = uhd.types.RXMetadata()
    buf = np.zeros((1, CHUNK), dtype=np.complex64)
    out = np.zeros(nsamps, dtype=np.complex64)

    cmd = uhd.types.StreamCMD(uhd.types.StreamMode.start_cont)
    cmd.stream_now = True
    streamer.issue_stream_cmd(cmd)
    got, overflows, discard = 0, 0, int(0.05 * RATE)  # drop the first 50 ms (gain/LO settling)
    try:
        while got < nsamps:
            n = streamer.recv(buf, md, 1.0)
            if md.error_code == uhd.types.RXMetadataErrorCode.overflow:
                overflows += 1
                continue
            if md.error_code != uhd.types.RXMetadataErrorCode.none:
                raise RuntimeError(f"receive error: {md.strerror()}")
            if discard > 0:
                discard -= n
                continue
            take = min(n, nsamps - got)
            out[got:got + take] = buf[0, :take]
            got += take
    finally:
        streamer.issue_stream_cmd(uhd.types.StreamCMD(uhd.types.StreamMode.stop_cont))
    return out, overflows, usrp.get_rx_antenna(0), usrp.get_rx_gain(0)


def to_int16(x):
    iq = np.empty(2 * x.size, dtype=np.int16)
    iq[0::2] = np.clip(np.round(x.real * 32767), -32768, 32767)
    iq[1::2] = np.clip(np.round(x.imag * 32767), -32768, 32767)
    return iq


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--serial", default="328A309")
    ap.add_argument("--gain", type=float, default=40)
    ap.add_argument("--ant", default="")
    ap.add_argument("--duration", type=float, default=1.0)
    ap.add_argument("--out")
    ap.add_argument("--probe", action="store_true")
    a = ap.parse_args()

    usrp, streamer = open_usrp(a.serial)
    print(f"   B200 {a.serial}: rate {usrp.get_rx_rate(0) / 1e6:.2f} Msps, freq {usrp.get_rx_freq(0) / 1e6:.6f} MHz, "
          f"antennas {list(usrp.get_rx_antennas(0))}")

    if a.probe:
        for ant in ("RX2", "TX/RX"):
            for gain in (0, 20, 40, 60):
                x, ovf, ant_used, g_used = capture(usrp, streamer, gain, ant, int(0.1 * RATE))
                xi = to_int16(x)
                clip = np.mean(np.abs(xi) >= 32760)
                f, q = fine_offset(xi[0::2].astype(np.float32) + 1j * xi[1::2].astype(np.float32))
                print(f"   port {ant_used:6s} gain {g_used:4.0f} dB: level {level_dbfs(x * 32767):6.1f} dBFS, "
                      f"clipped {100 * clip:.2f} %, OFDM quality {q:.2f}, fine offset {f:+8.1f} Hz, overflows {ovf}")
        return

    if not a.out:
        raise SystemExit("--out is required unless --probe")
    x, ovf, ant_used, g_used = capture(usrp, streamer, a.gain, a.ant, int(a.duration * RATE))
    to_int16(x).tofile(a.out)
    print(f"   recorded {x.size} samples on port {ant_used}, gain {g_used:.0f} dB, overflows {ovf} -> {a.out}")


if __name__ == "__main__":
    main()
