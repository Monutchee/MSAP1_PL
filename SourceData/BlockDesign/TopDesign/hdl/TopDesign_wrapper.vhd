--Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
--Copyright 2022-2025 Advanced Micro Devices, Inc. All Rights Reserved.
----------------------------------------------------------------------------------
--Tool Version: Vivado v.2025.2 (lin64) Build 6299465 Fri Nov 14 12:34:56 MST 2025
--Date        : Fri Jul 17 11:25:31 2026
--Host        : mnc1 running 64-bit Ubuntu 24.04.4 LTS
--Command     : generate_target TopDesign_wrapper.bd
--Design      : TopDesign_wrapper
--Purpose     : IP block netlist
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
library UNISIM;
use UNISIM.VCOMPONENTS.ALL;
entity TopDesign_wrapper is
  port (
    ADC_CONVST_SAR : out STD_LOGIC;
    ADC_DCLK : in STD_LOGIC;
    ADC_DOUT : in STD_LOGIC_VECTOR ( 3 downto 0 );
    ADC_DRDY_N : in STD_LOGIC;
    ADC_RESET_N : out STD_LOGIC;
    ADC_START_N : out STD_LOGIC;
    EXT_ADC_SPI_io0_io : inout STD_LOGIC;
    EXT_ADC_SPI_io1_io : inout STD_LOGIC;
    EXT_ADC_SPI_sck_io : inout STD_LOGIC;
    EXT_ADC_SPI_ss_io : inout STD_LOGIC_VECTOR ( 0 to 0 );
    KR260_Fan_PWM : out STD_LOGIC_VECTOR ( 0 to 0 );
    UF1_LED : out STD_LOGIC;
    UF2_LED_tri_o : out STD_LOGIC_VECTOR ( 0 to 0 )
  );
end TopDesign_wrapper;

architecture STRUCTURE of TopDesign_wrapper is
  component TopDesign is
  port (
    UF2_LED_tri_o : out STD_LOGIC_VECTOR ( 0 to 0 );
    EXT_ADC_SPI_io0_i : in STD_LOGIC;
    EXT_ADC_SPI_io0_o : out STD_LOGIC;
    EXT_ADC_SPI_io0_t : out STD_LOGIC;
    EXT_ADC_SPI_io1_i : in STD_LOGIC;
    EXT_ADC_SPI_io1_o : out STD_LOGIC;
    EXT_ADC_SPI_io1_t : out STD_LOGIC;
    EXT_ADC_SPI_sck_i : in STD_LOGIC;
    EXT_ADC_SPI_sck_o : out STD_LOGIC;
    EXT_ADC_SPI_sck_t : out STD_LOGIC;
    EXT_ADC_SPI_ss_i : in STD_LOGIC_VECTOR ( 0 to 0 );
    EXT_ADC_SPI_ss_o : out STD_LOGIC_VECTOR ( 0 to 0 );
    EXT_ADC_SPI_ss_t : out STD_LOGIC;
    KR260_Fan_PWM : out STD_LOGIC_VECTOR ( 0 to 0 );
    UF1_LED : out STD_LOGIC;
    ADC_DCLK : in STD_LOGIC;
    ADC_CONVST_SAR : out STD_LOGIC;
    ADC_RESET_N : out STD_LOGIC;
    ADC_START_N : out STD_LOGIC;
    ADC_DRDY_N : in STD_LOGIC;
    ADC_DOUT : in STD_LOGIC_VECTOR ( 3 downto 0 )
  );
  end component TopDesign;
  component IOBUF is
  port (
    I : in STD_LOGIC;
    O : out STD_LOGIC;
    T : in STD_LOGIC;
    IO : inout STD_LOGIC
  );
  end component IOBUF;
  signal EXT_ADC_SPI_io0_i : STD_LOGIC;
  signal EXT_ADC_SPI_io0_o : STD_LOGIC;
  signal EXT_ADC_SPI_io0_t : STD_LOGIC;
  signal EXT_ADC_SPI_io1_i : STD_LOGIC;
  signal EXT_ADC_SPI_io1_o : STD_LOGIC;
  signal EXT_ADC_SPI_io1_t : STD_LOGIC;
  signal EXT_ADC_SPI_sck_i : STD_LOGIC;
  signal EXT_ADC_SPI_sck_o : STD_LOGIC;
  signal EXT_ADC_SPI_sck_t : STD_LOGIC;
  signal EXT_ADC_SPI_ss_i_0 : STD_LOGIC_VECTOR ( 0 to 0 );
  signal EXT_ADC_SPI_ss_io_0 : STD_LOGIC_VECTOR ( 0 to 0 );
  signal EXT_ADC_SPI_ss_o_0 : STD_LOGIC_VECTOR ( 0 to 0 );
  signal EXT_ADC_SPI_ss_t : STD_LOGIC;
