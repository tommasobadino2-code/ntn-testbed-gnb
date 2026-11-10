// SPDX-FileCopyrightText: Copyright (C) 2021-2026 Software Radio Systems Limited
// SPDX-License-Identifier: BSD-3-Clause-Open-MPI

#pragma once

#include "coarse_freq_offset.h"
#include "radio_uhd_channel_emulator.h"
#include "radio_uhd_exception_handler.h"
#include "radio_uhd_multi_usrp.h"
#include "ocudu/gateways/baseband/baseband_gateway_receiver.h"
#include "ocudu/gateways/baseband/buffer/baseband_gateway_buffer_writer.h"
#include "ocudu/radio/radio_configuration.h"
#include "ocudu/radio/radio_event_notifier.h"
#include "ocudu/support/synchronization/stop_event.h"
#include <atomic>
#include <memory>
#include <string>
#include <vector>

namespace ocudu {

/// Implements a gateway receiver based on UHD receive stream.
class radio_uhd_rx_stream : public uhd_exception_handler, public baseband_gateway_receiver
{
  /// Indicates if the initialization of the stream was successful.
  bool is_init_successful = false;
  /// Indicates the stream identification for notifications.
  unsigned id;
  /// Sampling rate in hertz.
  double srate_Hz;
  /// Radio notification interface.
  radio_event_notifier& notifier;
  /// Owns the UHD Tx stream.
  uhd::rx_streamer::sptr stream;
  /// Maximum number of samples in a single packet.
  unsigned max_packet_size;
  /// Indicates the number of channels.
  unsigned nof_channels;
  /// Stop control.
  rt_stop_event_source stop_control;

  /// \brief Receives a single block of baseband samples.
  /// \param[out] nof_rxd_samples Indicate the number of samples received in the block.
  /// \param[in,out] buffs Provides the reception buffers.
  /// \param[in] buffer_offset Indicates the data offset in the reception buffers.
  /// \param[in] metadata Provides the reception metadata.
  /// \return True if no exception is caught. Otherwise false.
  /// \name Software channel emulation (see radio_uhd_channel_emulator.h).
  ///@{
  radio_uhd_channel_emulator*      emulator = nullptr;
  /// Per-channel delay line, indexed by absolute receive timestamp modulo its capacity.
  std::vector<std::vector<ci16_t>> delay_ring;
  uint64_t                         delay_capacity = 0;
  /// Per-channel uplink frequency shifters (OAI emulator's Coarse_Freq_Offset).
  std::vector<Coarse_Freq_Offset> rx_shifters;
  /// Once used, the shifter keeps running (also at 0 Hz) so its phase stays continuous.
  bool                            rx_shifter_used = false;
  /// Receive-thread state.
  uint64_t seen_update_seq = 0;
  uint64_t drift_base_ts   = 0;
  uint64_t first_ts        = 0;
  bool     have_data       = false;
  /// Delay steps: the integer delay only changes every delay_step_len samples (aligned to the absolute timestamp).
  uint64_t delay_step_len     = 1;
  uint64_t delay_step_offset  = 0;
  uint64_t current_step       = 0;
  int64_t  current_step_delay = 0;
  bool     have_step_delay    = false;

  /// Applies the emulated channel in place to a received buffer whose first sample has timestamp \c ts.
  void apply_channel_emulation(baseband_gateway_buffer_writer& buffs, uint64_t ts);

  /// \brief Optional debug capture of the uplink exactly as the PHY receives it (after Doppler and delay).
  ///
  /// Enabled with OCUDU_UHD_CHANNEL_EMU_CAPTURE=<file>. Starts OCUDU_UHD_CHANNEL_EMU_CAPTURE_DELAY_S (default 0) after
  /// the link first comes up, records OCUDU_UHD_CHANNEL_EMU_CAPTURE_S seconds (default 8) of channel 0 into memory,
  /// then a background thread writes them as interleaved int16 I/Q. The state is shared with that thread so it stays
  /// valid even if the stream is destroyed first.
  struct capture_state {
    std::vector<ci16_t> buf;
    std::string         path;
    std::atomic<bool>   full{false};
    std::atomic<bool>   abandon{false};
  };
  std::shared_ptr<capture_state> capture;
  uint64_t                       capture_pos       = 0;
  uint64_t                       capture_delay_sps = 0;
  uint64_t                       capture_link_ts   = 0;
  bool                           capture_link_seen = false;
  bool                           capture_running   = false;
  void                           capture_samples(span<const ci16_t> buf, uint64_t ts);
  ///@}

  bool receive_block(unsigned&                       nof_rxd_samples,
                     baseband_gateway_buffer_writer& buffs,
                     unsigned                        buffer_offset,
                     uhd::rx_metadata_t&             metadata);

public:
  /// Describes the necessary parameters to create an UHD transmit stream.
  struct stream_description {
    /// Identifies the stream.
    unsigned id;
    /// Sampling rate in hertz.
    double srate_Hz;
    /// Over-the-wire format.
    radio_configuration::over_the_wire_format otw_format;
    /// Stream arguments.
    std::string args;
    /// Indicates the port indexes for the stream.
    std::vector<size_t> ports;
  };

  /// \brief Constructs a receive UHD stream.
  /// \param[in] usrp Provides the USRP context.
  /// \param[in] description Provides the stream configuration parameters.
  /// \param[in] notifier_ Provides the radio event notification handler.
  radio_uhd_rx_stream(uhd::usrp::multi_usrp::sptr& usrp,
                      const stream_description&    description,
                      radio_event_notifier&        notifier_);

  /// \brief Starts the stream reception.
  /// \param[in] time_spec Indicates the start time of the stream.
  /// \return True if no exception is caught. Otherwise false.
  bool start(const uhd::time_spec_t& time_spec);

  /// \brief Stops the reception stream.
  /// \return True if no exception is caught. Otherwise false.
  bool stop();

  /// Gets the optimal transmitter buffer size.
  unsigned get_buffer_size() const { return max_packet_size; }

  /// \brief Connects the software channel emulator. Allocates the delay line unless the emulator is off.
  /// Must be called before the stream starts (not from the real-time thread).
  void set_channel_emulator(radio_uhd_channel_emulator& emu);

  // See interface for documentation.
  metadata receive(baseband_gateway_buffer_writer& data) override;
};

} // namespace ocudu
