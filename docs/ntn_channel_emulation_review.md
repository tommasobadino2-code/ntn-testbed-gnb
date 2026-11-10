# NTN channel emulation on the B200 testbed: review and architecture options

Branch `ntn-emu-review` (from `b200-doppler` @ 74c25c3). Scope: the UHD software channel emulator
(ed37083, a71b144), the gNB NTN manager (`lib/ntn/`), the OCUDU rfsim NTN channel (`lib/radio/rfsimulator/`)
and the OAI UE NTN code (ntn-testbed-ue `ntn-testbed` @ 83e7200, TOSSI `rfsim_ocudu`).

Tags used throughout:

- **[measured]**: from your logs or captures (as you reported them to me).
- **[code]**: read from the source, with file:line.
- **[computed]**: numbers I computed offline from the configs (two-body orbit propagation, RK4, 10 ms step;
  scripts kept in the session scratchpad, not committed). Orbit = `leo_uhd_dop_cfo_mcs_gnb.yml` (600 km,
  reference location at the pole) and `meo_uhd_dop_gnb.yml` (8000 km).
- **[hypothesis]**: not proven; each one comes with the measurement that would confirm or refute it.

UE file paths are relative to the OAI tree (`executables/`, `openair1/`, `openair2/`); gNB paths to this repo.

---

## 0. What the emulator does, in one paragraph [code]

Every ~160 ms the NTN manager computes the reference-location UL timing advance at the next SIB19 epoch,
back-extrapolates it to "now" with the RTT drift and sends it to the radio
(`lib/ntn/ntn_configuration_manager_impl.cpp:644-703`, called from `:972` with `epoch_time - tp`).
The UHD emulator (`lib/radio/uhd/radio_uhd_channel_emulator.cpp:101-121`) turns the service-link RTT drift into
one Doppler rate `-drift/2`, and multiplies it by the DL carrier (gNB TX shifter, `radio_uhd_tx_stream.cpp:198-229`)
and by the UL carrier (gNB RX shifter, `radio_uhd_rx_stream.cpp:276-288`). On receive, the samples go into a
0.65 s ring indexed by their UHD timestamp and are read back `delay` samples earlier; the integer delay is
`llround((rx_delay + drift * elapsed) * fs)`, evaluated once per 1 ms step aligned to absolute timestamps
(`radio_uhd_rx_stream.cpp:305-334`). The downlink is not delayed. This is the same placement and the same
Doppler law as the OCUDU rfsim channel (`lib/radio/rfsimulator/radio_session_rfsimulator_impl.cpp:139-160`,
`rfsim_shim.cpp:323-333`), except that rfsim re-evaluates the delay per received block, not per 1 ms step.

---

## 1. Task 1: review, point by point

### a. All delay on the uplink, downlink not delayed

**What the code does** [code]. The DL leaves the gNB with only the Doppler shift; the UL is delayed by the full
reference-location RTT (`ntn_configuration_manager_impl.cpp:672-674` uses `compute_ref_location_ul_ta`, the
service-link RTT plus ta-Common when a feeder link is configured; no feeder link in any current config).

**What a real transparent LEO/MEO/GEO link does.** The DL arrives at the UE one way later (d1 = service + feeder
one-way delay), the UE transmits its UL slot n at its received DL slot n minus T_TA, with
T_TA = (N_TA + N_TA,offset + N_TA,adj^common + N_TA,adj^UE) Tc (TS 38.211 4.3.1, TS 38.213 4.2), and the UL
arrives one way later again. The gNB sees the UL aligned with its own DL frame, offset by k_offset
scheduling (TS 38.213 / 38.214 K_offset, SIB19 `cellSpecificKoffset`).

**What is equivalent.**

| Quantity | Real link | Our emulator | Equivalent? |
|---|---|---|---|
| UL arrival at the gNB when the UE applies T_TA = RTT | aligned with the gNB frame | aligned (`T_n - RTT + RTT`) | yes |
| UE processing time between a DL grant and its UL slot | `T_n - T_k - RTT` | `T_n - T_k - RTT` (DL arrives d1 earlier, UL leaves d1 earlier) | yes |
| k_offset, RAR window offset by UE-gNB RTT (TS 38.321 5.1.4), HARQ/RLC timers at the gNB | from SIB19 | from SIB19 | yes |
| PRACH/PUSCH/PUCCH timing seen by the gNB receiver | | | yes |

**What is not equivalent.**

