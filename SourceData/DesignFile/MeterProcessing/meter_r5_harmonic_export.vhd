library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library xpm;
use xpm.vcomponents.all;

use work.meter_r5_aggregation_pkg.all;
use work.meter_r5_harmonic_pkg.all;

-- Buffers one complete HARMONIC-v1 family and wraps it in a CRC-protected
-- HRM1 packet for R5C1. The family payload remains byte-exact, so R5 can apply
-- the same provenance and geometry checks as Linux without asking PL to run a
-- second spectral algorithm.
entity meter_r5_harmonic_export is
  port (
    aclk    : in std_logic;
    aresetn : in std_logic;

    s_axis_tdata  : in  std_logic_vector(31 downto 0);
    s_axis_tkeep  : in  std_logic_vector(3 downto 0);
    s_axis_tvalid : in  std_logic;
    s_axis_tready : out std_logic;
    s_axis_tlast  : in  std_logic;

    m_axis_tdata  : out std_logic_vector(31 downto 0);
    m_axis_tkeep  : out std_logic_vector(3 downto 0);
    m_axis_tvalid : out std_logic;
    m_axis_tready : in  std_logic;
    m_axis_tlast  : out std_logic;

    accepted_family_count_o    : out std_logic_vector(31 downto 0);
    transmitted_family_count_o : out std_logic_vector(31 downto 0);
    framing_error_count_o      : out std_logic_vector(31 downto 0)
  );
end entity;

architecture rtl of meter_r5_harmonic_export is
  type output_phase_t is (CAPTURE_FAMILY, OUTPUT_HEADER, OUTPUT_PAYLOAD,
                          OUTPUT_CRC);

  signal output_phase : output_phase_t := CAPTURE_FAMILY;
  signal capture_index : natural range 0 to R5_HARMONIC_PAYLOAD_WORDS - 1 := 0;
  signal header_index  : natural range 0 to R5_HARMONIC_HEADER_WORDS - 1 := 0;
  signal payload_index : natural range 0 to R5_HARMONIC_PAYLOAD_WORDS - 1 := 0;
  signal transport_sequence : std_logic_vector(31 downto 0) := (others => '0');

  signal fifo_write     : std_logic;
  signal fifo_read      : std_logic;
  signal fifo_data      : std_logic_vector(31 downto 0);
  signal fifo_full      : std_logic;
  signal fifo_empty     : std_logic;
  signal fifo_overflow  : std_logic;
  signal fifo_underflow : std_logic;
  signal fifo_wr_busy   : std_logic;
  signal fifo_rd_busy   : std_logic;

  signal input_accept : std_logic;
  signal output_word  : std_logic_vector(31 downto 0);
  signal output_valid : std_logic;
  signal output_last  : std_logic;
  signal output_accept: std_logic;
  signal crc_state    : std_logic_vector(31 downto 0) := R5_AGG_CRC_INITIAL;

  signal accepted_family_count    : unsigned(31 downto 0) := (others => '0');
  signal transmitted_family_count : unsigned(31 downto 0) := (others => '0');
  signal framing_error_count      : unsigned(31 downto 0) := (others => '0');
