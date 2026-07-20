library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library xpm;
use xpm.vcomponents.all;

entity ad7771_capture is
    port (
        s_axi_aclk       : in  std_logic;
        s_axi_aresetn    : in  std_logic;

        s_axi_awaddr     : in  std_logic_vector(7 downto 0);
        s_axi_awvalid    : in  std_logic;
        s_axi_awready    : out std_logic;
        s_axi_wdata      : in  std_logic_vector(31 downto 0);
        s_axi_wstrb      : in  std_logic_vector(3 downto 0);
        s_axi_wvalid     : in  std_logic;
        s_axi_wready     : out std_logic;
        s_axi_bresp      : out std_logic_vector(1 downto 0);
        s_axi_bvalid     : out std_logic;
        s_axi_bready     : in  std_logic;
        s_axi_araddr     : in  std_logic_vector(7 downto 0);
        s_axi_arvalid    : in  std_logic;
        s_axi_arready    : out std_logic;
        s_axi_rdata      : out std_logic_vector(31 downto 0);
        s_axi_rresp      : out std_logic_vector(1 downto 0);
        s_axi_rvalid     : out std_logic;
        s_axi_rready     : in  std_logic;

        m_axis_tdata     : out std_logic_vector(31 downto 0);
        m_axis_tkeep     : out std_logic_vector(3 downto 0);
        m_axis_tvalid    : out std_logic;
        m_axis_tready    : in  std_logic;
        m_axis_tlast     : out std_logic;

        capture_frame_count    : out std_logic_vector(31 downto 0);
        capture_overflow_count : out std_logic_vector(31 downto 0);
        capture_header_errors  : out std_logic_vector(31 downto 0);
        capture_alert_count    : out std_logic_vector(31 downto 0);

        adc_dclk         : in  std_logic;
        adc_drdy_n       : in  std_logic;
        adc_dout         : in  std_logic_vector(3 downto 0);
        adc_reset_n      : out std_logic;
        adc_start_n      : out std_logic;
        adc_convst_sar   : out std_logic
    );
end entity ad7771_capture;

architecture rtl of ad7771_capture is
    signal capture_enable          : std_logic;
    signal capture_enable_dclk     : std_logic;
    signal fifo_reset              : std_logic;
    signal packet_frames           : std_logic_vector(15 downto 0);

    signal frame_data              : std_logic_vector(255 downto 0);
    signal frame_valid             : std_logic;
    signal receiver_busy_dclk      : std_logic;
    signal receiver_busy_axi       : std_logic;
    signal frame_count_dclk        : std_logic_vector(31 downto 0);
    signal overflow_count_dclk     : std_logic_vector(31 downto 0);
    signal header_error_count_dclk : std_logic_vector(31 downto 0);
    signal alert_count_dclk        : std_logic_vector(31 downto 0);
    signal frame_count_axi         : std_logic_vector(31 downto 0);
    signal overflow_count_axi      : std_logic_vector(31 downto 0);
    signal header_error_count_axi  : std_logic_vector(31 downto 0);
    signal alert_count_axi         : std_logic_vector(31 downto 0);

    signal fifo_rst_axi            : std_logic := '1';
    signal fifo_rst_dclk           : std_logic;
    signal fifo_full               : std_logic;
    signal fifo_full_axi           : std_logic;
    signal fifo_empty              : std_logic;
    signal fifo_overflow           : std_logic;
    signal fifo_underflow          : std_logic;
    signal fifo_wr_reset_busy      : std_logic;
    signal fifo_wr_reset_busy_axi  : std_logic;
    signal fifo_rd_reset_busy      : std_logic;
    signal fifo_read_enable        : std_logic;
    signal fifo_data_out           : std_logic_vector(31 downto 0);
    signal adc_drdy_n_axi          : std_logic;

    signal fifo_prog_full          : std_logic;
    signal fifo_wr_data_count      : std_logic_vector(9 downto 0);
    signal fifo_almost_full        : std_logic;
    signal fifo_wr_ack             : std_logic;
    signal fifo_prog_empty         : std_logic;
    signal fifo_rd_data_count      : std_logic_vector(12 downto 0);
    signal fifo_almost_empty       : std_logic;
    signal fifo_data_valid         : std_logic;
    signal fifo_sbiterr            : std_logic;
    signal fifo_dbiterr            : std_logic;

    signal beat_in_packet          : unsigned(18 downto 0) := (others => '0');
    signal beats_per_packet        : unsigned(18 downto 0);
    signal packet_count_i          : unsigned(31 downto 0) := (others => '0');
    signal packet_count            : std_logic_vector(31 downto 0);
    signal m_axis_tvalid_i         : std_logic;
    signal m_axis_tlast_i          : std_logic;
    signal fifo_overflow_sticky    : std_logic;
    signal header_error_sticky     : std_logic;
    signal alert_sticky            : std_logic;
