// SPDX-License-Identifier: BSD-3-Clause-Open-MPI
//
// Software NTN channel emulator for the UHD radio (B2xx cable/loopback testbeds).
//
// The emulator delays and frequency-shifts the baseband samples right after UHD delivers them (uplink, gNB receive)
// and frequency-shifts them right before UHD sends them (downlink, gNB transmit), keeping all timestamps unchanged.
// The whole round-trip delay is applied on the gNB receive side, as the TOSSI rfsimulator NTN channel does.
//
// Mode, selected at gNB start with the environment variable OCUDU_UHD_CHANNEL_EMU:
//   off   (default) - nothing is applied; the radio behaves exactly as the unmodified UHD driver. Use this with a
//                     hardware channel emulator (e.g. Kratos).
//   orbit           - values come from the gNB's own NTN manager (same orbit as broadcast in SIB19), ~every 160 ms.
//   udp             - values come from UDP messages "f: <DL Hz>, <UL Hz>, <delay samples>, <txg>, <rxg>" on port
//                     OCUDU_UHD_CHANNEL_EMU_PORT (default 41515), e.g. sent by channel_model.py. Gains are ignored.

#pragma once

#include <atomic>
#include <cstdint>
#include <thread>

namespace ocudu {

class radio_uhd_channel_emulator
{
public:
  enum class mode { off, orbit, udp };

  /// Snapshot of the channel parameters, read by the streams once per block.
  struct parameters {
    double   delay_us       = 0.0; ///< Delay applied to the received signal (round-trip sized), microseconds.
    double   drift_us_per_s = 0.0; ///< Delay drift applied between updates, microseconds per second.
    double   rx_doppler_Hz  = 0.0; ///< Frequency shift applied to the received (uplink) signal.
    double   tx_doppler_Hz  = 0.0; ///< Frequency shift applied to the transmitted (downlink) signal.
    bool     link_up        = true; ///< False when the satellite is below the horizon: both directions are silenced.
    uint64_t update_seq     = 0;   ///< Incremented on every update; used to re-anchor the delay drift.
  };

  /// Maximum emulated delay in seconds (covers a GEO round trip including a feeder link).
  static constexpr double max_delay_s = 0.65;

  /// Reads the mode from the environment and, in UDP mode, starts the listener thread.
  radio_uhd_channel_emulator(double srate_Hz, double tx_center_freq_Hz, double rx_center_freq_Hz);
  ~radio_uhd_channel_emulator();

  mode get_mode() const { return emu_mode; }

  /// True once the emulator has values to apply (always false in mode off).
  bool is_active() const { return active.load(std::memory_order_acquire); }

  /// Current parameters.
  parameters get_parameters() const;

  /// Input from the gNB NTN manager. Returns false (values ignored) unless the mode is orbit.
  bool set_from_orbit(double delay_us,
                      double delay_drift_us_per_s,
                      double service_drift_us_per_s,
                      bool   emulate_doppler,
                      bool   link_up);

private:
  void store(double delay_us, double drift_us_per_s, double rx_doppler_Hz, double tx_doppler_Hz, bool link_up);
  void udp_listener();

  mode   emu_mode = mode::off;
  double srate_Hz;
  double tx_freq_Hz;
  double rx_freq_Hz;
  int    udp_port = 41515;

  std::atomic<bool>     active{false};
  std::atomic<double>   delay_us{0.0};
  std::atomic<double>   drift_us_per_s{0.0};
  std::atomic<double>   rx_doppler_Hz{0.0};
  std::atomic<double>   tx_doppler_Hz{0.0};
  std::atomic<bool>     link_up{true};
  std::atomic<uint64_t> update_seq{0};

  std::atomic<bool> stop_listener{false};
  std::thread       listener;
};

} // namespace ocudu
