library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.metering_pkg.all;
use work.grid_timing_pkg.all;

-- Grid-cycle timing for IEC 61000-4-30 basic measurement blocks.
--
-- This block is a pure observer of the accepted converted-frame stream: it
-- has no ready output and can never backpressure ADC capture, RMS, or the
-- frequency engine. It consumes the combinational crossing view of the one
-- shared zero-crossing detector (inside meter_frequency) instead of
-- duplicating the detector.
--
-- Block generation, evaluated on every accepted frame:
--   * locked: a qualified rising crossing that completes the configured
--     cycle count (10 at 50 Hz, 12 at 60 Hz) closes the block. The crossing
--     frame is the LAST frame of the closing block, so the next block starts
--     at exactly first + count: blocks are gapless by construction.
--   * unlocked (reference unusable or crossings stale): blocks close on the
--     configured fallback sample-count window so records keep flowing, and
--     the very next qualified crossing closes the running block early to
--     re-align cycle counting. Such blocks are flagged free_run_fallback.
--
-- frame_closes_block_o is combinational and valid during frame_accept_i.
-- The RMS engine registers it alongside the frame itself, so both modules
-- always agree on exactly which frames belong to which block regardless of
-- their internal pipeline depths.
--
-- Configuration commits on the shared processing APPLY toggle, so a block
-- can never span two configuration generations.
entity grid_cycle_timing is
  port (
    aclk    : in std_logic;
    aresetn : in std_logic;

    -- Accepted-frame observation, aligned with the RMS engine input.
    frame_accept_i        : in std_logic;
    sample_index_low_i    : in std_logic_vector(31 downto 0);
    sample_index_high_i   : in std_logic_vector(31 downto 0);

    -- Combinational crossing view from the shared detector, valid during
    -- frame_accept_i.
    rising_crossing_i     : in std_logic;
    falling_crossing_i    : in std_logic;
    reference_valid_i     : in std_logic;

    -- Shadow configuration and the shared APPLY toggle.
    config_grid_i           : in std_logic_vector(31 downto 0);
    config_window_samples_i : in std_logic_vector(31 downto 0);
    config_apply_toggle_i   : in std_logic;

    -- Software-visible readback and status.
    active_grid_o : out std_logic_vector(31 downto 0);
    status_o      : out std_logic_vector(31 downto 0);

    -- Block-close marker for the RMS engine (combinational, see above) and
    -- the active cycle-timing enable it must obey.
    frame_closes_block_o : out std_logic;
    cycle_mode_o         : out std_logic;

    -- Registered timing strobes, one aclk after the crossing frame. Nothing
    -- consumes these yet; a future PQ event engine will.
    cycle_boundary_o      : out std_logic;
    half_cycle_boundary_o : out std_logic;
    cycle_sequence_o      : out std_logic_vector(31 downto 0);

    -- Provenance of the most recently closed block. Stable from the close
    -- until the next close, which comfortably covers the RMS calculation
    -- latency before the result hub samples these values.
    block_first_sample_o : out std_logic_vector(63 downto 0);
    block_cycle_count_o  : out std_logic_vector(7 downto 0);
    block_nominal_hz_o   : out std_logic_vector(7 downto 0);
    block_flags_o        : out std_logic_vector(2 downto 0)
  );
end entity;

