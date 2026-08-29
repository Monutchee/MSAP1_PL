library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library xpm;
use xpm.vcomponents.all;

use work.meter_r5_aggregation_pkg.all;

-- Nonblocking packetizer for the bounded M18 sufficient-statistic streams.
-- The source presents one fixed-size payload. At payload word zero this block
-- either reserves capacity for the entire packet or consumes/discards the
-- entire payload. Downstream R5 congestion can therefore never backpressure a
-- metrology engine after its packet has begun.
entity meter_r5_fixed_packet_export is
  generic (
    G_MAGIC            : std_logic_vector(31 downto 0);
    G_PAYLOAD_WORDS    : positive;
    G_FIFO_DEPTH       : positive := 512;
    G_FIFO_COUNT_WIDTH : positive := 10;
    G_PACKET_SLOTS     : positive := 4
  );
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

    accepted_packet_count_o    : out std_logic_vector(31 downto 0);
    dropped_packet_count_o     : out std_logic_vector(31 downto 0);
    transmitted_packet_count_o : out std_logic_vector(31 downto 0);
    framing_error_count_o      : out std_logic_vector(31 downto 0)
  );
end entity;

architecture rtl of meter_r5_fixed_packet_export is
  type output_phase_t is (OUTPUT_IDLE, OUTPUT_HEADER, OUTPUT_PAYLOAD,
                          OUTPUT_CRC);

  signal input_index    : natural range 0 to G_PAYLOAD_WORDS - 1 := 0;
  signal capture_packet : std_logic := '0';
  signal reserve_packet : std_logic;
  signal capture_word   : std_logic;
  signal input_accept   : std_logic;

  signal fifo_write     : std_logic;
  signal fifo_read      : std_logic;
  signal fifo_data      : std_logic_vector(31 downto 0);
  signal fifo_full      : std_logic;
  signal fifo_empty     : std_logic;
  signal fifo_overflow  : std_logic;
  signal fifo_underflow : std_logic;
  signal fifo_wr_busy   : std_logic;
  signal fifo_rd_busy   : std_logic;
  signal fifo_count     : std_logic_vector(G_FIFO_COUNT_WIDTH - 1 downto 0);

  signal complete_packet_count : natural range 0 to G_PACKET_SLOTS := 0;
  signal reserved_packet_count : natural range 0 to G_PACKET_SLOTS := 0;

  signal output_phase        : output_phase_t := OUTPUT_IDLE;
  signal output_header_index : natural range 0 to 3 := 0;
  signal output_payload_index: natural range 0 to G_PAYLOAD_WORDS - 1 := 0;
  signal output_word         : std_logic_vector(31 downto 0);
  signal output_valid        : std_logic;
  signal output_last         : std_logic;
  signal output_accept       : std_logic;
  signal crc_state           : std_logic_vector(31 downto 0) :=
    R5_AGG_CRC_INITIAL;

  signal accepted_packet_count    : unsigned(31 downto 0) := (others => '0');
  signal dropped_packet_count     : unsigned(31 downto 0) := (others => '0');
  signal transmitted_packet_count : unsigned(31 downto 0) := (others => '0');
  signal framing_error_count      : unsigned(31 downto 0) := (others => '0');