begin
    beats_per_packet <= to_unsigned(8, beats_per_packet'length)
        when unsigned(packet_frames) = 0 else
        shift_left(resize(unsigned(packet_frames), beats_per_packet'length), 3);

    packet_count <= std_logic_vector(packet_count_i);
    fifo_overflow_sticky <= '1' when unsigned(overflow_count_axi) /= 0 else '0';
    header_error_sticky  <= '1' when unsigned(header_error_count_axi) /= 0 else '0';
    alert_sticky         <= '1' when unsigned(alert_count_axi) /= 0 else '0';

    register_fifo_reset : process(s_axi_aclk)
    begin
        if rising_edge(s_axi_aclk) then
            if s_axi_aresetn = '0' then
                fifo_rst_axi <= '1';
            else
                fifo_rst_axi <= fifo_reset;
            end if;
        end if;
    end process register_fifo_reset;

    capture_enable_cdc : xpm_cdc_single
        generic map (
            DEST_SYNC_FF   => 2,
            INIT_SYNC_FF   => 1,
            SIM_ASSERT_CHK => 1,
            SRC_INPUT_REG  => 1
        )
        port map (
            src_clk  => s_axi_aclk,
            src_in   => capture_enable,
            dest_clk => adc_dclk,
            dest_out => capture_enable_dclk
        );

    -- XPM_FIFO_ASYNC requires its common reset synchronous to wr_clk.
    fifo_reset_cdc : xpm_cdc_sync_rst
        generic map (
            DEST_SYNC_FF   => 4,
            INIT           => 1,
            INIT_SYNC_FF   => 1,
            SIM_ASSERT_CHK => 1
        )
        port map (
            src_rst  => fifo_rst_axi,
            dest_clk => adc_dclk,
            dest_rst => fifo_rst_dclk
        );

    receiver : entity work.ad7771_receiver
        port map (
            adc_dclk           => adc_dclk,
            receiver_reset     => fifo_wr_reset_busy,
            capture_enable     => capture_enable_dclk,
            adc_drdy_n         => adc_drdy_n,
            adc_dout           => adc_dout,
            frame_sink_full    => fifo_full,
            frame_data         => frame_data,
            frame_valid        => frame_valid,
            receiver_busy      => receiver_busy_dclk,
            frame_count        => frame_count_dclk,
            overflow_count     => overflow_count_dclk,
            header_error_count => header_error_count_dclk,
            alert_count        => alert_count_dclk
        );

    -- One FIFO entry is one simultaneous eight-channel conversion. The FIFO
    -- performs the 256-to-32-bit width conversion and emits CH0 first.
    frame_fifo : xpm_fifo_async
        generic map (
            CDC_SYNC_STAGES     => 2,
            DOUT_RESET_VALUE    => "0",
            ECC_MODE            => "no_ecc",
            FIFO_MEMORY_TYPE    => "block",
            FIFO_READ_LATENCY   => 0,
            FIFO_WRITE_DEPTH    => 512,
            FULL_RESET_VALUE    => 0,
            READ_DATA_WIDTH     => 32,
            READ_MODE           => "fwft",
            RELATED_CLOCKS      => 0,
            SIM_ASSERT_CHK      => 1,
            USE_ADV_FEATURES    => "0000",
            WRITE_DATA_WIDTH    => 256,
            WR_DATA_COUNT_WIDTH => 10,
            RD_DATA_COUNT_WIDTH => 13
        )
        port map (
            sleep         => '0',
            rst           => fifo_rst_dclk,
            wr_clk        => adc_dclk,
            wr_en         => frame_valid,
            din           => frame_data,
            full          => fifo_full,
            prog_full     => fifo_prog_full,
            wr_data_count => fifo_wr_data_count,
            overflow      => fifo_overflow,
            wr_rst_busy   => fifo_wr_reset_busy,
            almost_full   => fifo_almost_full,
            wr_ack        => fifo_wr_ack,
            rd_clk        => s_axi_aclk,
            rd_en         => fifo_read_enable,
            dout          => fifo_data_out,
            empty         => fifo_empty,
            prog_empty    => fifo_prog_empty,
            rd_data_count => fifo_rd_data_count,
            underflow     => fifo_underflow,
            rd_rst_busy   => fifo_rd_reset_busy,
            almost_empty  => fifo_almost_empty,
            data_valid    => fifo_data_valid,
            injectsbiterr => '0',
            injectdbiterr => '0',
            sbiterr       => fifo_sbiterr,
            dbiterr       => fifo_dbiterr
        );

    m_axis_tdata    <= fifo_data_out;
    m_axis_tkeep    <= "1111";
    m_axis_tvalid_i <= not fifo_empty and not fifo_rd_reset_busy and not fifo_reset;
    m_axis_tlast_i  <= '1' when
        m_axis_tvalid_i = '1' and beat_in_packet = beats_per_packet - 1 else '0';
    fifo_read_enable <= m_axis_tvalid_i and m_axis_tready;
    m_axis_tvalid <= m_axis_tvalid_i;
    m_axis_tlast  <= m_axis_tlast_i;
    capture_frame_count    <= frame_count_axi;
    capture_overflow_count <= overflow_count_axi;
    capture_header_errors  <= header_error_count_axi;
    capture_alert_count    <= alert_count_axi;

    count_stream_packets : process(s_axi_aclk)
    begin
        if rising_edge(s_axi_aclk) then
            if s_axi_aresetn = '0' or fifo_reset = '1' or
               fifo_rd_reset_busy = '1' then
                beat_in_packet <= (others => '0');
                packet_count_i <= (others => '0');
            elsif fifo_read_enable = '1' then
                if m_axis_tlast_i = '1' then
                    beat_in_packet <= (others => '0');
                    packet_count_i <= packet_count_i + 1;
                else
                    beat_in_packet <= beat_in_packet + 1;
                end if;
            end if;
        end if;
    end process count_stream_packets;

    frame_count_cdc : xpm_cdc_gray
        generic map (DEST_SYNC_FF => 2, INIT_SYNC_FF => 1, WIDTH => 32)
        port map (
            src_clk => adc_dclk, src_in_bin => frame_count_dclk,
            dest_clk => s_axi_aclk, dest_out_bin => frame_count_axi);

    overflow_count_cdc : xpm_cdc_gray
        generic map (DEST_SYNC_FF => 2, INIT_SYNC_FF => 1, WIDTH => 32)
        port map (
            src_clk => adc_dclk, src_in_bin => overflow_count_dclk,
            dest_clk => s_axi_aclk, dest_out_bin => overflow_count_axi);

    header_error_count_cdc : xpm_cdc_gray
        generic map (DEST_SYNC_FF => 2, INIT_SYNC_FF => 1, WIDTH => 32)
        port map (
            src_clk => adc_dclk, src_in_bin => header_error_count_dclk,
            dest_clk => s_axi_aclk, dest_out_bin => header_error_count_axi);

    alert_count_cdc : xpm_cdc_gray
        generic map (DEST_SYNC_FF => 2, INIT_SYNC_FF => 1, WIDTH => 32)
        port map (
            src_clk => adc_dclk, src_in_bin => alert_count_dclk,
            dest_clk => s_axi_aclk, dest_out_bin => alert_count_axi);

    receiver_busy_cdc : xpm_cdc_single
        generic map (DEST_SYNC_FF => 2, INIT_SYNC_FF => 1, SRC_INPUT_REG => 1)
        port map (
            src_clk => adc_dclk, src_in => receiver_busy_dclk,
            dest_clk => s_axi_aclk, dest_out => receiver_busy_axi);

    fifo_full_cdc : xpm_cdc_single
        generic map (DEST_SYNC_FF => 2, INIT_SYNC_FF => 1, SRC_INPUT_REG => 1)
        port map (
            src_clk => adc_dclk, src_in => fifo_full,
            dest_clk => s_axi_aclk, dest_out => fifo_full_axi);

    fifo_wr_busy_cdc : xpm_cdc_single
        generic map (DEST_SYNC_FF => 2, INIT_SYNC_FF => 1, SRC_INPUT_REG => 1)
        port map (
            src_clk => adc_dclk, src_in => fifo_wr_reset_busy,
            dest_clk => s_axi_aclk, dest_out => fifo_wr_reset_busy_axi);

    adc_drdy_cdc : xpm_cdc_single
        generic map (DEST_SYNC_FF => 2, INIT_SYNC_FF => 1, SRC_INPUT_REG => 1)
        port map (
            src_clk => adc_dclk, src_in => adc_drdy_n,
            dest_clk => s_axi_aclk, dest_out => adc_drdy_n_axi);

    registers : entity work.ad7771_axi_regs
        port map (
            s_axi_aclk       => s_axi_aclk,
            s_axi_aresetn    => s_axi_aresetn,
            s_axi_awaddr     => s_axi_awaddr,
            s_axi_awvalid    => s_axi_awvalid,
            s_axi_awready    => s_axi_awready,
            s_axi_wdata      => s_axi_wdata,
            s_axi_wstrb      => s_axi_wstrb,
            s_axi_wvalid     => s_axi_wvalid,
            s_axi_wready     => s_axi_wready,
            s_axi_bresp      => s_axi_bresp,
            s_axi_bvalid     => s_axi_bvalid,
            s_axi_bready     => s_axi_bready,
            s_axi_araddr     => s_axi_araddr,
            s_axi_arvalid    => s_axi_arvalid,
            s_axi_arready    => s_axi_arready,
            s_axi_rdata      => s_axi_rdata,
            s_axi_rresp      => s_axi_rresp,
            s_axi_rvalid     => s_axi_rvalid,
            s_axi_rready     => s_axi_rready,
            capture_enable   => capture_enable,
            fifo_reset       => fifo_reset,
            adc_reset_n      => adc_reset_n,
            adc_start_n      => adc_start_n,
            adc_convst_sar   => adc_convst_sar,
            packet_frames    => packet_frames,
            receiver_busy        => receiver_busy_axi,
            fifo_full            => fifo_full_axi,
            fifo_empty           => fifo_empty,
            fifo_overflow_sticky => fifo_overflow_sticky,
            header_error_sticky  => header_error_sticky,
            alert_sticky         => alert_sticky,
            adc_drdy_n           => adc_drdy_n_axi,
            fifo_wr_reset_busy   => fifo_wr_reset_busy_axi,
            fifo_rd_reset_busy   => fifo_rd_reset_busy,
            frame_count          => frame_count_axi,
            overflow_count       => overflow_count_axi,
            header_error_count   => header_error_count_axi,
            alert_count          => alert_count_axi,
            packet_count         => packet_count
        );
end architecture rtl;
