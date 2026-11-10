# B200 port of the PRACH fix (format B4, index 209): checks, configs, commands

Branch `ntn-emu-review`. Context: `docs/ntn_channel_emulation_review.md` (point g). Configs and scripts only:
**no rebuild of the gNB or the UE is needed.**

## 1. Checks [code]

| Question | Answer |
|---|---|
| Does `time_alignment_calibration` reach the UHD path like rfsim? | Yes. It is an `ru_sdr` option (`apps/units/flexible_o_du/split_8/helpers/ru_sdr_config_cli11_schema.cpp:81`), copied to the lower PHY config (`ru_sdr_config_translator.cpp:41-47`) and applied as a TX time offset `N_TA,offset - cal` in the shared lower PHY (`lib/phy/lower/lower_phy_factory.cpp:41-47`), for any radio driver. Negative = gNB transmits later. On our bench the UE times its UL from the gNB DL, so every arrival (PRACH, PUSCH, PUCCH) moves later by `-cal / 15.36` us; the emulator's UL delay line is unaffected (it works on RX timestamps). |
| What do the current B200 configs set in `ru_sdr`? | Nothing: no `time_alignment_calibration` in any `configs/ntn/*.yml`, so 0 (translator default). |
| Is 209 valid in OCUDU for this cell? | Yes. FDD FR1 accepts 0-108, 147-167, 198-256 (`lib/ran/prach/prach_helper.cpp:19`). Entry 209 of Table 6.3.3.2-2 (`lib/ran/prach/prach_configuration.cpp:221`) = B4, x = 1, y = 0, **subframe 1**, start symbol 0, 12 symbols: the same RO timing as index 44 (subframe 1 of every frame), so runs are comparable. Root index 1 is valid for L139 (max 137, `prach_helper.cpp:171`). Defaults: zero-correlation zone 0, 64 preambles, one root per preamble. |
| And in the OAI UE? | Yes. `openair2/LAYER2/NR_MAC_COMMON/nr_mac_common.c:626` (entry 209) = `{0xb4, -1, 1, 0, 2 (subframe 1), 0, 2, 1, 12}`, identical. Your 10 Nov rfsim runs with this UE commit transmitted 209 intact [measured]. |
| Which tools assume format 1? | `prach_freq.py` (839 x 1.25 kHz, ~1.05 MHz width, 12.4 us per 1.25 kHz): added `--short` for B4. `run_ntn_uhd_local.sh` `TA_CHECK/TA_TOL` (restart when the first TA is > 10 steps from 31): built for the format-1 symptom; it would also hide failures from the statistics, so the loop forces `TA_CHECK=0`. Keep it 0 for interactive B4 runs too. With a calibration the expected first TA moves to `31 + (-cal/15.36)/0.52`. `ntn-metrics.sh` PRACH section: format-independent (reads `ta=` and `detection_metric`), unchanged. TA steps are 0.52 us for any preamble. |

Note on `-A 216`: it was measured on format 1 so that the first TA is ~31, i.e. arrivals at ~0 us. That
is exactly where B4 failed over rfsim (peaks 0.48-1.44 us *before* zero, not searched by the detector).
So on the B200s Test A may well fail the same way; the dump in step 3 measures it.

## 2. New files

