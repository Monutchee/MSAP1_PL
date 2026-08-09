library ieee;
use ieee.std_logic_1164.all;

library xpm;
use xpm.vcomponents.all;

library work;
use work.measurement_record_bus_pkg.all;

-- Structural integration for the complete ADC-to-meter-record datapath.
-- Vendor/platform integration remains outside this entity in TopDesign.bd.
entity meter_core is
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

    s_axi_simulator_awaddr  : in  std_logic_vector(7 downto 0);
    s_axi_simulator_awvalid : in  std_logic;
    s_axi_simulator_awready : out std_logic;
    s_axi_simulator_wdata   : in  std_logic_vector(31 downto 0);
    s_axi_simulator_wstrb   : in  std_logic_vector(3 downto 0);
    s_axi_simulator_wvalid  : in  std_logic;
    s_axi_simulator_wready  : out std_logic;
    s_axi_simulator_bresp   : out std_logic_vector(1 downto 0);
    s_axi_simulator_bvalid  : out std_logic;
    s_axi_simulator_bready  : in  std_logic;
    s_axi_simulator_araddr  : in  std_logic_vector(7 downto 0);
    s_axi_simulator_arvalid : in  std_logic;
    s_axi_simulator_arready : out std_logic;
    s_axi_simulator_rdata   : out std_logic_vector(31 downto 0);
    s_axi_simulator_rresp   : out std_logic_vector(1 downto 0);
    s_axi_simulator_rvalid  : out std_logic;
    s_axi_simulator_rready  : in  std_logic;

    m_axis_meter_tdata  : out std_logic_vector(31 downto 0);
    m_axis_meter_tkeep  : out std_logic_vector(3 downto 0);
    m_axis_meter_tvalid : out std_logic;
    m_axis_meter_tready : in  std_logic;
    m_axis_meter_tlast  : out std_logic;

    m_axis_waveform_tdata  : out std_logic_vector(31 downto 0);
    m_axis_waveform_tkeep  : out std_logic_vector(3 downto 0);
    m_axis_waveform_tvalid : out std_logic;
    m_axis_waveform_tready : in  std_logic;
    m_axis_waveform_tlast  : out std_logic;

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
    data  : std_logic_vector(511 downto 0);
    keep  : std_logic_vector(63 downto 0);
    user  : std_logic_vector(383 downto 0);
    valid : std_logic;
    ready : std_logic;
    last  : std_logic;
  end record;

  type result_bundle_t is record
    valid_mask : std_logic_vector(7 downto 0);
    mean_q16   : std_logic_vector(511 downto 0);
    rms_q16    : std_logic_vector(511 downto 0);
    rms_count  : std_logic_vector(255 downto 0);
  end record;

  signal physical_raw_stream : axis32_stream_t;
  signal simulator_raw_stream: axis32_stream_t;
  signal raw_stream          : axis32_stream_t;
  signal converted_source : converted_stream_t;
  signal converted_fifo   : converted_stream_t;
  signal engine_valid     : std_logic;
  signal engine_ready     : std_logic;

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
  signal processing_status : std_logic_vector(31 downto 0);
  signal result_valid      : std_logic;
  signal result_sequence   : std_logic_vector(31 downto 0);
  signal result_generation : std_logic_vector(31 downto 0);
  signal result_sample_rate: std_logic_vector(31 downto 0);
  signal result_window     : std_logic_vector(31 downto 0);
  signal result_status     : std_logic_vector(31 downto 0);
  signal meter_result      : result_bundle_t;
  signal result_drop_count : std_logic_vector(31 downto 0);

  signal record_data          : std_logic_vector(2047 downto 0);
  signal record_valid         : std_logic;
  signal record_ready         : std_logic;
  signal hub_drop_count       : std_logic_vector(31 downto 0);
  signal packetizer_drop_count: std_logic_vector(31 downto 0);

  -- Measurement record bus: Basic (hub) and aggregate producers meet at
  -- the arbiter, which feeds the single existing packetizer/DMA path.
  signal basic_result           : basic_measurement_result_t;
  signal aggregate_valid        : std_logic;
  signal aggregate_sequence     : std_logic_vector(31 downto 0);
  signal aggregate_generation   : std_logic_vector(31 downto 0);
  signal aggregate_sample_rate  : std_logic_vector(31 downto 0);
  signal aggregate_samples      : std_logic_vector(31 downto 0);
  signal aggregate_valid_mask   : std_logic_vector(7 downto 0);
  signal aggregate_arithmetic   : std_logic;
  signal aggregate_freq_valid   : std_logic;
  signal aggregate_first_seq    : std_logic_vector(31 downto 0);
  signal aggregate_last_seq     : std_logic_vector(31 downto 0);
  signal aggregate_nominal      : std_logic_vector(7 downto 0);
  signal aggregate_cycles       : std_logic_vector(15 downto 0);
  signal aggregate_first_sample : std_logic_vector(63 downto 0);
  signal aggregate_rms_q16      : std_logic_vector(511 downto 0);
  signal aggregate_freq_millihz : std_logic_vector(31 downto 0);
  signal agg_status             : std_logic_vector(31 downto 0);
  signal agg_record_count       : std_logic_vector(31 downto 0);
  signal agg_reset_count        : std_logic_vector(31 downto 0);
  signal agg_ineligible_count   : std_logic_vector(31 downto 0);
  signal agg_continuity_count   : std_logic_vector(31 downto 0);
  signal agg_record_data        : measurement_record_t;
  signal agg_record_valid       : std_logic;
  signal agg_record_ready       : std_logic;
  signal agg_drop_count         : std_logic_vector(31 downto 0);
  signal bus_record_data        : measurement_record_t;
  signal bus_record_valid       : std_logic;
  signal bus_record_ready       : std_logic;

  signal waveform_enable      : std_logic;
  signal waveform_clear_stats : std_logic;
  signal waveform_tick        : std_logic_vector(63 downto 0);
  signal waveform_sequence    : std_logic_vector(63 downto 0);
  signal waveform_drop_count  : std_logic_vector(31 downto 0);
  signal waveform_block_count : std_logic_vector(31 downto 0);
  signal waveform_status      : std_logic_vector(31 downto 0);
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
      clear_stats_o => waveform_clear_stats
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
      TDATA_WIDTH          => 512,
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

  -- The unified engine calculates all configured current and voltage
  -- channels from one coherent window.
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
      grid_active_config_i => grid_active_config,
      grid_status_i => grid_status,
      agg_status_i => agg_status,
      agg_record_count_i => agg_record_count,
      agg_reset_count_i => agg_reset_count,
      agg_ineligible_count_i => agg_ineligible_count,
      agg_continuity_count_i => agg_continuity_count,
      agg_drop_count_i => agg_drop_count,
      active_generation_i => active_generation,
      result_sequence_i => result_sequence,
      result_drop_count_i => result_drop_count,
      packet_drop_count_i => packetizer_drop_count,
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
      cycle_boundary_o => open,
      half_cycle_boundary_o => open,
      cycle_sequence_o => open,
      block_first_sample_o => block_first_sample,
      block_cycle_count_o => block_cycle_count,
      block_nominal_hz_o => block_nominal_hz,
      block_flags_o => block_flags
    );

  rms_engine : entity work.meter_rms
    generic map (
      G_FIRST_CHANNEL => 0,
      G_CHANNEL_COUNT => 7,
      G_RESULT_MASK => x"7F"
    )
    port map (
      aclk => aclk,
      aresetn => aresetn,
      s_axis_tdata => converted_fifo.data,
      s_axis_tkeep => converted_fifo.keep,
      s_axis_tuser => converted_fifo.user,
      s_axis_tvalid => engine_valid,
      s_axis_tready => engine_ready,
      s_axis_tlast => converted_fifo.last,
      config_generation_i => shadow_generation,
      config_sample_rate_i => shadow_sample_rate,
      config_window_samples_i => shadow_window_samples,
      config_valid_mask_i => shadow_valid_mask,
      config_enable_i => shadow_enable,
      config_dc_remove_i => shadow_dc_remove,
      config_apply_toggle_i => apply_toggle,
      cycle_mode_i => grid_cycle_mode,
      frame_closes_block_i => grid_frame_closes_block,
      active_generation_o => active_generation,
      status_o => processing_status,
      result_valid_o => result_valid,
      result_sequence_o => result_sequence,
      result_generation_o => result_generation,
      result_sample_rate_o => result_sample_rate,
      result_window_samples_o => result_window,
      result_valid_mask_o => meter_result.valid_mask,
      result_status_o => result_status,
      result_mean_q16_o => meter_result.mean_q16,
      result_rms_q16_o => meter_result.rms_q16,
      result_rms_count_o => meter_result.rms_count,
      result_drop_count_o => result_drop_count
    );

  result_hub : entity work.MeterResultHub_Wrapper
    port map (
      aclk => aclk,
      aresetn => aresetn,
      voltage_result_valid_i => result_valid,
      result_sequence_i => result_sequence,
      config_generation_i => result_generation,
      sample_rate_i => result_sample_rate,
      window_samples_i => result_window,
      voltage_valid_mask_i => meter_result.valid_mask and x"F0",
      result_status_i => result_status,
      voltage_mean_q16_i => meter_result.mean_q16,
      voltage_rms_q16_i => meter_result.rms_q16,
      voltage_rms_count_i => meter_result.rms_count,
      current_valid_mask_i => meter_result.valid_mask and x"0F",
      current_mean_q16_i => meter_result.mean_q16,
      current_rms_q16_i => meter_result.rms_q16,
      current_rms_count_i => meter_result.rms_count,
      frequency_millihz_i => frequency_millihz,
      frequency_status_i => frequency_status,
      frequency_period_q16_i => frequency_period_q16,
      frequency_sequence_i => frequency_sequence,
      capture_frame_count_i => capture_frame_count,
      capture_header_errors_i => capture_headers,
      capture_overflows_i => capture_overflows,
      capture_alerts_i => capture_alerts,
      packetizer_drop_count_i => packetizer_drop_count,
      block_first_sample_i => block_first_sample,
      block_cycle_count_i => block_cycle_count,
      block_nominal_hz_i => block_nominal_hz,
      block_flags_i => block_flags,
      record_data_o => record_data,
      record_valid_o => record_valid,
      record_ready_i => record_ready,
      hub_drop_count_o => hub_drop_count
    );

  -- The internal Basic measurement result event: one bundle consumed by
  -- both the Basic record producer (the hub above) and the cycle
  -- aggregator, so the aggregator operates on standardized Basic results,
  -- never on decoded MTR1 packets or raw samples.
  basic_result.valid <= result_valid;
  basic_result.result_sequence <= result_sequence;
  basic_result.generation <= result_generation;
  basic_result.sample_rate_hz <= result_sample_rate;
  basic_result.sample_count <= result_window;
  basic_result.valid_mask <= meter_result.valid_mask;
  basic_result.status <= result_status;
  basic_result.rms_q16 <= meter_result.rms_q16;
  basic_result.first_sample <= block_first_sample;
  basic_result.cycle_count <= block_cycle_count;
  basic_result.nominal_hz <= block_nominal_hz;
  basic_result.flags <= block_flags;
  basic_result.frequency_millihz <= frequency_millihz;
  -- FREQUENCY_STATUS_VALID (meter_frequency_pkg bit 1).
  basic_result.frequency_valid <= frequency_status(1);

  cycle_aggregator : entity work.meter_cycle_aggregator
    port map (
      aclk => aclk,
      aresetn => aresetn,
      basic_i => basic_result,
      config_apply_toggle_i => apply_toggle,
      aggregate_valid_o => aggregate_valid,
      aggregate_sequence_o => aggregate_sequence,
      aggregate_generation_o => aggregate_generation,
      aggregate_sample_rate_o => aggregate_sample_rate,
      aggregate_samples_o => aggregate_samples,
      aggregate_valid_mask_o => aggregate_valid_mask,
      aggregate_arithmetic_o => aggregate_arithmetic,
      aggregate_freq_valid_o => aggregate_freq_valid,
      aggregate_first_seq_o => aggregate_first_seq,
      aggregate_last_seq_o => aggregate_last_seq,
      aggregate_nominal_o => aggregate_nominal,
      aggregate_cycles_o => aggregate_cycles,
      aggregate_first_sample_o => aggregate_first_sample,
      aggregate_rms_q16_o => aggregate_rms_q16,
      aggregate_freq_millihz_o => aggregate_freq_millihz,
      status_o => agg_status,
      record_count_o => agg_record_count,
      reset_count_o => agg_reset_count,
      ineligible_count_o => agg_ineligible_count,
      continuity_count_o => agg_continuity_count
    );

  aggregate_producer : entity work.aggregate_record_producer
    port map (
      aclk => aclk,
      aresetn => aresetn,
      aggregate_valid_i => aggregate_valid,
      aggregate_sequence_i => aggregate_sequence,
      aggregate_generation_i => aggregate_generation,
      aggregate_sample_rate_i => aggregate_sample_rate,
      aggregate_samples_i => aggregate_samples,
      aggregate_valid_mask_i => aggregate_valid_mask,
      aggregate_arithmetic_i => aggregate_arithmetic,
      aggregate_freq_valid_i => aggregate_freq_valid,
      aggregate_first_seq_i => aggregate_first_seq,
      aggregate_last_seq_i => aggregate_last_seq,
      aggregate_nominal_i => aggregate_nominal,
      aggregate_cycles_i => aggregate_cycles,
      aggregate_first_sample_i => aggregate_first_sample,
      aggregate_rms_q16_i => aggregate_rms_q16,
      aggregate_freq_millihz_i => aggregate_freq_millihz,
      record_data_o => agg_record_data,
      record_valid_o => agg_record_valid,
      record_ready_i => agg_record_ready,
      drop_count_o => agg_drop_count
    );

  record_arbiter : entity work.measurement_record_arbiter
    port map (
      basic_record_i => record_data,
      basic_valid_i => record_valid,
      basic_ready_o => record_ready,
      aggregate_record_i => agg_record_data,
      aggregate_valid_i => agg_record_valid,
      aggregate_ready_o => agg_record_ready,
      m_record_o => bus_record_data,
      m_valid_o => bus_record_valid,
      m_ready_i => bus_record_ready
    );

  packetizer : entity work.MeterPacketizer_Wrapper
    port map (
      aclk => aclk,
      aresetn => aresetn,
      record_data_i => bus_record_data,
      record_valid_i => bus_record_valid,
      record_ready_o => bus_record_ready,
      m_axis_meter_tdata => m_axis_meter_tdata,
      m_axis_meter_tkeep => m_axis_meter_tkeep,
      m_axis_meter_tvalid => m_axis_meter_tvalid,
      m_axis_meter_tready => m_axis_meter_tready,
      m_axis_meter_tlast => m_axis_meter_tlast,
      drop_count_o => packetizer_drop_count
    );
end architecture;
