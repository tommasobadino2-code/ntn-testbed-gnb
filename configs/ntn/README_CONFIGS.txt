 OCUDU-RAN NTN TESTBED - CONFIGURATION FILES (configs/ntn/) AND SCRIPTS
 Branch: ntn-testbed, on top of TOSSI-Foundation/OCUDU-RAN commit 9722c5efe7

This branch runs TOSSI's rfsimulator-based NTN testbed (OCUDU gNB + OAI nrUE) against
a free5GC core instead of SD-Core / OAI CN5G, and adds MEO (8000 km) scenarios.
All gNB configs use band n256 (DL 2185 MHz, UL 1995 MHz), dl_arfcn 437000,
10 MHz channel, 15 kHz SCS, 15.36 Msps, the OCUDU rfsimulator radio.


 1. HOW THE FILES ARE COMBINED
The gNB takes several -c files; later files override earlier ones:

    gnb -c <base config> [-c <scenario overlay>] [-c configs/ntn/sdcore.yml]

  base config       complete gNB config for one orbit: radio, cell, NTN parameters,
                    satellite ephemeris (geo_/leo_/meo_rfsim_gnb.yml)
  scenario overlay  small file adding one feature: satellite switch, satellite
                    train, or the second-satellite settings for a handover
  sdcore.yml        core-network addresses (free5GC); must come LAST when the
                    base config still carries TOSSI's default addresses


 2. CORE-NETWORK ADDRESSES (free5GC)
  AMF                     10.100.200.16
  gNB (satellite 1)       10.100.200.1     N2 bind and N3 (GTP-U) bind
  gNB (satellite 2)       10.100.200.120   second gNB in handover scenarios

Files that carry these addresses DIRECTLY (work on their own):
  geo_rfsim_gnb.yml, leo_ho_sat1.yml, leo_ho_sat2.yml, meo_ho_sat1.yml,
  meo_ho_sat2.yml, sdcore.yml

Files that still carry TOSSI's defaults (AMF 192.168.70.132, gNB 192.168.70.129,
i.e. OAI CN5G) and therefore NEED "-c configs/ntn/sdcore.yml" last:
  leo_rfsim_gnb.yml, meo_rfsim_gnb.yml

Note: scripts/run_leo_rfsim.sh and scripts/run_leo_satswitch_rfsim.sh do not add
sdcore.yml; with free5GC the gNB then tries to bind 192.168.70.129 and exits.
Run those scenarios by hand (section 5) or add sdcore.yml to the script.
The name "sdcore.yml" is historical: the overlay was written for SD-Core and now
points at free5GC.


 3. THE CONFIGURATION FILES

geo_rfsim_gnb.yml  (base, GEO, 158 lines)
  Geostationary satellite. rfsimulator as server on port 4043 with a FIXED
  propagation delay: device_args "prop_delay=119.36926" (35,786 km / c), no
  orbit-driven channel model. cell_specific_koffset 240 ms,
  ntn_ul_sync_validity_dur 240 s. free5GC addresses included.
  Log /tmp/gnb_geo.log, pcaps /tmp/ntn_geo_{mac,ngap}.pcap.

leo_rfsim_gnb.yml  (base, LEO, 162 lines)
  LEO satellite, circular polar orbit 600 km above the UE (orbit radius
  6,956,752 m). rfsimulator as server on port 4043 with
  "options=chanmod,realtime": the NTN channel model computes delay and drift from
  the ephemeris and paces samples to the wall clock. cell_specific_koffset 40 ms,
  ntn_ul_sync_validity_dur 30 s, emulate_doppler false, use_state_vector true
  (ECEF position/velocity ephemeris). TOSSI default addresses -> add sdcore.yml.
  Log /tmp/gnb_leo.log, pcaps /tmp/ntn_leo_{mac,ngap}.pcap.

