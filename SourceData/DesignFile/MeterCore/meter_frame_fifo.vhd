library ieee;
use ieee.std_logic_1164.all;

-- Small same-clock first-word-fall-through FIFO for converted meter frames.
-- Keeping this buffer in RTL removes the AXI4-Stream Data FIFO dependency from
-- the block design while preserving the existing depth of 16 frames.
entity meter_frame_fifo is
  generic (
    DEPTH : positive := 16
  );
  port (
    aclk          : in  std_logic;
    aresetn       : in  std_logic;

    s_axis_tdata  : in  std_logic_vector(511 downto 0);
    s_axis_tkeep  : in  std_logic_vector(63 downto 0);
    s_axis_tuser  : in  std_logic_vector(383 downto 0);
    s_axis_tvalid : in  std_logic;
    s_axis_tready : out std_logic;
    s_axis_tlast  : in  std_logic;

    m_axis_tdata  : out std_logic_vector(511 downto 0);
    m_axis_tkeep  : out std_logic_vector(63 downto 0);
    m_axis_tuser  : out std_logic_vector(383 downto 0);
    m_axis_tvalid : out std_logic;
    m_axis_tready : in  std_logic;
    m_axis_tlast  : out std_logic
  );
end entity;

architecture rtl of meter_frame_fifo is
  constant FRAME_WIDTH : positive := 512 + 64 + 384 + 1;
  subtype frame_word_t is std_logic_vector(FRAME_WIDTH - 1 downto 0);
  type frame_memory_t is array (0 to DEPTH - 1) of frame_word_t;

  signal frame_memory : frame_memory_t;
  signal write_index  : natural range 0 to DEPTH - 1 := 0;
  signal read_index   : natural range 0 to DEPTH - 1 := 0;
  signal frame_count  : natural range 0 to DEPTH := 0;
  signal input_ready  : std_logic;
  signal output_valid : std_logic;
  signal output_word  : frame_word_t;

  attribute ram_style : string;
  attribute ram_style of frame_memory : signal is "distributed";
begin
  output_valid <= '1' when frame_count /= 0 else '0';

  -- A full FIFO can accept another frame in the same cycle that its current
  -- head is consumed. This keeps one frame per clock throughput.
  input_ready <= '1' when frame_count < DEPTH or
                          (output_valid = '1' and m_axis_tready = '1') else '0';

  s_axis_tready <= input_ready;
  m_axis_tvalid <= output_valid;

  output_word <= frame_memory(read_index) when frame_count /= 0 else
                 (others => '0');
  m_axis_tdata <= output_word(511 downto 0);
  m_axis_tkeep <= output_word(575 downto 512);
  m_axis_tuser <= output_word(959 downto 576);
  m_axis_tlast <= output_word(960);

  process (aclk)
    variable push : boolean;
    variable pop  : boolean;
  begin
    if rising_edge(aclk) then
      if aresetn = '0' then
        write_index <= 0;
        read_index <= 0;
        frame_count <= 0;
      else
        push := s_axis_tvalid = '1' and input_ready = '1';
        pop := output_valid = '1' and m_axis_tready = '1';

        if push then
          frame_memory(write_index) <= s_axis_tlast & s_axis_tuser &
                                       s_axis_tkeep & s_axis_tdata;
          if write_index = DEPTH - 1 then
            write_index <= 0;
          else
            write_index <= write_index + 1;
          end if;
        end if;

        if pop then
          if read_index = DEPTH - 1 then
            read_index <= 0;
          else
            read_index <= read_index + 1;
          end if;
        end if;

        if push and not pop then
          frame_count <= frame_count + 1;
        elsif pop and not push then
          frame_count <= frame_count - 1;
        end if;
      end if;
    end if;
  end process;
end architecture;