1. *UE DL frame timing.* The UE's DL frame is the gNB frame plus cable, not plus d1 (9.4 ms LEO horizon,
   ~120 ms GEO). Anything the UE derives from absolute DL timing changes: the SIB19 epoch time is
   "the starting time of a DL sub-frame" (TS 38.331 `epochTime`), which the UE can only locate on its received
   DL. In a real link the UE evaluates the ephemeris d1 after the gNB's instant of the same SFN; the satellite
   moves d1 x 7.5 km/s (~70 m at LEO horizon) in between, i.e. a ~0.43 us RTT difference (46 us/s x 9.4 ms)
   that the gNB has to account for (TS 38.331 reference-point convention). **Our emulator hides this term
   entirely (d1 = 0 at the UE)**, so a correct result on our bench does not prove the gNB and UE agree on the
   epoch reference point. Matters for timing accuracy at the sub-us level only.
2. *DL timing drift.* A real UE sees the DL drift at half the RTT drift (-23 us/s LEO horizon, -7.8 us/s MEO
   horizon) and its time tracking must follow it; on our bench the UE sees **no** DL drift (only the B200
   sample-clock offset, ~0.17 ppm = 0.17 us/s [measured: 340 Hz at 2 GHz]). So the UE time-tracking loop is not
   exercised as in orbit.