architecture rtl of grid_cycle_timing is
  signal apply_seen        : std_logic := '0';
  signal active_enable     : std_logic := '1';
  signal active_cycles     : unsigned(7 downto 0) :=
    to_unsigned(GRID_CYCLES_60HZ, 8);
  signal active_nominal    : unsigned(7 downto 0) := to_unsigned(60, 8);
  signal active_window     : unsigned(31 downto 0) := to_unsigned(6400, 32);

  signal locked                 : std_logic := '0';
  signal reference_seen         : std_logic := '0';
  signal cycles_in_block        : unsigned(7 downto 0) := (others => '0');
  signal samples_in_block       : unsigned(31 downto 0) := (others => '0');
  signal samples_since_crossing : unsigned(31 downto 0) := (others => '0');
  signal cycle_sequence         : unsigned(31 downto 0) := (others => '0');
  signal current_first_sample   : unsigned(63 downto 0) := (others => '0');
  signal block_start_pending    : std_logic := '1';
  signal first_block_flag       : std_logic := '1';

  signal closed_first_sample : unsigned(63 downto 0) := (others => '0');
  signal closed_cycle_count  : unsigned(7 downto 0) := (others => '0');
  signal closed_nominal_hz   : unsigned(7 downto 0) := to_unsigned(60, 8);
  signal closed_flags        : std_logic_vector(2 downto 0) := (others => '0');

  -- Provenance self-check, reported through GRID_STATUS. current_first_sample
  -- has to hold the block start for a whole ~200 ms block, which makes it the
  -- longest-lived value in the record; these count the closes where it did
  -- not survive and had to be corrected. Zero on a healthy board.
  signal provenance_repaired : std_logic := '0';
  signal provenance_repairs  : unsigned(7 downto 0) := (others => '0');

  -- Redundant copy of the published block start, written on the same edge.
  -- The published value has to survive from the close until the RMS result
  -- reaches the hub, and then until the next close: a disturbance in that
  -- window cannot be recomputed from live state, so it is held twice and
  -- scrubbed. A single disturbance hits one copy, never both.
  signal closed_first_sample_alt : unsigned(63 downto 0) := (others => '0');

  signal close_locked   : std_logic;
  signal close_relock   : std_logic;
  signal close_fallback : std_logic;
  signal frame_closes   : std_logic;
  signal sample_index   : unsigned(63 downto 0);
  signal crossing_stale : std_logic;
