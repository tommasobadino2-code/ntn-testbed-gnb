// SPDX-License-Identifier: BSD-3-Clause-Open-MPI

#include "radio_uhd_channel_emulator.h"
#include <algorithm>
#include <arpa/inet.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fmt/format.h>
#include <netinet/in.h>
#include <string>
#include <sys/socket.h>
#include <unistd.h>

using namespace ocudu;

radio_uhd_channel_emulator::radio_uhd_channel_emulator(double srate_Hz_,
                                                       double tx_center_freq_Hz,
                                                       double rx_center_freq_Hz) :
  srate_Hz(srate_Hz_), tx_freq_Hz(tx_center_freq_Hz), rx_freq_Hz(rx_center_freq_Hz)
{
  const char* env_mode = std::getenv("OCUDU_UHD_CHANNEL_EMU");
  std::string mode_str = (env_mode != nullptr) ? std::string(env_mode) : std::string("off");

  if (mode_str == "orbit") {
    emu_mode = mode::orbit;
  } else if (mode_str == "udp") {
    emu_mode = mode::udp;
  } else {
    if (mode_str != "off") {
      fmt::println("Warning: unknown OCUDU_UHD_CHANNEL_EMU='{}'; use off, orbit or udp. Emulator off.", mode_str);
    }
    emu_mode = mode::off;
  }

  if (const char* env_port = std::getenv("OCUDU_UHD_CHANNEL_EMU_PORT")) {
    udp_port = std::atoi(env_port);
  }

  switch (emu_mode) {
    case mode::off:
      fmt::println("UHD channel emulator: off (signals pass unchanged; use this with a hardware channel emulator).");
      break;
    case mode::orbit:
      fmt::println("UHD channel emulator: orbit (delay/Doppler from the gNB NTN manager), DL {:.3f} MHz, UL {:.3f} MHz.",
                   tx_freq_Hz * 1e-6,
                   rx_freq_Hz * 1e-6);
      break;
    case mode::udp:
      fmt::println("UHD channel emulator: udp (listening on port {}, delay in samples at {:.2f} Msps).",
                   udp_port,
                   srate_Hz * 1e-6);
      // Active from the start with a transparent channel until the first message arrives.
      store(0.0, 0.0, 0.0, 0.0, true);
      listener = std::thread([this]() { udp_listener(); });
      break;
  }
}

radio_uhd_channel_emulator::~radio_uhd_channel_emulator()
{
  stop_listener.store(true, std::memory_order_relaxed);
  if (listener.joinable()) {
    listener.join();
  }
}

radio_uhd_channel_emulator::parameters radio_uhd_channel_emulator::get_parameters() const
{
  parameters p;
  p.update_seq     = update_seq.load(std::memory_order_acquire);
  p.delay_us       = delay_us.load(std::memory_order_relaxed);
  p.drift_us_per_s = drift_us_per_s.load(std::memory_order_relaxed);
  p.rx_doppler_Hz  = rx_doppler_Hz.load(std::memory_order_relaxed);
  p.tx_doppler_Hz  = tx_doppler_Hz.load(std::memory_order_relaxed);
  p.link_up        = link_up.load(std::memory_order_relaxed);
  return p;
}

void radio_uhd_channel_emulator::store(double delay_us_,
                                       double drift_us_per_s_,
                                       double rx_doppler_Hz_,
                                       double tx_doppler_Hz_,
                                       bool   link_up_)
{
  static constexpr double max_delay_us = max_delay_s * 1e6 * 0.95;
  if (delay_us_ > max_delay_us) {
    fmt::println("Warning: emulated delay {:.0f} us exceeds the delay line; clamped to {:.0f} us.", delay_us_, max_delay_us);
    delay_us_ = max_delay_us;
  }

  delay_us.store(std::max(delay_us_, 0.0), std::memory_order_relaxed);
  drift_us_per_s.store(drift_us_per_s_, std::memory_order_relaxed);
  rx_doppler_Hz.store(rx_doppler_Hz_, std::memory_order_relaxed);
  tx_doppler_Hz.store(tx_doppler_Hz_, std::memory_order_relaxed);
  link_up.store(link_up_, std::memory_order_relaxed);
  update_seq.fetch_add(1, std::memory_order_release);
  active.store(true, std::memory_order_release);
}

bool radio_uhd_channel_emulator::set_from_orbit(double delay_us_,
                                                double delay_drift_us_per_s,
                                                double service_drift_us_per_s,
                                                bool   emulate_doppler,
                                                bool   link_up_)
{
  if (emu_mode != mode::orbit) {
    return false;
  }

  // Same Doppler model as the TOSSI rfsimulator: one-way rate = -1/2 * service-link delay drift, per carrier.
  double rx_shift = 0.0;
  double tx_shift = 0.0;
  if (emulate_doppler) {
    const double one_way_rate = -(0.5 * service_drift_us_per_s * 1e-6);
    rx_shift                  = one_way_rate * rx_freq_Hz;
    tx_shift                  = one_way_rate * tx_freq_Hz;
  }

  store(delay_us_, delay_drift_us_per_s, rx_shift, tx_shift, link_up_);
  return true;
}

void radio_uhd_channel_emulator::udp_listener()
{
  int sock = ::socket(AF_INET, SOCK_DGRAM, 0);
  if (sock < 0) {
    fmt::println("Error: UHD channel emulator could not create its UDP socket.");
    return;
  }

  int reuse = 1;
  ::setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));

  // Wake up regularly so the thread can stop when the gNB exits.
  timeval timeout = {};
  timeout.tv_sec  = 0;
  timeout.tv_usec = 200000;
  ::setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));

  sockaddr_in addr     = {};
  addr.sin_family      = AF_INET;
  addr.sin_addr.s_addr = INADDR_ANY;
  addr.sin_port        = htons(static_cast<uint16_t>(udp_port));
  if (::bind(sock, reinterpret_cast<const sockaddr*>(&addr), sizeof(addr)) < 0) {
    fmt::println("Error: UHD channel emulator could not bind UDP port {} (already in use?).", udp_port);
    ::close(sock);
    return;
  }

  char buffer[256];
  while (!stop_listener.load(std::memory_order_relaxed)) {
    ssize_t len = ::recv(sock, buffer, sizeof(buffer) - 1, 0);
    if (len <= 0) {
      continue;
    }
    buffer[len] = '\0';

    // Same message format as the OAI emulator: "f: <DL Hz>, <UL Hz>, <delay>, <txg>, <rxg>".
    float dl_Hz = 0, ul_Hz = 0;
    int   delay_samples = 0, txg = 0, rxg = 0;
    if (std::sscanf(buffer, "f: %f, %f, %d, %d, %d", &dl_Hz, &ul_Hz, &delay_samples, &txg, &rxg) < 3) {
      fmt::println("Warning: UHD channel emulator ignored a malformed UDP message.");
      continue;
    }

    const double delay_us_new = std::max(delay_samples, 0) / srate_Hz * 1e6;
    store(delay_us_new, 0.0, ul_Hz, dl_Hz, true);
    fmt::println("UHD channel emulator update: DL shift {:.1f} Hz, UL shift {:.1f} Hz, delay {} samples ({:.3f} ms){}.",
                 dl_Hz,
                 ul_Hz,
                 delay_samples,
                 delay_us_new * 1e-3,
                 (txg != 0 || rxg != 0) ? ", gain fields ignored" : "");
  }

  ::close(sock);
}
