library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- AD7771 four-DOUT receiver.
--
-- The converter drives DOUT0..3 and DRDY_N synchronously to DCLK. DRDY_N is
-- low for most of the conversion interval, pulses high before the next frame,
-- and falls when the new frame starts. In the selected four-lane format each
-- lane carries two 32-bit channel words:
--
--   DOUT0: CH0, CH1    DOUT1: CH2, CH3
--   DOUT2: CH4, CH5    DOUT3: CH6, CH7
--
-- Each channel word is an 8-bit header followed by a signed 24-bit sample,
-- MSB first. The receiver emits one packed 256-bit frame with eight
-- sign-extended 32-bit samples. Sample 0 occupies bits 31 downto 0.
entity ad7771_receiver is
    port (
        adc_dclk          : in  std_logic;
        receiver_reset    : in  std_logic;
        capture_enable    : in  std_logic;
        adc_drdy_n        : in  std_logic;
        adc_dout          : in  std_logic_vector(3 downto 0);
        frame_sink_full   : in  std_logic;

        frame_data        : out std_logic_vector(255 downto 0);
        frame_valid       : out std_logic;
        receiver_busy     : out std_logic;
        frame_count       : out std_logic_vector(31 downto 0);
        overflow_count    : out std_logic_vector(31 downto 0);
        header_error_count : out std_logic_vector(31 downto 0);
        alert_count       : out std_logic_vector(31 downto 0)
    );
end entity ad7771_receiver;

architecture rtl of ad7771_receiver is
    type lane_array_t is array (0 to 3) of std_logic_vector(63 downto 0);
    type word_array_t is array (0 to 7) of std_logic_vector(31 downto 0);

    signal lane_shift           : lane_array_t := (others => (others => '0'));
    signal lane_next            : lane_array_t;
    signal bits_captured        : unsigned(5 downto 0) := (others => '0');
    signal adc_drdy_n_previous  : std_logic := '0';
    signal frame_data_next      : std_logic_vector(255 downto 0);
    signal headers_valid        : std_logic;
    signal alert_present        : std_logic;

    signal frame_data_i         : std_logic_vector(255 downto 0) := (others => '0');
    signal frame_valid_i        : std_logic := '0';
    signal receiver_busy_i      : std_logic := '0';
    signal frame_count_i        : unsigned(31 downto 0) := (others => '0');
    signal overflow_count_i     : unsigned(31 downto 0) := (others => '0');
    signal header_error_count_i : unsigned(31 downto 0) := (others => '0');
    signal alert_count_i        : unsigned(31 downto 0) := (others => '0');
begin
    frame_data         <= frame_data_i;
    frame_valid        <= frame_valid_i;
    receiver_busy      <= receiver_busy_i;
    frame_count        <= std_logic_vector(frame_count_i);
    overflow_count     <= std_logic_vector(overflow_count_i);
    header_error_count <= std_logic_vector(header_error_count_i);
    alert_count        <= std_logic_vector(alert_count_i);

    decode_frame : process(all)
        variable lane_next_v      : lane_array_t;
        variable channel_word_v   : word_array_t;
        variable frame_data_v     : std_logic_vector(255 downto 0);
        variable headers_valid_v  : std_logic;
        variable alert_present_v  : std_logic;
    begin
        for lane in 0 to 3 loop
            lane_next_v(lane) := lane_shift(lane)(62 downto 0) & adc_dout(lane);
        end loop;

        channel_word_v(0) := lane_next_v(0)(63 downto 32);
        channel_word_v(1) := lane_next_v(0)(31 downto 0);
        channel_word_v(2) := lane_next_v(1)(63 downto 32);
        channel_word_v(3) := lane_next_v(1)(31 downto 0);
        channel_word_v(4) := lane_next_v(2)(63 downto 32);
        channel_word_v(5) := lane_next_v(2)(31 downto 0);
        channel_word_v(6) := lane_next_v(3)(63 downto 32);
        channel_word_v(7) := lane_next_v(3)(31 downto 0);

        headers_valid_v := '1';
        alert_present_v := '0';
        frame_data_v := (others => '0');
        for channel in 0 to 7 loop
            if unsigned(channel_word_v(channel)(30 downto 28)) /=
               to_unsigned(channel, 3) then
                headers_valid_v := '0';
            end if;
            if channel_word_v(channel)(31) = '1' then
                alert_present_v := '1';
            end if;

            -- XPM FIFO width conversion reads the least-significant 32-bit
            -- word first, so pack CH0 in the least-significant word.
            frame_data_v(channel * 32 + 23 downto channel * 32) :=
                channel_word_v(channel)(23 downto 0);
            frame_data_v(channel * 32 + 31 downto channel * 32 + 24) :=
                (others => channel_word_v(channel)(23));
        end loop;

        lane_next       <= lane_next_v;
        frame_data_next <= frame_data_v;
        headers_valid   <= headers_valid_v;
        alert_present   <= alert_present_v;
    end process decode_frame;

    -- DOUT changes after the DCLK rising edge and is sampled on the falling
    -- edge. A DRDY high-to-low transition starts exactly one 64-bit frame.
    capture_frame : process(adc_dclk)
    begin
        if falling_edge(adc_dclk) then
            if receiver_reset = '1' then
                lane_shift           <= (others => (others => '0'));
                bits_captured        <= (others => '0');
                adc_drdy_n_previous  <= '0';
                frame_valid_i        <= '0';
                frame_data_i         <= (others => '0');
                receiver_busy_i      <= '0';
                frame_count_i        <= (others => '0');
                overflow_count_i     <= (others => '0');
                header_error_count_i <= (others => '0');
                alert_count_i        <= (others => '0');
            else
                adc_drdy_n_previous <= adc_drdy_n;
                frame_valid_i <= '0';

                if capture_enable = '0' then
                    bits_captured   <= (others => '0');
                    receiver_busy_i <= '0';
                elsif receiver_busy_i = '0' then
                    -- Detect the edge rather than the low level. DRDY_N stays
                    -- low between frames and level detection would repeatedly
                    -- deserialize the previous LSB data.
                    if adc_drdy_n_previous = '1' and adc_drdy_n = '0' then
                        for lane in 0 to 3 loop
                            lane_shift(lane) <=
                                (63 downto 1 => '0') & adc_dout(lane);
                        end loop;
                        bits_captured   <= to_unsigned(1, bits_captured'length);
                        receiver_busy_i <= '1';
                    end if;
                else
                    lane_shift <= lane_next;

                    if bits_captured = to_unsigned(63, bits_captured'length) then
                        receiver_busy_i <= '0';
                        bits_captured   <= (others => '0');
                        frame_count_i   <= frame_count_i + 1;

                        if headers_valid = '0' then
                            header_error_count_i <= header_error_count_i + 1;
                        end if;
                        if alert_present = '1' then
                            alert_count_i <= alert_count_i + 1;
                        end if;

                        if frame_sink_full = '1' then
                            overflow_count_i <= overflow_count_i + 1;
                        else
                            frame_data_i  <= frame_data_next;
                            frame_valid_i <= '1';
                        end if;
                    else
                        bits_captured <= bits_captured + 1;
                    end if;
                end if;
            end if;
        end if;
    end process capture_frame;
end architecture rtl;
