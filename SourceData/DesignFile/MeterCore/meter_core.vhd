library ieee;
use ieee.std_logic_1164.all;

library xpm;
use xpm.vcomponents.all;

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

    m_axis_meter_tdata  : out std_logic_vector(31 downto 0);
    m_axis_meter_tkeep  : out std_logic_vector(3 downto 0);
    m_axis_meter_tvalid : out std_logic;
    m_axis_meter_tready : in  std_logic;
    m_axis_meter_tlast  : out std_logic;

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

  signal raw_stream       : axis32_stream_t;
  signal converted_source : converted_stream_t;
  signal converted_fifo   : converted_stream_t;
  signal engine_valid     : std_logic;
  signal voltage_ready    : std_logic;
  signal current_ready    : std_logic;

  signal capture_frame_count : std_logic_vector(31 downto 0);
  signal capture_overflows   : std_logic_vector(31 downto 0);
  signal capture_headers     : std_logic_vector(31 downto 0);
  signal capture_alerts      : std_logic_vector(31 downto 0);

  signal shadow_generation     : std_logic_vector(31 downto 0);
  signal shadow_sample_rate    : std_logic_vector(31 downto 0);
  signal shadow_window_samples : std_logic_vector(31 downto 0);
  signal shadow_valid_mask     : std_logic_vector(7 downto 0);
  signal shadow_enable         : std_logic;
  signal shadow_dc_remove      : std_logic;
  signal apply_toggle          : std_logic;

  signal active_generation : std_logic_vector(31 downto 0);
  signal processing_status : std_logic_vector(31 downto 0);
  signal result_valid      : std_logic;
  signal result_sequence   : std_logic_vector(31 downto 0);
  signal result_generation : std_logic_vector(31 downto 0);
  signal result_sample_rate: std_logic_vector(31 downto 0);
  signal result_window     : std_logic_vector(31 downto 0);
  signal result_status     : std_logic_vector(31 downto 0);
  signal voltage_result    : result_bundle_t;
  signal current_result    : result_bundle_t;
  signal result_drop_count : std_logic_vector(31 downto 0);

  signal record_data          : std_logic_vector(2047 downto 0);
  signal record_valid         : std_logic;
  signal record_ready         : std_logic;
  signal hub_drop_count       : std_logic_vector(31 downto 0);
  signal packetizer_drop_count: std_logic_vector(31 downto 0);
begin
  capture : entity work.ad7771_capture
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
      m_axis_tdata => raw_stream.data,
      m_axis_tkeep => raw_stream.keep,
      m_axis_tvalid => raw_stream.valid,
      m_axis_tready => raw_stream.ready,
      m_axis_tlast => raw_stream.last,
      capture_frame_count => capture_frame_count,
      capture_overflow_count => capture_overflows,
      capture_header_errors => capture_headers,
      capture_alert_count => capture_alerts,
      adc_dclk => adc_dclk,
      adc_drdy_n => adc_drdy_n,
      adc_dout => adc_dout,
      adc_reset_n => adc_reset_n,
      adc_start_n => adc_start_n,
      adc_convst_sar => adc_convst_sar
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

  -- Every branch observes each accepted frame exactly once. No calculation
  -- branch is allowed to apply backpressure independently to capture.
  converted_fifo.ready <= voltage_ready and current_ready;
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
      active_generation_i => active_generation,
      result_sequence_i => result_sequence,
      result_drop_count_i => result_drop_count,
      packet_drop_count_i => packetizer_drop_count,
      status_i => processing_status
    );

  voltage_engine : entity work.voltage_rms
    port map (
      aclk => aclk,
      aresetn => aresetn,
      s_axis_tdata => converted_fifo.data,
      s_axis_tkeep => converted_fifo.keep,
      s_axis_tuser => converted_fifo.user,
      s_axis_tvalid => engine_valid,
      s_axis_tready => voltage_ready,
      s_axis_tlast => converted_fifo.last,
      config_generation_i => shadow_generation,
      config_sample_rate_i => shadow_sample_rate,
      config_window_samples_i => shadow_window_samples,
      config_valid_mask_i => shadow_valid_mask,
      config_enable_i => shadow_enable,
      config_dc_remove_i => shadow_dc_remove,
      config_apply_toggle_i => apply_toggle,
      active_generation_o => active_generation,
      status_o => processing_status,
      result_valid_o => result_valid,
      result_sequence_o => result_sequence,
      result_generation_o => result_generation,
      result_sample_rate_o => result_sample_rate,
      result_window_samples_o => result_window,
      result_valid_mask_o => voltage_result.valid_mask,
      result_status_o => result_status,
      result_mean_q16_o => voltage_result.mean_q16,
      result_rms_q16_o => voltage_result.rms_q16,
      result_rms_count_o => voltage_result.rms_count,
      result_drop_count_o => result_drop_count
    );

  current_engine : entity work.CurrentRms_Wrapper
    port map (
      aclk => aclk,
      aresetn => aresetn,
      s_axis_converted_tdata => converted_fifo.data,
      s_axis_converted_tkeep => converted_fifo.keep,
      s_axis_converted_tuser => converted_fifo.user,
      s_axis_converted_tvalid => engine_valid,
      s_axis_converted_tready => current_ready,
      s_axis_converted_tlast => converted_fifo.last,
      current_valid_mask_o => current_result.valid_mask,
      current_mean_q16_o => current_result.mean_q16,
      current_rms_q16_o => current_result.rms_q16,
      current_rms_count_o => current_result.rms_count
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
      voltage_valid_mask_i => voltage_result.valid_mask,
      result_status_i => result_status,
      voltage_mean_q16_i => voltage_result.mean_q16,
      voltage_rms_q16_i => voltage_result.rms_q16,
      voltage_rms_count_i => voltage_result.rms_count,
      current_valid_mask_i => current_result.valid_mask,
      current_mean_q16_i => current_result.mean_q16,
      current_rms_q16_i => current_result.rms_q16,
      current_rms_count_i => current_result.rms_count,
      capture_frame_count_i => capture_frame_count,
      capture_header_errors_i => capture_headers,
      capture_overflows_i => capture_overflows,
      capture_alerts_i => capture_alerts,
      packetizer_drop_count_i => packetizer_drop_count,
      record_data_o => record_data,
      record_valid_o => record_valid,
      record_ready_i => record_ready,
      hub_drop_count_o => hub_drop_count
    );

  packetizer : entity work.MeterPacketizer_Wrapper
    port map (
      aclk => aclk,
      aresetn => aresetn,
      record_data_i => record_data,
      record_valid_i => record_valid,
      record_ready_o => record_ready,
      m_axis_meter_tdata => m_axis_meter_tdata,
      m_axis_meter_tkeep => m_axis_meter_tkeep,
      m_axis_meter_tvalid => m_axis_meter_tvalid,
      m_axis_meter_tready => m_axis_meter_tready,
      m_axis_meter_tlast => m_axis_meter_tlast,
      drop_count_o => packetizer_drop_count
    );
end architecture;