3. *`--ntn-initial-time-drift -40` and `--time-sync-I 0.1`* [code]: `executables/nr-ue.c:758-761` preloads the
   PI integrator with `max_pos_acc = drift * 1e-6 * samples_per_frame / I` = -40e-6 x 153600 / 0.1 = **-61**,
   and `nr-ue.c:969` then shifts the UE frame by `-round(max_pos_acc * I)` = **+6 samples per frame**
   (0.39 us per 10 ms, i.e. 39 us/s), and `nr-ue.c:872` adds a lump `(init_sync_frame + trashed + 2) x 6`
   samples at sync. Positive shift = shorter read = UE frame moves **earlier**. With an undelayed DL there is
   no drift to follow, so this preload is wrong for our bench: the loop must first unwind the -61 accumulator
   against measured SSB timing errors (`nr_adjust_synch_ue.c:53-71`), during which the UE DL reference, and
   hence its UL transmission, is early by a few to ~12 samples (0.1-0.8 us) [hypothesis on the size;
   the sign is from the code]. The value -40 comes from setups that delay the DL (the upstream OAI rfsim model).
   **For this emulator the correct value is 0** (or the B200 pair's relative clock drift, ~0.2 us/s).
4. *Time compression on the DL* (see b): not modelled.

**Does it matter for what we test?** For gNB-side behaviour (PRACH detection, TA loop, k_offset scheduling,
HARQ timing) the placement is equivalent. For UE-side timing (DL tracking, epoch interpretation, the UE's own
TA accuracy) it is not, and item 3 is a candidate contributor to the "preambles 0.48-1.44 us early" finding.

**How to check it.**

- Compare the UE frame shifts with -40 and with 0. One run each, LEO horizon, index 209 (so detection is not
  the variable), everything else unchanged; read the first PRACH `ta=` in the gNB log and the UE's
  `max_pos_acc = ..., shiftForNextFrame = ...` line (LOG_I, `nr-ue.c:873`).
  Expected if item 3 matters: with 0 the first PRACH arrives later (larger `ta=`) by a few hundred ns.
- Epoch reference point: only testable with a delayed DL (option 3a in Task 2).

### b. Delay drift / time compression

**What the code does** [code]. Integer delay `llround(delay_us * 1e-6 * fs)` (`radio_uhd_rx_stream.cpp:319`),
held for a whole 1 ms step aligned to absolute timestamps (`:309-322`, v3), so at LEO horizon
(0.707 samples/ms) the UL timing moves by one sample (65 ns) at a slot boundary in ~70 % of slots. No
fractional delay, no resampling. rfsim does the same per block (`rfsim_shim.cpp:331`). The DL has no delay
and therefore no drift.

**Real link.** The delay is continuous; a drift of 46 us/s is a 46 ppm time compression of the UL waveform
(and 23 ppm on the DL): every subcarrier gets its own Doppler `(f_c + f_k) v/c`, and the symbol timing slides
continuously.

**Does it matter?**

- *Carrier Doppler*: modelled (point c).
- *Baseband time compression*: modelled only as 65 ns steps on the UL. The residual is the
  across-band Doppler difference: one-way 2.3e-5 x 4.68 MHz (band edge, 52 PRB) = **±108 Hz** [computed], i.e.
  0.7 % of the 15 kHz SCS. Negligible for the PHY (ICI < -40 dB), but it means the emulator is ~50 % "too
  ideal" on the UE DL (no compression at all) and a real UE's sample-rate tracking is untested.
- *Step size*: 65 ns per step is 1.4 % of the 4.7 us normal CP; harmless for PUSCH/PUCCH. For a
  3-subframe format-1 preamble, at LEO horizon there are usually two 1-sample steps inside the preamble;
  each is a small timing discontinuity in the 839-length sequence (< 1 bin of 0.95 us), i.e. a small
  correlation loss, not a timing error.
- *Per-update jump*: at every 160 ms update the base delay is replaced by a value rounded to whole us
  (point d), so the UL timing jumps by up to ±1 us (±15 samples) at a slot boundary every 160 ms. The gNB
  sees this as TA noise; with `ta_cmd_offset_threshold: 1` that can cause TA commands that only chase
  the rounding.

**How to check it.**

- v4 capture: correlate consecutive PUSCH DMRS (or SSB-free UL bursts) against each other across a 160 ms
  update and look for a ±1-15 sample step; or simpler, count TA commands per second in the gNB log at
  LEO horizon vs GEO (no drift): `grep -ac "TA cmd"`-type counts, same duration.
- Time compression on DL: not measurable until the DL is delayed (Task 2, option 3a).

### c. Doppler

**What the code does** [code].

- One frequency per update: `-0.5 x service_drift x 1e-6 x f` (`radio_uhd_channel_emulator.cpp:115-117`),
  from the range rate at the **SIB19 epoch** (up to one SI period + window ahead, `ntn_configuration_manager_impl.cpp:812-828`),
  held for ~160 ms. First-order only (the UE uses `v/(c-v) f` for DL and `v/c f` for UL,
  `nr_ntn_l1.c:92-96`; the difference is f v^2/c^2 = 1.2 Hz at LEO, negligible).
- DL scaled with the DL carrier (2185 MHz), UL with the UL carrier (1995 MHz): correct.
- Phase continuity [code + computed]: `Coarse_Freq_Offset` keeps a 32-bit phase accumulator across blocks and
  across updates (`coarse_freq_offset.h:59`, `.cpp:141`); the new frequency takes effect at the start of the
  next block because `phase_inc` is latched once per call (`coarse_freq_offset.cpp:67`; the raised-cosine
  ramp in `set_freq` therefore only moves the *next* block's value). Result: phase-continuous, frequency
  steps with one-block (≤ 1 ms) latency. Offline test (this review): at 46 027.4 Hz the output tone is
  46 027.24 Hz (-0.16 Hz, 3.5 ppm of the shift), amplitude error ≤ 1.4 LSB at 10 000 (-77 dB).
  The resolution is fs/2^32 = 0.0036 Hz. Sine table: 1024-segment linear interpolation, error ~5e-6.
- Order on the UL: shift first, then delay (`radio_uhd_rx_stream.cpp:284-294`), like the OAI emulator. With a
  frequency that is constant over 160 ms the order only changes a constant phase; the Doppler phase is not
  tied to the delay (`phase != -2 pi f_c tau(t)`), which only matters for carrier-phase ranging.
- int16 wrap [code + computed]: `static_cast<int16_t>(float)` (`coarse_freq_offset.cpp:124-137, 156-157`) wraps
  instead of saturating. A rotation keeps |z|, so a sample wraps iff |z| > 32767, e.g. any
  (24000, 24000) input (33 % of samples in my test), never (32000, 0). DL: with `tx_gain_backoff: 12` and
  OCUDU's clipping this needs a near-full-scale peak, rare. UL: only when the B200 ADC is already
  saturated. Fix (one line per sample, saturating conversion) is cheap; not urgent.

**Real link.** Doppler varies continuously; at LEO the rate peaks at zenith.

| Orbit (our configs) | UL Doppler range | max Doppler rate | worst UL Doppler error, held 160 ms, computed 0.04-0.2 s ahead |
|---|---|---|---|
| LEO 600 km, pass over the reference | ±46.0 kHz | 576 Hz/s (zenith) | **115-208 Hz** (at high elevation); ~0.05 Hz at horizon (0.13 Hz/s) |
| MEO 8000 km | -14.8..+15.5 kHz | 9.7 Hz/s | 2-4 Hz |

[computed]

**Does it matter?** At the LEO horizon (where you test) no. Near zenith, a 100-200 Hz sawtooth on the UL is
comparable to the UE pre-compensation residual you already see (+170/+340 Hz); on a format-1 PRACH it moves
energy from the true peak into an alias 12.4 us away (see g; the TA itself only jumps once the total error
passes ~half a bin, 625 Hz). For B4 PRACH and PUSCH (with the CFO estimator on) it is harmless.

**How to check it.** Zenith run (`set_leo_pass.sh --single --elev 80`), v4 capture of 1 s, then estimate the
PUSCH DMRS phase slope per slot: you should see a sawtooth with a 160 ms period and a peak-to-peak close to
576 Hz/s x 0.16 s = 92 Hz (+ lead bias). At horizon: flat within a few Hz.

### d. Consistency between the channel and SIB19

There are two computations [code]: the gNB's (Kepler propagation in ECI, `ntn_orbital_compute_module.cpp:180-235`;
RTT rounded to whole us, `:258-268`; lead correction rounded again, `ntn_configuration_manager_impl.cpp:672-674`;
linear extrapolation between updates in the emulator) and the UE's (`openair2/LAYER2/NR_MAC_UE/config_ue.c:280-337`:
SIB19 ECEF state vector quantised to 1.3 m / 0.06 m/s, then a circular-orbit rotation in the ECEF plane spanned
by r and v; `nr_ntn_l1.c:48-109`: TA evaluated once per 1 ms subframe with integer ms since epoch, converted
to an int by truncation).

