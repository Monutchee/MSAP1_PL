library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library xpm;
use xpm.vcomponents.all;

-- Measures the external AD7771 data-clock frequency against the PL AXI clock.
--
-- A free-running binary counter advances in the DCLK domain. XPM transfers its
-- Gray-coded value into the reference domain, where successive one-second
-- snapshots are subtracted. Using a full-second window makes the counter delta
-- directly equal to hertz and avoids a divider in this diagnostic path.
entity ad7771_dclk_meter is
  generic (
    REFERENCE_CLOCK_HZ : positive := 99999001
  );
  port (
    reference_clk    : in  std_logic;
    reference_resetn : in  std_logic;
    adc_dclk         : in  std_logic;
    frequency_hz_o   : out std_logic_vector(31 downto 0);
    valid_o          : out std_logic
  );
end entity ad7771_dclk_meter;

architecture rtl of ad7771_dclk_meter is
  signal dclk_reset          : std_logic;
  signal dclk_count          : std_logic_vector(31 downto 0) := (others => '0');
  signal dclk_count_sync     : std_logic_vector(31 downto 0);
  signal reference_count     : natural range 0 to REFERENCE_CLOCK_HZ - 1 := 0;
  signal previous_snapshot   : unsigned(31 downto 0) := (others => '0');
  signal snapshot_primed     : std_logic := '0';
  signal measured_frequency  : std_logic_vector(31 downto 0) := (others => '0');
  signal measurement_valid   : std_logic := '0';
begin
  frequency_hz_o <= measured_frequency;
  valid_o <= measurement_valid;

  -- Reset is synchronized into DCLK so the source counter never receives an
  -- asynchronous reset release. If DCLK is absent, the destination naturally
  -- reports zero/invalid after its observation window.
  dclk_reset_sync : xpm_cdc_async_rst
    generic map (
      DEST_SYNC_FF    => 4,
      INIT_SYNC_FF    => 1,
      RST_ACTIVE_HIGH => 1
    )
    port map (
      src_arst  => not reference_resetn,
      dest_clk  => adc_dclk,
      dest_arst => dclk_reset
    );

  count_dclk_edges : process (adc_dclk)
  begin
    if rising_edge(adc_dclk) then
      if dclk_reset = '1' then
        dclk_count <= (others => '0');
      else
        dclk_count <= std_logic_vector(unsigned(dclk_count) + 1);
      end if;
    end if;
  end process;

  dclk_count_cdc : xpm_cdc_gray
    generic map (
      DEST_SYNC_FF   => 2,
      INIT_SYNC_FF   => 1,
      REG_OUTPUT     => 1,
      SIM_ASSERT_CHK => 1,
      SIM_LOSSLESS_GRAY_CHK => 0,
      WIDTH          => 32
    )
    port map (
      src_clk      => adc_dclk,
      src_in_bin   => dclk_count,
      dest_clk     => reference_clk,
      dest_out_bin => dclk_count_sync
    );

  measure_one_second : process (reference_clk)
    variable delta : unsigned(31 downto 0);
  begin
    if rising_edge(reference_clk) then
      if reference_resetn = '0' then
        reference_count <= 0;
        previous_snapshot <= (others => '0');
        snapshot_primed <= '0';
        measured_frequency <= (others => '0');
        measurement_valid <= '0';
      elsif reference_count = REFERENCE_CLOCK_HZ - 1 then
        reference_count <= 0;
        delta := unsigned(dclk_count_sync) - previous_snapshot;
        previous_snapshot <= unsigned(dclk_count_sync);

        -- The first window establishes a CDC-aligned baseline. Results become
        -- valid from the second window and are invalidated if DCLK disappears.
        if snapshot_primed = '1' then
          measured_frequency <= std_logic_vector(delta);
          if delta = 0 then
            measurement_valid <= '0';
          else
            measurement_valid <= '1';
          end if;
        else
          snapshot_primed <= '1';
          measurement_valid <= '0';
        end if;
      else
        reference_count <= reference_count + 1;
      end if;
    end if;
  end process;
end architecture rtl;
