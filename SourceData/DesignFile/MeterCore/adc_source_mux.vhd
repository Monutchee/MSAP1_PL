library ieee;
use ieee.std_logic_1164.all;

-- Selects exactly one raw ADC AXI4-Stream source.  Source selection is
-- changed by software only while capture is stopped; consequently no partial
-- frame can cross the boundary.  Backpressure is returned only to the active
-- source so an inactive physical receiver or simulator cannot consume data.
entity adc_source_mux is
  port (
    select_simulator_i : in std_logic;

    physical_tdata_i  : in  std_logic_vector(31 downto 0);
    physical_tkeep_i  : in  std_logic_vector(3 downto 0);
    physical_tvalid_i : in  std_logic;
    physical_tready_o : out std_logic;
    physical_tlast_i  : in  std_logic;

    simulator_tdata_i  : in  std_logic_vector(31 downto 0);
    simulator_tkeep_i  : in  std_logic_vector(3 downto 0);
    simulator_tvalid_i : in  std_logic;
    simulator_tready_o : out std_logic;
    simulator_tlast_i  : in  std_logic;

    m_axis_tdata_o  : out std_logic_vector(31 downto 0);
    m_axis_tkeep_o  : out std_logic_vector(3 downto 0);
    m_axis_tvalid_o : out std_logic;
    m_axis_tready_i : in  std_logic;
    m_axis_tlast_o  : out std_logic
  );
end entity;

architecture rtl of adc_source_mux is
begin
  physical_tready_o <= m_axis_tready_i when select_simulator_i = '0' else '0';
  simulator_tready_o <= m_axis_tready_i when select_simulator_i = '1' else '0';

  m_axis_tdata_o <= simulator_tdata_i when select_simulator_i = '1' else physical_tdata_i;
  m_axis_tkeep_o <= simulator_tkeep_i when select_simulator_i = '1' else physical_tkeep_i;
  m_axis_tvalid_o <= simulator_tvalid_i when select_simulator_i = '1' else physical_tvalid_i;
  m_axis_tlast_o <= simulator_tlast_i when select_simulator_i = '1' else physical_tlast_i;
end architecture;