begin
EXT_ADC_SPI_io0_iobuf: component IOBUF
     port map (
      I => EXT_ADC_SPI_io0_o,
      IO => EXT_ADC_SPI_io0_io,
      O => EXT_ADC_SPI_io0_i,
      T => EXT_ADC_SPI_io0_t
    );
EXT_ADC_SPI_io1_iobuf: component IOBUF
     port map (
      I => EXT_ADC_SPI_io1_o,
      IO => EXT_ADC_SPI_io1_io,
      O => EXT_ADC_SPI_io1_i,
      T => EXT_ADC_SPI_io1_t
    );
EXT_ADC_SPI_sck_iobuf: component IOBUF
     port map (
      I => EXT_ADC_SPI_sck_o,
      IO => EXT_ADC_SPI_sck_io,
      O => EXT_ADC_SPI_sck_i,
      T => EXT_ADC_SPI_sck_t
    );
EXT_ADC_SPI_ss_iobuf_0: component IOBUF
     port map (
      I => EXT_ADC_SPI_ss_o_0(0),
      IO => EXT_ADC_SPI_ss_io(0),
      O => EXT_ADC_SPI_ss_i_0(0),
      T => EXT_ADC_SPI_ss_t
    );
TopDesign_i: component TopDesign
     port map (
      ADC_CONVST_SAR => ADC_CONVST_SAR,
      ADC_DCLK => ADC_DCLK,
      ADC_DOUT(3 downto 0) => ADC_DOUT(3 downto 0),
      ADC_DRDY_N => ADC_DRDY_N,
      ADC_RESET_N => ADC_RESET_N,
      ADC_START_N => ADC_START_N,
      EXT_ADC_SPI_io0_i => EXT_ADC_SPI_io0_i,
      EXT_ADC_SPI_io0_o => EXT_ADC_SPI_io0_o,
      EXT_ADC_SPI_io0_t => EXT_ADC_SPI_io0_t,
      EXT_ADC_SPI_io1_i => EXT_ADC_SPI_io1_i,
      EXT_ADC_SPI_io1_o => EXT_ADC_SPI_io1_o,
      EXT_ADC_SPI_io1_t => EXT_ADC_SPI_io1_t,
      EXT_ADC_SPI_sck_i => EXT_ADC_SPI_sck_i,
      EXT_ADC_SPI_sck_o => EXT_ADC_SPI_sck_o,
      EXT_ADC_SPI_sck_t => EXT_ADC_SPI_sck_t,
      EXT_ADC_SPI_ss_i(0) => EXT_ADC_SPI_ss_i_0(0),
      EXT_ADC_SPI_ss_o(0) => EXT_ADC_SPI_ss_o_0(0),
      EXT_ADC_SPI_ss_t => EXT_ADC_SPI_ss_t,
      KR260_Fan_PWM(0) => KR260_Fan_PWM(0),
      UF1_LED => UF1_LED,
      UF2_LED_tri_o(0) => UF2_LED_tri_o(0)
    );
end STRUCTURE;
