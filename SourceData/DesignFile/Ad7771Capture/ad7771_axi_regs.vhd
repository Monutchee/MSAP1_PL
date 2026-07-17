library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity ad7771_axi_regs is
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

        capture_enable   : out std_logic;
        fifo_reset       : out std_logic;
        adc_reset_n      : out std_logic;
        adc_start_n      : out std_logic;
        adc_convst_sar   : out std_logic;
        packet_frames    : out std_logic_vector(15 downto 0);

        receiver_busy        : in std_logic;
        fifo_full            : in std_logic;
        fifo_empty           : in std_logic;
        fifo_overflow_sticky : in std_logic;
        header_error_sticky  : in std_logic;
        alert_sticky         : in std_logic;
        adc_drdy_n           : in std_logic;
        fifo_wr_reset_busy   : in std_logic;
        fifo_rd_reset_busy   : in std_logic;
        frame_count          : in std_logic_vector(31 downto 0);
        overflow_count       : in std_logic_vector(31 downto 0);
        header_error_count   : in std_logic_vector(31 downto 0);
        alert_count          : in std_logic_vector(31 downto 0);
        packet_count         : in std_logic_vector(31 downto 0)
    );
end entity ad7771_axi_regs;

architecture rtl of ad7771_axi_regs is
    constant VERSION       : std_logic_vector(31 downto 0) := x"00010000";
    constant IDENTIFIER    : std_logic_vector(31 downto 0) := x"41443731"; -- "AD71"
    -- START is a positive synchronization pulse. Normal synchronization uses
    -- the AD7771 SPI_SYNC bit, so START remains low after reset.
    constant CONTROL_RESET : std_logic_vector(31 downto 0) := x"00000002";

    signal control_reg       : std_logic_vector(31 downto 0) := CONTROL_RESET;
    signal packet_frames_reg : std_logic_vector(31 downto 0) := x"00000100";
    signal read_data_mux     : std_logic_vector(31 downto 0);
    signal s_axi_awready_i   : std_logic;
    signal s_axi_wready_i    : std_logic;
    signal s_axi_bvalid_i    : std_logic := '0';
    signal s_axi_arready_i   : std_logic;
    signal s_axi_rdata_i     : std_logic_vector(31 downto 0) := (others => '0');
    signal s_axi_rvalid_i    : std_logic := '0';
    signal write_fire        : std_logic;
    signal read_fire         : std_logic;

    function apply_write_strobes(
        old_value : std_logic_vector(31 downto 0);
        new_value : std_logic_vector(31 downto 0);
        strobes   : std_logic_vector(3 downto 0)
    ) return std_logic_vector is
        variable result : std_logic_vector(31 downto 0) := old_value;
    begin
        for byte_index in 0 to 3 loop
            if strobes(byte_index) = '1' then
                result(byte_index * 8 + 7 downto byte_index * 8) :=
                    new_value(byte_index * 8 + 7 downto byte_index * 8);
            end if;
        end loop;
        return result;
    end function apply_write_strobes;
begin
    capture_enable <= control_reg(0);
    fifo_reset     <= control_reg(1);
    adc_reset_n    <= control_reg(2);
    adc_start_n    <= control_reg(3);
    adc_convst_sar <= control_reg(4);
    packet_frames  <= packet_frames_reg(15 downto 0);

    s_axi_awready_i <= '1' when
        s_axi_aresetn = '1' and s_axi_bvalid_i = '0' and
        s_axi_awvalid = '1' and s_axi_wvalid = '1' else '0';
    s_axi_wready_i <= '1' when
        s_axi_aresetn = '1' and s_axi_bvalid_i = '0' and
        s_axi_awvalid = '1' and s_axi_wvalid = '1' else '0';
    write_fire <= s_axi_awready_i and s_axi_awvalid and
                  s_axi_wready_i and s_axi_wvalid;

    s_axi_awready <= s_axi_awready_i;
    s_axi_wready  <= s_axi_wready_i;
    s_axi_bvalid  <= s_axi_bvalid_i;
    s_axi_bresp   <= "00";

    write_registers : process(s_axi_aclk)
    begin
        if rising_edge(s_axi_aclk) then
            if s_axi_aresetn = '0' then
                control_reg       <= CONTROL_RESET;
                packet_frames_reg <= x"00000100";
                s_axi_bvalid_i    <= '0';
            else
                if write_fire = '1' then
                    case s_axi_awaddr(7 downto 2) is
                        when "000001" =>
                            control_reg <= apply_write_strobes(
                                control_reg, s_axi_wdata, s_axi_wstrb);
                        when "000010" =>
                            packet_frames_reg <= apply_write_strobes(
                                packet_frames_reg, s_axi_wdata, s_axi_wstrb);
                        when others =>
                            null;
                    end case;
                    s_axi_bvalid_i <= '1';
                elsif s_axi_bvalid_i = '1' and s_axi_bready = '1' then
                    s_axi_bvalid_i <= '0';
                end if;
            end if;
        end if;
    end process write_registers;

    s_axi_arready_i <= '1' when
        s_axi_aresetn = '1' and s_axi_rvalid_i = '0' else '0';
    read_fire <= s_axi_arready_i and s_axi_arvalid;

    s_axi_arready <= s_axi_arready_i;
    s_axi_rdata   <= s_axi_rdata_i;
    s_axi_rvalid  <= s_axi_rvalid_i;
    s_axi_rresp   <= "00";

    read_decode : process(all)
    begin
        case s_axi_araddr(7 downto 2) is
            when "000000" => read_data_mux <= VERSION;
            when "000001" => read_data_mux <= control_reg;
            when "000010" => read_data_mux <= packet_frames_reg;
            when "000011" =>
                read_data_mux <=
                    (31 downto 10 => '0') &
                    fifo_rd_reset_busy & fifo_wr_reset_busy & adc_drdy_n &
                    alert_sticky & header_error_sticky & fifo_overflow_sticky &
                    fifo_empty & fifo_full & receiver_busy & control_reg(0);
            when "000100" => read_data_mux <= frame_count;
            when "000101" => read_data_mux <= overflow_count;
            when "000110" => read_data_mux <= header_error_count;
            when "000111" => read_data_mux <= alert_count;
            when "001000" => read_data_mux <= packet_count;
            when "001001" => read_data_mux <= x"00080420";
            when "001010" => read_data_mux <= IDENTIFIER;
            when others   => read_data_mux <= (others => '0');
        end case;
    end process read_decode;

    read_registers : process(s_axi_aclk)
    begin
        if rising_edge(s_axi_aclk) then
            if s_axi_aresetn = '0' then
                s_axi_rdata_i  <= (others => '0');
                s_axi_rvalid_i <= '0';
            else
                if read_fire = '1' then
                    s_axi_rdata_i  <= read_data_mux;
                    s_axi_rvalid_i <= '1';
                elsif s_axi_rvalid_i = '1' and s_axi_rready = '1' then
                    s_axi_rvalid_i <= '0';
                end if;
            end if;
        end if;
    end process read_registers;
end architecture rtl;