Worst-case contributions [computed unless noted]:

| Term | LEO horizon | LEO zenith | MEO | GEO | Sign |
|---|---|---|---|---|---|
| gNB RTT rounding (`round` to 1 us) | ±0.5 us | ±0.5 us | ±0.5 us | ±0.5 us | random per update |
| gNB lead-correction rounding (`llround`) | ±0.5 us | ±0.5 us | ±0.5 us | 0 (drift≈0) | random per update |
| Linear extrapolation over ≤0.36 s | 0.000 us | 0.04 us | 0.001 us | 0 | systematic |
| UE propagation model vs two-body, t = 0.2 / 5 / 30 s since epoch | 0.00 / 0.002 / 0.05 us | similar | smaller | 0 | systematic |
| SIB19 quantisation (1.3 m) | ≤ 0.008 us | ≤ 0.008 us | ≤ 0.008 us | ≤ 0.008 us | |
| Emulator integer sample + 1 ms hold | ±0.033 + 0.046 us | | | | |
| UE int truncation of TA + 1 ms hold | 0..-0.065 + 0.046 us | | | | |
| Delay valid at `tp` applied from the next RX block (DU slot clock leads the radio) [hypothesis on size: 2-5 ms] | 0.1-0.25 us **early** | ~0 | 0.03-0.08 us | 0 | early when approaching |
| Epoch reference point (not modelled, see a.1) | (0.43 us in a real link) | | | | |
| **Total, worst** | **≈ 1.1-1.4 us** | ≈ 1.1 us | ≈ 1.1 us | ≈ 1.0 us | |

Frequency mismatch: the UE evaluates its UL pre-compensation every subframe from its own propagation (error
< 0.5 Hz up to 5 s after the epoch [computed]); the channel holds one value for 160 ms: up to 0.05 Hz (LEO
horizon), 115-208 Hz (LEO zenith), 2-4 Hz (MEO) [computed].

**Comparison with the rfsim finding (0.48-1.44 us early).** The size matches this budget: it is dominated by
the two 1-us roundings, not by the orbit propagation (the two propagators agree to a few ns over seconds; the
linear extrapolation is accurate to ns over 160 ms at the horizon). The *systematic* early part (no late
cases) is not explained by symmetric rounding; candidates are the application-time lead (row "valid at tp")
and the UE time-tracking preload of point a.3. So the 10 Nov statement "mismatch grows with drift" is right
for those two terms but the rounding is the bigger, drift-independent part, and it also exists at GEO.

**Upstream OAI**, for comparison: the channel delay and SIB19 are derived from the same orbit state in the
same process at sample resolution, so this whole table collapses to the UE-side rows (< 0.1 us).

**How to check it (existing logs, no new run).**

- [CONTAINER] gNB values (rx_delay in us, drift):

```bash
grep -a "Emulated NTN channel updated" /tmp/gnb_leo_dop.log | head -n 3
```

- [CONTAINER] UE values (timing_advance_ntn in samples at 15.36 Msps = us x 15.36):

```bash
sed 's/\x1b\[[0-9;]*m//g' /tmp/ue_leo_uhd.log | grep -a "timing_advance_ntn" | head -n 3
```

  Expected: UE `timing_advance_ntn / 15.36` and the gNB `rx_delay` (moved to the same instant with the drift)
  agree within ~1 us; a stable sign of the difference over many updates would point at the application-time term.
- Direct: the PRACH receive dump (Task 3) gives the arrival offset per preamble at sample resolution.

### e. Hardware effects on the B200 path

- *Independent oscillators* [measured]: residual UL +170 Hz (mode 1) / +340 Hz (mode 3) ≈ 0.17 ppm relative.
  Same ppm on the sample clock: 2.6 samples/s, 0.17 us/s of timing drift, followed by the UE time tracking and
  the gNB TA loop. Harmless with PUSCH CFO compensation on, **not harmless for format 1 PRACH**: 340 Hz is
  27 % of a 1.25 kHz bin: about 1 dB of correlation loss and an alias peak 12.4 us late at roughly -10 dB
  (point g); with any further error of ~300 Hz the alias wins and the TA jumps by 12.4 us. B4 (15 kHz SCS)
  tolerates it (2 % of a bin).
- *TX/RX turnaround and buffering*: FDD with continuous streams, so no turnaround; what matters is the
  fixed TX-to-RX latency of each radio. `-A 216` (14.06 us) on the UE and `time_alignment_calibration`
  (default 0, `apps/units/flexible_o_du/split_8/helpers/ru_sdr_config_translator.cpp:41-47`) on the gNB are the
  two knobs; they act on the same quantity (preamble arrival), so they must be calibrated together.
  USB latency itself is hidden by timestamps; it only costs real-time margin (late TX, overflows).
