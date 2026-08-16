library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.measurement_record_bus_pkg.all;

-- Observational tap on one producer's 32-bit AXIS record stream.
--
-- The HLS engines carry their health counters INSIDE their records
-- (envelope words 3/8/11/12 plus the MTR2 diagnostics at 33..35 —
-- normative map: HLS_DesignFile/common/include/measurement_record.hpp).
-- This tap watches the beats of every accepted packet and republishes
-- those words to the AXI-Lite register file, so the registers read "as of
-- the last emitted record" — the CycleAggregator register precedent, now
-- uniform for every producer.
--
-- Strictly passive: it never drives or gates the stream, so it cannot
-- create backpressure, cannot duplicate, and cannot lose a record. Words
-- captured mid-packet publish atomically on the TLAST beat, so a register
-- read never sees a torn mix of two records.
entity record_word_tap is
  port (
    aclk    : in std_logic;
    aresetn : in std_logic;

    -- The tapped stream (observed, never driven).
    tdata_i  : in std_logic_vector(31 downto 0);
    tvalid_i : in std_logic;
    tready_i : in std_logic;
    tlast_i  : in std_logic;

    -- Envelope words, as of the last complete record.
    sequence_o     : out std_logic_vector(31 downto 0);  -- word 3
    status_o       : out std_logic_vector(31 downto 0);  -- word 8
    emit_drops_o   : out std_logic_vector(31 downto 0);  -- word 11
    result_drops_o : out std_logic_vector(31 downto 0);  -- word 12
    -- MTR2 diagnostics (words 33..35); zero for producers that leave the
    -- words reserved.
    reset_count_o      : out std_logic_vector(31 downto 0);
    ineligible_count_o : out std_logic_vector(31 downto 0);
    continuity_count_o : out std_logic_vector(31 downto 0);

    -- Framing watchdog: sticky flag plus counter for any TLAST not on
    -- beat 63 or any packet running past 64 beats — the DMA-ring
    -- alignment invariant made observable in silicon (ILA-friendly).
    framing_error_o       : out std_logic;
    framing_error_count_o : out std_logic_vector(31 downto 0)
  );
end entity;

architecture rtl of record_word_tap is
  signal beat_index : natural range 0 to MEASUREMENT_RECORD_WORDS - 1 := 0;

  signal shadow_sequence     : std_logic_vector(31 downto 0) := (others => '0');
  signal shadow_status       : std_logic_vector(31 downto 0) := (others => '0');
  signal shadow_emit_drops   : std_logic_vector(31 downto 0) := (others => '0');
  signal shadow_result_drops : std_logic_vector(31 downto 0) := (others => '0');
  signal shadow_reset        : std_logic_vector(31 downto 0) := (others => '0');
  signal shadow_ineligible   : std_logic_vector(31 downto 0) := (others => '0');
  signal shadow_continuity   : std_logic_vector(31 downto 0) := (others => '0');

  signal published_sequence     : std_logic_vector(31 downto 0) := (others => '0');
  signal published_status       : std_logic_vector(31 downto 0) := (others => '0');
  signal published_emit_drops   : std_logic_vector(31 downto 0) := (others => '0');
  signal published_result_drops : std_logic_vector(31 downto 0) := (others => '0');
  signal published_reset        : std_logic_vector(31 downto 0) := (others => '0');
  signal published_ineligible   : std_logic_vector(31 downto 0) := (others => '0');
  signal published_continuity   : std_logic_vector(31 downto 0) := (others => '0');

  signal framing_error       : std_logic := '0';
  signal framing_error_count : unsigned(31 downto 0) := (others => '0');
begin
  sequence_o <= published_sequence;
  status_o <= published_status;
  emit_drops_o <= published_emit_drops;
  result_drops_o <= published_result_drops;
  reset_count_o <= published_reset;
  ineligible_count_o <= published_ineligible;
  continuity_count_o <= published_continuity;
  framing_error_o <= framing_error;
  framing_error_count_o <= std_logic_vector(framing_error_count);

  process (aclk)
  begin
    if rising_edge(aclk) then
      if aresetn = '0' then
        beat_index <= 0;
        published_sequence <= (others => '0');
        published_status <= (others => '0');
        published_emit_drops <= (others => '0');
        published_result_drops <= (others => '0');
        published_reset <= (others => '0');
        published_ineligible <= (others => '0');
        published_continuity <= (others => '0');
        framing_error <= '0';
        framing_error_count <= (others => '0');
      elsif tvalid_i = '1' and tready_i = '1' then
        case beat_index is
          when 3 => shadow_sequence <= tdata_i;
          when 8 => shadow_status <= tdata_i;
          when 11 => shadow_emit_drops <= tdata_i;
          when 12 => shadow_result_drops <= tdata_i;
          when 33 => shadow_reset <= tdata_i;
          when 34 => shadow_ineligible <= tdata_i;
          when 35 => shadow_continuity <= tdata_i;
          when others => null;
        end case;

        if tlast_i = '1' then
          if beat_index = MEASUREMENT_RECORD_WORDS - 1 then
            -- Complete, well-framed record: publish atomically.
            published_sequence <= shadow_sequence;
            published_status <= shadow_status;
            published_emit_drops <= shadow_emit_drops;
            published_result_drops <= shadow_result_drops;
            published_reset <= shadow_reset;
            published_ineligible <= shadow_ineligible;
            published_continuity <= shadow_continuity;
          else
            framing_error <= '1';
            framing_error_count <= framing_error_count + 1;
          end if;
          beat_index <= 0;
        elsif beat_index = MEASUREMENT_RECORD_WORDS - 1 then
          -- Beat 64 without TLAST: a long packet would phase-shift the
          -- DMA ring permanently; flag it and resynchronize on TLAST.
          framing_error <= '1';
          framing_error_count <= framing_error_count + 1;
          beat_index <= 0;
        else
          beat_index <= beat_index + 1;
        end if;
      end if;
    end if;
  end process;
end architecture;
