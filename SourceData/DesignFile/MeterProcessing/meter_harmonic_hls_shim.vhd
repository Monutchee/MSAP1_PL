library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library xpm;
use xpm.vcomponents.all;

-- MeterCore-owned M16 boundary.  The conditioner/frontend, context pairing,
-- HarmonicEngine packaged IP, XFFT health handling, and complete-family record
-- storage live here; only the Xilinx XFFT customization remains in the block
-- design.
entity meter_harmonic_hls_shim is
  port (
    aclk    : in std_logic;
    aresetn : in std_logic;
    config_apply_toggle_i : in std_logic;

    s_axis_context_tdata  : in  std_logic_vector(575 downto 0);
    s_axis_context_tvalid : in  std_logic;
    s_axis_context_tready : out std_logic;

    s_axis_frame_tdata  : in  std_logic_vector(167 downto 0);
    s_axis_frame_tvalid : in  std_logic;
    s_axis_frame_tready : out std_logic;
    s_axis_frame_tlast  : in  std_logic;
    s_axis_frame_fault  : in  std_logic;

    -- To the external XFFT S_AXIS_DATA.
    m_axis_fft_data_tdata  : out std_logic_vector(47 downto 0);
    m_axis_fft_data_tvalid : out std_logic;
    m_axis_fft_data_tready : in  std_logic;
    m_axis_fft_data_tlast  : out std_logic;

    -- From the external XFFT M_AXIS_DATA.
    s_axis_fft_data_tdata  : in  std_logic_vector(47 downto 0);
    s_axis_fft_data_tuser  : in  std_logic_vector(23 downto 0);
    s_axis_fft_data_tvalid : in  std_logic;
    s_axis_fft_data_tready : out std_logic;
    s_axis_fft_data_tlast  : in  std_logic;

    -- XFFT forward-transform runtime configuration and status drain.
    m_axis_fft_config_tdata  : out std_logic_vector(7 downto 0);
    m_axis_fft_config_tvalid : out std_logic;
    m_axis_fft_config_tready : in  std_logic;
    s_axis_fft_status_tdata  : in  std_logic_vector(7 downto 0);
    s_axis_fft_status_tvalid : in  std_logic;
    s_axis_fft_status_tready : out std_logic;

    xfft_event_frame_started_i       : in std_logic;
    xfft_event_tlast_unexpected_i    : in std_logic;
    xfft_event_tlast_missing_i       : in std_logic;
    xfft_event_status_channel_halt_i : in std_logic;
    xfft_event_data_in_channel_halt_i: in std_logic;
    xfft_event_data_out_channel_halt_i: in std_logic;

    m_axis_records_tdata  : out std_logic_vector(31 downto 0);
    m_axis_records_tkeep  : out std_logic_vector(3 downto 0);
    m_axis_records_tvalid : out std_logic;
    m_axis_records_tready : in  std_logic;
    m_axis_records_tlast  : out std_logic;

    -- Private CRC-protected complete-family packet to R5C1.
    m_axis_r5_harmonic_tdata  : out std_logic_vector(31 downto 0);
    m_axis_r5_harmonic_tkeep  : out std_logic_vector(3 downto 0);
    m_axis_r5_harmonic_tvalid : out std_logic;
    m_axis_r5_harmonic_tready : in  std_logic;
    m_axis_r5_harmonic_tlast  : out std_logic;

    frontend_completed_windows_o : out std_logic_vector(31 downto 0);
    frontend_dropped_windows_o   : out std_logic_vector(31 downto 0);
    frontend_malformed_windows_o : out std_logic_vector(31 downto 0);
    xfft_fault_count_o            : out std_logic_vector(31 downto 0);
    xfft_data_in_halt_count_o     : out std_logic_vector(31 downto 0);
    xfft_data_out_halt_count_o    : out std_logic_vector(31 downto 0);
    xfft_status_halt_count_o      : out std_logic_vector(31 downto 0)
  );
end entity;

