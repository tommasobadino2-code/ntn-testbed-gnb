// SPDX-FileCopyrightText: Copyright (C) 2021-2026 Software Radio Systems Limited
// SPDX-License-Identifier: BSD-3-Clause-Open-MPI

#include "radio_uhd_rx_stream.h"
#include "ocudu/ocuduvec/zero.h"
#include <algorithm>
#include <cmath>

using namespace ocudu;

/// Receive timeout in seconds.
static constexpr double RECEIVE_TIMEOUT_S = 0.2f;
/// Set to true for receiving data in a single packet.
static constexpr bool ONE_PACKET = false;

bool radio_uhd_rx_stream::receive_block(unsigned&                       nof_rxd_samples,
                                        baseband_gateway_buffer_writer& data,
                                        unsigned                        offset,
                                        uhd::rx_metadata_t&             md)
{
  // Extract number of samples.
  unsigned num_samples = data.get_nof_samples() - offset;

  // Make sure the number of channels is equal.
  ocudu_assert(data.get_nof_channels() == nof_channels, "Number of channels does not match.");

  // Flatten buffers.
  static_vector<void*, RADIO_MAX_NOF_CHANNELS> buffs_flat_ptr;
  for (unsigned channel = 0; channel != nof_channels; ++channel) {
    buffs_flat_ptr.emplace_back(reinterpret_cast<void*>(data[channel].subspan(offset, num_samples).data()));
  }

  uhd::rx_streamer::buffs_type buffs_cpp(buffs_flat_ptr.data(), nof_channels);

  return safe_execution([this, buffs_cpp, num_samples, &md, &nof_rxd_samples]() {
    nof_rxd_samples = stream->recv(buffs_cpp, num_samples, md, RECEIVE_TIMEOUT_S, ONE_PACKET);
  });
}

radio_uhd_rx_stream::radio_uhd_rx_stream(uhd::usrp::multi_usrp::sptr& usrp,
                                         const stream_description&    description,
                                         radio_event_notifier&        notifier_) :
  id(description.id), srate_Hz(description.srate_Hz), notifier(notifier_)
{
  ocudu_assert(std::isnormal(srate_Hz) && (srate_Hz > 0.0), "Invalid sampling rate {}.", srate_Hz);

  // Build stream arguments.
  uhd::stream_args_t stream_args = {};
  stream_args.cpu_format         = "sc16";
  switch (description.otw_format) {
    case radio_configuration::over_the_wire_format::DEFAULT:
    case radio_configuration::over_the_wire_format::SC16:
      stream_args.otw_format = "sc16";
      break;
    case radio_configuration::over_the_wire_format::SC12:
      stream_args.otw_format = "sc12";
      break;
    case radio_configuration::over_the_wire_format::SC8:
      stream_args.otw_format = "sc8";
      break;
  }
  stream_args.args     = description.args;
  stream_args.channels = description.ports;

  if (!safe_execution([this, usrp, &stream_args]() {
        stream          = usrp->get_rx_stream(stream_args);
        max_packet_size = stream->get_max_num_samps();
        nof_channels    = stream->get_num_channels();
      })) {
    return;
  }

  is_init_successful = true;
}

bool radio_uhd_rx_stream::start(const uhd::time_spec_t& time_spec)
{
  if (!is_init_successful) {
    return false;
  }

  stop_control.reset();

  if (!safe_execution([this, &time_spec]() {
        uhd::stream_cmd_t stream_cmd(uhd::stream_cmd_t::STREAM_MODE_START_CONTINUOUS);
        stream_cmd.time_spec  = time_spec;
        stream_cmd.stream_now = (time_spec.get_real_secs() == uhd::time_spec_t());

        stream->issue_stream_cmd(stream_cmd);
      })) {
    fmt::println("Error: failed to start receive stream {}. {}.", id, get_error_message().c_str());
  }

  return true;
}

baseband_gateway_receiver::metadata radio_uhd_rx_stream::receive(baseband_gateway_buffer_writer& buffs)
{
  baseband_gateway_receiver::metadata ret = {};
  uhd::rx_metadata_t                  md;

  auto token = stop_control.get_token();
  if (OCUDU_UNLIKELY(token.is_stop_requested())) {
    for (unsigned i = 0, e = buffs.get_nof_channels(); i != e; ++i) {
      ocuduvec::zero(buffs[i]);
    }
    ret.ts = md.time_spec.to_ticks(srate_Hz);
    return ret;
  }

  unsigned nsamples            = buffs[0].size();
  unsigned rxd_samples_total   = 0;
  unsigned timeout_trial_count = 0;

  // Receive stream in multiple blocks.
  while (rxd_samples_total < nsamples) {
    unsigned rxd_samples = 0;
    if (!receive_block(rxd_samples, buffs, rxd_samples_total, md)) {
      fmt::println("Error: failed receiving packet. {}.", get_error_message().c_str());
      return {};
    }

    // Save timespec for first block only if the last timestamp is unknown.
    if (rxd_samples_total == 0) {
      ret.ts = md.time_spec.to_ticks(srate_Hz);
    }

    // Increase the total amount of received samples.
    rxd_samples_total += rxd_samples;

    // Prepare notification event.
    radio_event_notifier::event_description event = {.stream_id  = id,
                                                     .channel_id = std::nullopt,
                                                     .source     = radio_event_source::RECEIVE,
                                                     .type       = radio_event_type::UNDEFINED,
                                                     .timestamp  = std::nullopt};

    // Handle error.
    switch (md.error_code) {
      case uhd::rx_metadata_t::ERROR_CODE_TIMEOUT:
        ++timeout_trial_count;
        if (timeout_trial_count >= 10) {
          fmt::println("Error: exceeded maximum number of timed out receive calls.");
          return ret;
        }
        break;
      case uhd::rx_metadata_t::ERROR_CODE_NONE:
        // Ignored.
        break;
      case uhd::rx_metadata_t::ERROR_CODE_LATE_COMMAND:
        event.type = radio_event_type::LATE;
        break;
      case uhd::rx_metadata_t::ERROR_CODE_OVERFLOW:
        event.type = radio_event_type::OVERFLOW;
        break;
      case uhd::rx_metadata_t::ERROR_CODE_BROKEN_CHAIN:
      case uhd::rx_metadata_t::ERROR_CODE_ALIGNMENT:
      case uhd::rx_metadata_t::ERROR_CODE_BAD_PACKET:
        event.type = radio_event_type::OTHER;
        break;
    }

    // Notify if the event type was set.
    if (event.type != radio_event_type::UNDEFINED) {
      notifier.on_radio_rt_event(event);
    }
  }

  // Software channel emulation (no-op unless enabled with OCUDU_UHD_CHANNEL_EMU).
  apply_channel_emulation(buffs, ret.ts);

  // If it reaches here, there is no error.
  return ret;
}