- *Gain / int16 headroom*: see c (wrap only above |z| = 32767). The emulator works on int16 after OCUDU's
  amplitude control, so the TX backoff protects it.
- *Real-time load inside the gNB*: per sample and per direction one table-lookup rotation (scalar sin/cos,
  SSE multiply) plus a ring copy and a delayed read, in the UHD RX/TX threads themselves. Roughly 0.3-0.6
  of a core at 15.36 Msps both directions [estimate, not measured]. Risk: overflows/late packets at higher
  rates. Check: `grep -ac "Real-time failure"` and UHD `O`/`U`/`L` counts in the gNB stdout, and `top -H -p
  $(pgrep -x gnb)` per-thread CPU, emulator off vs orbit.
- *Overflow gaps* [code]: the ring is indexed by timestamp (`radio_uhd_rx_stream.cpp:291-294`); after a UHD
  overflow the missing indices keep data from 0.65 s earlier, which is replayed as a ghost burst. Rare;
  zero-fill the gap if it ever matters.
- *Parameter snapshot* [code]: `get_parameters()` reads six atomics without a seqlock
  (`radio_uhd_channel_emulator.cpp:68-78`); a block that races with an update can use the new delay with the
  old drift anchor, i.e. one 1 ms step off by drift x 160 ms (~7 us at LEO horizon). Very rare (ns window).

### f. Missing effects that matter for NTN studies

| Effect | Status | Why it matters | Size |
|---|---|---|---|
| Feeder link delay (ta-Common) and its drift / drift variant | not configured (no `feeder_link_info`) | TA-common path in SIB19 and the gNB is untested; transparent payload adds the feeder RTT (several ms LEO, ~240 ms GEO) | |
| Feeder-link Doppler (and its compensation at gateway/satellite, `send_cfo_compensation_request`) | not modelled | gNB-side CFO pre-compensation path untested | up to ~±50 kHz LEO |
| Differential delay / Doppler across the cell (UE ≠ reference location) | not modelled (UE at the reference point) | UE-specific TA vs gNB assumptions, PRACH window sizing | up to ms (TR 38.821 6.1) |
| UE GNSS error | not modelled | 1 km error → up to 6.7 us TA error | |
| Path loss vs elevation | not modelled (fixed 20 dB cable) | link budget over a pass (600 km: 154 dB at zenith, ~168 dB at 0°: 14 dB swing) | |
| Noise / SNR control | none | MCS/BLER studies | |
| Fading (TR 38.811 NTN-TDL-A..D, LOS/NLOS, Rician K vs elevation), shadowing | none | link adaptation, HARQ | |
| Time compression on DL, DL delay | none (a, b) | UE timing loops | |
| Satellite switch / feeder switch timing jumps | gNB side present (sat-switch), channel follows the NTN manager | | |

### g. Verdict

**Correct.**

- The UL delay/drift placement is equivalent for everything the gNB sees (TA, k_offset, PRACH/PUSCH timing,
  RAR window), and the emulator follows the same orbit the gNB broadcasts.
- Doppler law, carrier scaling (DL 2185, UL 1995), sign, phase continuity and frequency resolution are right
  (your DL measurement +16 987 Hz for +17 001 Hz [measured] and my offline 0.16 Hz error agree).
- v3 (delay steps only at slot boundaries) was a sound fix.

**Acceptable simplifications, with limits.**

- One Doppler per 160 ms: fine at horizon and MEO; at LEO zenith a 100-200 Hz sawtooth.
- Integer-sample delay with 1 ms holds: fine for every channel except sub-us timing studies.
- No DL delay: fine for the gNB; not for UE timing studies (a.1-a.3).

**Wrong or worth fixing (in order of impact).**

1. **gNB-side us rounding of the emulated delay** (two roundings, ±1 us total, a new value every 160 ms). It
   is the main term in the channel-vs-SIB19 mismatch and is drift-independent. Pass the delay as double
   (or ns) from the OCM to the radio.
2. **UE `--ntn-initial-time-drift -40` on a bench with an undelayed DL** (a.3): should be 0 (± the B200 clock
   drift). [hypothesis that it contributes to the early arrivals; one-run test in a.]
3. **Format 1 PRACH on an NTN link with any UL frequency residual** (see below).
4. Minor: saturating int16 conversion; seqlock for the parameter snapshot; zero-fill after overflow.

**Most likely root cause of the index-44 first-PRACH failure.**

What the data say:

- [measured] One capture: first preamble ~+27.5 kHz off; the ZC frequency-to-time mapping predicts 273 us,
  270 us measured. Msg3 and later are within a few hundred Hz.