begin
  sample_index <= unsigned(sample_index_high_i) & unsigned(sample_index_low_i);

  active_grid_o <= pack_grid_config(
    to_integer(active_cycles), to_integer(active_nominal), active_enable);
  cycle_mode_o <= active_enable;
  cycle_sequence_o <= std_logic_vector(cycle_sequence);
  block_first_sample_o <= std_logic_vector(closed_first_sample);
  block_cycle_count_o <= std_logic_vector(closed_cycle_count);
  -- The nominal frequency is latched together with the other closed-block
  -- registers, never taken from the live active configuration: an APPLY
  -- that lands between a block close and the result hub consuming the
  -- metadata must not relabel the finished block with the new nominal.
  block_nominal_hz_o <= std_logic_vector(closed_nominal_hz);
  block_flags_o <= closed_flags;

  status : process (all)
    variable value : std_logic_vector(31 downto 0);
  begin
    value := (others => '0');
    value(GRID_STATUS_LOCKED_BIT) := locked;
    value(GRID_STATUS_REFERENCE_BIT) := reference_seen;
    value(GRID_STATUS_ENABLED_BIT) := active_enable;
    value(GRID_STATUS_PROVENANCE_BIT) := provenance_repaired;
    value(GRID_STATUS_CYCLES_LSB + 7 downto GRID_STATUS_CYCLES_LSB) :=
      std_logic_vector(cycles_in_block);
    value(GRID_STATUS_REPAIRS_LSB + 7 downto GRID_STATUS_REPAIRS_LSB) :=
      std_logic_vector(provenance_repairs);
    status_o <= value;
  end process;

  -- Crossings become stale when no qualified crossing has arrived for about
  -- a quarter of the fallback window (2.5 nominal cycles at 50 Hz, 3 at
  -- 60 Hz). A shift keeps this divider-free; the exact margin is not
  -- metrologically significant because affected blocks are flagged anyway.
  crossing_stale <= '1' when shift_right(active_window, 2) /= 0 and
                             samples_since_crossing >=
                             shift_right(active_window, 2)
                    else '0';

  -- Combinational block-close decision for the frame currently being
  -- accepted. The three causes are mutually exclusive by construction.
  close_locked <= '1' when active_enable = '1' and frame_accept_i = '1' and
                           locked = '1' and rising_crossing_i = '1' and
                           cycles_in_block + 1 >= active_cycles
                  else '0';
  close_relock <= '1' when active_enable = '1' and frame_accept_i = '1' and
                           locked = '0' and rising_crossing_i = '1'
                  else '0';
  close_fallback <= '1' when active_enable = '1' and frame_accept_i = '1' and
                             locked = '0' and rising_crossing_i = '0' and
                             active_window /= 0 and
                             samples_in_block + 1 >= active_window
                    else '0';
  frame_closes <= close_locked or close_relock or close_fallback;
  frame_closes_block_o <= frame_closes;

  process (aclk)
    variable start_index   : unsigned(63 downto 0);
    variable derived_index : unsigned(63 downto 0);
  begin
    if rising_edge(aclk) then
      cycle_boundary_o <= '0';
      half_cycle_boundary_o <= '0';

      if aresetn = '0' then
        apply_seen <= '0';
        active_enable <= '1';
        active_cycles <= to_unsigned(GRID_CYCLES_60HZ, 8);
        active_nominal <= to_unsigned(60, 8);
        active_window <= to_unsigned(6400, 32);
        locked <= '0';
        reference_seen <= '0';
        cycles_in_block <= (others => '0');
        samples_in_block <= (others => '0');
        samples_since_crossing <= (others => '0');
        cycle_sequence <= (others => '0');
        current_first_sample <= (others => '0');
        block_start_pending <= '1';
        first_block_flag <= '1';
        closed_first_sample <= (others => '0');
        closed_first_sample_alt <= (others => '0');
        closed_cycle_count <= (others => '0');
        closed_nominal_hz <= to_unsigned(60, 8);
        closed_flags <= (others => '0');
        provenance_repaired <= '0';
        provenance_repairs <= (others => '0');
      elsif config_apply_toggle_i /= apply_seen then
        -- Same commit discipline as the RMS and frequency engines: copy the
        -- complete shadow set in one cycle and restart block tracking, so
        -- the first record after an apply is a clean, flagged block.
        apply_seen <= config_apply_toggle_i;
        active_enable <= config_grid_i(GRID_CONFIG_ENABLE_BIT);
        active_cycles <= unsigned(
          config_grid_i(GRID_CONFIG_CYCLES_LSB + 7 downto
                        GRID_CONFIG_CYCLES_LSB));
        active_nominal <= unsigned(
          config_grid_i(GRID_CONFIG_NOMINAL_LSB + 7 downto
                        GRID_CONFIG_NOMINAL_LSB));
        active_window <= unsigned(config_window_samples_i);
        locked <= '0';
        cycles_in_block <= (others => '0');
        samples_in_block <= (others => '0');
        samples_since_crossing <= (others => '0');
        block_start_pending <= '1';
        first_block_flag <= '1';
      elsif frame_accept_i = '1' and active_enable = '1' then
        reference_seen <= reference_valid_i;

        -- Scrub the already-published block start against its redundant copy.
        -- Zero is not a reachable index: adc_conversion issues index 1 for the
        -- first accepted frame and the counter is free-running and monotonic,
        -- so a zero on one copy only is a disturbed register, never data. This
        -- runs on every accepted frame, so a disturbance is corrected within
        -- one frame period (~7.8 us at 128 kSPS) rather than persisting for the
        -- rest of the block (~200 ms) -- comfortably ahead of the ~45 us the
        -- RMS engine needs before the hub samples this provenance. A close in
        -- the same cycle overrides the scrub below with the fresh value, which
        -- is the correct precedence.
        if closed_first_sample = 0 and closed_first_sample_alt /= 0 then
          closed_first_sample <= closed_first_sample_alt;
          provenance_repaired <= '1';
          if provenance_repairs /= x"FF" then
            provenance_repairs <= provenance_repairs + 1;
          end if;
        elsif closed_first_sample_alt = 0 and closed_first_sample /= 0 then
          closed_first_sample_alt <= closed_first_sample;
          provenance_repaired <= '1';
          if provenance_repairs /= x"FF" then
            provenance_repairs <= provenance_repairs + 1;
          end if;
        end if;

        -- The first accepted frame after an apply (or reset) opens the
        -- block; afterwards block starts chain from the previous close.
        start_index := current_first_sample;
        if block_start_pending = '1' then
          start_index := sample_index;
          current_first_sample <= sample_index;
          block_start_pending <= '0';
        end if;

        -- Cycle bookkeeping from the shared detector's qualified crossings.
        if rising_crossing_i = '1' then
          cycle_sequence <= cycle_sequence + 1;
          samples_since_crossing <= (others => '0');
          cycle_boundary_o <= '1';
        else
          samples_since_crossing <= samples_since_crossing + 1;
        end if;
        if rising_crossing_i = '1' or falling_crossing_i = '1' then
          half_cycle_boundary_o <= '1';
        end if;

        -- Lock tracking. Losing the reference drops the lock immediately;
        -- stale crossings drop it after the timeout above. Any qualified
        -- crossing while unlocked re-locks through close_relock below.
        if reference_valid_i = '0' or crossing_stale = '1' then
          locked <= '0';
        end if;

        if frame_closes = '1' then
          -- This frame is the last frame of the closing block. Publish the
          -- block's provenance and open the next block at index + 1.
          --
          -- Provenance self-check. current_first_sample is chained forward
          -- from the previous close, so it must survive the whole block --
          -- about 200 ms, or 25 600 samples at 128 kSPS. That makes it by far
          -- the longest-lived contributor to the record, and it is the ONLY
          -- source of words 60/61: if it is disturbed, the hub publishes the
          -- disturbed value as authoritative and the APU turns it into a
          -- confidently wrong UTC anchor with a small error bound.
          --
          -- Because blocks are gapless by construction the same quantity is
          -- independently derivable from state that is refreshed every frame:
          -- the closing frame's index minus the frames already counted in
          -- this block. The two agree in every legitimate case, including a
          -- block that closes on its own first frame (samples_in_block = 0)
          -- and the first block after reset or APPLY (block_start_pending
          -- took start_index straight from sample_index).
          --
          -- A disagreement is therefore not a legitimate operating state. The
          -- derived value wins because it depends only on short-lived state,
          -- and the event is counted in GRID_STATUS instead of being emitted
          -- as a silently wrong timestamp anchor. This corrects the record
          -- rather than hiding the fault: a non-zero repair count is a
          -- hardware defect indicator that software must surface.
          derived_index := sample_index - resize(samples_in_block, 64);
          if start_index /= derived_index then
            start_index := derived_index;
            provenance_repaired <= '1';
            -- Saturate: the count is a fault indicator, not a metric, and
            -- must never wrap back to a healthy-looking zero.
            if provenance_repairs /= x"FF" then
              provenance_repairs <= provenance_repairs + 1;
            end if;
          end if;
          closed_first_sample <= start_index;
          closed_first_sample_alt <= start_index;
          -- The nominal frequency is configuration echoed by the PL, never a
          -- measurement, and it can only ever be 50 or 60: those are the only
          -- values the RPU writes and it is latched once at APPLY. An
          -- impossible nominal at close time is the same class of fault as a
          -- disturbed first-sample chain, and it is more damaging: the APU
          -- rejects the ENTIRE record on an invalid nominal, discarding good
          -- electrical data with it. Hold the last good label and count the
          -- event instead. (A close that repairs both the first sample and the
          -- nominal still counts once -- this is a fault indicator, not a
          -- precise metric.)
          if active_nominal = 50 or active_nominal = 60 then
            closed_nominal_hz <= active_nominal;
          else
            provenance_repaired <= '1';
            if provenance_repairs /= x"FF" then
              provenance_repairs <= provenance_repairs + 1;
            end if;
          end if;
          if close_locked = '1' then
            closed_cycle_count <= cycles_in_block + 1;
          else
            closed_cycle_count <= cycles_in_block;
          end if;
          closed_flags <= (others => '0');
          closed_flags(GRID_BLOCK_FLAG_LOCKED) <= close_locked;
          closed_flags(GRID_BLOCK_FLAG_FALLBACK) <=
            close_relock or close_fallback;
          closed_flags(GRID_BLOCK_FLAG_FIRST_BLOCK) <= first_block_flag;
          first_block_flag <= '0';
          current_first_sample <= sample_index + 1;
          cycles_in_block <= (others => '0');
          samples_in_block <= (others => '0');
          if close_relock = '1' or close_locked = '1' then
            locked <= '1';
          end if;
        else
          samples_in_block <= samples_in_block + 1;
          if rising_crossing_i = '1' and locked = '1' then
            cycles_in_block <= cycles_in_block + 1;
          end if;
        end if;
      end if;
    end if;
  end process;
end architecture;
