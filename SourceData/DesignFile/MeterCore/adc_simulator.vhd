library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.adc_simulator_pkg.all;

-- Raw signed-24-bit ADC source used to exercise the complete MeterCore data
-- path without physical ADC traffic.  Software supplies already-calculated
-- raw peak counts and phase offsets, keeping sensor/profile policy in Linux.
--
-- CONTROL bit 0 selects this source and bit 1 enables sample generation.
-- Shadow values are committed by writing bit 0 to APPLY.  A commit occurs
-- only between eight-channel frames, so a frame never mixes generations.
entity adc_simulator is
  generic (
    G_ACLK_HZ       : positive := 99999001;
    G_PACKET_FRAMES : positive := 256
  );
  port (
    aclk    : in std_logic;
    aresetn : in std_logic;

    s_axi_awaddr  : in  std_logic_vector(7 downto 0);
    s_axi_awvalid : in  std_logic;
    s_axi_awready : out std_logic;
    s_axi_wdata   : in  std_logic_vector(31 downto 0);
    s_axi_wstrb   : in  std_logic_vector(3 downto 0);
    s_axi_wvalid  : in  std_logic;
    s_axi_wready  : out std_logic;
    s_axi_bresp   : out std_logic_vector(1 downto 0);
    s_axi_bvalid  : out std_logic;
    s_axi_bready  : in  std_logic;
    s_axi_araddr  : in  std_logic_vector(7 downto 0);
    s_axi_arvalid : in  std_logic;
    s_axi_arready : out std_logic;
    s_axi_rdata   : out std_logic_vector(31 downto 0);
    s_axi_rresp   : out std_logic_vector(1 downto 0);
    s_axi_rvalid  : out std_logic;
    s_axi_rready  : in  std_logic;

    m_axis_tdata  : out std_logic_vector(31 downto 0);
    m_axis_tkeep  : out std_logic_vector(3 downto 0);
    m_axis_tvalid : out std_logic;
    m_axis_tready : in  std_logic;
    m_axis_tlast  : out std_logic;

    source_select_o    : out std_logic;
    frame_count_o      : out std_logic_vector(31 downto 0);
    frame_rate_hz_o    : out std_logic_vector(31 downto 0);
    frame_rate_valid_o : out std_logic;
    saturation_count_o : out std_logic_vector(31 downto 0)
  );
end entity;

architecture rtl of adc_simulator is
  type word_array_t is array (0 to 7) of std_logic_vector(31 downto 0);

  signal shadow_control     : std_logic_vector(31 downto 0) := (others => '0');
  signal shadow_sample_rate : std_logic_vector(31 downto 0) := std_logic_vector(to_unsigned(32000, 32));
  signal shadow_frequency   : std_logic_vector(31 downto 0) := std_logic_vector(to_unsigned(60000, 32));
  signal shadow_valid_mask  : std_logic_vector(7 downto 0) := x"7F";
  signal shadow_generation  : std_logic_vector(31 downto 0) := (others => '0');
  signal shadow_phase_step  : std_logic_vector(31 downto 0) := (others => '0');
  signal shadow_peak        : word_array_t := (others => (others => '0'));
  signal shadow_phase       : word_array_t := (others => (others => '0'));

  signal active_control     : std_logic_vector(31 downto 0) := (others => '0');
  signal active_sample_rate : std_logic_vector(31 downto 0) := std_logic_vector(to_unsigned(32000, 32));
  signal active_frequency   : std_logic_vector(31 downto 0) := std_logic_vector(to_unsigned(60000, 32));
  signal active_valid_mask  : std_logic_vector(7 downto 0) := x"7F";
  signal active_generation  : std_logic_vector(31 downto 0) := (others => '0');
  signal active_phase_step  : std_logic_vector(31 downto 0) := (others => '0');
  signal active_peak        : word_array_t := (others => (others => '0'));
  signal active_phase       : word_array_t := (others => (others => '0'));

  signal apply_pending : std_logic := '0';
  signal sample_accumulator : unsigned(32 downto 0) := (others => '0');
  signal sample_pending     : std_logic := '0';
  signal base_phase         : unsigned(31 downto 0) := (others => '0');
  signal channel_index      : natural range 0 to 7 := 0;
  signal packet_frame_index : natural range 0 to G_PACKET_FRAMES - 1 := 0;
  signal frame_active       : std_logic := '0';
  signal axis_data          : std_logic_vector(31 downto 0) := (others => '0');
  signal axis_valid         : std_logic := '0';
  signal axis_last          : std_logic := '0';
  signal frame_count        : unsigned(31 downto 0) := (others => '0');
  signal saturation_count   : unsigned(31 downto 0) := (others => '0');
  signal missed_sample_count : unsigned(31 downto 0) := (others => '0');

  signal aw_stored : std_logic := '0';
  signal awaddr    : std_logic_vector(7 downto 0) := (others => '0');
  signal w_stored  : std_logic := '0';
  signal wdata     : std_logic_vector(31 downto 0) := (others => '0');
  signal wstrb     : std_logic_vector(3 downto 0) := (others => '0');
  signal bvalid    : std_logic := '0';
  signal rvalid    : std_logic := '0';
  signal rdata     : std_logic_vector(31 downto 0) := (others => '0');

  function merge_strobes(
    current_value : std_logic_vector(31 downto 0);
    new_value     : std_logic_vector(31 downto 0);
    strobes       : std_logic_vector(3 downto 0)) return std_logic_vector is
    variable result : std_logic_vector(31 downto 0) := current_value;
  begin
    for byte_index in 0 to 3 loop
      if strobes(byte_index) = '1' then
        result((byte_index * 8) + 7 downto byte_index * 8) :=
          new_value((byte_index * 8) + 7 downto byte_index * 8);
      end if;
    end loop;
    return result;
  end function;