| File | Change vs its parent |
|---|---|
| `configs/ntn/leo_uhd_dop_b4_gnb.yml` | Test A: `leo_uhd_dop_cfo_mcs_gnb.yml` with `prach_config_index: 209` only |
| `configs/ntn/leo_uhd_dop_b4_cal_gnb.yml` | Test B: Test A + `ru_sdr: time_alignment_calibration` (placeholder 0, set in step 4) |
| `configs/ntn/leo_uhd_dop_b4_dump_gnb.yml` | Test A + PRACH receive dump (`log: phy_rx_symbols_filename`, `phy_rx_symbols_prach: true`) |
| `configs/ntn/meo_uhd_dop_b4_gnb.yml`, `meo_uhd_dop_b4_cal_gnb.yml` | the LEO A/B configs with the MEO geometry, `cell_specific_koffset: 100` and `/tmp/gnb_meo_dop.log` of `meo_uhd_dop_gnb.yml` (so the MEO runs also get `max_ue_mcs 24` and PUSCH CFO compensation, like the LEO baseline) |
| `scripts/prach_loop.sh` | HOST: N runs, core restart + AMF wait before each, logs per run, one line per run |
| `scripts/prach_run_summary.sh` | the per-run line (also usable alone on any run's logs) |
| `scripts/prach_dump_delay.py` | signed arrival offset of every preamble in a PRACH dump (`--selftest` included) |
| `scripts/prach_freq.py` | `--short` for B4 captures |

Geometry: the new configs copy the horizon geometry of their parents. Do not run `set_meo_pass.sh` for them
(it also rewrites `meo_satswitch.yml`); `--show` is read-only if you want to check.

## 3. Commands

The loop runs on the **host** from a checkout of this branch, and starts the run script inside the
container from the container's copy of the repository (same branch). Run the [HOST] loop commands from the
host checkout's top directory. Set the two paths once per terminal:

[HOST] (replace both paths: the repository as seen inside the container, and the directory with `core-up.sh`)

```bash
export REPO=/path/to/ntn-testbed-gnb/in/container CORE_DIR=/path/to/free5gc-compose
```

If `core-up.sh` does not restart a running core by itself, add `CORE_DOWN="sudo ./core-down.sh"` (or your
stop command) to each loop command. If your run needs other variables (e.g. `OAI=...`), add
`RUN_ENV="OAI=/path"`.

What each run line means:

```
run 3: first TA 33 (+1.0 us) | Epoch SFN 40 | first RO 41.1 | first det 41.1 ta=1.04us | preambles until RAR 1 | attached yes | pings 20/20 | PASS
```

`first TA` = UE "received TA command" (31 = no correction); `Epoch SFN` = last SIB19 epoch before the first
preamble; `first RO` = frame.slot of the UE's first preamble (UE log); `first det` = first gNB detection
and its `ta=`; `preambles until RAR` = preambles sent before the first RAR (1 = first preamble detected).
PASS = 1 preamble, attached, all pings. The last line is the tally. Logs: `~/prach_runs/<config>_<date>/runN/`.

### Step 1: Test A, LEO horizon, index 209 only (10 runs)

[HOST]

```bash
CFG=configs/ntn/leo_uhd_dop_b4_gnb.yml ORBIT=leo TIME_DRIFT=-40 UE_EXTRA_ARGS="--cont-fo-comp 3 --initial-fo 50411" N=10 ./scripts/prach_loop.sh
```

Expected: a few minutes per run (core restart + attach + 20 pings). Success: >= 9/10 PASS. Read the failures: `preambles
until RAR` > 1 with no `first det` at the first RO = preambles arriving early (as in rfsim); `first det`
present but `first TA` far from 31 = something else, send me the run directory.

### Step 2: decide

If step 1 passes >= 9/10, the calibration is not needed: still do step 3 once (it tells us the margin),
then go to step 5 with the `_b4_` (Test A) configs. Otherwise steps 3 and 4.

### Step 3: one run with the PRACH receive dump (measures the B200 arrival offset)

The dump also writes every UL slot's resource grid (~70 MB/s; ~3-5 GB for this run). Check the space first.

[CONTAINER]

```bash
df -h /tmp
```

Expected: at least 10 GB available. Then:

[HOST]

```bash
CFG=configs/ntn/leo_uhd_dop_b4_dump_gnb.yml ORBIT=leo TIME_DRIFT=-40 UE_EXTRA_ARGS="--cont-fo-comp 3 --initial-fo 50411" N=1 PING_COUNT=1 ./scripts/prach_loop.sh
```

Then analyse in the container (the dump stays there; the gNB log copy is in the run directory on the host,
but `/tmp/gnb_leo_dop.log` in the container is the same file until the next run):

[CONTAINER] (from the repository directory)

```bash
python3 scripts/prach_dump_delay.py /tmp/gnb_leo_dop.log /tmp/gnb_prach_dump.bin
```

Expected: one line per PRACH window with energy: `sfn.slot`, power, root, **signed `delay_us`**, peak,
`cfo_Hz`, and the gNB's detection for that window. Check first that for detected preambles `delay_us` equals
the gNB `ta=` within ~0.1 us (validates the script on real data). Then read the summary line
`delay min ... median ... max`. Negative values = early preambles the gNB could not see. `cfo_Hz` = residual
UL frequency per preamble (expect a few hundred Hz on the B200s). If numpy is missing in the container,
run `python3 scripts/prach_dump_delay.py --selftest` on the host and copy both files out instead.

Delete the dump afterwards:

[CONTAINER]

```bash
rm -f /tmp/gnb_prach_dump.bin
```

### Step 4: Test B, set the calibration from the measurement (10 runs)

Rule: move the earliest measured arrival to about +2 us (margin for the ±1 us gNB delay rounding and the
B200 jitter; B4's search window is ~24 us, so this costs nothing):
`cal = -ceil((2.0 - delay_min_us) x 15.36)`. Examples: min -1.4 us -> -53; min -0.5 us -> -39;
min +0.6 us -> -22. Do not copy rfsim's -46: it contains no B200 offsets.

[CONTAINER] (from the repository directory; replace -53 with your value)

```bash
sed -i 's/^  time_alignment_calibration: .*/  time_alignment_calibration: -53/' configs/ntn/leo_uhd_dop_b4_cal_gnb.yml configs/ntn/meo_uhd_dop_b4_cal_gnb.yml
```

[HOST]

```bash
CFG=configs/ntn/leo_uhd_dop_b4_cal_gnb.yml ORBIT=leo TIME_DRIFT=-40 UE_EXTRA_ARGS="--cont-fo-comp 3 --initial-fo 50411" N=10 ./scripts/prach_loop.sh
```

Expected: >= 9/10 PASS, `first TA` ≈ 31 + 2/0.52 ≈ 35 (constant offset, the side effect seen on rfsim;
the TA loop absorbs it for PUSCH/PUCCH).

### Step 5: MEO horizon (10 runs, with the variant that passed on LEO: `_b4_` or `_b4_cal_`)

[HOST]

```bash
CFG=configs/ntn/meo_uhd_dop_b4_cal_gnb.yml ORBIT=meo TIME_DRIFT=-15.6 UE_EXTRA_ARGS="--cont-fo-comp 3 --initial-fo 17004" N=10 ./scripts/prach_loop.sh
```

Expected: >= 9/10 PASS.

### Step 6: one long LEO pass (with the LEO variant that passed)

[HOST]

```bash
CFG=configs/ntn/leo_uhd_dop_b4_cal_gnb.yml ORBIT=leo TIME_DRIFT=-40 UE_EXTRA_ARGS="--cont-fo-comp 3 --initial-fo 50411" N=1 PING_COUNT=800 RUN_MAX=1400 ./scripts/prach_loop.sh
```

How to read it: the pass is visible for ~769 s after the epoch [computed], the epoch is stamped 12 s after the
start and the attach takes some tens of seconds, so 800 pings at 1/s end after the satellite sets: losses
in the last ~60-100 pings are the link going down below the horizon (emulated LOS), not a failure. Count the
losses before that: `grep -c "icmp_seq" ~/prach_runs/<dir>/run1/run.out` gives the answered pings. Then the
usual summary for PUSCH/PUCCH:

[HOST] (replace the directory)

```bash
./scripts/ntn-metrics.sh ~/prach_runs/<dir>/run1/gnb.log ~/prach_runs/<dir>/run1/ue.log
```

## 4. What to send me

For each loop: the `summary.txt` (all lines). For step 3: the full output of `prach_dump_delay.py`. For any
odd run: its run directory (`gnb.log`, `ue.log`, `run.out`, `gnb_stdout.log`).

## 5. Next, one change at a time (not part of this test)

1. UE `--ntn-initial-time-drift 0` instead of -40 (review a.3), with the passing B4 config.
2. Index-44 root cause, E1/E2 of the review (only to understand the UE; B4 does not need it).
3. Emulator: delay passed as double and evaluated per block (review g.1).