begin
  assert G_FIFO_DEPTH >= G_PAYLOAD_WORDS * G_PACKET_SLOTS
    report "fixed packet FIFO cannot reserve every packet slot"
    severity failure;

  reserve_packet <= '1' when
    reserved_packet_count < G_PACKET_SLOTS and
    unsigned(fifo_count) <= to_unsigned(G_FIFO_DEPTH - G_PAYLOAD_WORDS,
                                        fifo_count'length) and
    fifo_full = '0' and fifo_wr_busy = '0' else '0';

  -- Always consume an offered payload. Capacity is decided only at its first
  -- word, so an R5 stall cannot propagate into the HLS engine mid-payload.
  s_axis_tready <= aresetn;
  input_accept <= s_axis_tvalid and s_axis_tready;
  capture_word <= reserve_packet when input_index = 0 else capture_packet;
  fifo_write <= input_accept and capture_word;

  payload_fifo : xpm_fifo_sync
    generic map (
      DOUT_RESET_VALUE => "0", ECC_MODE => "no_ecc",
      FIFO_MEMORY_TYPE => "auto", FIFO_READ_LATENCY => 0,
      FIFO_WRITE_DEPTH => G_FIFO_DEPTH, FULL_RESET_VALUE => 0,
      PROG_EMPTY_THRESH => 2, PROG_FULL_THRESH => G_FIFO_DEPTH - 2,
      RD_DATA_COUNT_WIDTH => G_FIFO_COUNT_WIDTH, READ_DATA_WIDTH => 32,
      READ_MODE => "fwft", SIM_ASSERT_CHK => 1,
      USE_ADV_FEATURES => "1000", WAKEUP_TIME => 0,
      WRITE_DATA_WIDTH => 32, WR_DATA_COUNT_WIDTH => G_FIFO_COUNT_WIDTH)
    port map (
      sleep => '0', rst => not aresetn, wr_clk => aclk,
      wr_en => fifo_write, din => s_axis_tdata,
      full => fifo_full, overflow => fifo_overflow,
      wr_rst_busy => fifo_wr_busy,
      rd_en => fifo_read, dout => fifo_data,
      empty => fifo_empty, underflow => fifo_underflow,
      rd_rst_busy => fifo_rd_busy, data_valid => open,
      almost_empty => open, almost_full => open, prog_empty => open,
      prog_full => open, rd_data_count => open, wr_data_count => fifo_count,
      wr_ack => open, injectsbiterr => '0', injectdbiterr => '0',
      sbiterr => open, dbiterr => open);

  process (all)
  begin
    output_word <= (others => '0');
    output_valid <= '0';
    output_last <= '0';
    case output_phase is
      when OUTPUT_IDLE =>
        null;
      when OUTPUT_HEADER =>
        output_valid <= '1';
        case output_header_index is
          when 0 => output_word <= G_MAGIC;
          when 1 => output_word <= x"00000001";
          when 2 => output_word <= std_logic_vector(
            to_unsigned(G_PAYLOAD_WORDS, 32));
          when others => output_word <= fifo_data;
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
    variable complete_next : natural range 0 to G_PACKET_SLOTS;
    variable reserved_next : natural range 0 to G_PACKET_SLOTS;
  begin
    if rising_edge(aclk) then
      if aresetn = '0' then
        input_index <= 0;
        capture_packet <= '0';
        complete_packet_count <= 0;
        reserved_packet_count <= 0;
        output_phase <= OUTPUT_IDLE;
        output_header_index <= 0;
        output_payload_index <= 0;
        crc_state <= R5_AGG_CRC_INITIAL;
        accepted_packet_count <= (others => '0');
        dropped_packet_count <= (others => '0');
        transmitted_packet_count <= (others => '0');
        framing_error_count <= (others => '0');
      else
        complete_next := complete_packet_count;
        reserved_next := reserved_packet_count;

        if fifo_overflow = '1' or fifo_underflow = '1' then
          framing_error_count <= saturating_increment(framing_error_count);
        end if;

        if input_accept = '1' then
          if input_index = G_PAYLOAD_WORDS - 1 then
            expected_last := '1';
          else
            expected_last := '0';
          end if;
          if s_axis_tkeep /= "1111" or s_axis_tlast /= expected_last then
            framing_error_count <= saturating_increment(framing_error_count);
          end if;

          if input_index = 0 then
            capture_packet <= reserve_packet;
            if reserve_packet = '1' then
              reserved_next := reserved_next + 1;
              accepted_packet_count <=
                saturating_increment(accepted_packet_count);
            end if;
          end if;

          if input_index = G_PAYLOAD_WORDS - 1 then
            input_index <= 0;
            capture_packet <= '0';
            if capture_word = '1' then
              complete_next := complete_next + 1;
            else
              dropped_packet_count <=
                saturating_increment(dropped_packet_count);
            end if;
          else
            input_index <= input_index + 1;
          end if;
        end if;

        case output_phase is
          when OUTPUT_IDLE =>
            if complete_packet_count /= 0 then
              complete_next := complete_next - 1;
              output_phase <= OUTPUT_HEADER;
              output_header_index <= 0;
              output_payload_index <= 0;
              crc_state <= R5_AGG_CRC_INITIAL;
            end if;
          when OUTPUT_HEADER =>
            if output_accept = '1' then
              crc_state <= crc32c_update_word(crc_state, output_word);
              if output_header_index = 3 then
                output_phase <= OUTPUT_PAYLOAD;
                output_payload_index <= 0;
              else
                output_header_index <= output_header_index + 1;
              end if;
            end if;
          when OUTPUT_PAYLOAD =>
            if output_accept = '1' then
              crc_state <= crc32c_update_word(crc_state, output_word);
              if output_payload_index = G_PAYLOAD_WORDS - 1 then
                output_phase <= OUTPUT_CRC;
              else
                output_payload_index <= output_payload_index + 1;
              end if;
            end if;
          when OUTPUT_CRC =>
            if output_accept = '1' then
              output_phase <= OUTPUT_IDLE;
              reserved_next := reserved_next - 1;
              transmitted_packet_count <=
                saturating_increment(transmitted_packet_count);
            end if;
        end case;

        complete_packet_count <= complete_next;
        reserved_packet_count <= reserved_next;
      end if;
    end if;
  end process;

  accepted_packet_count_o <= std_logic_vector(accepted_packet_count);
  dropped_packet_count_o <= std_logic_vector(dropped_packet_count);
  transmitted_packet_count_o <= std_logic_vector(transmitted_packet_count);
  framing_error_count_o <= std_logic_vector(framing_error_count);
end architecture;
