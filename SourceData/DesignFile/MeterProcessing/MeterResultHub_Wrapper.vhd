library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity MeterResultHub_Wrapper is
  port (
    aclk                    : in  std_logic;
    aresetn                 : in  std_logic;
    voltage_result_valid_i  : in  std_logic;
    result_sequence_i       : in  std_logic_vector(31 downto 0);
    config_generation_i     : in  std_logic_vector(31 downto 0);
    sample_rate_i           : in  std_logic_vector(31 downto 0);
    window_samples_i        : in  std_logic_vector(31 downto 0);
    voltage_valid_mask_i    : in  std_logic_vector(7 downto 0);
    result_status_i         : in  std_logic_vector(31 downto 0);
    voltage_mean_q16_i      : in  std_logic_vector(511 downto 0);
    voltage_rms_q16_i       : in  std_logic_vector(511 downto 0);
    voltage_rms_count_i     : in  std_logic_vector(255 downto 0);
    current_valid_mask_i    : in  std_logic_vector(7 downto 0);
    current_mean_q16_i      : in  std_logic_vector(511 downto 0);
    current_rms_q16_i       : in  std_logic_vector(511 downto 0);
    current_rms_count_i     : in  std_logic_vector(255 downto 0);
    capture_frame_count_i   : in  std_logic_vector(31 downto 0);
    capture_header_errors_i : in  std_logic_vector(31 downto 0);
    capture_overflows_i     : in  std_logic_vector(31 downto 0);
    capture_alerts_i        : in  std_logic_vector(31 downto 0);
    packetizer_drop_count_i : in  std_logic_vector(31 downto 0);
    record_data_o           : out std_logic_vector(2047 downto 0);
    record_valid_o          : out std_logic;
    record_ready_i          : in  std_logic;
    hub_drop_count_o        : out std_logic_vector(31 downto 0)
  );

  attribute X_INTERFACE_INFO : string;
  attribute X_INTERFACE_PARAMETER : string;
  attribute X_INTERFACE_INFO of aclk : signal is "xilinx.com:signal:clock:1.0 aclk CLK";
  attribute X_INTERFACE_PARAMETER of aclk : signal is
    "XIL_INTERFACENAME aclk, ASSOCIATED_RESET aresetn, FREQ_HZ 99999001";
  attribute X_INTERFACE_INFO of aresetn : signal is "xilinx.com:signal:reset:1.0 aresetn RST";
  attribute X_INTERFACE_PARAMETER of aresetn : signal is "XIL_INTERFACENAME aresetn, POLARITY ACTIVE_LOW";
end entity;

architecture rtl of MeterResultHub_Wrapper is
  signal record_data    : std_logic_vector(2047 downto 0) := (others => '0');
  signal record_valid   : std_logic := '0';
  signal hub_drop_count : unsigned(31 downto 0) := (others => '0');
begin
  record_data_o <= record_data;
  record_valid_o <= record_valid;
  hub_drop_count_o <= std_logic_vector(hub_drop_count);

  process (aclk)
    variable next_record : std_logic_vector(2047 downto 0);
    variable valid_mask  : std_logic_vector(7 downto 0);
    variable mean_q16    : signed(63 downto 0);
    variable rms_q16     : signed(63 downto 0);
    variable mean_units  : signed(63 downto 0);
    variable rms_units   : signed(63 downto 0);
    variable rms_count   : std_logic_vector(31 downto 0);
    variable word_base   : natural;
  begin
    if rising_edge(aclk) then
      if aresetn = '0' then
        record_data <= (others => '0');
        record_valid <= '0';
        hub_drop_count <= (others => '0');
      else
        if record_valid = '1' and record_ready_i = '1' then
          record_valid <= '0';
        end if;

        if voltage_result_valid_i = '1' then
          next_record := (others => '0');
          valid_mask := voltage_valid_mask_i or current_valid_mask_i;

          next_record(31 downto 0) := x"3152544D"; -- little-endian bytes "MTR1"
          next_record(63 downto 32) := x"00010001"; -- format 1, periodic meter record
          next_record(95 downto 64) := std_logic_vector(to_unsigned(256, 32));
          next_record(127 downto 96) := result_sequence_i;
          next_record(159 downto 128) := config_generation_i;
          next_record(191 downto 160) := sample_rate_i;
          next_record(223 downto 192) := window_samples_i;
          next_record(255 downto 224) := x"000000" & valid_mask;
          next_record(287 downto 256) := result_status_i;
          next_record(319 downto 288) := capture_frame_count_i;
          next_record(351 downto 320) := capture_header_errors_i;
          next_record(383 downto 352) := capture_overflows_i;
          next_record(415 downto 384) := packetizer_drop_count_i;
          next_record(447 downto 416) := std_logic_vector(hub_drop_count);
          next_record(479 downto 448) := capture_alerts_i;

          for channel_index in 0 to 7 loop
            if current_valid_mask_i(channel_index) = '1' then
              mean_q16 := signed(current_mean_q16_i(
                (channel_index * 64) + 63 downto channel_index * 64));
              rms_q16 := signed(current_rms_q16_i(
                (channel_index * 64) + 63 downto channel_index * 64));
              rms_count := current_rms_count_i(
                (channel_index * 32) + 31 downto channel_index * 32);
            else
              mean_q16 := signed(voltage_mean_q16_i(
                (channel_index * 64) + 63 downto channel_index * 64));
              rms_q16 := signed(voltage_rms_q16_i(
                (channel_index * 64) + 63 downto channel_index * 64));
              rms_count := voltage_rms_count_i(
                (channel_index * 32) + 31 downto channel_index * 32);
            end if;
            mean_units := shift_right(mean_q16, 16);
            rms_units := shift_right(rms_q16, 16);
            word_base := 16 + (channel_index * 5);
            next_record(((word_base + 0) * 32) + 31 downto
                        (word_base + 0) * 32) := std_logic_vector(mean_units(31 downto 0));
            next_record(((word_base + 1) * 32) + 31 downto
                        (word_base + 1) * 32) := std_logic_vector(mean_units(63 downto 32));
            next_record(((word_base + 2) * 32) + 31 downto
                        (word_base + 2) * 32) := rms_count;
            next_record(((word_base + 3) * 32) + 31 downto
                        (word_base + 3) * 32) := std_logic_vector(rms_units(31 downto 0));
            next_record(((word_base + 4) * 32) + 31 downto
                        (word_base + 4) * 32) := std_logic_vector(rms_units(63 downto 32));
          end loop;

          if record_valid = '1' and record_ready_i = '0' then
            hub_drop_count <= hub_drop_count + 1;
          end if;
          record_data <= next_record;
          record_valid <= '1';
        end if;
      end if;
    end if;
  end process;
end architecture;