- [computed from your list, (TA-31) x 0.52 us, then / 12.4 us x 1.25 kHz]: every bad first TA maps onto a
  positive UL frequency error that is a run-dependent fraction of the 46.0 kHz UL Doppler:

  | first TA | 300 | 310 | 504 | 549 | 790 | 825 | 831 | 865 | 1069 | 1072 (rfsim) |
  |---|---|---|---|---|---|---|---|---|---|---|
  | us | 140 | 145 | 246 | 270 | 395 | 414 | 417 | 434 | 541 | 542 |
  | equivalent Δf (kHz) | 14.1 | 14.6 | 24.8 | 27.2 | 39.8 | 41.7 | 42.0 | 43.8 | 54.5 (or -26 mod 800 us) | 54.7 |
  | % of UL Doppler | 31 | 32 | 54 | 59 | 87 | 91 | 91 | 95 | ? | ? |

- [measured] Same failure over rfsim without hardware; B4 alone was intact at the UE (+88 Hz).

Conclusion: **the failure is a frequency error on the first preamble, turned into a timing error by the
format-1 waveform.** It is not a timing (TA/delay) error: the timing part of the budget (d) is ~1 us, two
orders of magnitude smaller. Two things combine:

1. *Why format 1 is fragile* [code + 38.211]: the 839-length sequence with ΔfRA = 1.25 kHz maps a frequency
   offset Δf onto a cyclic shift of (Δf/1.25 kHz) x (u^-1 mod 839) samples (13 samples = 12.4 us per 1.25 kHz
   for u = 710, unrestricted set). Precisely: the integer part of Δf/1.25 kHz sets the shift; a fractional
   part splits the energy between two neighbouring shifts, so the TA is right until the error passes ~625 Hz,
   then jumps by 12.4 us per bin; tens of kHz move it by hundreds of us and the gNB happily reports the
   alias. B4 (139-length, 15 kHz SCS) needs 12x more frequency error for the same effect (7.5 kHz). This is
   why index 209 fixes the symptom even though the cause below is not removed, and why the B200's own
   +340 Hz residual already leaves format 1 with only ~300 Hz of margin.
2. *Why only the first preamble* [hypothesis, not proven]: the UE sends the first preamble with its UL
   Doppler pre-compensation missing or partial. The evidence points at the UE TX chain around the switch to
   NTN timing; I checked the mechanisms you named:
   - OAI generates the whole long preamble in its first slot (`phy_procedures_nr_ue.c:1322-1365`) and each of
     the 3 slots is then pre-compensated in place by its own `RU_write`
     (`nr-ue.c:353-369`, `nr_fo_compensation` with the phase referenced to the absolute write timestamp,
     `nr_phy_common.c:434-437`). With a constant `ul_Doppler_shift` this is coherent; when the shift is
     updated between the 3 slots (every subframe, `nr-ue.c:973-977`) the phase jumps by Δf x t_abs: at the LEO
     horizon Δf ≈ 0.13 mHz per ms so this is negligible, but it is a real flaw (it does not explain kHz).
   - At the switch (`nr-ue.c:1048-1056` -> `nr_ntn_l1.c:150-160`) the TX timeline jumps by
     k_offset - RTT ≈ 40 - 18.9 = 21 ms; the first slot written after the switch has
     `writeBlockSize` = 1 slot + 21 ms and `RU_write` fills the excess with **copies of that slot written before
     and without the Doppler pre-compensation** (`nr-ue.c:342-351` precede `:353-367`). If that slot is the
     first preamble slot, 21 uncompensated copies of it reach the gNB in the 21 ms before the real preamble,
     overlapping the previous frame's RO. This produces a fully uncompensated (≈ +46 kHz → TA ≈ 880-910)
     "preamble", but only when the first NTN TX slot coincides with the RO (≈ 1 in 10 for index 44), and it
     does not explain intermediate values (14-27 kHz). So it can explain part of the 790-865 cluster, not all.
   - `--num-ul-actors 1` already refuted the race between slots of the same preamble.
   I did **not** find in the code a path that would produce an intermediate pre-compensation of 30-60 %, so
   the honest status is: *the first preamble leaves the UE (or reaches the gNB) with a large, variable
   positive frequency error; where it is created is not yet located*. The decisive measurement is cheap:

   - **E1 (existing logs)**: in a bad run's gNB log, list all PRACH detections in the 100 ms around the first
     one (frame, slot, preamble id, `ta=`). Two detections of the same preamble id one frame apart, the
     first with TA ≈ 880-910, confirm the copy mechanism above.
   - **E2 (decisive, rfsim, no hardware)**: index 44, Doppler on, the same UE TX IQ capture used on 10 Nov for
     index 209. Measure the frequency of the first preamble **per subframe** (3 segments of 1 ms) at the UE
     TX, before the channel. Expected if the UE is at fault: at least one segment at ≈ 0 Hz instead of
     -46.0 kHz, or one intermediate value. If all three are at -46.0 kHz, the error is added after the UE
     and I will look at the gNB side next.

   The format-1-across-the-NTN-switch idea you asked me to evaluate is therefore **half right**: format 1 is
   the reason a frequency error becomes a fatal timing error (and B4 avoids it), but I found no evidence that
   the 3-slot generation itself creates the frequency error except through the 21 ms dummy fill.

