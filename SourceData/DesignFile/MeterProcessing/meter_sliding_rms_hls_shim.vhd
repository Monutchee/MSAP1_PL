library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.pq_event_pkg.all;
use work.metering_pkg.all;

-- Integration shim for the HLS sliding one-cycle RMS / PQ event engine
-- (metrology M12) — the structural twin of meter_single_cycle_hls_shim:
-- it observes the SAME accepted-frame fan-out (frames are broadcast
-- signals, not a stream, so the two sample-domain observers never
-- arbitrate) and widens each frame into the engine's input beat.
--
-- Its only work is widening plus a small elastic buffer: the engine's
-- half-cycle finalize (six roots plus the detection comparisons) is far
-- longer than one frame interval but happens only twice per grid cycle,
-- so a short FIFO absorbs it. Drops are COUNTED and never backpressure
-- the measurement path — the house rule for every observer.
--
-- The half-cycle strobe arrives registered from grid_cycle_timing and is
-- sampled one cycle after the frame it closes, exactly like the
-- single-cycle shim samples cycle_boundary_i.
entity meter_sliding_rms_hls_shim is
  port (
    aclk    : in std_logic;
    aresetn : in std_logic;

    -- Accepted converted frame (one beat per frame_accept_i pulse).
    frame_accept_i : in std_logic;
    frame_data_i   : in std_logic_vector(METER_CONVERTED_FRAME_BITS - 1 downto 0);
    frame_keep_i   : in std_logic_vector(METER_CONVERTED_KEEP_BITS - 1 downto 0);
    frame_user_i   : in std_logic_vector(383 downto 0);

    -- Half-cycle boundary strobe and the live grid view.
    half_cycle_boundary_i : in std_logic;
    cycle_locked_i        : in std_logic;
    cycle_fallback_i      : in std_logic;

    -- Shadow configuration and the shared APPLY toggle.
    shadow_generation_i   : in std_logic_vector(31 downto 0);
    shadow_sample_rate_i  : in std_logic_vector(31 downto 0);
    shadow_valid_mask_i   : in std_logic_vector(7 downto 0);
    shadow_enable_i       : in std_logic;
    config_apply_toggle_i : in std_logic;

    -- Shadow PQ configuration (pq_event_pkg register layout).
    shadow_pq_reference_i : in std_logic_vector(31 downto 0);
    shadow_pq_threshold_i : in std_logic_vector(31 downto 0);
    shadow_pq_limits_i    : in std_logic_vector(31 downto 0);

    -- Free-running PL tick for the processing timestamp.
    pl_tick_i : in std_logic_vector(63 downto 0);

    -- PQEVT-v1 record stream (to the exported M_AXIS_PQ boundary).
    m_axis_pq_tdata  : out std_logic_vector(31 downto 0);
    m_axis_pq_tkeep  : out std_logic_vector(3 downto 0);
    m_axis_pq_tvalid : out std_logic;
    m_axis_pq_tready : in  std_logic;
    m_axis_pq_tlast  : out std_logic;

    -- M18 half-cycle sufficient-statistic payload. The fixed packet exporter
    -- adds the PQE1 header and CRC32C for R5C1.
    m_axis_pqe_tdata  : out std_logic_vector(31 downto 0);
    m_axis_pqe_tkeep  : out std_logic_vector(3 downto 0);
    m_axis_pqe_tvalid : out std_logic;
    m_axis_pqe_tready : in  std_logic;
    m_axis_pqe_tlast  : out std_logic;

    -- Frames dropped because the engine was still busy (saturating).
    drop_count_o : out std_logic_vector(31 downto 0)
  );
end entity;