leo_ho_sat1.yml  (handover, LEO, satellite 1 / source gNB, 98 lines)
  Complete second-level config for the source gNB of the Xn handover:
  gnb_id 411, ran_node_name gnb-sat1, cell PCI 1, neighbour cell PCI 2 (band 256).
  rfsimulator as CLIENT ("serveraddr=127.0.0.1,serverport=4043,options=chanmod,
  realtime"): in handover runs the UE is the rfsim server and both gNBs connect
  to it. koffset 40 ms, validity 30 s, emulate_doppler false. free5GC addresses
  (bind 10.100.200.1). Log /tmp/gnb_leo_sat1.log, NGAP and XnAP pcaps.

leo_ho_sat2.yml  (handover, LEO, satellite 2 / target gNB, 90 lines)
  gnb_id 412, ran_node_name gnb-sat2, PCI 2, neighbour PCI 1, rfsim client.
  free5GC addresses with bind 10.100.200.120 (this address must exist on the
  host's br-free5gc bridge). NTN timing values come from the base config.
  Log /tmp/gnb_leo_sat2.log, NGAP and XnAP pcaps.

leo_satswitch.yml  (overlay, LEO, intra-cell satellite switch, 27 lines)
  Adds 3GPP Rel-18 satSwitchWithReSync to the base cell: t_service and
  sat_switch_with_resync { epoch_timestamp, ECEF ephemeris of the target
  satellite, t_service_start, use_state_vector true, promote_to_serving true,
  promote_neighbors false }. ntn_ul_sync_validity_dur 5 s (cell and target).
  Same cell, same UE context: no handover, no random access at the switch.
  Log /tmp/gnb_leo_satswitch.log.

leo_sattrain.yml  (overlay, LEO, satellite train, 10 lines)
  sat_train { num_satellites 12, switch_elevation_deg 4.5, min_lead_s 10 }:
  the gNB generates 12 satellites evenly spaced on the base orbit and switches
  to the next one each time the serving satellite sinks to 4.5 deg (about every
  481 s), announcing each switch at least 10 s ahead. Validity 5 s.
  Log /tmp/gnb_leo_sattrain.log.

meo_rfsim_gnb.yml  (base, MEO, 162 lines)              [added on this branch]
  Same structure as leo_rfsim_gnb.yml for an 8000 km orbit (orbit radius
  14,356,752 m, period 4.76 h, pass 101 min, round trip 53.4-85.9 ms).
  cell_specific_koffset 100 ms, validity 30 s, emulate_doppler false.
  TOSSI default addresses -> add sdcore.yml. Log /tmp/gnb_meo.log.

meo_ho_sat1.yml / meo_ho_sat2.yml  (handover, MEO)     [added on this branch]
  Copies of the LEO handover configs (gnb_id 411/412, PCI 1/2, rfsim clients,
  free5GC addresses) with koffset 100 ms in sat1. They keep the LEO log names
  /tmp/gnb_leo_sat1.log and /tmp/gnb_leo_sat2.log because
  scripts/run_leo_ho_rfsim.sh hardcodes them.

meo_satswitch.yml  (overlay, MEO, satellite switch)    [added on this branch]
  Same keys as leo_satswitch.yml. Created by "set_meo_pass.sh --init" as a COPY
  of the LEO file: it contains a LEO target satellite until
  "set_meo_pass.sh --switch --at S" has been run. Log /tmp/gnb_meo_satswitch.log.

meo_sattrain.yml  (overlay, MEO, satellite train)      [added on this branch]
  num_satellites 36 (spacing about 476 s on the MEO orbit), switch at 4.5 deg,
  min lead 10 s, validity 5 s. Log /tmp/gnb_meo_sattrain.log.

sdcore.yml  (overlay, core addresses, 21 lines)        [modified on this branch]
  cu_cp AMF 10.100.200.16, bind 10.100.200.1; cu_up N3 bind 10.100.200.1;
  plus the cell's PLMN/slice settings. Always the last -c.


 4. VALUES REWRITTEN AT EVERY RUN (do not treat them as settings)

The satellite geometry is defined by an epoch (UTC) plus an ECEF state vector.
The pass scripts recompute and write them shortly before each run:

  epoch_timestamp           base configs, *_ho_sat*.yml, *_satswitch.yml
  ephemeris_info_ecef       pos_x/y/z (m), vel_x/y/z (m/s) of each satellite
  t_service, t_service_start  *_satswitch.yml (switch time = epoch + S)

The values committed here are TOSSI's originals or a past run; they are
overwritten by set_leo_pass.sh / set_meo_pass.sh. The run scripts also re-stamp
the epoch unless KEEP_EPOCH=1. The current epoch is also written to
/tmp/leo_epoch or /tmp/meo_epoch.

Geometry model (both scripts): circular polar orbit, UE at the north pole on the
WGS84 polar radius, every pass straight overhead, propagated by the gNB's
Keplerian propagator from epoch_timestamp. The same ephemeris is broadcast in
SIB19 and drives the rfsim channel model, so the UE's timing calculation and the
emulated delay always agree.


 5. WHICH FILES EACH SCENARIO USES
(run from the OCUDU-RAN directory; gnb = ./build_ntn/apps/gnb/gnb)

GEO
  scripts/run_geo_rfsim_local.sh  (or run_geo_rfsim.sh)
  -> geo_rfsim_gnb.yml alone

LEO 1  single pass
  ./scripts/set_leo_pass.sh --elev horizon --single --lead 20
  gnb -c configs/ntn/leo_rfsim_gnb.yml -c configs/ntn/sdcore.yml

LEO 2  Xn handover + NGAP Path Switch
  ./scripts/set_leo_pass.sh --elev 30 --ho --no-epoch
  ./scripts/run_leo_ho_rfsim.sh
  -> leo_rfsim_gnb.yml + leo_ho_sat1.yml (gNB 1), + leo_ho_sat2.yml (gNB 2)

LEO 3  satellite switch, one-shot
  ./scripts/set_leo_pass.sh --elev 30 --single --no-epoch, set epoch and t_service
  gnb -c leo_rfsim_gnb.yml -c leo_satswitch.yml -c sdcore.yml

LEO 4  satellite train
  ./scripts/set_leo_pass.sh --elev zenith --single --lead 20
  gnb -c leo_rfsim_gnb.yml -c leo_sattrain.yml -c sdcore.yml

MEO 1  single pass
  ./scripts/set_meo_pass.sh --single --elev horizon --lead 30
  gnb -c meo_rfsim_gnb.yml -c sdcore.yml

MEO 2  Xn handover (target at 34 deg and rising at T+420 s)
  ./scripts/set_meo_pass.sh --ho --at 420 --no-epoch
  BASE=$PWD/configs/ntn/meo_rfsim_gnb.yml CFG1=$PWD/configs/ntn/meo_ho_sat1.yml \
  CFG2=$PWD/configs/ntn/meo_ho_sat2.yml TIME_DRIFT=13.6 HO_AT=420 DUR=1200 \
  ./scripts/run_leo_ho_rfsim.sh

MEO 3  satellite switch at the 30 deg crossover
  ./scripts/set_meo_pass.sh --switch --at 420
  gnb -c meo_rfsim_gnb.yml -c meo_satswitch.yml -c sdcore.yml

MEO 4  satellite train
  ./scripts/set_meo_pass.sh --single --elev 20 --setting   (first switch ~T+661 s)
  gnb -c meo_rfsim_gnb.yml -c meo_sattrain.yml -c sdcore.yml

UE side (OAI-RAN, not in this repository): nr-uesoftmodem with
  ue.ntn.leo.rfsim.conf, --band 256 -C 2185000000 --CO -190000000 -r 52
  --numerology 0 --ssb 62 --rfsim --rfsimulator.[0].serveraddr 127.0.0.1,
  --ntn-initial-time-drift as printed by the pass script (LEO -40; MEO e.g. -15.6
  rising / +12..15 setting), and the LEO subscriber (IMSI 001010100000001,
  SST 1, SD 0x010203, DNN internet).


 6. SCRIPTS
TOSSI (upstream):
  set_leo_pass.sh            writes LEO geometry (epoch, ephemeris) into
                             leo_rfsim_gnb.yml and leo_ho_sat1/2.yml
  run_leo_rfsim.sh           single-cell LEO run (gNB + UE + ping)
  run_leo_ho_rfsim.sh        handover run: UE as rfsim server, gNB 1, gNB 2 at
                             SAT2_AT, HO at HO_AT; configurable via BASE, CFG1,
                             CFG2, TIME_DRIFT, HO_AT, SAT2_AT, DUR
  run_leo_satswitch_rfsim.sh satellite-switch run (BASE, CFG, SWITCH_AT, DUR,
                             GNB_LOG); does not add sdcore.yml
  run_geo_rfsim.sh           GEO run
  leo_tracker.py             live web dashboard (port 8500) from gNB/UE logs

Added on this branch:
  set_meo_pass.sh            MEO counterpart of set_leo_pass.sh (default 8000 km,
                             --alt); --init creates the meo_*.yml files from the
                             LEO configs; --single, --switch --at S [--cross E],
                             --ho --at S [--elev1 --elev2], --show; prints the UE
                             drift and a run timeline
  make_meo_tracker.py        generates meo_tracker.py from leo_tracker.py for
                             another altitude (--alt), leaving the upstream file
                             untouched
  meo_tracker.py             generated MEO dashboard (its docstring still reads
                             "LEO" because it is derived from leo_tracker.py)
  run_geo_rfsim_local.sh     local variant of run_geo_rfsim.sh used with the
                             free5GC setup (PING_TARGET)