---

## 2. Task 2: how to emulate the NTN channel with UHD and SDRs

### Options

**1. Emulator inside the gNB UHD driver (current `b200-doppler`).**
Hardware: 2 B200 (have). Cost: 0. Latency: none added (same process, timestamps). Fidelity: integer delay
with 1 ms holds, Doppler stepped every 160 ms, no DL delay, delay from the gNB NTN manager (consistent with
SIB19 up to the ±1 us rounding). Effort to improve: small (pass delay as double, evaluate per block, saturate).
Measures: everything on the gNB side and the OAI UE on real RF with real oscillators.
Cons: couples the channel to the device under test (gNB real-time load, a gNB bug and an emulator bug look
alike), no DL delay, UHD only, cannot be reused with a different gNB.

**2. OCUDU built-in rfsim chanmod.** Hardware: none. Lockstep, so no real-time limits. Same fidelity and
placement as 1 (delay per block instead of per ms). Measures: protocol/timing logic, reproducibility
(it reproduced the index-44 failure). Cons: no RF impairments, same model as 1 so it cannot validate 1.

**3. External software IQ bridge on the rfsim TCP protocol** (32-byte `samplesBlockHeader_t`: size, nbAnt,
timestamp, option_value, option_flag, beam_map, `lib/radio/rfsimulator/oai_shim/common_lib.h:8-15`; int16 IQ;
template `lib/radio/rfsimulator/tests/test_rfsim_protocol.cpp`). The bridge is a server to one side and a
client to the other. Delay = timestamp rewrite (a block with timestamp t is forwarded as t + d(t)); the
first d samples are zeros; output timestamps must be strictly monotonic, so a decreasing delay is applied by
resampling/dropping, not by going back in time; fractional delay via a Farrow/FIR interpolator (cheap: 16-32 taps).
Doppler per sample from a geometry engine. Pacing: in a pure rfsim topology it is lockstep (no real time); with
a B200 on one side the B200 stream is the clock and the rfsim peer must keep up.

- *3a. gNB-rfsim ↔ bridge ↔ UE-rfsim.* Hardware: none. Fidelity: the best you can get in software: DL and UL
  delayed separately (one way each), fractional continuous delay, per-sample Doppler, time compression,
  feeder link, differential delay, AWGN, TDL fading per TR 38.811, all from one geometry engine that also
  produces the SIB19 values. Effort: medium (~1-2 weeks: protocol is simple; geometry engine and the SIB19
  coupling are the work). Measures: UE timing loops, epoch reference point, all of a/b/f; the reference
  against which 1 and 2 are judged.
- *3b. gNB-rfsim ↔ bridge ↔ B200 ~ cable ~ B200 ↔ OAI UE.* Hardware: the 2 B200 you have. The gNB runs
  without a radio; the bridge owns the "gNB" B200. Real-time: the bridge must stream 15.36 Msps both ways and
  pace the gNB. Fidelity as 3a on the channel, plus real RF on the UE side. Measures: the OAI UE on hardware
  with a correct NTN channel (DL delay, continuous Doppler). Cons: the gNB's own radio path (calibration,
  lower PHY timing) is not exercised; extra latency only matters for the DL path (the gNB does not see it).
- *3c. OCUDU gNB ↔ B200 ~ cable ~ B200 ↔ bridge ↔ UE-rfsim.* Mirror of 3b: real gNB radio, software UE.
  Measures: the gNB on hardware (PRACH detection, calibration, real-time) with a correct channel.

**4. Dedicated channel-emulator host with its own SDRs between the gNB and UE radios.**
Hardware: 2 more B200 (one faces the gNB: RX 2185/TX 1995; one faces the UE: RX 1995/TX 2185) or one 2x2
X310 (2 UBX-160) / N310, **plus a shared 10 MHz/PPS for all radios**. Delay line in host RAM: GEO RTT
0.24 s x 15.36 Msps x 4 B = 15 MB per direction, trivial. Latency: each direction pays host RX + processing +
host TX; B200 over USB3 ~1-3 ms per direction [typical, to be measured], X310 over 10 GbE well under 1 ms.
The intrinsic latency is a floor on the emulated one-way delay (LEO zenith one way is 2 ms: marginal on
B200, fine on X310) and must be calibrated out. Fidelity: as 3a (continuous delay both directions, Doppler,
fading, noise) with real RF on both ends. Effort: medium-high (real-time host code; reuse the 3a engine).
Measures: both stacks unmodified on RF, any gNB/UE, closest to a commercial emulator.
B200 limits: no RFNoC (Spartan-6, not RFNoC-capable), so delay and Doppler cannot go into the FPGA; 1x1 per
B200; USB latency jitter. X310/N310 support RFNoC (FPGA delay/Doppler blocks possible later).

