library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.metering_pkg.all;
use work.pq_event_pkg.all;

library xpm;
use xpm.vcomponents.all;

-- Structural integration for the complete ADC-to-meter-record datapath.
-- Vendor/platform integration remains outside this entity in TopDesign.bd.
-- Record formats and engine contracts are normative in C++
-- (SourceData/HLS_DesignFile/common/include and each engine's header).
entity meter_core is
  generic (
    -- Dev/test infrastructure switch: the raw ADC simulator (waveform
    -- engine, harmonic slots, register bank). true (default) elaborates
    -- it exactly as before; false removes it from the netlist entirely
    -- (K24 production target) and a minimal AXI-lite stub answers its
    -- register window with zeros so the RPU probe fails cleanly (the
    -- AdcController isolates simulator-init failure by design).
    G_SIMULATOR_ENABLE : boolean := true
  );
  port (
    aclk    : in std_logic;
    aresetn : in std_logic;

    s_axi_capture_awaddr  : in  std_logic_vector(7 downto 0);
    s_axi_capture_awvalid : in  std_logic;
    s_axi_capture_awready : out std_logic;
    s_axi_capture_wdata   : in  std_logic_vector(31 downto 0);
    s_axi_capture_wstrb   : in  std_logic_vector(3 downto 0);
    s_axi_capture_wvalid  : in  std_logic;
    s_axi_capture_wready  : out std_logic;
    s_axi_capture_bresp   : out std_logic_vector(1 downto 0);
    s_axi_capture_bvalid  : out std_logic;
    s_axi_capture_bready  : in  std_logic;
    s_axi_capture_araddr  : in  std_logic_vector(7 downto 0);
    s_axi_capture_arvalid : in  std_logic;
    s_axi_capture_arready : out std_logic;
    s_axi_capture_rdata   : out std_logic_vector(31 downto 0);
    s_axi_capture_rresp   : out std_logic_vector(1 downto 0);
    s_axi_capture_rvalid  : out std_logic;
    s_axi_capture_rready  : in  std_logic;

    s_axi_conversion_awaddr  : in  std_logic_vector(7 downto 0);
    s_axi_conversion_awvalid : in  std_logic;
    s_axi_conversion_awready : out std_logic;
    s_axi_conversion_wdata   : in  std_logic_vector(31 downto 0);
    s_axi_conversion_wstrb   : in  std_logic_vector(3 downto 0);
    s_axi_conversion_wvalid  : in  std_logic;
    s_axi_conversion_wready  : out std_logic;
    s_axi_conversion_bresp   : out std_logic_vector(1 downto 0);
    s_axi_conversion_bvalid  : out std_logic;
    s_axi_conversion_bready  : in  std_logic;
    s_axi_conversion_araddr  : in  std_logic_vector(7 downto 0);
    s_axi_conversion_arvalid : in  std_logic;
    s_axi_conversion_arready : out std_logic;
    s_axi_conversion_rdata   : out std_logic_vector(31 downto 0);
    s_axi_conversion_rresp   : out std_logic_vector(1 downto 0);
    s_axi_conversion_rvalid  : out std_logic;
    s_axi_conversion_rready  : in  std_logic;

    s_axi_processing_awaddr  : in  std_logic_vector(7 downto 0);
    s_axi_processing_awvalid : in  std_logic;
    s_axi_processing_awready : out std_logic;
    s_axi_processing_wdata   : in  std_logic_vector(31 downto 0);
    s_axi_processing_wstrb   : in  std_logic_vector(3 downto 0);
    s_axi_processing_wvalid  : in  std_logic;
    s_axi_processing_wready  : out std_logic;
    s_axi_processing_bresp   : out std_logic_vector(1 downto 0);
    s_axi_processing_bvalid  : out std_logic;
    s_axi_processing_bready  : in  std_logic;
    s_axi_processing_araddr  : in  std_logic_vector(7 downto 0);
    s_axi_processing_arvalid : in  std_logic;
    s_axi_processing_arready : out std_logic;
    s_axi_processing_rdata   : out std_logic_vector(31 downto 0);
    s_axi_processing_rresp   : out std_logic_vector(1 downto 0);
    s_axi_processing_rvalid  : out std_logic;
    s_axi_processing_rready  : in  std_logic;

    s_axi_waveform_awaddr  : in  std_logic_vector(7 downto 0);
    s_axi_waveform_awvalid : in  std_logic;
    s_axi_waveform_awready : out std_logic;
    s_axi_waveform_wdata   : in  std_logic_vector(31 downto 0);
    s_axi_waveform_wstrb   : in  std_logic_vector(3 downto 0);
    s_axi_waveform_wvalid  : in  std_logic;
    s_axi_waveform_wready  : out std_logic;
    s_axi_waveform_bresp   : out std_logic_vector(1 downto 0);
    s_axi_waveform_bvalid  : out std_logic;
    s_axi_waveform_bready  : in  std_logic;
    s_axi_waveform_araddr  : in  std_logic_vector(7 downto 0);
    s_axi_waveform_arvalid : in  std_logic;
    s_axi_waveform_arready : out std_logic;
    s_axi_waveform_rdata   : out std_logic_vector(31 downto 0);
    s_axi_waveform_rresp   : out std_logic_vector(1 downto 0);
    s_axi_waveform_rvalid  : out std_logic;
    s_axi_waveform_rready  : in  std_logic;

    s_axi_simulator_awaddr  : in  std_logic_vector(11 downto 0);
    s_axi_simulator_awvalid : in  std_logic;
    s_axi_simulator_awready : out std_logic;
    s_axi_simulator_wdata   : in  std_logic_vector(31 downto 0);
    s_axi_simulator_wstrb   : in  std_logic_vector(3 downto 0);
    s_axi_simulator_wvalid  : in  std_logic;
    s_axi_simulator_wready  : out std_logic;
    s_axi_simulator_bresp   : out std_logic_vector(1 downto 0);
    s_axi_simulator_bvalid  : out std_logic;
    s_axi_simulator_bready  : in  std_logic;
    s_axi_simulator_araddr  : in  std_logic_vector(11 downto 0);
    s_axi_simulator_arvalid : in  std_logic;
    s_axi_simulator_arready : out std_logic;
    s_axi_simulator_rdata   : out std_logic_vector(31 downto 0);
    s_axi_simulator_rresp   : out std_logic_vector(1 downto 0);
    s_axi_simulator_rvalid  : out std_logic;
    s_axi_simulator_rready  : in  std_logic;

    -- PQEVT-v1 record stream: the sliding Urms(1/2) / event tier's own
    -- producer port (metrology M12).
    m_axis_pq_tdata  : out std_logic_vector(31 downto 0);
    m_axis_pq_tkeep  : out std_logic_vector(3 downto 0);
    m_axis_pq_tvalid : out std_logic;
    m_axis_pq_tready : in  std_logic;
    m_axis_pq_tlast  : out std_logic;

    -- Dedicated HARMONIC-v1 record stream. The internal packet FIFO holds a
    -- complete 42-record family; connect this master to its own meter-switch
    -- input and retain TLAST-based arbitration in the block design.
    m_axis_harmonic_tdata  : out std_logic_vector(31 downto 0);
    m_axis_harmonic_tkeep  : out std_logic_vector(3 downto 0);
    m_axis_harmonic_tvalid : out std_logic;
    m_axis_harmonic_tready : in  std_logic;
    m_axis_harmonic_tlast  : out std_logic;

    -- Single-cycle diagnostic record stream (SCYC-v1, one per grid cycle
    -- while cycle timing is locked; metrology roadmap M2).
    m_axis_scyc_tdata  : out std_logic_vector(31 downto 0);
    m_axis_scyc_tkeep  : out std_logic_vector(3 downto 0);
    m_axis_scyc_tvalid : out std_logic;
    m_axis_scyc_tready : in  std_logic;
    m_axis_scyc_tlast  : out std_logic;

    -- Shadow sufficient-statistics stream for the R5C1 aggregation
    -- migration.  This stream is deliberately observational: its exporter
    -- never owns SingleCycle TREADY and therefore cannot stall metrology.
    m_axis_r5_agg_input_tdata  : out std_logic_vector(31 downto 0);
    m_axis_r5_agg_input_tkeep  : out std_logic_vector(3 downto 0);
    m_axis_r5_agg_input_tvalid : out std_logic;
    m_axis_r5_agg_input_tready : in  std_logic;
    m_axis_r5_agg_input_tlast  : out std_logic;

    m_axis_waveform_tdata  : out std_logic_vector(31 downto 0);
    m_axis_waveform_tkeep  : out std_logic_vector(3 downto 0);
    m_axis_waveform_tvalid : out std_logic;
    m_axis_waveform_tready : in  std_logic;
    m_axis_waveform_tlast  : out std_logic;

    -- The only M16 block-design dependency: one AMD/Xilinx XFFT v9.1.
    -- MeterCore owns conditioning, window storage, HLS classification,
    -- record buffering, and record-stream arbitration around this boundary.
    m_axis_fft_data_tdata  : out std_logic_vector(47 downto 0);
    m_axis_fft_data_tvalid : out std_logic;
    m_axis_fft_data_tready : in  std_logic;
    m_axis_fft_data_tlast  : out std_logic;

    s_axis_fft_data_tdata  : in  std_logic_vector(47 downto 0);
    s_axis_fft_data_tuser  : in  std_logic_vector(23 downto 0);
    s_axis_fft_data_tvalid : in  std_logic;
    s_axis_fft_data_tready : out std_logic;
    s_axis_fft_data_tlast  : in  std_logic;

    m_axis_fft_config_tdata  : out std_logic_vector(7 downto 0);
    m_axis_fft_config_tvalid : out std_logic;
    m_axis_fft_config_tready : in  std_logic;
    s_axis_fft_status_tdata  : in  std_logic_vector(7 downto 0);
    s_axis_fft_status_tvalid : in  std_logic;
    s_axis_fft_status_tready : out std_logic;

    xfft_event_frame_started        : in std_logic;
    xfft_event_tlast_unexpected     : in std_logic;
    xfft_event_tlast_missing        : in std_logic;
    xfft_event_status_channel_halt  : in std_logic;
    xfft_event_data_in_channel_halt : in std_logic;
    xfft_event_data_out_channel_halt: in std_logic;

    adc_dclk       : in  std_logic;
    adc_drdy_n     : in  std_logic;
    adc_dout       : in  std_logic_vector(3 downto 0);
    adc_reset_n    : out std_logic;
    adc_start_n    : out std_logic;
    adc_convst_sar : out std_logic
  );
end entity;

architecture structural of meter_core is
  type axis32_stream_t is record
    data  : std_logic_vector(31 downto 0);
    keep  : std_logic_vector(3 downto 0);
    valid : std_logic;
    ready : std_logic;
    last  : std_logic;
  end record;

  type converted_stream_t is record
    data  : std_logic_vector(METER_CONVERTED_FRAME_BITS - 1 downto 0);
    keep  : std_logic_vector(METER_CONVERTED_KEEP_BITS - 1 downto 0);
    user  : std_logic_vector(383 downto 0);
    valid : std_logic;
    ready : std_logic;
    last  : std_logic;
  end record;

  signal physical_raw_stream : axis32_stream_t;
  signal simulator_raw_stream: axis32_stream_t;
  signal raw_stream          : axis32_stream_t;
  signal converted_source : converted_stream_t;
  signal converted_fifo   : converted_stream_t;
  signal engine_valid     : std_logic;
  signal engine_ready     : std_logic;
  signal conversion_active_scale : std_logic_vector(255 downto 0);

  signal capture_frame_count : std_logic_vector(31 downto 0);
  signal capture_overflows   : std_logic_vector(31 downto 0);
  signal capture_headers     : std_logic_vector(31 downto 0);
  signal capture_alerts      : std_logic_vector(31 downto 0);
  signal capture_frame_rate  : std_logic_vector(31 downto 0);
  signal capture_frame_rate_valid : std_logic;
  signal physical_frame_count : std_logic_vector(31 downto 0);
  signal physical_overflows   : std_logic_vector(31 downto 0);
  signal physical_headers     : std_logic_vector(31 downto 0);
  signal physical_alerts      : std_logic_vector(31 downto 0);
  signal physical_frame_rate  : std_logic_vector(31 downto 0);
  signal physical_frame_rate_valid : std_logic;
  signal simulator_selected   : std_logic;
  signal simulator_frame_count: std_logic_vector(31 downto 0);
  signal simulator_frame_rate : std_logic_vector(31 downto 0);
  signal simulator_frame_rate_valid : std_logic;
  signal simulator_saturations: std_logic_vector(31 downto 0);

  signal shadow_generation     : std_logic_vector(31 downto 0);
  signal shadow_sample_rate    : std_logic_vector(31 downto 0);
  signal shadow_window_samples : std_logic_vector(31 downto 0);
  signal shadow_valid_mask     : std_logic_vector(7 downto 0);
  signal shadow_enable         : std_logic;
  signal shadow_dc_remove      : std_logic;
  signal apply_toggle          : std_logic;
  signal frequency_shadow_control         : std_logic_vector(31 downto 0);
  signal frequency_shadow_window          : std_logic_vector(31 downto 0);
  signal frequency_shadow_minimum         : std_logic_vector(31 downto 0);
  signal frequency_shadow_maximum         : std_logic_vector(31 downto 0);
  signal frequency_shadow_hysteresis      : std_logic_vector(31 downto 0);
  signal frequency_active_control         : std_logic_vector(31 downto 0);
  signal frequency_active_window          : std_logic_vector(31 downto 0);
  signal frequency_active_minimum         : std_logic_vector(31 downto 0);
  signal frequency_active_maximum         : std_logic_vector(31 downto 0);
  signal frequency_active_hysteresis      : std_logic_vector(31 downto 0);
  signal frequency_status                 : std_logic_vector(31 downto 0);
  signal frequency_millihz                : std_logic_vector(31 downto 0);
  signal frequency_period_q16             : std_logic_vector(31 downto 0);
  signal frequency_sequence               : std_logic_vector(31 downto 0);
  signal frequency_rejected               : std_logic_vector(31 downto 0);

  signal active_generation : std_logic_vector(31 downto 0);
  signal active_enable     : std_logic;
  signal apply_seen        : std_logic;
  signal processing_status : std_logic_vector(31 downto 0);

  -- The PL SingleCycle engine builds its own SCYC diagnostic record and an
  -- ordered 221-word sufficient-statistics packet. The private exporter adds
  -- context and CRC32C for R5C1, which owns every interval record. Returned
  -- MTR1/MTR2 records bypass this module through the block-design AXIS switch;
  -- MeterCore no longer exposes duplicate legacy record outputs or taps.
  signal scyc_shim_drop_count : std_logic_vector(31 downto 0);
  signal grid_cycle_locked    : std_logic;
  signal grid_cycle_fallback  : std_logic;
  signal scyc_result_tready   : std_logic;
  signal grid_cycle_boundary  : std_logic;
  signal grid_cycle_sequence  : std_logic_vector(31 downto 0);
  -- Internal single-cycle result transport: 221 ordered 32-bit words.
  -- Keeping this boundary narrow avoids a 7,488-bit routed datapath after
  -- the aggregation shim appends its context.
  signal scyc_result_tdata  : std_logic_vector(31 downto 0);
  signal scyc_result_tvalid : std_logic;
  signal r5_export_input_ready : std_logic;
  signal r5_agg_accepted_packets  : std_logic_vector(31 downto 0);
  signal r5_agg_dropped_packets   : std_logic_vector(31 downto 0);
  signal r5_agg_transmitted_packets : std_logic_vector(31 downto 0);
  signal r5_agg_framing_errors    : std_logic_vector(31 downto 0);
  signal r5_agg_last_sequence     : std_logic_vector(31 downto 0);
  signal r5_agg_queue_level       : std_logic_vector(7 downto 0);
  signal r5_agg_status            : std_logic_vector(31 downto 0);

  -- Sliding Urms(1/2) / PQ event producer (M12). Its shim observes the
  -- same accepted-frame fan-out the single-cycle shim does.
  signal pq_axis_tdata      : std_logic_vector(31 downto 0);
  signal pq_axis_tkeep      : std_logic_vector(3 downto 0);
  signal pq_axis_tvalid     : std_logic;
  signal pq_axis_tlast      : std_logic;
  signal pq_shim_drop_count : std_logic_vector(31 downto 0);
  signal grid_half_boundary : std_logic;
  signal pq_shadow_reference : std_logic_vector(31 downto 0);
  signal pq_shadow_threshold : std_logic_vector(31 downto 0);
  signal pq_shadow_limits    : std_logic_vector(31 downto 0);
  signal pq_tap_kind         : std_logic_vector(31 downto 0);
  signal pq_tap_event_seq    : std_logic_vector(31 downto 0);
  signal pq_status           : std_logic_vector(31 downto 0);
  signal pq_event_active     : std_logic;

  signal waveform_enable      : std_logic;
  signal waveform_clear_stats : std_logic;
  signal waveform_tick        : std_logic_vector(63 downto 0);
  signal waveform_sequence    : std_logic_vector(63 downto 0);
  signal waveform_drop_count  : std_logic_vector(31 downto 0);
  signal waveform_block_count : std_logic_vector(31 downto 0);
  signal waveform_status      : std_logic_vector(31 downto 0);
  signal ten_minute_target_sample : std_logic_vector(63 downto 0);
  signal ten_minute_target_valid  : std_logic;
  signal ten_minute_target_update : std_logic;
  signal conversion_frame_accept : std_logic;
  signal waveform_sample_index   : std_logic_vector(63 downto 0);

  -- Grid-cycle timing: configuration, the shared detector's combinational
  -- crossing view, and the closed-block provenance handed to the hub.
  signal grid_shadow_config       : std_logic_vector(31 downto 0);
  signal grid_active_config       : std_logic_vector(31 downto 0);
  signal grid_status              : std_logic_vector(31 downto 0);
  signal grid_frame_closes_block  : std_logic;
  signal grid_cycle_mode          : std_logic;
  signal rising_crossing_now      : std_logic;
  signal falling_crossing_now     : std_logic;
  signal reference_valid_now      : std_logic;
  signal block_first_sample       : std_logic_vector(63 downto 0);
  signal block_cycle_count        : std_logic_vector(7 downto 0);
  signal block_nominal_hz         : std_logic_vector(7 downto 0);
  signal block_flags              : std_logic_vector(2 downto 0);

  signal harmonic_context_tdata  : std_logic_vector(575 downto 0);
  signal harmonic_context_tvalid : std_logic;
  signal harmonic_context_tready : std_logic;
  signal harmonic_frame_tdata    : std_logic_vector(167 downto 0);
  signal harmonic_frame_tvalid   : std_logic;
  signal harmonic_frame_tready   : std_logic;
  signal harmonic_frame_tlast    : std_logic;
  signal harmonic_frame_fault    : std_logic;
  signal harmonic_conditioned_blocks : std_logic_vector(31 downto 0);
  signal harmonic_invalid_blocks     : std_logic_vector(31 downto 0);
  signal harmonic_service_overruns   : std_logic_vector(31 downto 0);
  signal harmonic_frontend_completed : std_logic_vector(31 downto 0);
  signal harmonic_frontend_dropped   : std_logic_vector(31 downto 0);
  signal harmonic_frontend_malformed : std_logic_vector(31 downto 0);
  signal harmonic_xfft_faults        : std_logic_vector(31 downto 0);
begin
  capture_frame_count <= simulator_frame_count when simulator_selected = '1' else physical_frame_count;
  capture_overflows <= (others => '0') when simulator_selected = '1' else physical_overflows;
  capture_headers <= (others => '0') when simulator_selected = '1' else physical_headers;
  capture_alerts <= simulator_saturations when simulator_selected = '1' else physical_alerts;
  capture_frame_rate <= simulator_frame_rate when simulator_selected = '1' else physical_frame_rate;
  capture_frame_rate_valid <= simulator_frame_rate_valid when simulator_selected = '1' else physical_frame_rate_valid;

  capture : entity work.ad7771_capture
    generic map (
      S_AXI_CLOCK_HZ => 99999001
    )
    port map (
      s_axi_aclk => aclk,
      s_axi_aresetn => aresetn,
      s_axi_awaddr => s_axi_capture_awaddr,
      s_axi_awvalid => s_axi_capture_awvalid,
      s_axi_awready => s_axi_capture_awready,
      s_axi_wdata => s_axi_capture_wdata,
      s_axi_wstrb => s_axi_capture_wstrb,
      s_axi_wvalid => s_axi_capture_wvalid,
      s_axi_wready => s_axi_capture_wready,
      s_axi_bresp => s_axi_capture_bresp,
      s_axi_bvalid => s_axi_capture_bvalid,
      s_axi_bready => s_axi_capture_bready,
      s_axi_araddr => s_axi_capture_araddr,
      s_axi_arvalid => s_axi_capture_arvalid,
      s_axi_arready => s_axi_capture_arready,
      s_axi_rdata => s_axi_capture_rdata,
      s_axi_rresp => s_axi_capture_rresp,
      s_axi_rvalid => s_axi_capture_rvalid,
      s_axi_rready => s_axi_capture_rready,
      m_axis_tdata => physical_raw_stream.data,
      m_axis_tkeep => physical_raw_stream.keep,
      m_axis_tvalid => physical_raw_stream.valid,
      m_axis_tready => physical_raw_stream.ready,
      m_axis_tlast => physical_raw_stream.last,
      capture_frame_count => physical_frame_count,
      capture_overflow_count => physical_overflows,
      capture_header_errors => physical_headers,
      capture_alert_count => physical_alerts,
      capture_frame_rate_hz => physical_frame_rate,
      capture_frame_rate_valid => physical_frame_rate_valid,
      adc_dclk => adc_dclk,
      adc_drdy_n => adc_drdy_n,
      adc_dout => adc_dout,
      adc_reset_n => adc_reset_n,
      adc_start_n => adc_start_n,
      adc_convst_sar => adc_convst_sar
    );

  simulator_enabled : if G_SIMULATOR_ENABLE generate
  simulator : entity work.adc_simulator
    generic map (
      G_ACLK_HZ => 99999001,
      G_PACKET_FRAMES => 256
    )
    port map (
      aclk => aclk,
      aresetn => aresetn,
      s_axi_awaddr => s_axi_simulator_awaddr,
      s_axi_awvalid => s_axi_simulator_awvalid,
      s_axi_awready => s_axi_simulator_awready,
      s_axi_wdata => s_axi_simulator_wdata,
      s_axi_wstrb => s_axi_simulator_wstrb,
      s_axi_wvalid => s_axi_simulator_wvalid,
      s_axi_wready => s_axi_simulator_wready,
      s_axi_bresp => s_axi_simulator_bresp,
      s_axi_bvalid => s_axi_simulator_bvalid,
      s_axi_bready => s_axi_simulator_bready,
      s_axi_araddr => s_axi_simulator_araddr,
      s_axi_arvalid => s_axi_simulator_arvalid,
      s_axi_arready => s_axi_simulator_arready,
      s_axi_rdata => s_axi_simulator_rdata,
      s_axi_rresp => s_axi_simulator_rresp,
      s_axi_rvalid => s_axi_simulator_rvalid,
      s_axi_rready => s_axi_simulator_rready,
      m_axis_tdata => simulator_raw_stream.data,
      m_axis_tkeep => simulator_raw_stream.keep,
      m_axis_tvalid => simulator_raw_stream.valid,
      m_axis_tready => simulator_raw_stream.ready,
      m_axis_tlast => simulator_raw_stream.last,
      source_select_o => simulator_selected,
      frame_count_o => simulator_frame_count,
      frame_rate_hz_o => simulator_frame_rate,
      frame_rate_valid_o => simulator_frame_rate_valid,
      saturation_count_o => simulator_saturations
    );
  end generate;

  -- K24 production shape: the simulator does not exist. Its register
  -- window still answers (zeros, OKAY) so the RPU's probe terminates
  -- instead of hanging the interconnect; the source mux is pinned to the
  -- physical front end and the status counters read zero.
  simulator_absent : if not G_SIMULATOR_ENABLE generate
    simulator_stub : block
      signal write_pending : std_logic := '0';
      signal read_pending  : std_logic := '0';
      signal aw_seen       : std_logic := '0';
      signal w_seen        : std_logic := '0';
    begin
      s_axi_simulator_awready <= not aw_seen and not write_pending;
      s_axi_simulator_wready  <= not w_seen and not write_pending;
      s_axi_simulator_bvalid  <= write_pending;
      s_axi_simulator_bresp   <= "00";
      s_axi_simulator_arready <= not read_pending;
      s_axi_simulator_rvalid  <= read_pending;
      s_axi_simulator_rdata   <= (others => '0');
      s_axi_simulator_rresp   <= "00";

      process (aclk)
      begin
        if rising_edge(aclk) then
          if aresetn = '0' then
            write_pending <= '0';
            read_pending <= '0';
            aw_seen <= '0';
            w_seen <= '0';
          else
            if write_pending = '0' then
              if s_axi_simulator_awvalid = '1' then
                aw_seen <= '1';
              end if;
              if s_axi_simulator_wvalid = '1' then
                w_seen <= '1';
              end if;
              if (aw_seen = '1' or s_axi_simulator_awvalid = '1') and
                 (w_seen = '1' or s_axi_simulator_wvalid = '1') then
                write_pending <= '1';
              end if;
            elsif s_axi_simulator_bready = '1' then
              write_pending <= '0';
              aw_seen <= '0';
              w_seen <= '0';
            end if;

            if read_pending = '0' then
              if s_axi_simulator_arvalid = '1' then
                read_pending <= '1';
              end if;
            elsif s_axi_simulator_rready = '1' then
              read_pending <= '0';
            end if;
          end if;
        end if;
      end process;
    end block;

    simulator_raw_stream.data <= (others => '0');
    simulator_raw_stream.keep <= (others => '0');
    simulator_raw_stream.valid <= '0';
    simulator_raw_stream.last <= '0';
    simulator_selected <= '0';
    simulator_frame_count <= (others => '0');
    simulator_frame_rate <= (others => '0');
    simulator_frame_rate_valid <= '0';
    simulator_saturations <= (others => '0');
  end generate;

  source_mux : entity work.adc_source_mux
    port map (
      select_simulator_i => simulator_selected,
      physical_tdata_i => physical_raw_stream.data,
      physical_tkeep_i => physical_raw_stream.keep,
      physical_tvalid_i => physical_raw_stream.valid,
      physical_tready_o => physical_raw_stream.ready,
      physical_tlast_i => physical_raw_stream.last,
      simulator_tdata_i => simulator_raw_stream.data,
      simulator_tkeep_i => simulator_raw_stream.keep,
      simulator_tvalid_i => simulator_raw_stream.valid,
      simulator_tready_o => simulator_raw_stream.ready,
      simulator_tlast_i => simulator_raw_stream.last,
      m_axis_tdata_o => raw_stream.data,
      m_axis_tkeep_o => raw_stream.keep,
      m_axis_tvalid_o => raw_stream.valid,
      m_axis_tready_i => raw_stream.ready,
      m_axis_tlast_o => raw_stream.last
    );

  conversion : entity work.adc_conversion
    port map (
      aclk => aclk,
      aresetn => aresetn,
      s_axis_tdata => raw_stream.data,
      s_axis_tkeep => raw_stream.keep,
      s_axis_tvalid => raw_stream.valid,
      s_axis_tready => raw_stream.ready,
      s_axis_tlast => raw_stream.last,
      m_axis_tdata => converted_source.data,
      m_axis_tkeep => converted_source.keep,
      m_axis_tuser => converted_source.user,
      m_axis_tvalid => converted_source.valid,
      m_axis_tready => converted_source.ready,
      m_axis_tlast => converted_source.last,
      active_scale_q16_o => conversion_active_scale,
      s_axi_awaddr => s_axi_conversion_awaddr,
      s_axi_awvalid => s_axi_conversion_awvalid,
      s_axi_awready => s_axi_conversion_awready,
      s_axi_wdata => s_axi_conversion_wdata,
      s_axi_wstrb => s_axi_conversion_wstrb,
      s_axi_wvalid => s_axi_conversion_wvalid,
      s_axi_wready => s_axi_conversion_wready,
      s_axi_bresp => s_axi_conversion_bresp,
      s_axi_bvalid => s_axi_conversion_bvalid,
      s_axi_bready => s_axi_conversion_bready,
      s_axi_araddr => s_axi_conversion_araddr,
      s_axi_arvalid => s_axi_conversion_arvalid,
      s_axi_arready => s_axi_conversion_arready,
      s_axi_rdata => s_axi_conversion_rdata,
      s_axi_rresp => s_axi_conversion_rresp,
      s_axi_rvalid => s_axi_conversion_rvalid,
      s_axi_rready => s_axi_conversion_rready
    );

  -- The waveform branch observes the exact frame accepted into the normal
  -- conversion-to-processing FIFO. It never owns converted_source.ready, so a
  -- stopped waveform DMA cannot backpressure RMS or ADC acquisition.
  conversion_frame_accept <= converted_source.valid and converted_source.ready;

  -- The 64-bit sample index travels with each frame in TUSER (low word in
  -- bits 31:0, high word in bits 105:74), so every tap along the pipeline
  -- observes the same measurement timebase regardless of FIFO depth.
  waveform_sample_index <= converted_source.user(105 downto 74) &
                           converted_source.user(31 downto 0);

  waveform_registers : entity work.meter_waveform_axi_regs
    port map (
      aclk => aclk,
      aresetn => aresetn,
      s_axi_awaddr => s_axi_waveform_awaddr,
      s_axi_awvalid => s_axi_waveform_awvalid,
      s_axi_awready => s_axi_waveform_awready,
      s_axi_wdata => s_axi_waveform_wdata,
      s_axi_wstrb => s_axi_waveform_wstrb,
      s_axi_wvalid => s_axi_waveform_wvalid,
      s_axi_wready => s_axi_waveform_wready,
      s_axi_bresp => s_axi_waveform_bresp,
      s_axi_bvalid => s_axi_waveform_bvalid,
      s_axi_bready => s_axi_waveform_bready,
      s_axi_araddr => s_axi_waveform_araddr,
      s_axi_arvalid => s_axi_waveform_arvalid,
      s_axi_arready => s_axi_waveform_arready,
      s_axi_rdata => s_axi_waveform_rdata,
      s_axi_rresp => s_axi_waveform_rresp,
      s_axi_rvalid => s_axi_waveform_rvalid,
      s_axi_rready => s_axi_waveform_rready,
      tick_i => waveform_tick,
      sequence_i => waveform_sequence,
      drop_count_i => waveform_drop_count,
      block_count_i => waveform_block_count,
      status_i => waveform_status,
      enable_o => waveform_enable,
      clear_stats_o => waveform_clear_stats,
      ten_minute_target_sample_o => ten_minute_target_sample,
      ten_minute_target_valid_o => ten_minute_target_valid,
      ten_minute_target_update_o => ten_minute_target_update
    );

  waveform_stream : entity work.meter_waveform
    generic map (
      G_FRAMES_PER_BLOCK => 1024,
      G_FIFO_DEPTH => 256
    )
    port map (
      aclk => aclk,
      aresetn => aresetn,
      frame_accept_i => conversion_frame_accept,
      raw_frame_i => converted_source.user(383 downto 128),
      sample_index_i => waveform_sample_index,
      config_generation_i => converted_source.user(63 downto 32),
      measured_frame_rate_hz_i => capture_frame_rate,
      measured_frame_rate_valid_i => capture_frame_rate_valid,
      enable_i => waveform_enable,
      clear_stats_i => waveform_clear_stats,
      tick_o => waveform_tick,
      sequence_o => waveform_sequence,
      drop_count_o => waveform_drop_count,
      block_count_o => waveform_block_count,
      status_o => waveform_status,
      m_axis_tdata => m_axis_waveform_tdata,
      m_axis_tkeep => m_axis_waveform_tkeep,
      m_axis_tvalid => m_axis_waveform_tvalid,
      m_axis_tready => m_axis_waveform_tready,
      m_axis_tlast => m_axis_waveform_tlast
    );

  -- Same-clock elasticity between conversion and the calculation engines.
  -- XPM owns the AXI4-Stream handshake and storage implementation; no
  -- generated XCI or block-design FIFO is required.
  frame_fifo : xpm_fifo_axis
    generic map (
      CLOCKING_MODE        => "common_clock",
      FIFO_MEMORY_TYPE     => "auto",
      CASCADE_HEIGHT       => 0,
      PACKET_FIFO          => "false",
      FIFO_DEPTH           => 16,
      TDATA_WIDTH          => METER_CONVERTED_FRAME_BITS,
      TID_WIDTH            => 1,
      TDEST_WIDTH          => 1,
      TUSER_WIDTH          => 384,
      ECC_MODE             => "no_ecc",
      RELATED_CLOCKS       => 0,
      USE_ADV_FEATURES     => "1000",
      WR_DATA_COUNT_WIDTH  => 5,
      RD_DATA_COUNT_WIDTH  => 5,
      PROG_FULL_THRESH     => 10,
      PROG_EMPTY_THRESH    => 10,
      SIM_ASSERT_CHK       => 1,
      EN_SIM_ASSERT_ERR    => "warning",
      CDC_SYNC_STAGES      => 2
    )
    port map (
      s_aresetn => aresetn,
      s_aclk => aclk,
      m_aclk => aclk,
      s_axis_tdata => converted_source.data,
      s_axis_tstrb => (others => '1'),
      s_axis_tkeep => converted_source.keep,
      s_axis_tuser => converted_source.user,
      s_axis_tvalid => converted_source.valid,
      s_axis_tready => converted_source.ready,
      s_axis_tlast => converted_source.last,
      s_axis_tid => (others => '0'),
      s_axis_tdest => (others => '0'),
      m_axis_tdata => converted_fifo.data,
      m_axis_tstrb => open,
      m_axis_tkeep => converted_fifo.keep,
      m_axis_tuser => converted_fifo.user,
      m_axis_tvalid => converted_fifo.valid,
      m_axis_tready => converted_fifo.ready,
      m_axis_tlast => converted_fifo.last,
      m_axis_tid => open,
      m_axis_tdest => open,
      prog_full_axis => open,
      wr_data_count_axis => open,
      almost_full_axis => open,
      prog_empty_axis => open,
      rd_data_count_axis => open,
      almost_empty_axis => open,
      injectsbiterr_axis => '0',
      injectdbiterr_axis => '0',
      sbiterr_axis => open,
      dbiterr_axis => open
    );

  -- The metering branches never backpressure conversion: every frame is
  -- accepted the cycle it appears; the MTR1 shim's beat FIFO absorbs the
  -- HLS engine's finalize latency and counts (never hides) any overflow.
  engine_ready <= '1';
  converted_fifo.ready <= engine_ready;
  engine_valid <= converted_fifo.valid and converted_fifo.ready;

  processing_registers : entity work.meter_processing_axi_regs
    port map (
      aclk => aclk,
      aresetn => aresetn,
      s_axi_awaddr => s_axi_processing_awaddr,
      s_axi_awvalid => s_axi_processing_awvalid,
      s_axi_awready => s_axi_processing_awready,
      s_axi_wdata => s_axi_processing_wdata,
      s_axi_wstrb => s_axi_processing_wstrb,
      s_axi_wvalid => s_axi_processing_wvalid,
      s_axi_wready => s_axi_processing_wready,
      s_axi_bresp => s_axi_processing_bresp,
      s_axi_bvalid => s_axi_processing_bvalid,
      s_axi_bready => s_axi_processing_bready,
      s_axi_araddr => s_axi_processing_araddr,
      s_axi_arvalid => s_axi_processing_arvalid,
      s_axi_arready => s_axi_processing_arready,
      s_axi_rdata => s_axi_processing_rdata,
      s_axi_rresp => s_axi_processing_rresp,
      s_axi_rvalid => s_axi_processing_rvalid,
      s_axi_rready => s_axi_processing_rready,
      shadow_generation_o => shadow_generation,
      shadow_sample_rate_o => shadow_sample_rate,
      shadow_window_samples_o => shadow_window_samples,
      shadow_valid_mask_o => shadow_valid_mask,
      shadow_enable_o => shadow_enable,
      shadow_dc_remove_o => shadow_dc_remove,
      apply_toggle_o => apply_toggle,
      frequency_shadow_control_o => frequency_shadow_control,
      frequency_shadow_window_samples_o => frequency_shadow_window,
      frequency_shadow_minimum_millihz_o => frequency_shadow_minimum,
      frequency_shadow_maximum_millihz_o => frequency_shadow_maximum,
      frequency_shadow_hysteresis_uv_o => frequency_shadow_hysteresis,
      frequency_active_control_i => frequency_active_control,
      frequency_active_window_samples_i => frequency_active_window,
      frequency_active_minimum_millihz_i => frequency_active_minimum,
      frequency_active_maximum_millihz_i => frequency_active_maximum,
      frequency_active_hysteresis_uv_i => frequency_active_hysteresis,
      frequency_status_i => frequency_status,
      frequency_millihz_i => frequency_millihz,
      frequency_period_q16_samples_i => frequency_period_q16,
      frequency_measurement_sequence_i => frequency_sequence,
      frequency_rejected_count_i => frequency_rejected,
      grid_shadow_config_o => grid_shadow_config,
      pq_shadow_reference_o => pq_shadow_reference,
      pq_shadow_threshold_o => pq_shadow_threshold,
      pq_shadow_limits_o => pq_shadow_limits,
      pq_status_i => pq_status,
      grid_active_config_i => grid_active_config,
      grid_status_i => grid_status,
      -- The retired PL interval/result diagnostics keep their AXI-Lite
      -- offsets and read zero. AGG_STATUS has no live equivalent since the
      -- RTL engine's retirement and HLS_AGG_MISMATCH_COUNT remains reserved.
      -- HLS_AGG_DROP_COUNT is the exception: it remains the live
      -- SingleCycle sample-beat FIFO drop counter (any nonzero is a fault).
      agg_status_i => (others => '0'),
      agg_record_count_i => (others => '0'),
      agg_reset_count_i => (others => '0'),
      agg_ineligible_count_i => (others => '0'),
      agg_continuity_count_i => (others => '0'),
      agg_drop_count_i => (others => '0'),
      legacy_agg_record_count_i => (others => '0'),
      legacy_agg_mismatch_count_i => (others => '0'),
      -- The sample-domain loss point is now the single-cycle shim's FIFO
      -- (the retired Mtr1 shim's counter died with it).
      legacy_agg_drop_count_i => scyc_shim_drop_count,
      r5_agg_export_status_i => r5_agg_status,
      r5_agg_export_accepted_count_i => r5_agg_accepted_packets,
      r5_agg_export_dropped_count_i => r5_agg_dropped_packets,
      r5_agg_export_transmitted_count_i => r5_agg_transmitted_packets,
      r5_agg_export_framing_errors_i => r5_agg_framing_errors,
      r5_agg_export_last_sequence_i => r5_agg_last_sequence,
      r5_agg_export_queue_level_i =>
        x"000000" & r5_agg_queue_level,
      harmonic_conditioned_blocks_i => harmonic_conditioned_blocks,
      harmonic_invalid_blocks_i => harmonic_invalid_blocks,
      harmonic_service_overruns_i => harmonic_service_overruns,
      harmonic_frontend_completed_i => harmonic_frontend_completed,
      harmonic_frontend_dropped_i => harmonic_frontend_dropped,
      harmonic_frontend_malformed_i => harmonic_frontend_malformed,
      harmonic_xfft_fault_count_i => harmonic_xfft_faults,
      active_generation_i => active_generation,
      result_sequence_i => (others => '0'),
      result_drop_count_i => (others => '0'),
      packet_drop_count_i => (others => '0'),
      status_i => processing_status
    );

  -- Frequency observes the exact frames accepted by the RMS engine. It has no
  -- ready path and therefore cannot stop conversion, RMS, or ADC capture.
  frequency_engine : entity work.meter_frequency
    port map (
      aclk => aclk,
      aresetn => aresetn,
      frame_accept_i => engine_valid,
      frame_data_i => converted_fifo.data,
      frame_keep_i => converted_fifo.keep,
      frame_user_i => converted_fifo.user,
      config_generation_i => shadow_generation,
      measured_frame_rate_hz_i => capture_frame_rate,
      measured_frame_rate_valid_i => capture_frame_rate_valid,
      config_control_i => frequency_shadow_control,
      config_window_samples_i => frequency_shadow_window,
      config_minimum_millihz_i => frequency_shadow_minimum,
      config_maximum_millihz_i => frequency_shadow_maximum,
      config_hysteresis_uv_i => frequency_shadow_hysteresis,
      config_apply_toggle_i => apply_toggle,
      active_control_o => frequency_active_control,
      active_window_samples_o => frequency_active_window,
      active_minimum_millihz_o => frequency_active_minimum,
      active_maximum_millihz_o => frequency_active_maximum,
      active_hysteresis_uv_o => frequency_active_hysteresis,
      status_o => frequency_status,
      frequency_millihz_o => frequency_millihz,
      period_q16_samples_o => frequency_period_q16,
      measurement_sequence_o => frequency_sequence,
      rejected_count_o => frequency_rejected,
      rising_crossing_now_o => rising_crossing_now,
      falling_crossing_now_o => falling_crossing_now,
      reference_valid_now_o => reference_valid_now
    );

  -- Grid-cycle timing derives IEC 61000-4-30 basic-block boundaries from the
  -- same qualified zero crossings the frequency engine uses. Like the
  -- frequency and waveform branches it only observes accepted frames and can
  -- never backpressure the stream.
  grid_timing : entity work.grid_cycle_timing
    port map (
      aclk => aclk,
      aresetn => aresetn,
      frame_accept_i => engine_valid,
      sample_index_low_i => converted_fifo.user(31 downto 0),
      sample_index_high_i => converted_fifo.user(105 downto 74),
      rising_crossing_i => rising_crossing_now,
      falling_crossing_i => falling_crossing_now,
      reference_valid_i => reference_valid_now,
      config_grid_i => grid_shadow_config,
      config_window_samples_i => shadow_window_samples,
      config_apply_toggle_i => apply_toggle,
      active_grid_o => grid_active_config,
      status_o => grid_status,
      frame_closes_block_o => grid_frame_closes_block,
      cycle_mode_o => grid_cycle_mode,
      cycle_boundary_o => grid_cycle_boundary,
      half_cycle_boundary_o => grid_half_boundary,
      cycle_locked_o => grid_cycle_locked,
      cycle_sequence_o => grid_cycle_sequence,
      block_first_sample_o => block_first_sample,
      block_cycle_count_o => block_cycle_count,
      block_nominal_hz_o => block_nominal_hz,
      block_flags_o => block_flags
    );

  -- Live fallback view: enabled but running on synthetic boundaries.
  grid_cycle_fallback <= grid_cycle_mode and not grid_cycle_locked;

  -- M16 spectral observer.  The fixed profile is qualified only for an exact
  -- 32 kSPS / 6,400-frame basic block; other geometries are explicitly
  -- invalidated by the frontend instead of being dropped or zero padded.
  harmonic_conditioner : entity work.meter_spectral_conditioner
    port map (
      aclk => aclk,
      aresetn => aresetn,
      frame_accept_i => engine_valid,
      raw_frame_i => converted_fifo.user(383 downto 128),
      frame_user_i => converted_fifo.user,
      frame_closes_block_i => grid_frame_closes_block,
      grid_locked_i => grid_cycle_locked,
      grid_nominal_hz_i => grid_active_config(15 downto 8),
      grid_cycle_count_i => grid_active_config(7 downto 0),
      config_enable_i => shadow_enable,
      config_apply_toggle_i => apply_toggle,
      source_frame_rate_i => capture_frame_rate,
      source_frame_rate_valid_i => capture_frame_rate_valid,
      frequency_millihz_i => frequency_millihz,
      frequency_valid_i => frequency_status(1),
      active_scale_q16_i => conversion_active_scale,
      emit_drops_i => (others => '0'),
      m_axis_context_tdata => harmonic_context_tdata,
      m_axis_context_tvalid => harmonic_context_tvalid,
      m_axis_context_tready => harmonic_context_tready,
      m_axis_frame_tdata => harmonic_frame_tdata,
      m_axis_frame_tvalid => harmonic_frame_tvalid,
      m_axis_frame_tready => harmonic_frame_tready,
      m_axis_frame_tlast => harmonic_frame_tlast,
      m_axis_frame_fault => harmonic_frame_fault,
      completed_blocks_o => harmonic_conditioned_blocks,
      invalid_blocks_o => harmonic_invalid_blocks,
      service_overruns_o => harmonic_service_overruns
    );

  harmonic_engine : entity work.meter_harmonic_hls_shim
    port map (
      aclk => aclk,
      aresetn => aresetn,
      s_axis_context_tdata => harmonic_context_tdata,
      s_axis_context_tvalid => harmonic_context_tvalid,
      s_axis_context_tready => harmonic_context_tready,
      s_axis_frame_tdata => harmonic_frame_tdata,
      s_axis_frame_tvalid => harmonic_frame_tvalid,
      s_axis_frame_tready => harmonic_frame_tready,
      s_axis_frame_tlast => harmonic_frame_tlast,
      s_axis_frame_fault => harmonic_frame_fault,
      m_axis_fft_data_tdata => m_axis_fft_data_tdata,
      m_axis_fft_data_tvalid => m_axis_fft_data_tvalid,
      m_axis_fft_data_tready => m_axis_fft_data_tready,
      m_axis_fft_data_tlast => m_axis_fft_data_tlast,
      s_axis_fft_data_tdata => s_axis_fft_data_tdata,
      s_axis_fft_data_tuser => s_axis_fft_data_tuser,
      s_axis_fft_data_tvalid => s_axis_fft_data_tvalid,
      s_axis_fft_data_tready => s_axis_fft_data_tready,
      s_axis_fft_data_tlast => s_axis_fft_data_tlast,
      m_axis_fft_config_tdata => m_axis_fft_config_tdata,
      m_axis_fft_config_tvalid => m_axis_fft_config_tvalid,
      m_axis_fft_config_tready => m_axis_fft_config_tready,
      s_axis_fft_status_tdata => s_axis_fft_status_tdata,
      s_axis_fft_status_tvalid => s_axis_fft_status_tvalid,
      s_axis_fft_status_tready => s_axis_fft_status_tready,
      xfft_event_frame_started_i => xfft_event_frame_started,
      xfft_event_tlast_unexpected_i => xfft_event_tlast_unexpected,
      xfft_event_tlast_missing_i => xfft_event_tlast_missing,
      xfft_event_status_channel_halt_i =>
        xfft_event_status_channel_halt,
      xfft_event_data_in_channel_halt_i =>
        xfft_event_data_in_channel_halt,
      xfft_event_data_out_channel_halt_i =>
        xfft_event_data_out_channel_halt,
      m_axis_records_tdata => m_axis_harmonic_tdata,
      m_axis_records_tkeep => m_axis_harmonic_tkeep,
      m_axis_records_tvalid => m_axis_harmonic_tvalid,
      m_axis_records_tready => m_axis_harmonic_tready,
      m_axis_records_tlast => m_axis_harmonic_tlast,
      frontend_completed_windows_o => harmonic_frontend_completed,
      frontend_dropped_windows_o => harmonic_frontend_dropped,
      frontend_malformed_windows_o => harmonic_frontend_malformed,
      xfft_fault_count_o => harmonic_xfft_faults
    );

  -- R5C1 is the only interval-aggregation owner. The exporter consumes the
  -- SingleCycle packet without backpressuring metrology and emits a complete,
  -- integrity-protected private-link frame. Finished MTR1/MTR2 records return
  -- through the independent block-design R5 FIFO path.
  scyc_result_tready <= r5_export_input_ready;

  -- R5 receives this same configuration snapshot in every input packet.
  active_generation <= shadow_generation;
  active_enable <= shadow_enable;
  apply_seen <= apply_toggle;

  r5_aggregation_export : entity work.meter_r5_aggregation_export
    port map (
      aclk => aclk,
      aresetn => aresetn,
      result_word_valid_i => scyc_result_tvalid,
      result_word_ready_o => r5_export_input_ready,
      result_word_i => scyc_result_tdata,
      cycle_locked_i => grid_cycle_locked,
      cycle_fallback_i => grid_cycle_fallback,
      shadow_generation_i => shadow_generation,
      shadow_sample_rate_i => shadow_sample_rate,
      shadow_valid_mask_i => shadow_valid_mask,
      shadow_enable_i => shadow_enable,
      shadow_dc_remove_i => shadow_dc_remove,
      config_apply_toggle_i => apply_toggle,
      frequency_status_i => frequency_status,
      frequency_period_i => frequency_period_q16,
      frequency_sequence_i => frequency_sequence,
      capture_frame_count_i => capture_frame_count,
      capture_header_errors_i => capture_headers,
      capture_overflows_i => capture_overflows,
      capture_alerts_i => capture_alerts,
      ten_minute_target_sample_i => ten_minute_target_sample,
      ten_minute_target_valid_i => ten_minute_target_valid,
      ten_minute_target_update_i => ten_minute_target_update,
      m_axis_tdata => m_axis_r5_agg_input_tdata,
      m_axis_tkeep => m_axis_r5_agg_input_tkeep,
      m_axis_tvalid => m_axis_r5_agg_input_tvalid,
      m_axis_tready => m_axis_r5_agg_input_tready,
      m_axis_tlast => m_axis_r5_agg_input_tlast,
      accepted_packet_count_o => r5_agg_accepted_packets,
      dropped_packet_count_o => r5_agg_dropped_packets,
      transmitted_packet_count_o => r5_agg_transmitted_packets,
      framing_error_count_o => r5_agg_framing_errors,
      last_sequence_o => r5_agg_last_sequence,
      queue_level_o => r5_agg_queue_level,
      status_o => r5_agg_status
    );

  -- STATUS (0x0C): enabled, apply pending, calculation busy, overflow.
  -- Retired PL busy/overflow fields stay zero for register compatibility.
  processing_status <= (31 downto 2 => '0') &
                       (apply_toggle xor apply_seen) & active_enable;

  -- R5C1 reports aggregation health through its firmware contract.
  -- Single-cycle producer: sample-beat shim + HLS engine (per-cycle
  -- provenance in M2; statistics/power/phasor accumulate here from M3).
  -- Its result stream feeds the private R5C1 exporter.
  scyc_producer : entity work.meter_single_cycle_hls_shim
    port map (
      aclk => aclk,
      aresetn => aresetn,
      frame_accept_i => engine_valid,
      frame_data_i => converted_fifo.data,
      frame_keep_i => converted_fifo.keep,
      frame_user_i => converted_fifo.user,
      cycle_boundary_i => grid_cycle_boundary,
      cycle_sequence_i => grid_cycle_sequence,
      cycle_mode_i => grid_cycle_mode,
      block_nominal_hz_i => block_nominal_hz,
      block_flags_i => block_flags,
      shadow_generation_i => shadow_generation,
      shadow_sample_rate_i => shadow_sample_rate,
      shadow_valid_mask_i => shadow_valid_mask,
      shadow_enable_i => shadow_enable,
      shadow_dc_remove_i => shadow_dc_remove,
      config_apply_toggle_i => apply_toggle,
      pl_tick_i => waveform_tick,
      frequency_millihz_i => frequency_millihz,
      frequency_status_i => frequency_status,
      m_axis_scyc_tdata => m_axis_scyc_tdata,
      m_axis_scyc_tkeep => m_axis_scyc_tkeep,
      m_axis_scyc_tvalid => m_axis_scyc_tvalid,
      m_axis_scyc_tready => m_axis_scyc_tready,
      m_axis_scyc_tlast => m_axis_scyc_tlast,
      m_result_tdata => scyc_result_tdata,
      m_result_tvalid => scyc_result_tvalid,
      m_result_tready => scyc_result_tready,
      drop_count_o => scyc_shim_drop_count
    );

  -- Sliding Urms(1/2) / PQ event producer (M12). It observes the same
  -- accepted-frame fan-out as the single-cycle producer -- frames are
  -- broadcast signals, so the two observers never arbitrate -- and drives
  -- its own exported record stream.
  pq_producer : entity work.meter_sliding_rms_hls_shim
    port map (
      aclk => aclk,
      aresetn => aresetn,
      frame_accept_i => engine_valid,
      frame_data_i => converted_fifo.data,
      frame_keep_i => converted_fifo.keep,
      frame_user_i => converted_fifo.user,
      half_cycle_boundary_i => grid_half_boundary,
      cycle_locked_i => grid_cycle_locked,
      cycle_fallback_i => grid_cycle_fallback,
      shadow_generation_i => shadow_generation,
      shadow_sample_rate_i => shadow_sample_rate,
      shadow_valid_mask_i => shadow_valid_mask,
      shadow_enable_i => shadow_enable,
      config_apply_toggle_i => apply_toggle,
      shadow_pq_reference_i => pq_shadow_reference,
      shadow_pq_threshold_i => pq_shadow_threshold,
      shadow_pq_limits_i => pq_shadow_limits,
      pl_tick_i => waveform_tick,
      m_axis_pq_tdata => pq_axis_tdata,
      m_axis_pq_tkeep => pq_axis_tkeep,
      m_axis_pq_tvalid => pq_axis_tvalid,
      m_axis_pq_tready => m_axis_pq_tready,
      m_axis_pq_tlast => pq_axis_tlast,
      drop_count_o => pq_shim_drop_count
    );

  m_axis_pq_tdata <= pq_axis_tdata;
  m_axis_pq_tkeep <= pq_axis_tkeep;
  m_axis_pq_tvalid <= pq_axis_tvalid;
  m_axis_pq_tlast <= pq_axis_tlast;

  pq_tap : entity work.record_word_tap
    generic map (
      -- The PQ producer emits one format, and its live event state lives
      -- in the format-header word (13) and the event sequence (28).
      G_AUX0_WORD => 13,
      G_AUX1_WORD => 28,
      -- Kind byte: refresh the PQ status register only on an event edge,
      -- never on a periodic heartbeat (measured on target 2026-08-20 --
      -- without this the register reads 0 outside the ~0.83 s window
      -- between an edge record and the next heartbeat).
      G_AUX_UPDATE_MASK => x"000000FF"
    )
    port map (
      aclk => aclk,
      aresetn => aresetn,
      tdata_i => pq_axis_tdata,
      tvalid_i => pq_axis_tvalid,
      tready_i => m_axis_pq_tready,
      tlast_i => pq_axis_tlast,
      sequence_o => open,
      status_o => open,
      emit_drops_o => open,
      result_drops_o => open,
      reset_count_o => open,
      ineligible_count_o => open,
      continuity_count_o => open,
      aux0_o => pq_tap_kind,
      aux1_o => pq_tap_event_seq,
      framing_error_o => open,
      framing_error_count_o => open
    );

  -- PQ_STATUS (pq_event_pkg layout), composed from the last emitted
  -- record: an event is "in progress" exactly when the newest record was
  -- an event START, since an END always follows the same event.
  pq_event_active <= '1'
    when unsigned(pq_tap_kind(7 downto 0)) = PQ_KIND_EVENT_START else '0';
  pq_status <= pq_tap_event_seq(15 downto 0) &  -- [31:16] completed events
               "00000" &                        -- [15:11] reserved
               pq_tap_kind(18 downto 16) &      -- [10:8]  affected phases
               "0000" &                         -- [7:4]   reserved
               pq_tap_kind(10 downto 8) &       -- [3:1]   event type
               pq_event_active;                 -- [0]     event in progress

end architecture;