architecture rtl of meter_sliding_rms_hls_shim is
  -- Engine input layout (sliding_one_cycle_rms_engine.hpp, normative there).
  constant IN_SAMPLES_LSB    : natural := 0;
  constant IN_FRAME_MASK_LSB : natural := 384;
  constant IN_HALF_BIT       : natural := 392;
  constant IN_MALFORMED_BIT  : natural := 393;
  constant IN_LOCKED_BIT     : natural := 394;
  constant IN_FALLBACK_BIT   : natural := 395;
  constant IN_APPLY_BIT      : natural := 396;
  constant IN_ENABLE_BIT     : natural := 397;
  constant IN_CFG_GEN_LSB    : natural := 400;
  constant IN_CFG_RATE_LSB   : natural := 432;
  constant IN_CFG_MASK_LSB   : natural := 464;
  constant IN_SAMPLE_IDX_LSB : natural := 512;
  constant IN_PL_TICK_LSB    : natural := 576;
  constant IN_REFERENCE_LSB  : natural := 640;
  constant IN_SAG_LSB        : natural := 672;
  constant IN_SWELL_LSB      : natural := 688;
  constant IN_INTERRUPT_LSB  : natural := 704;
  constant IN_HYSTERESIS_LSB : natural := 720;
  constant BEAT_BITS         : natural := 736;

  constant FIFO_DEPTH : natural := 8;

  component hls_sliding_one_cycle_rms_engine_ip is
    port (
      ap_clk         : in  std_logic;
      ap_rst_n       : in  std_logic;
      s_frame_TDATA  : in  std_logic_vector(BEAT_BITS - 1 downto 0);
      s_frame_TVALID : in  std_logic;
      s_frame_TREADY : out std_logic;
      m_axis_TDATA   : out std_logic_vector(31 downto 0);
      m_axis_TVALID  : out std_logic;
      m_axis_TREADY  : in  std_logic;
      m_axis_TKEEP   : out std_logic_vector(3 downto 0);
      m_axis_TSTRB   : out std_logic_vector(3 downto 0);
      m_axis_TLAST   : out std_logic_vector(0 downto 0);
      m_pqe_TDATA    : out std_logic_vector(31 downto 0);
      m_pqe_TVALID   : out std_logic;
      m_pqe_TREADY   : in  std_logic;
      m_pqe_TKEEP    : out std_logic_vector(3 downto 0);
      m_pqe_TSTRB    : out std_logic_vector(3 downto 0);
      m_pqe_TLAST    : out std_logic_vector(0 downto 0)
    );
  end component;

  type beat_array_t is array (0 to FIFO_DEPTH - 1) of
    std_logic_vector(BEAT_BITS - 1 downto 0);
  -- Distributed RAM: a handful of wide words would waste a block RAM
  -- (the single-cycle shim's precedent).
  signal fifo_mem : beat_array_t;
  attribute ram_style : string;
  attribute ram_style of fifo_mem : signal is "distributed";

  signal wr_ptr     : natural range 0 to FIFO_DEPTH - 1 := 0;
  signal rd_ptr     : natural range 0 to FIFO_DEPTH - 1 := 0;
  signal fill_level : natural range 0 to FIFO_DEPTH := 0;
  signal drop_count : unsigned(31 downto 0) := (others => '0');

  signal head_valid : std_logic;
  signal in_ready   : std_logic;
  signal tlast_vec  : std_logic_vector(0 downto 0);
  signal pqe_tlast_vec : std_logic_vector(0 downto 0);
  -- Records are never sparse: TSTRB duplicates TKEEP and terminates here.
  signal tstrb_nc   : std_logic_vector(3 downto 0);
  signal pqe_tstrb_nc : std_logic_vector(3 downto 0);

  -- One-cycle frame stage: payload captured with the frame, the strobes
  -- and configuration sampled at the push, one cycle later, so
  -- grid_cycle_timing's registered half-cycle boundary lands on the frame
  -- that completed the half cycle.
  signal staged_valid     : std_logic := '0';
  signal staged_data      : std_logic_vector(METER_CONVERTED_FRAME_BITS - 1 downto 0) := (others => '0');
  signal staged_mask      : std_logic_vector(7 downto 0) := (others => '0');
  signal staged_index     : std_logic_vector(63 downto 0) := (others => '0');
  signal staged_malformed : std_logic := '0';
begin
  core : hls_sliding_one_cycle_rms_engine_ip
    port map (
      ap_clk         => aclk,
      ap_rst_n       => aresetn,
      s_frame_TDATA  => fifo_mem(rd_ptr),
      s_frame_TVALID => head_valid,
      s_frame_TREADY => in_ready,
      m_axis_TDATA   => m_axis_pq_tdata,
      m_axis_TVALID  => m_axis_pq_tvalid,
      m_axis_TREADY  => m_axis_pq_tready,
      m_axis_TKEEP   => m_axis_pq_tkeep,
      m_axis_TSTRB   => tstrb_nc,
      m_axis_TLAST   => tlast_vec,
      m_pqe_TDATA    => m_axis_pqe_tdata,
      m_pqe_TVALID   => m_axis_pqe_tvalid,
      m_pqe_TREADY   => m_axis_pqe_tready,
      m_pqe_TKEEP    => m_axis_pqe_tkeep,
      m_pqe_TSTRB    => pqe_tstrb_nc,
      m_pqe_TLAST    => pqe_tlast_vec
    );
  m_axis_pq_tlast <= tlast_vec(0);
  m_axis_pqe_tlast <= pqe_tlast_vec(0);
  head_valid <= '1' when fill_level /= 0 else '0';
  drop_count_o <= std_logic_vector(drop_count);

  process (aclk)
    variable beat    : std_logic_vector(BEAT_BITS - 1 downto 0);
    variable pushing : boolean;
    variable popping : boolean;
  begin
    if rising_edge(aclk) then
      if aresetn = '0' then
        wr_ptr <= 0;
        rd_ptr <= 0;
        fill_level <= 0;
        drop_count <= (others => '0');
        staged_valid <= '0';
      else
        popping := head_valid = '1' and in_ready = '1';
        pushing := false;

        if staged_valid = '1' then
          if fill_level = FIFO_DEPTH and not popping then
            -- Drop and count: an observer must never backpressure
            -- conversion, and a lost frame only blurs one half-cycle root.
            if drop_count /= (drop_count'range => '1') then
              drop_count <= drop_count + 1;
            end if;
          else
            pushing := true;
            beat := (others => '0');
            beat(IN_SAMPLES_LSB + METER_CONVERTED_FRAME_BITS - 1 downto
                 IN_SAMPLES_LSB) := staged_data;
            beat(IN_FRAME_MASK_LSB + 7 downto IN_FRAME_MASK_LSB) :=
              staged_mask;
            beat(IN_MALFORMED_BIT) := staged_malformed;
            beat(IN_HALF_BIT) := half_cycle_boundary_i;
            beat(IN_LOCKED_BIT) := cycle_locked_i;
            beat(IN_FALLBACK_BIT) := cycle_fallback_i;
            beat(IN_APPLY_BIT) := config_apply_toggle_i;
            beat(IN_ENABLE_BIT) := shadow_enable_i;
            beat(IN_CFG_GEN_LSB + 31 downto IN_CFG_GEN_LSB) :=
              shadow_generation_i;
            beat(IN_CFG_RATE_LSB + 31 downto IN_CFG_RATE_LSB) :=
              shadow_sample_rate_i;
            beat(IN_CFG_MASK_LSB + 7 downto IN_CFG_MASK_LSB) :=
              shadow_valid_mask_i;
            beat(IN_SAMPLE_IDX_LSB + 63 downto IN_SAMPLE_IDX_LSB) :=
              staged_index;
            beat(IN_PL_TICK_LSB + 63 downto IN_PL_TICK_LSB) := pl_tick_i;
            beat(IN_REFERENCE_LSB + 31 downto IN_REFERENCE_LSB) :=
              shadow_pq_reference_i;
            beat(IN_SAG_LSB + 15 downto IN_SAG_LSB) :=
              shadow_pq_threshold_i(PQ_THRESHOLD_SAG_LSB + 15 downto
                                    PQ_THRESHOLD_SAG_LSB);
            beat(IN_SWELL_LSB + 15 downto IN_SWELL_LSB) :=
              shadow_pq_threshold_i(PQ_THRESHOLD_SWELL_LSB + 15 downto
                                    PQ_THRESHOLD_SWELL_LSB);
            beat(IN_INTERRUPT_LSB + 15 downto IN_INTERRUPT_LSB) :=
              shadow_pq_limits_i(PQ_LIMITS_INTERRUPT_LSB + 15 downto
                                 PQ_LIMITS_INTERRUPT_LSB);
            beat(IN_HYSTERESIS_LSB + 15 downto IN_HYSTERESIS_LSB) :=
              shadow_pq_limits_i(PQ_LIMITS_HYSTERESIS_LSB + 15 downto
                                 PQ_LIMITS_HYSTERESIS_LSB);
            fifo_mem(wr_ptr) <= beat;
            if wr_ptr = FIFO_DEPTH - 1 then
              wr_ptr <= 0;
            else
              wr_ptr <= wr_ptr + 1;
            end if;
          end if;
          staged_valid <= '0';
        end if;

        -- Stage the incoming frame. The 64-bit conversion index rides in
        -- TUSER: low word [31:0], high word [105:74]; the frame's own
        -- valid mask is [71:64].
        if frame_accept_i = '1' then
          staged_valid <= '1';
          staged_data <= frame_data_i;
          staged_mask <= frame_user_i(71 downto 64);
          staged_index <= frame_user_i(105 downto 74) &
                          frame_user_i(31 downto 0);
          if frame_keep_i /= (frame_keep_i'range => '1') then
            staged_malformed <= '1';
          else
            staged_malformed <= '0';
          end if;
        end if;

        if popping then
          if rd_ptr = FIFO_DEPTH - 1 then
            rd_ptr <= 0;
          else
            rd_ptr <= rd_ptr + 1;
          end if;
        end if;

        if pushing and not popping then
          fill_level <= fill_level + 1;
        elsif popping and not pushing then
          fill_level <= fill_level - 1;
        end if;
      end if;
    end if;
  end process;
end architecture;
