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
-- the last emitted record" — the aggregation-engine register precedent, now
-- uniform for every producer.
--
-- Strictly passive: it never drives or gates the stream, so it cannot
-- create backpressure, cannot duplicate, and cannot lose a record. Words
-- captured mid-packet publish atomically on the TLAST beat, so a register
-- read never sees a torn mix of two records.
entity record_word_tap is
  generic (
    -- Format word (record word 1) whose diagnostics words 33..35 this
    -- tap republishes. Streams carry MULTIPLE record formats back to
    -- back (M8..M11); only one format on a stream owns the diagnostic
    -- map, and latching those words from its siblings would wipe the
    -- registers with payload or reserved zeros. All-zeros (the default)
    -- matches every record — the envelope words are format-invariant.
    G_DIAG_FORMAT : std_logic_vector(31 downto 0) := (others => '0');
    -- Two extra record words to republish, chosen per producer (0 =
    -- unused, which reads back zero). The PQ producer uses these for its
    -- live event state, which lives in the record's format-header word
    -- rather than the shared diagnostics slots.
    G_AUX0_WORD : natural range 0 to MEASUREMENT_RECORD_WORDS - 1 := 0;
    G_AUX1_WORD : natural range 0 to MEASUREMENT_RECORD_WORDS - 1 := 0;
    -- Aux publish gate: the aux registers refresh only on a record whose
    -- AUX0 word ANDed with this mask is non-zero. All-zeros (the default)
    -- refreshes on every record, which is what every non-PQ instance
    -- wants.
    --
    -- The PQ producer sets the kind byte (0x000000FF) so its periodic
    -- HEARTBEATS -- kind 0, and outnumbering event edges ~100:1 -- cannot
    -- wipe the live event state between a poller's reads. Gating by
    -- FORMAT (G_DIAG_FORMAT) is not enough here: three record KINDS share
    -- the one PQEVT format, so the discriminator has to be a payload
    -- value, not the format word. With the gate the register becomes a
    -- proper most-recent-EVENT latch instead of a most-recent-RECORD one.
    G_AUX_UPDATE_MASK : std_logic_vector(31 downto 0) := (others => '0')
  );
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

    -- Aux words selected by G_AUX0_WORD / G_AUX1_WORD, published with
    -- the same atomic-at-TLAST discipline as everything else.
    aux0_o : out std_logic_vector(31 downto 0);
    aux1_o : out std_logic_vector(31 downto 0);

    -- Framing watchdog: sticky flag plus counter for any TLAST not on
    -- beat 63 or any packet running past 64 beats — the DMA-ring
    -- alignment invariant made observable in silicon (ILA-friendly).
    framing_error_o       : out std_logic;
    framing_error_count_o : out std_logic_vector(31 downto 0)
  );
end entity;

architecture rtl of record_word_tap is
  signal beat_index : natural range 0 to MEASUREMENT_RECORD_WORDS - 1 := 0;
  -- Does the in-flight record own the diagnostics map? Decided at its
  -- format beat (word 1); shadows for 33..35 hold the last owning
  -- record's values through non-owning siblings, so the atomic publish
  -- at TLAST always republishes the owner's diagnostics.
  signal diag_owner : std_logic := '0';

  signal shadow_sequence     : std_logic_vector(31 downto 0) := (others => '0');
  signal shadow_status       : std_logic_vector(31 downto 0) := (others => '0');
  signal shadow_emit_drops   : std_logic_vector(31 downto 0) := (others => '0');
  signal shadow_result_drops : std_logic_vector(31 downto 0) := (others => '0');
  signal shadow_reset        : std_logic_vector(31 downto 0) := (others => '0');
  signal shadow_ineligible   : std_logic_vector(31 downto 0) := (others => '0');
  signal shadow_continuity   : std_logic_vector(31 downto 0) := (others => '0');
  signal shadow_aux0         : std_logic_vector(31 downto 0) := (others => '0');
  signal shadow_aux1         : std_logic_vector(31 downto 0) := (others => '0');

  signal published_sequence     : std_logic_vector(31 downto 0) := (others => '0');
  signal published_status       : std_logic_vector(31 downto 0) := (others => '0');
  signal published_emit_drops   : std_logic_vector(31 downto 0) := (others => '0');
  signal published_result_drops : std_logic_vector(31 downto 0) := (others => '0');
  signal published_reset        : std_logic_vector(31 downto 0) := (others => '0');
  signal published_ineligible   : std_logic_vector(31 downto 0) := (others => '0');
  signal published_continuity   : std_logic_vector(31 downto 0) := (others => '0');
  signal published_aux0         : std_logic_vector(31 downto 0) := (others => '0');
  signal published_aux1         : std_logic_vector(31 downto 0) := (others => '0');

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
  aux0_o <= published_aux0;
  aux1_o <= published_aux1;
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
        published_aux0 <= (others => '0');
        published_aux1 <= (others => '0');
        framing_error <= '0';
        framing_error_count <= (others => '0');
      elsif tvalid_i = '1' and tready_i = '1' then
        case beat_index is
          when 1 =>
            if G_DIAG_FORMAT = (G_DIAG_FORMAT'range => '0') or
               tdata_i = G_DIAG_FORMAT then
              diag_owner <= '1';
            else
              diag_owner <= '0';
            end if;
          when 3 => shadow_sequence <= tdata_i;
          when 8 => shadow_status <= tdata_i;
          when 11 => shadow_emit_drops <= tdata_i;
          when 12 => shadow_result_drops <= tdata_i;
          when 33 =>
            if diag_owner = '1' then shadow_reset <= tdata_i; end if;
          when 34 =>
            if diag_owner = '1' then shadow_ineligible <= tdata_i; end if;
          when 35 =>
            if diag_owner = '1' then shadow_continuity <= tdata_i; end if;
          when others => null;
        end case;
        if G_AUX0_WORD /= 0 and beat_index = G_AUX0_WORD then
          shadow_aux0 <= tdata_i;
        end if;
        if G_AUX1_WORD /= 0 and beat_index = G_AUX1_WORD then
          shadow_aux1 <= tdata_i;
        end if;

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
            if G_AUX_UPDATE_MASK = (G_AUX_UPDATE_MASK'range => '0') or
               (shadow_aux0 and G_AUX_UPDATE_MASK) /=
                 (G_AUX_UPDATE_MASK'range => '0') then
              published_aux0 <= shadow_aux0;
              published_aux1 <= shadow_aux1;
            end if;
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