**5. Commercial emulators** (Keysight PROPSIM F64/FS16 with the NTN option, Kratos (you already used one for
GEO, `configs/ntn/geo_kratos_gnb.yml`)): continuous fractional delay and Doppler from orbit files, fading
(38.811), noise, both directions, validated. Cost: typically five to six figures [order of magnitude, not a
quote]. Use as the reference to validate the software emulator, not as the daily bench.

### Comparison

| | 1 in-gNB | 2 rfsim | 3a bridge sw | 3b/3c bridge + 2 B200 | 4 emulator host | 5 commercial |
|---|---|---|---|---|---|---|
| Extra hardware | none | none | none | none | 2 SDR + ref | instrument |
| Approx. cost | 0 | 0 | 0 | 0 | ~3 k$ (2 B200) to ~15 k$ (X310) + ref | ≫ |
| Delay resolution | 1 sample, 1 ms holds | 1 sample per block | fractional | fractional | fractional | fractional |
| DL delay | no | no | yes | yes | yes | yes |
| Continuous Doppler | 160 ms steps | 160 ms steps | yes | yes | yes | yes |
| Consistency with SIB19 | ±1 us (rounding) | ±1 us | exact (same engine) | exact | exact if fed the same ephemeris | needs orbit file = SIB19 orbit |
| Real RF | both ends | none | none | one end | both | both |
| Real time needed | gNB | no | no | yes | yes | n/a |
| Effort | done | done | medium | medium | medium-high | integration |
| What it lets you measure | gNB behaviour on RF | logic, regressions | UE timing loops, epoch ref, fading | UE (3b) or gNB (3c) on RF with a correct channel | both stacks on RF | reference/validation |

### Cross-cutting design decisions

- **One geometry "truth" engine.** Compute the satellite state once, broadcast it in SIB19, and derive the
  channel (delay per direction, Doppler, path loss) from the *same* propagated state on the *same* time base
  (radio sample timestamps), without intermediate rounding. Independent computations (today: gNB OCM with
  1 us rounding vs UE propagation) are what produced the 0.5-1.4 us early arrivals. In option 1 this means
  passing the OCM state (or a double delay with its exact timestamp) to the emulator; in 3/4 the bridge reads
  the gNB's epoch + ephemeris (or the gNB reads the bridge's).
- **Shared 10 MHz/PPS.** Without it every radio pair adds a ppm-level CFO and a sample-clock drift that the
  emulator does not control (your +340 Hz). With an emulator host (option 4) it becomes mandatory: two
  free-running emulator radios would add their own Doppler-like offset. B200s take 10 MHz and PPS on SMA; a
  GPSDO with a splitter or an OctoClock-G is enough.
- **What B200s cannot do:** RFNoC/FPGA channel processing, >1x1 per device (B210 is 2x2), deterministic
  sub-ms latency over USB.

### Recommendation

**(i) Now, with the 2 B200s.** Keep option 1 as the daily LEO/MEO/GEO bench, and make it trustworthy in this
order, one change per test:

1. PRACH B4 (index 209) with a measured calibration (Task 3). This removes the frequency fragility of format 1.
2. UE `--ntn-initial-time-drift 0` (a.3).
3. Emulator delay passed as double and evaluated per block at the matching radio time (removes the ±1 us).
4. Saturating int16, seqlock, gap zero-fill.

In parallel, build option **3a** (software only) as the reference: it is the only way, without new hardware,
to test the DL-side effects (a.1, a.2, b) and to get exact channel/SIB19 consistency. Once 3a exists, 3b and 3c
come almost for free with the same 2 B200s.

**(ii) If you can buy hardware.** First a shared 10 MHz/PPS (cheapest, largest gain: removes the B200 CFO and
clock drift from every result). Then option 4 with an X310 (2x UBX-160) or 2 more B200/B210 on the same
reference, running the 3a engine in real time. Use the Kratos/PROPSIM occasionally to validate the software
emulator, not as the daily bench.

**Migration plan.**

1. Finish Task 3 on option 1 (B4 + calibration), get ≥ 9/10 LEO/MEO.
2. Fix the emulator items (3, 4 above) one at a time, re-run the 10-run loop after each.
3. Write the 3a bridge (geometry engine + rfsim protocol), validate against option 2 with DL delay disabled
   (must reproduce option 2 within one sample), then enable DL delay and fading.
4. 3b/3c with the existing B200s.
5. With a reference and new radios, move the engine to an emulator host (option 4) and retire option 1.