void radio_uhd_rx_stream::set_channel_emulator(radio_uhd_channel_emulator& emu)
{
  emulator = &emu;
  if (!is_init_successful || emu.get_mode() == radio_uhd_channel_emulator::mode::off) {
    return;
  }

  delay_capacity = static_cast<uint64_t>(std::ceil(radio_uhd_channel_emulator::max_delay_s * srate_Hz));
  delay_ring.assign(nof_channels, std::vector<ci16_t>(delay_capacity, ci16_t{0, 0}));
  rx_shifters.clear();
  for (unsigned ch = 0; ch != nof_channels; ++ch) {
    rx_shifters.emplace_back(0.0, srate_Hz);
  }
  fmt::println("UHD channel emulator: rx stream {} delay line {:.0f} ms ({} samples x {} channels).",
               id,
               radio_uhd_channel_emulator::max_delay_s * 1e3,
               delay_capacity,
               nof_channels);
}

void radio_uhd_rx_stream::apply_channel_emulation(baseband_gateway_buffer_writer& buffs, uint64_t ts)
{
  if (emulator == nullptr || delay_capacity == 0 || !emulator->is_active()) {
    return;
  }

  const uint64_t cap = delay_capacity;
  const unsigned n   = buffs[0].size();
  if (n == 0 || n >= cap) {
    return;
  }

  const radio_uhd_channel_emulator::parameters p = emulator->get_parameters();

  // Re-anchor the delay drift on every parameter update (same scheme as the rfsim NTN channel).
  if (p.update_seq != seen_update_seq) {
    seen_update_seq = p.update_seq;
    drift_base_ts   = ts;
  }
  if (!have_data) {
    first_ts  = ts;
    have_data = true;
  }

  // Delay for this block in samples: base delay plus drift since the last update.
  const double elapsed_s = (ts > drift_base_ts) ? static_cast<double>(ts - drift_base_ts) / srate_Hz : 0.0;
  const double delay_us  = p.delay_us + p.drift_us_per_s * elapsed_s;
  int64_t      delay_sps = std::llround(std::max(delay_us, 0.0) * 1e-6 * srate_Hz);
  delay_sps              = std::min<int64_t>(delay_sps, static_cast<int64_t>(cap - n - 1));

  // Uplink frequency shift: once used, keep the shifter running so its phase never jumps.
  rx_shifter_used  = rx_shifter_used || (p.rx_doppler_Hz != 0.0);
  const bool shift = rx_shifter_used;

  for (unsigned ch = 0; ch != nof_channels; ++ch) {
    span<ci16_t>         buf  = buffs[ch];
    std::vector<ci16_t>& ring = delay_ring[ch];

    // 1. Uplink Doppler (as in the OAI emulator: shift first, then delay).
    if (shift) {
      rx_shifters[ch].set_freq(static_cast<float>(2.0 * M_PI * p.rx_doppler_Hz / srate_Hz), static_cast<float>(n) - 1.0f);
      rx_shifters[ch].freq_shift(buf.data(), static_cast<int>(n));
    }

    // 2. Store the samples at their own timestamps.
    uint64_t pos   = ts % cap;
    unsigned first = static_cast<unsigned>(std::min<uint64_t>(n, cap - pos));
    std::copy(buf.begin(), buf.begin() + first, ring.begin() + pos);
    std::copy(buf.begin() + first, buf.end(), ring.begin());

    // 3. Output what arrived delay_sps samples earlier; silence below the horizon or before any data existed.
    if (!p.link_up) {
      std::fill(buf.begin(), buf.end(), ci16_t{0, 0});
      continue;
    }
    for (unsigned i = 0; i != n; ++i) {
      const int64_t src = static_cast<int64_t>(ts + i) - delay_sps;
      buf[i] = (src < static_cast<int64_t>(first_ts)) ? ci16_t{0, 0} : ring[static_cast<uint64_t>(src) % cap];
    }
  }
}

bool radio_uhd_rx_stream::stop()
{
  stop_control.stop();

  // Try to stop the stream.
  if (!safe_execution([this]() {
        uhd::stream_cmd_t stream_cmd(uhd::stream_cmd_t::STREAM_MODE_STOP_CONTINUOUS);
        stream_cmd.time_spec  = uhd::time_spec_t();
        stream_cmd.stream_now = true;

        stream->issue_stream_cmd(stream_cmd);
      })) {
    fmt::println("Error: failed to stop stream {}. {}.", id, get_error_message().c_str());
    return false;
  }

  return true;
}