begin
  s_axi_awready <= not aw_stored;
  s_axi_wready <= not w_stored;
  s_axi_bresp <= "00";
  s_axi_bvalid <= bvalid;
  s_axi_arready <= not rvalid;
  s_axi_rresp <= "00";
  s_axi_rvalid <= rvalid;
  s_axi_rdata <= rdata;

  m_axis_tdata <= axis_data;
  m_axis_tkeep <= (others => '1');
  m_axis_tvalid <= axis_valid;
  m_axis_tlast <= axis_last;

  source_select_o <= active_control(0);
  frame_count_o <= std_logic_vector(frame_count);
  frame_rate_hz_o <= active_sample_rate;
  frame_rate_valid_o <= active_control(0) and active_control(1);
  saturation_count_o <= std_logic_vector(saturation_count);

  process (aclk)
    variable write_address : natural range 0 to 255;
    variable read_address  : natural range 0 to 255;
    variable array_index   : natural range 0 to 7;
    variable phase_value   : unsigned(31 downto 0);
    variable product       : signed(49 downto 0);
    variable scaled        : signed(49 downto 0);
    variable sample_value  : signed(31 downto 0);
    variable next_accumulator : unsigned(32 downto 0);
  begin
    if rising_edge(aclk) then
      if aresetn = '0' then
        shadow_control <= (others => '0');
        shadow_sample_rate <= std_logic_vector(to_unsigned(32000, 32));
        shadow_frequency <= std_logic_vector(to_unsigned(60000, 32));
        shadow_valid_mask <= x"7F";
        shadow_generation <= (others => '0');
        shadow_phase_step <= (others => '0');
        shadow_peak <= (others => (others => '0'));
        shadow_phase <= (others => (others => '0'));
        active_control <= (others => '0');
        active_sample_rate <= std_logic_vector(to_unsigned(32000, 32));
        active_frequency <= std_logic_vector(to_unsigned(60000, 32));
        active_valid_mask <= x"7F";
        active_generation <= (others => '0');
        active_phase_step <= (others => '0');
        active_peak <= (others => (others => '0'));
        active_phase <= (others => (others => '0'));
        apply_pending <= '0';
        sample_accumulator <= (others => '0');
        sample_pending <= '0';
        base_phase <= (others => '0');
        channel_index <= 0;
        packet_frame_index <= 0;
        frame_active <= '0';
        axis_data <= (others => '0');
        axis_valid <= '0';
        axis_last <= '0';
        frame_count <= (others => '0');
        saturation_count <= (others => '0');
        missed_sample_count <= (others => '0');
        aw_stored <= '0';
        w_stored <= '0';
        bvalid <= '0';
        rvalid <= '0';
        rdata <= (others => '0');
      else
        if s_axi_awvalid = '1' and aw_stored = '0' then
          awaddr <= s_axi_awaddr;
          aw_stored <= '1';
        end if;
        if s_axi_wvalid = '1' and w_stored = '0' then
          wdata <= s_axi_wdata;
          wstrb <= s_axi_wstrb;
          w_stored <= '1';
        end if;
        if bvalid = '1' and s_axi_bready = '1' then
          bvalid <= '0';
        end if;

        if aw_stored = '1' and w_stored = '1' and bvalid = '0' then
          write_address := to_integer(unsigned(awaddr));
          case write_address is
            when ADC_SIM_REG_SHADOW_CONTROL =>
              shadow_control <= merge_strobes(shadow_control, wdata, wstrb);
            when ADC_SIM_REG_SHADOW_SAMPLE_RATE =>
              shadow_sample_rate <= merge_strobes(shadow_sample_rate, wdata, wstrb);
            when ADC_SIM_REG_SHADOW_FREQUENCY =>
              shadow_frequency <= merge_strobes(shadow_frequency, wdata, wstrb);
            when ADC_SIM_REG_SHADOW_VALID_MASK =>
              shadow_valid_mask <= merge_strobes(x"000000" & shadow_valid_mask, wdata, wstrb)(7 downto 0);
            when ADC_SIM_REG_SHADOW_GENERATION =>
              shadow_generation <= merge_strobes(shadow_generation, wdata, wstrb);
            when ADC_SIM_REG_APPLY =>
              if wdata(0) = '1' then
                apply_pending <= '1';
              end if;
            when ADC_SIM_REG_SHADOW_PHASE_STEP =>
              shadow_phase_step <= merge_strobes(shadow_phase_step, wdata, wstrb);
            when others =>
              if write_address >= ADC_SIM_REG_SHADOW_PEAK_BASE and
                 write_address < ADC_SIM_REG_SHADOW_PEAK_BASE + 32 and
                 (write_address mod 4) = 0 then
                array_index := (write_address - ADC_SIM_REG_SHADOW_PEAK_BASE) / 4;
                shadow_peak(array_index) <= merge_strobes(shadow_peak(array_index), wdata, wstrb);
              elsif write_address >= ADC_SIM_REG_SHADOW_PHASE_BASE and
                    write_address < ADC_SIM_REG_SHADOW_PHASE_BASE + 32 and
                    (write_address mod 4) = 0 then
                array_index := (write_address - ADC_SIM_REG_SHADOW_PHASE_BASE) / 4;
                shadow_phase(array_index) <= merge_strobes(shadow_phase(array_index), wdata, wstrb);
              end if;
          end case;
          aw_stored <= '0';
          w_stored <= '0';
          bvalid <= '1';
        end if;

        if rvalid = '1' and s_axi_rready = '1' then
          rvalid <= '0';
        end if;
        if s_axi_arvalid = '1' and rvalid = '0' then
          read_address := to_integer(unsigned(s_axi_araddr));
          case read_address is
            when ADC_SIM_REG_ID => rdata <= ADC_SIMULATOR_ID;
            when ADC_SIM_REG_VERSION => rdata <= ADC_SIMULATOR_VERSION;
            when ADC_SIM_REG_SHADOW_CONTROL => rdata <= shadow_control;
            when ADC_SIM_REG_SHADOW_SAMPLE_RATE => rdata <= shadow_sample_rate;
            when ADC_SIM_REG_SHADOW_FREQUENCY => rdata <= shadow_frequency;
            when ADC_SIM_REG_SHADOW_VALID_MASK => rdata <= x"000000" & shadow_valid_mask;
            when ADC_SIM_REG_SHADOW_GENERATION => rdata <= shadow_generation;
            when ADC_SIM_REG_STATUS =>
              rdata <= (others => '0');
              rdata(0) <= active_control(0);
              rdata(1) <= active_control(1);
              rdata(2) <= apply_pending;
              if saturation_count /= 0 then
                rdata(3) <= '1';
              else
                rdata(3) <= '0';
              end if;
              if missed_sample_count /= 0 then
                rdata(4) <= '1';
              else
                rdata(4) <= '0';
              end if;
            when ADC_SIM_REG_ACTIVE_SAMPLE_RATE => rdata <= active_sample_rate;
            when ADC_SIM_REG_ACTIVE_FREQUENCY => rdata <= active_frequency;
            when ADC_SIM_REG_ACTIVE_VALID_MASK => rdata <= x"000000" & active_valid_mask;
            when ADC_SIM_REG_ACTIVE_GENERATION => rdata <= active_generation;
            when ADC_SIM_REG_FRAME_COUNT => rdata <= std_logic_vector(frame_count);
            when ADC_SIM_REG_SATURATION_COUNT => rdata <= std_logic_vector(saturation_count);
            when ADC_SIM_REG_MISSED_SAMPLE_COUNT => rdata <= std_logic_vector(missed_sample_count);
            when ADC_SIM_REG_SHADOW_PHASE_STEP => rdata <= shadow_phase_step;
            when ADC_SIM_REG_ACTIVE_CONTROL => rdata <= active_control;
            when ADC_SIM_REG_ACTIVE_PHASE_STEP => rdata <= active_phase_step;
            when others =>
              rdata <= (others => '0');
              if read_address >= ADC_SIM_REG_SHADOW_PEAK_BASE and
                 read_address < ADC_SIM_REG_SHADOW_PEAK_BASE + 32 and
                 (read_address mod 4) = 0 then
                array_index := (read_address - ADC_SIM_REG_SHADOW_PEAK_BASE) / 4;
                rdata <= shadow_peak(array_index);
              elsif read_address >= ADC_SIM_REG_SHADOW_PHASE_BASE and
                    read_address < ADC_SIM_REG_SHADOW_PHASE_BASE + 32 and
                    (read_address mod 4) = 0 then
                array_index := (read_address - ADC_SIM_REG_SHADOW_PHASE_BASE) / 4;
                rdata <= shadow_phase(array_index);
              end if;
          end case;
          rvalid <= '1';
        end if;

        -- The shadow bank crosses into active operation only at an idle frame
        -- boundary.  Clearing scheduler state makes the first generated frame
        -- deterministic after a source/configuration transaction.
        if apply_pending = '1' and frame_active = '0' and axis_valid = '0' then
          active_control <= shadow_control;
          active_sample_rate <= shadow_sample_rate;
          active_frequency <= shadow_frequency;
          active_valid_mask <= shadow_valid_mask and x"7F";
          active_generation <= shadow_generation;
          active_phase_step <= shadow_phase_step;
          active_peak <= shadow_peak;
          active_phase <= shadow_phase;
          apply_pending <= '0';
          sample_accumulator <= (others => '0');
          sample_pending <= '0';
          base_phase <= (others => '0');
          channel_index <= 0;
          packet_frame_index <= 0;
        elsif active_control(0) = '1' and active_control(1) = '1' then
          -- Advance the fractional scheduler every PL clock, including while
          -- the eight beats of the previous frame are emitted.  A one-frame
          -- pending flag absorbs normal AXI latency without biasing the
          -- requested sample rate.
          next_accumulator := sample_accumulator + resize(unsigned(active_sample_rate), 33);
          if next_accumulator >= to_unsigned(G_ACLK_HZ, 33) then
            sample_accumulator <= next_accumulator - to_unsigned(G_ACLK_HZ, 33);
            if frame_active = '0' and axis_valid = '0' then
              frame_active <= '1';
              channel_index <= 0;
            else
              if sample_pending = '1' then
                missed_sample_count <= missed_sample_count + 1;
              end if;
              sample_pending <= '1';
            end if;
          else
            sample_accumulator <= next_accumulator;
            if sample_pending = '1' and frame_active = '0' and axis_valid = '0' then
              sample_pending <= '0';
              frame_active <= '1';
              channel_index <= 0;
            end if;
          end if;

          if frame_active = '1' and axis_valid = '0' then
            if channel_index = 7 or active_valid_mask(channel_index) = '0' then
              sample_value := (others => '0');
            else
              phase_value := base_phase + unsigned(active_phase(channel_index));
              product := signed(active_peak(channel_index)) * SINE_LUT(to_integer(phase_value(31 downto 24)));
              scaled := shift_right(product, 17);
              if scaled > to_signed(8388607, scaled'length) then
                sample_value := to_signed(8388607, 32);
                saturation_count <= saturation_count + 1;
              elsif scaled < to_signed(-8388608, scaled'length) then
                sample_value := to_signed(-8388608, 32);
                saturation_count <= saturation_count + 1;
              else
                sample_value := resize(scaled, 32);
              end if;
            end if;
            axis_data <= std_logic_vector(sample_value);
            axis_last <= '1' when channel_index = 7 and
                                  packet_frame_index = G_PACKET_FRAMES - 1 else '0';
            axis_valid <= '1';
          end if;

          if axis_valid = '1' and m_axis_tready = '1' then
            axis_valid <= '0';
            axis_last <= '0';
            if channel_index = 7 then
              frame_active <= '0';
              frame_count <= frame_count + 1;
              base_phase <= base_phase + unsigned(active_phase_step);
              if packet_frame_index = G_PACKET_FRAMES - 1 then
                packet_frame_index <= 0;
              else
                packet_frame_index <= packet_frame_index + 1;
              end if;
            else
              channel_index <= channel_index + 1;
            end if;
          end if;
        else
          frame_active <= '0';
          axis_valid <= '0';
          axis_last <= '0';
          sample_accumulator <= (others => '0');
          sample_pending <= '0';
        end if;
      end if;
    end if;
  end process;
end architecture;