architecture rtl of meter_harmonic_hls_shim is
  component meter_spectral_frontend is
    generic (
      CHANNELS     : integer := 7;
      SAMPLE_WIDTH : integer := 24;
      FFT_LENGTH   : integer := 4096;
      CONTEXT_BITS : integer := 576;
      USE_XPM      : boolean := true
    );
    port (
      aclk    : in std_logic;
      aresetn : in std_logic;
      config_apply_toggle_i : in std_logic;
      s_axis_context_tdata  : in  std_logic_vector(575 downto 0);
      s_axis_context_tvalid : in  std_logic;
      s_axis_context_tready : out std_logic;
      s_axis_frame_tdata  : in  std_logic_vector(167 downto 0);
      s_axis_frame_tvalid : in  std_logic;
      s_axis_frame_tready : out std_logic;
      s_axis_frame_tlast  : in  std_logic;
      s_axis_frame_fault  : in  std_logic;
      m_axis_context_tdata  : out std_logic_vector(575 downto 0);
      m_axis_context_tvalid : out std_logic;
      m_axis_context_tready : in  std_logic;
      m_axis_fft_tdata  : out std_logic_vector(47 downto 0);
      m_axis_fft_tvalid : out std_logic;
      m_axis_fft_tready : in  std_logic;
      m_axis_fft_tlast  : out std_logic;
      busy              : out std_logic;
      completed_windows : out std_logic_vector(31 downto 0);
      dropped_windows   : out std_logic_vector(31 downto 0);
      malformed_windows : out std_logic_vector(31 downto 0)
    );
  end component;

  component hls_harmonic_engine_ip is
    port (
      ap_clk           : in  std_logic;
      ap_rst_n         : in  std_logic;
      s_context_TDATA  : in  std_logic_vector(575 downto 0);
      s_context_TVALID : in  std_logic;
      s_context_TREADY : out std_logic;
      s_fft_TDATA      : in  std_logic_vector(47 downto 0);
      s_fft_TVALID     : in  std_logic;
      s_fft_TREADY     : out std_logic;
      s_fft_TUSER      : in  std_logic_vector(23 downto 0);
      s_fft_TLAST      : in  std_logic_vector(0 downto 0);
      m_records_TDATA  : out std_logic_vector(31 downto 0);
      m_records_TVALID : out std_logic;
      m_records_TREADY : in  std_logic;
      m_records_TKEEP  : out std_logic_vector(3 downto 0);
      m_records_TSTRB  : out std_logic_vector(3 downto 0);
      m_records_TLAST  : out std_logic_vector(0 downto 0)
    );
  end component;

  signal frontend_context_tdata  : std_logic_vector(575 downto 0);
  signal frontend_context_tvalid : std_logic;
  signal frontend_context_tready : std_logic;
  signal frontend_fft_tdata      : std_logic_vector(47 downto 0);
  signal frontend_fft_tvalid     : std_logic;
  signal frontend_fft_tready     : std_logic;
  signal frontend_fft_tlast      : std_logic;
  signal frontend_busy           : std_logic;

  signal hls_context_tready : std_logic;
  signal hls_fft_tready     : std_logic;
  signal hls_fft_tuser      : std_logic_vector(23 downto 0);
  signal hls_fft_tlast      : std_logic_vector(0 downto 0);
  signal hls_record_tdata   : std_logic_vector(31 downto 0);
  signal hls_record_tvalid  : std_logic;
  signal hls_record_tready  : std_logic;
  signal hls_record_tkeep   : std_logic_vector(3 downto 0);
  signal hls_record_tstrb   : std_logic_vector(3 downto 0);
  signal hls_record_tlast   : std_logic_vector(0 downto 0);
  signal public_record_ready       : std_logic;
  signal r5_harmonic_input_ready   : std_logic;

  signal config_valid      : std_logic := '1';
  signal fft_configured    : std_logic := '0';
  signal family_fault       : std_logic := '0';
  signal structural_fault   : std_logic;
  signal returned_channel   : unsigned(2 downto 0) := (others => '0');
  signal xfft_fault_count   : unsigned(31 downto 0) := (others => '0');
  signal data_in_halt_count : unsigned(31 downto 0) := (others => '0');
  signal data_out_halt_count: unsigned(31 downto 0) := (others => '0');
  signal status_halt_count  : unsigned(31 downto 0) := (others => '0');
  signal structural_fault_d : std_logic := '0';
  signal data_in_halt_d     : std_logic := '0';
  signal data_out_halt_d    : std_logic := '0';
  signal status_halt_d      : std_logic := '0';
