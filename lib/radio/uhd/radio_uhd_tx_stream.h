// SPDX-FileCopyrightText: Copyright (C) 2021-2026 Software Radio Systems Limited
// SPDX-License-Identifier: BSD-3-Clause-Open-MPI

#pragma once

#include "coarse_freq_offset.h"
#include "radio_uhd_channel_emulator.h"
#include "radio_uhd_exception_handler.h"
#include "radio_uhd_multi_usrp.h"
#include "radio_uhd_tx_stream_fsm.h"
#include "ocudu/gateways/baseband/baseband_gateway_transmitter.h"
#include "ocudu/gateways/baseband/buffer/baseband_gateway_buffer_dynamic.h"
#include "ocudu/gateways/baseband/buffer/baseband_gateway_buffer_reader.h"
#include "ocudu/radio/radio_configuration.h"
#include "ocudu/radio/radio_event_notifier.h"
#include "ocudu/support/executors/task_executor.h"
#include "ocudu/support/synchronization/stop_event.h"
#include <memory>
#include <vector>

namespace ocudu {

/// Implements a gateway transmitter based on UHD transmit stream.
class radio_uhd_tx_stream : public baseband_gateway_transmitter, public uhd_exception_handler
{
  /// Indicates the stream identification for notifications.
  unsigned stream_id;
  /// Task executor for asynchronous messages.
  task_executor& async_executor;
  /// Radio notification interface.
  radio_event_notifier& notifier;
  /// Owns the UHD Tx stream.
  uhd::tx_streamer::sptr stream;
  /// Maximum number of samples in a single packet.
  unsigned max_packet_size;
  /// Sampling rate in Hz.
  double srate_hz;
  /// Indicates the number of channels.
  unsigned nof_channels;
  /// Indicates the current internal state.
  radio_uhd_tx_stream_fsm state_fsm;
  /// Discontinuous transmission mode flag.
  bool discontinuous_tx;
  /// Number of samples to advance the burst start to protect against power ramping effects.
  unsigned power_ramping_nof_samples;
  /// Stores the time of the last transmitted sample.
  uhd::time_spec_t last_tx_timespec;
  /// Power ramping transmit buffer. It is filled with zeros, used to absorb power ramping when starting a transmission.
  baseband_gateway_buffer_dynamic power_ramping_buffer;
  /// Stop control.
  rt_stop_event_source stop_control;

  /// Receive asynchronous message.
  void recv_async_msg();

  /// Runs the asynchronous message reception through the asynchronous task executor.
  void run_recv_async_msg();

  /// \brief Transmits a single baseband block.
  /// \param[out] nof_txd_samples Number of transmitted samples.
  /// \param[in] data             Buffer to transmit.
  /// \param[in] offset           Sample offset in the transmit buffers.
  /// \param[in] md               Transmission metadata.
  /// \return True if no exception is caught in the transmission process, false otherwise.
  bool transmit_block(unsigned&                             nof_txd_samples,
                      const baseband_gateway_buffer_reader& data,
                      unsigned                              offset,
                      const uhd::tx_metadata_t&             md);

public:
  /// Describes the necessary parameters to create an UHD transmit stream.
  struct stream_description {
    /// Identifies the stream.
    unsigned id;
    /// Over-the-wire format.
    radio_configuration::over_the_wire_format otw_format;
    /// Sampling rate in Hz.
    double srate_hz;
    /// Stream arguments.
    std::string args;
    /// Indicates the port indexes for the stream.
    std::vector<size_t> ports;
    /// Enables discontinuous transmission mode.
    bool discontiuous_tx;
    /// Time by which to advance the burst start, using zero padding to protect against power ramping.
    float power_ramping_us;
  };

  /// \brief Constructs an UHD transmit stream.
  /// \param[in] usrp Provides the USRP context.
  /// \param[in] description Provides the stream configuration parameters.
  /// \param[in] async_executor_ Provides the asynchronous task executor.
  /// \param[in] notifier_ Provides the radio event notification handler.
  radio_uhd_tx_stream(uhd::usrp::multi_usrp::sptr& usrp,
                      const stream_description&    description,
                      task_executor&               async_executor_,
                      radio_event_notifier&        notifier_);

  /// Gets the optimal transmitter buffer size.
  unsigned get_buffer_size() const { return max_packet_size; }

  // See interface for documentation.
  void transmit(const baseband_gateway_buffer_reader&        data,
                const baseband_gateway_transmitter_metadata& metadata) override;

  /// \brief Connects the software channel emulator (see radio_uhd_channel_emulator.h).
  /// Must be called before the stream starts (not from the real-time thread).
  void set_channel_emulator(radio_uhd_channel_emulator& emu);

  /// Start the transmission.
  void start();

  /// Stop the transmission.
  void stop();

private:
  /// Transmits the samples to UHD (the original transmit path).
  void transmit_to_uhd(const baseband_gateway_buffer_reader&        data,
                       const baseband_gateway_transmitter_metadata& metadata);

  /// \name Software channel emulation (see radio_uhd_channel_emulator.h).
  ///@{
  radio_uhd_channel_emulator*                      emulator = nullptr;
  std::unique_ptr<baseband_gateway_buffer_dynamic> emu_scratch;
  /// Per-channel downlink frequency shifters (OAI emulator's Coarse_Freq_Offset).
  std::vector<Coarse_Freq_Offset> tx_shifters;
  /// Once used, the shifter keeps running (also at 0 Hz) so its phase stays continuous.
  bool tx_shifter_used = false;
  ///@}
};

} // namespace ocudu