begin
  s_axis_tready <= '1' when output_phase = CAPTURE_FAMILY and
                            fifo_full = '0' and fifo_wr_busy = '0' else '0';
  input_accept <= s_axis_tvalid and s_axis_tready;
  fifo_write <= input_accept;

  -- One symmetric 32-bit K26 UltraRAM retains the complete-family depth while
  -- avoiding four BRAM tiles in the private HRM1 path.
  family_words : xpm_fifo_sync
    generic map (
      DOUT_RESET_VALUE    => "0", ECC_MODE => "no_ecc",
      FIFO_MEMORY_TYPE    => "ultra", FIFO_READ_LATENCY => 0,
      FIFO_WRITE_DEPTH    => 4096, FULL_RESET_VALUE => 0,
      PROG_EMPTY_THRESH   => 10, PROG_FULL_THRESH => 4000,
      RD_DATA_COUNT_WIDTH => 13, READ_DATA_WIDTH => 32,
      READ_MODE           => "fwft", SIM_ASSERT_CHK => 1,
      USE_ADV_FEATURES    => "1000", WAKEUP_TIME => 0,
      WRITE_DATA_WIDTH    => 32, WR_DATA_COUNT_WIDTH => 13)
    port map (
      sleep => '0', rst => not aresetn, wr_clk => aclk,
      wr_en => fifo_write, din => s_axis_tdata,
      full => fifo_full, overflow => fifo_overflow,
      wr_rst_busy => fifo_wr_busy,
      rd_en => fifo_read, dout => fifo_data,
      empty => fifo_empty, underflow => fifo_underflow,
      rd_rst_busy => fifo_rd_busy, data_valid => open,
      almost_empty => open, almost_full => open, prog_empty => open,
      prog_full => open, rd_data_count => open, wr_data_count => open,
      wr_ack => open, injectsbiterr => '0', injectdbiterr => '0',
      sbiterr => open, dbiterr => open);

  process (all)
  begin
    output_word <= (others => '0');
    output_valid <= '0';
    output_last <= '0';
    case output_phase is
      when CAPTURE_FAMILY =>
        null;
      when OUTPUT_HEADER =>
        output_valid <= '1';
        case header_index is
          when 0 => output_word <= R5_HARMONIC_MAGIC;
          when 1 => output_word <= R5_HARMONIC_CONTRACT_REVISION;
          when 2 => output_word <= std_logic_vector(
            to_unsigned(R5_HARMONIC_PAYLOAD_WORDS, 32));
          when others => output_word <= transport_sequence;
        end case;
      when OUTPUT_PAYLOAD =>
        output_valid <= not fifo_empty and not fifo_rd_busy;
        output_word <= fifo_data;
      when OUTPUT_CRC =>
        output_valid <= '1';
        output_word <= not crc_state;
        output_last <= '1';
    end case;
  end process;

  output_accept <= output_valid and m_axis_tready;
  fifo_read <= output_accept when output_phase = OUTPUT_PAYLOAD else '0';
  m_axis_tdata <= output_word;
  m_axis_tkeep <= (others => '1');
  m_axis_tvalid <= output_valid;
  m_axis_tlast <= output_last;

  process (aclk)
    variable expected_last : std_logic;
  begin
    if rising_edge(aclk) then
      if aresetn = '0' then
        output_phase <= CAPTURE_FAMILY;
        capture_index <= 0;
        header_index <= 0;
        payload_index <= 0;
        transport_sequence <= (others => '0');
        crc_state <= R5_AGG_CRC_INITIAL;
        accepted_family_count <= (others => '0');
        transmitted_family_count <= (others => '0');
        framing_error_count <= (others => '0');
      else
        if fifo_overflow = '1' or fifo_underflow = '1' then
          framing_error_count <= saturating_increment(framing_error_count);
        end if;

        if output_phase = CAPTURE_FAMILY and input_accept = '1' then
          if capture_index = 3 then
            transport_sequence <= s_axis_tdata;
          end if;
          if (capture_index mod R5_HARMONIC_RECORD_WORDS) =
             R5_HARMONIC_RECORD_WORDS - 1 then
            expected_last := '1';
          else
            expected_last := '0';
          end if;
          if s_axis_tkeep /= "1111" or s_axis_tlast /= expected_last then
            framing_error_count <= saturating_increment(framing_error_count);
          end if;

          if capture_index = R5_HARMONIC_PAYLOAD_WORDS - 1 then
            capture_index <= 0;
            output_phase <= OUTPUT_HEADER;
            header_index <= 0;
            payload_index <= 0;
            crc_state <= R5_AGG_CRC_INITIAL;
            accepted_family_count <=
              saturating_increment(accepted_family_count);
          else
            capture_index <= capture_index + 1;
          end if;
        elsif output_accept = '1' then
          if output_phase /= OUTPUT_CRC then
            crc_state <= crc32c_update_word(crc_state, output_word);
          end if;
          case output_phase is
            when OUTPUT_HEADER =>
              if header_index = R5_HARMONIC_HEADER_WORDS - 1 then
                output_phase <= OUTPUT_PAYLOAD;
                payload_index <= 0;
              else
                header_index <= header_index + 1;
              end if;
            when OUTPUT_PAYLOAD =>
              if payload_index = R5_HARMONIC_PAYLOAD_WORDS - 1 then
                output_phase <= OUTPUT_CRC;
              else
                payload_index <= payload_index + 1;
              end if;
            when OUTPUT_CRC =>
              output_phase <= CAPTURE_FAMILY;
              transmitted_family_count <=
                saturating_increment(transmitted_family_count);
            when others => null;
          end case;
        end if;
      end if;
    end if;
  end process;

  accepted_family_count_o <= std_logic_vector(accepted_family_count);
  transmitted_family_count_o <= std_logic_vector(transmitted_family_count);
  framing_error_count_o <= std_logic_vector(framing_error_count);
end architecture;