begin
  frontend : meter_spectral_frontend
    port map (
      aclk => aclk,
      aresetn => aresetn,
      config_apply_toggle_i => config_apply_toggle_i,
      s_axis_context_tdata => s_axis_context_tdata,
      s_axis_context_tvalid => s_axis_context_tvalid,
      s_axis_context_tready => s_axis_context_tready,
      s_axis_frame_tdata => s_axis_frame_tdata,
      s_axis_frame_tvalid => s_axis_frame_tvalid,
      s_axis_frame_tready => s_axis_frame_tready,
      s_axis_frame_tlast => s_axis_frame_tlast,
      s_axis_frame_fault => s_axis_frame_fault,
      m_axis_context_tdata => frontend_context_tdata,
      m_axis_context_tvalid => frontend_context_tvalid,
      m_axis_context_tready => frontend_context_tready,
      m_axis_fft_tdata => frontend_fft_tdata,
      m_axis_fft_tvalid => frontend_fft_tvalid,
      m_axis_fft_tready => frontend_fft_tready,
      m_axis_fft_tlast => frontend_fft_tlast,
      busy => frontend_busy,
      completed_windows => frontend_completed_windows_o,
      dropped_windows => frontend_dropped_windows_o,
      malformed_windows => frontend_malformed_windows_o
    );

  -- XFFT configuration bit 0 is FWD_INV=1.  Hold the transfer until XFFT
  -- accepts it and do not release context/data beforehand.
  m_axis_fft_config_tdata <= x"01";
  m_axis_fft_config_tvalid <= config_valid;
  frontend_context_tready <= hls_context_tready and fft_configured;
  m_axis_fft_data_tdata <= frontend_fft_tdata;
  m_axis_fft_data_tvalid <= frontend_fft_tvalid and fft_configured;
  m_axis_fft_data_tlast <= frontend_fft_tlast;
  frontend_fft_tready <= m_axis_fft_data_tready and fft_configured;

  -- Status is deliberately drained on every cycle. BLK_EXP is carried in
  -- M_AXIS_DATA.TUSER and checked by HarmonicEngine.
  s_axis_fft_status_tready <= '1';

  -- In the non-real-time XFFT configuration, channel-halt events are normal
  -- backpressure observations: the core pauses without corrupting the frame.
  -- Only the two TLAST events describe a structural frame failure and may
  -- invalidate the harmonic family.
  structural_fault <= xfft_event_tlast_unexpected_i or
                      xfft_event_tlast_missing_i;
  hls_fft_tuser <= s_axis_fft_data_tuser(23 downto 13) &
                   (s_axis_fft_data_tuser(12) or family_fault or
                    structural_fault) &
                   s_axis_fft_data_tuser(11 downto 0);
  hls_fft_tlast(0) <= s_axis_fft_data_tlast;
  s_axis_fft_data_tready <= hls_fft_tready when fft_configured = '1' else '0';

  engine : hls_harmonic_engine_ip
    port map (
      ap_clk => aclk,
      ap_rst_n => aresetn,
      s_context_TDATA => frontend_context_tdata,
      s_context_TVALID => frontend_context_tvalid and fft_configured,
      s_context_TREADY => hls_context_tready,
      s_fft_TDATA => s_axis_fft_data_tdata,
      s_fft_TVALID => s_axis_fft_data_tvalid and fft_configured,
      s_fft_TREADY => hls_fft_tready,
      s_fft_TUSER => hls_fft_tuser,
      s_fft_TLAST => hls_fft_tlast,
      m_records_TDATA => hls_record_tdata,
      m_records_TVALID => hls_record_tvalid,
      m_records_TREADY => hls_record_tready,
      m_records_TKEEP => hls_record_tkeep,
      m_records_TSTRB => hls_record_tstrb,
      m_records_TLAST => hls_record_tlast
    );

  -- Lossless two-way fork: a HLS word transfers only when both the public
  -- fallback FIFO and the private R5 family packetizer accept that same word.
  -- The packetizer emits in ~27 us and the next 10/12-cycle family is about
  -- 200 ms away, so it is back in capture state long before the next family.
  hls_record_tready <= public_record_ready and r5_harmonic_input_ready;

  r5_harmonic_export : entity work.meter_r5_harmonic_export
    port map (
      aclk => aclk,
      aresetn => aresetn,
      s_axis_tdata => hls_record_tdata,
      s_axis_tkeep => hls_record_tkeep,
      s_axis_tvalid => hls_record_tvalid and public_record_ready,
      s_axis_tready => r5_harmonic_input_ready,
      s_axis_tlast => hls_record_tlast(0),
      m_axis_tdata => m_axis_r5_harmonic_tdata,
      m_axis_tkeep => m_axis_r5_harmonic_tkeep,
      m_axis_tvalid => m_axis_r5_harmonic_tvalid,
      m_axis_tready => m_axis_r5_harmonic_tready,
      m_axis_tlast => m_axis_r5_harmonic_tlast,
      accepted_family_count_o => open,
      transmitted_family_count_o => open,
      framing_error_count_o => open
    );

  -- A complete-family packet FIFO (4096 words > 42 records x 64 words)
  -- absorbs record-switch arbitration without stalling the HLS finalizer.
  -- Its symmetric 32-bit geometry uses one K26 UltraRAM to preserve BRAM
  -- headroom without reducing the complete-family capacity.
  record_fifo : xpm_fifo_axis
    generic map (
      CLOCKING_MODE        => "common_clock",
      FIFO_MEMORY_TYPE     => "ultra",
      CASCADE_HEIGHT       => 0,
      PACKET_FIFO          => "true",
      FIFO_DEPTH           => 4096,
      TDATA_WIDTH          => 32,
      TID_WIDTH            => 1,
      TDEST_WIDTH          => 1,
      TUSER_WIDTH          => 1,
      ECC_MODE             => "no_ecc",
      RELATED_CLOCKS       => 0,
      USE_ADV_FEATURES     => "1000",
      WR_DATA_COUNT_WIDTH  => 13,
      RD_DATA_COUNT_WIDTH  => 13,
      PROG_FULL_THRESH     => 2048,
      PROG_EMPTY_THRESH    => 10,
      SIM_ASSERT_CHK       => 1,
      EN_SIM_ASSERT_ERR    => "warning",
      CDC_SYNC_STAGES      => 2
    )
    port map (
      s_aresetn => aresetn,
      s_aclk => aclk,
      m_aclk => aclk,
      s_axis_tdata => hls_record_tdata,
      s_axis_tstrb => hls_record_tstrb,
      s_axis_tkeep => hls_record_tkeep,
      s_axis_tuser => (others => '0'),
      s_axis_tvalid => hls_record_tvalid and r5_harmonic_input_ready,
      s_axis_tready => public_record_ready,
      s_axis_tlast => hls_record_tlast(0),
      s_axis_tid => (others => '0'),
      s_axis_tdest => (others => '0'),
      m_axis_tdata => m_axis_records_tdata,
      m_axis_tstrb => open,
      m_axis_tkeep => m_axis_records_tkeep,
      m_axis_tuser => open,
      m_axis_tvalid => m_axis_records_tvalid,
      m_axis_tready => m_axis_records_tready,
      m_axis_tlast => m_axis_records_tlast,
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

  xfft_fault_count_o <= std_logic_vector(xfft_fault_count);
  xfft_data_in_halt_count_o <= std_logic_vector(data_in_halt_count);
  xfft_data_out_halt_count_o <= std_logic_vector(data_out_halt_count);
  xfft_status_halt_count_o <= std_logic_vector(status_halt_count);

  process (aclk)
  begin
    if rising_edge(aclk) then
      if aresetn = '0' then
        config_valid <= '1';
        fft_configured <= '0';
        family_fault <= '0';
        returned_channel <= (others => '0');
        xfft_fault_count <= (others => '0');
        data_in_halt_count <= (others => '0');
        data_out_halt_count <= (others => '0');
        status_halt_count <= (others => '0');
        structural_fault_d <= '0';
        data_in_halt_d <= '0';
        data_out_halt_d <= '0';
        status_halt_d <= '0';
      else
        if config_valid = '1' and m_axis_fft_config_tready = '1' then
          config_valid <= '0';
          fft_configured <= '1';
        end if;

        if structural_fault = '1' then
          family_fault <= '1';
        end if;

        -- Event outputs may remain asserted for many cycles. Count entries
        -- into each condition so diagnostics report incidents, not duration.
        if structural_fault = '1' and structural_fault_d = '0' then
          if xfft_fault_count /= x"FFFFFFFF" then
            xfft_fault_count <= xfft_fault_count + 1;
          end if;
        end if;
        if xfft_event_data_in_channel_halt_i = '1' and data_in_halt_d = '0' then
          if data_in_halt_count /= x"FFFFFFFF" then
            data_in_halt_count <= data_in_halt_count + 1;
          end if;
        end if;
        if xfft_event_data_out_channel_halt_i = '1' and data_out_halt_d = '0' then
          if data_out_halt_count /= x"FFFFFFFF" then
            data_out_halt_count <= data_out_halt_count + 1;
          end if;
        end if;
        if xfft_event_status_channel_halt_i = '1' and status_halt_d = '0' then
          if status_halt_count /= x"FFFFFFFF" then
            status_halt_count <= status_halt_count + 1;
          end if;
        end if;

        structural_fault_d <= structural_fault;
        data_in_halt_d <= xfft_event_data_in_channel_halt_i;
        data_out_halt_d <= xfft_event_data_out_channel_halt_i;
        status_halt_d <= xfft_event_status_channel_halt_i;

        if s_axis_fft_data_tvalid = '1' and hls_fft_tready = '1' and
           fft_configured = '1' and s_axis_fft_data_tlast = '1' then
          if returned_channel = 6 then
            returned_channel <= (others => '0');
            -- The current event is already injected into this final beat.
            family_fault <= '0';
          else
            returned_channel <= returned_channel + 1;
          end if;
        end if;
      end if;
    end if;
  end process;

  -- event_frame_started is observational; status contents are deliberately
  -- drained but BLK_EXP remains authoritative in every data TUSER beat.
end architecture;
