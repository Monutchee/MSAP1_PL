library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.adc_simulator_pkg.all;

-- Raw signed-24-bit ADC source used to exercise the complete MeterCore data
-- path without physical ADC traffic.  Software supplies already-calculated
-- raw peak counts, phase offsets, and DC offsets, keeping sensor/profile
-- policy in Linux.
--
-- This block owns the deterministic infrastructure: the AXI-Lite register
-- file with its shadow/APPLY banks, the fractional sample-rate scheduler,
-- the Q0.32 phase accumulator, AXIS framing/TLAST, and the backpressure
-- and saturation accounting.  The per-frame waveform mathematics
-- (interpolated sine, amplitude scaling, DC offset, rail clamping) lives
-- in the packaged HLS engine hls_sim_wave_engine
-- (HLS_DesignFile/MeterCore/SimWaveEngine, normative beat layout in
-- sim_wave_engine.hpp, mirrored by adc_simulator_pkg).  One request beat
-- is issued per due frame; the engine returns exactly one response, so
-- the scheduler's single-frame pending accounting is unchanged from the
-- retired inline datapath.
--
-- CONTROL bit 0 selects this source, bit 1 enables sample generation, and
-- bit 2 preserves the phase accumulator, scheduler, and packet framing
-- across APPLY (seamless reconfiguration for scenario changes).  Shadow
-- values are committed by writing bit 0 to APPLY.  A commit occurs only
-- between eight-channel frames, so a frame never mixes generations.
--
-- The event sequencer (metrology M12) is the deterministic half of the
-- sag/swell/interruption feature: it owns a second shadow bank with its
-- own trigger -- so a burst launches against a steady configuration
-- without committing anything else -- and starts and ends the burst on
-- the generator's OWN half-cycle boundaries (the phase accumulator's MSB
-- flip).  The envelope is therefore phase-continuous by construction: no
-- APPLY, no accumulator reset, no discontinuity to be mistaken for the
-- event under test.  Only the amplitude multiply travels to the HLS
-- engine, as the request's event word.
entity adc_simulator is
  generic (
    G_ACLK_HZ       : positive := 99999001;
    G_PACKET_FRAMES : positive := 256
  );
  port (
    aclk    : in std_logic;
    aresetn : in std_logic;

    s_axi_awaddr  : in  std_logic_vector(11 downto 0);
    s_axi_awvalid : in  std_logic;
    s_axi_awready : out std_logic;
    s_axi_wdata   : in  std_logic_vector(31 downto 0);
    s_axi_wstrb   : in  std_logic_vector(3 downto 0);
    s_axi_wvalid  : in  std_logic;
    s_axi_wready  : out std_logic;
    s_axi_bresp   : out std_logic_vector(1 downto 0);
    s_axi_bvalid  : out std_logic;
    s_axi_bready  : in  std_logic;
    s_axi_araddr  : in  std_logic_vector(11 downto 0);
    s_axi_arvalid : in  std_logic;
    s_axi_arready : out std_logic;
    s_axi_rdata   : out std_logic_vector(31 downto 0);
    s_axi_rresp   : out std_logic_vector(1 downto 0);
    s_axi_rvalid  : out std_logic;
    s_axi_rready  : in  std_logic;

    m_axis_tdata  : out std_logic_vector(31 downto 0);
    m_axis_tkeep  : out std_logic_vector(3 downto 0);
    m_axis_tvalid : out std_logic;
    m_axis_tready : in  std_logic;
    m_axis_tlast  : out std_logic;

    source_select_o    : out std_logic;
    frame_count_o      : out std_logic_vector(31 downto 0);
    frame_rate_hz_o    : out std_logic_vector(31 downto 0);
    frame_rate_valid_o : out std_logic;
    saturation_count_o : out std_logic_vector(31 downto 0)
  );
end entity;

architecture rtl of adc_simulator is
  -- Packaged HLS waveform engine (SourceData/IP/hls_sim_wave_engine_ip in
  -- the product project; the non-project checks bind the same name to the
  -- packaged RTL through tb/hls_sim_wave_engine_ip.v).
  component hls_sim_wave_engine_ip is
    port (
      ap_clk           : in  std_logic;
      ap_rst_n         : in  std_logic;
      s_request_TDATA  : in  std_logic_vector(SIM_WAVE_REQ_BITS - 1 downto 0);
      s_request_TVALID : in  std_logic;
      s_request_TREADY : out std_logic;
      m_frame_TDATA    : out std_logic_vector(SIM_WAVE_RSP_BITS - 1 downto 0);
      m_frame_TVALID   : out std_logic;
      m_frame_TREADY   : in  std_logic
    );
  end component;

  type word_array_t is array (0 to 7) of std_logic_vector(31 downto 0);
  type harmonic_word_array_t is array (0 to SIM_WAVE_HARMONIC_WORDS - 1) of
    std_logic_vector(31 downto 0);

  signal shadow_control     : std_logic_vector(31 downto 0) := (others => '0');
  signal shadow_sample_rate : std_logic_vector(31 downto 0) := std_logic_vector(to_unsigned(32000, 32));
  signal shadow_frequency   : std_logic_vector(31 downto 0) := std_logic_vector(to_unsigned(60000, 32));
  signal shadow_valid_mask  : std_logic_vector(7 downto 0) := x"7F";
  signal shadow_generation  : std_logic_vector(31 downto 0) := (others => '0');
  signal shadow_phase_step  : std_logic_vector(31 downto 0) := (others => '0');
  signal shadow_peak        : word_array_t := (others => (others => '0'));
  signal shadow_phase       : word_array_t := (others => (others => '0'));
  signal shadow_dc          : word_array_t := (others => (others => '0'));
  signal shadow_noise       : word_array_t := (others => (others => '0'));
  signal shadow_harmonic    : harmonic_word_array_t := (others => (others => '0'));

  signal active_control     : std_logic_vector(31 downto 0) := (others => '0');
  signal active_sample_rate : std_logic_vector(31 downto 0) := std_logic_vector(to_unsigned(32000, 32));
  signal active_frequency   : std_logic_vector(31 downto 0) := std_logic_vector(to_unsigned(60000, 32));
  signal active_valid_mask  : std_logic_vector(7 downto 0) := x"7F";
  signal active_generation  : std_logic_vector(31 downto 0) := (others => '0');
  signal active_phase_step  : std_logic_vector(31 downto 0) := (others => '0');
  signal active_peak        : word_array_t := (others => (others => '0'));
  signal active_phase       : word_array_t := (others => (others => '0'));
  signal active_dc          : word_array_t := (others => (others => '0'));
  signal active_noise       : word_array_t := (others => (others => '0'));
  signal active_harmonic    : harmonic_word_array_t := (others => (others => '0'));

  -- Event sequencer bank and state.  ARMED waits for the next half-cycle
  -- boundary, RUNNING applies the envelope for the committed duration,
  -- HOLD counts out the remainder of a repeating burst's period.
  signal shadow_event_control : std_logic_vector(31 downto 0) := (others => '0');
  signal shadow_event_scale   : std_logic_vector(31 downto 0) :=
    std_logic_vector(to_unsigned(ADC_SIM_EVENT_SCALE_UNITY, 32));
  signal shadow_event_timing  : std_logic_vector(31 downto 0) := (others => '0');
  signal active_event_control : std_logic_vector(31 downto 0) := (others => '0');
  signal active_event_scale   : std_logic_vector(31 downto 0) :=
    std_logic_vector(to_unsigned(ADC_SIM_EVENT_SCALE_UNITY, 32));
  signal active_event_timing  : std_logic_vector(31 downto 0) := (others => '0');

  type event_state_t is (EVT_IDLE, EVT_ARMED, EVT_RUNNING, EVT_HOLD);
  signal event_state     : event_state_t := EVT_IDLE;
  signal event_remaining : unsigned(15 downto 0) := (others => '0');
  signal event_period    : unsigned(15 downto 0) := (others => '0');
  signal event_count     : unsigned(15 downto 0) := (others => '0');
  signal event_scale_now : std_logic_vector(18 downto 0);
  signal event_mask_now  : std_logic_vector(7 downto 0);

  signal apply_pending : std_logic := '0';
  signal sample_accumulator : unsigned(32 downto 0) := (others => '0');
  signal sample_pending     : std_logic := '0';
  signal base_phase         : unsigned(31 downto 0) := (others => '0');
  signal channel_index      : natural range 0 to 7 := 0;
  signal packet_frame_index : natural range 0 to G_PACKET_FRAMES - 1 := 0;

  -- Frame generation sequencer: IDLE (nothing in flight), REQUEST (beat
  -- offered to the engine), WAIT (response outstanding), EMIT (streaming
  -- the returned frame's eight beats).
  type gen_state_t is (GEN_IDLE, GEN_REQUEST, GEN_WAIT, GEN_EMIT);
  signal gen_state : gen_state_t := GEN_IDLE;

  signal req_data  : std_logic_vector(SIM_WAVE_REQ_BITS - 1 downto 0) := (others => '0');
  signal req_valid : std_logic := '0';
  signal req_ready : std_logic;
  signal rsp_data  : std_logic_vector(SIM_WAVE_RSP_BITS - 1 downto 0);
  signal rsp_valid : std_logic;

  signal frame_samples : word_array_t := (others => (others => '0'));
  signal axis_data     : std_logic_vector(31 downto 0) := (others => '0');
  signal axis_valid    : std_logic := '0';
  signal axis_last     : std_logic := '0';
  signal frame_count        : unsigned(31 downto 0) := (others => '0');
  signal saturation_count   : unsigned(31 downto 0) := (others => '0');
  signal missed_sample_count : unsigned(31 downto 0) := (others => '0');

  signal aw_stored : std_logic := '0';
  signal awaddr    : std_logic_vector(11 downto 0) := (others => '0');
  signal w_stored  : std_logic := '0';
  signal wdata     : std_logic_vector(31 downto 0) := (others => '0');
  signal wstrb     : std_logic_vector(3 downto 0) := (others => '0');
  signal bvalid    : std_logic := '0';
  signal rvalid    : std_logic := '0';
  signal rdata     : std_logic_vector(31 downto 0) := (others => '0');

  function merge_strobes(
    current_value : std_logic_vector(31 downto 0);
    new_value     : std_logic_vector(31 downto 0);
    strobes       : std_logic_vector(3 downto 0)) return std_logic_vector is
    variable result : std_logic_vector(31 downto 0) := current_value;
  begin
    for byte_index in 0 to 3 loop
      if strobes(byte_index) = '1' then
        result((byte_index * 8) + 7 downto byte_index * 8) :=
          new_value((byte_index * 8) + 7 downto byte_index * 8);
      end if;
    end loop;
    return result;
  end function;

  function pack_request(
    base_phase_v  : unsigned(31 downto 0);
    frame_index_v : unsigned(31 downto 0);
    mask_v        : std_logic_vector(7 downto 0);
    peak_v        : word_array_t;
    phase_v       : word_array_t;
    dc_v          : word_array_t;
    noise_v       : word_array_t;
    harmonic_v    : harmonic_word_array_t;
    event_scale_v : std_logic_vector(18 downto 0);
    event_mask_v  : std_logic_vector(7 downto 0)) return std_logic_vector is
    variable beat : std_logic_vector(SIM_WAVE_REQ_BITS - 1 downto 0) := (others => '0');
  begin
    beat(SIM_WAVE_REQ_BASE_PHASE_LSB + 31 downto SIM_WAVE_REQ_BASE_PHASE_LSB) :=
      std_logic_vector(base_phase_v);
    beat(SIM_WAVE_REQ_VALID_MASK_LSB + 7 downto SIM_WAVE_REQ_VALID_MASK_LSB) := mask_v;
    beat(SIM_WAVE_REQ_FRAME_INDEX_LSB + 31 downto SIM_WAVE_REQ_FRAME_INDEX_LSB) :=
      std_logic_vector(frame_index_v);
    for lane in 0 to SIM_WAVE_CHANNELS - 1 loop
      beat(SIM_WAVE_REQ_PEAK_LSB + (lane * 32) + 31 downto
           SIM_WAVE_REQ_PEAK_LSB + (lane * 32)) := peak_v(lane);
      beat(SIM_WAVE_REQ_PHASE_LSB + (lane * 32) + 31 downto
           SIM_WAVE_REQ_PHASE_LSB + (lane * 32)) := phase_v(lane);
      beat(SIM_WAVE_REQ_DC_LSB + (lane * 32) + 31 downto
           SIM_WAVE_REQ_DC_LSB + (lane * 32)) := dc_v(lane);
      beat(SIM_WAVE_REQ_NOISE_LSB + (lane * 32) + 31 downto
           SIM_WAVE_REQ_NOISE_LSB + (lane * 32)) := noise_v(lane);
    end loop;
    for word in 0 to SIM_WAVE_HARMONIC_WORDS - 1 loop
      beat(SIM_WAVE_REQ_HARMONIC_LSB + (word * 32) + 31 downto
           SIM_WAVE_REQ_HARMONIC_LSB + (word * 32)) := harmonic_v(word);
    end loop;
    beat(SIM_WAVE_REQ_EVENT_SCALE_LSB + 18 downto SIM_WAVE_REQ_EVENT_SCALE_LSB) :=
      event_scale_v;
    beat(SIM_WAVE_REQ_EVENT_MASK_LSB + 7 downto SIM_WAVE_REQ_EVENT_MASK_LSB) :=
      event_mask_v;
    return beat;
  end function;

  function count_ones(bits : std_logic_vector(7 downto 0)) return natural is
    variable total : natural range 0 to 8 := 0;
  begin
    for bit_index in bits'range loop
      if bits(bit_index) = '1' then
        total := total + 1;
      end if;
    end loop;
    return total;
  end function;
begin
  s_axi_awready <= not aw_stored;
  s_axi_wready <= not w_stored;
  s_axi_bresp <= "00";
  s_axi_bvalid <= bvalid;
  s_axi_arready <= not rvalid;
  s_axi_rresp <= "00";
  s_axi_rvalid <= rvalid;
  s_axi_rdata <= rdata;

  m_axis_tdata <= axis_data;
  m_axis_tkeep <= (others => '1');
  m_axis_tvalid <= axis_valid;
  m_axis_tlast <= axis_last;

  source_select_o <= active_control(ADC_SIM_CONTROL_SOURCE_BIT);
  frame_count_o <= std_logic_vector(frame_count);
  frame_rate_hz_o <= active_sample_rate;
  frame_rate_valid_o <= active_control(ADC_SIM_CONTROL_SOURCE_BIT) and
                        active_control(ADC_SIM_CONTROL_ENABLE_BIT);
  saturation_count_o <= std_logic_vector(saturation_count);

  -- Only a RUNNING burst reaches the engine; everything else is the
  -- inert unity envelope, which the engine treats as a bit-exact no-op.
  event_scale_now <= active_event_scale(18 downto 0) when event_state = EVT_RUNNING
                     else std_logic_vector(to_unsigned(ADC_SIM_EVENT_SCALE_UNITY, 19));
  event_mask_now <= active_event_control(ADC_SIM_EVENT_MASK_LSB + 7 downto
                                         ADC_SIM_EVENT_MASK_LSB)
                    when event_state = EVT_RUNNING else (others => '0');

  waveform_engine : hls_sim_wave_engine_ip
    port map (
      ap_clk           => aclk,
      ap_rst_n         => aresetn,
      s_request_TDATA  => req_data,
      s_request_TVALID => req_valid,
      s_request_TREADY => req_ready,
      m_frame_TDATA    => rsp_data,
      m_frame_TVALID   => rsp_valid,
      -- Responses are captured (or deliberately discarded) the cycle they
      -- appear; the engine is never backpressured.
      m_frame_TREADY   => '1'
    );

  process (aclk)
    variable write_address : natural range 0 to 4095;
    variable read_address  : natural range 0 to 4095;
    variable array_index   : natural range 0 to 7;
    variable next_accumulator : unsigned(32 downto 0);
    variable start_frame      : boolean;
    variable next_phase       : unsigned(31 downto 0);
    variable start_burst      : boolean;
    variable burst_duration   : unsigned(15 downto 0);
    variable burst_period     : unsigned(15 downto 0);
    variable event_scale_v    : unsigned(31 downto 0);
  begin
    if rising_edge(aclk) then
      if aresetn = '0' then
        shadow_control <= (others => '0');
        shadow_sample_rate <= std_logic_vector(to_unsigned(32000, 32));
        shadow_frequency <= std_logic_vector(to_unsigned(60000, 32));
        shadow_valid_mask <= x"7F";
        shadow_generation <= (others => '0');
        shadow_phase_step <= (others => '0');
        shadow_peak <= (others => (others => '0'));
        shadow_phase <= (others => (others => '0'));
        shadow_dc <= (others => (others => '0'));
        shadow_noise <= (others => (others => '0'));
        shadow_harmonic <= (others => (others => '0'));
        active_control <= (others => '0');
        active_sample_rate <= std_logic_vector(to_unsigned(32000, 32));
        active_frequency <= std_logic_vector(to_unsigned(60000, 32));
        active_valid_mask <= x"7F";
        active_generation <= (others => '0');
        active_phase_step <= (others => '0');
        active_peak <= (others => (others => '0'));
        active_phase <= (others => (others => '0'));
        active_dc <= (others => (others => '0'));
        active_noise <= (others => (others => '0'));
        active_harmonic <= (others => (others => '0'));
        shadow_event_control <= (others => '0');
        shadow_event_scale <=
          std_logic_vector(to_unsigned(ADC_SIM_EVENT_SCALE_UNITY, 32));
        shadow_event_timing <= (others => '0');
        active_event_control <= (others => '0');
        active_event_scale <=
          std_logic_vector(to_unsigned(ADC_SIM_EVENT_SCALE_UNITY, 32));
        active_event_timing <= (others => '0');
        event_state <= EVT_IDLE;
        event_remaining <= (others => '0');
        event_period <= (others => '0');
        event_count <= (others => '0');
        apply_pending <= '0';
        sample_accumulator <= (others => '0');
        sample_pending <= '0';
        base_phase <= (others => '0');
        channel_index <= 0;
        packet_frame_index <= 0;
        gen_state <= GEN_IDLE;
        req_data <= (others => '0');
        req_valid <= '0';
        frame_samples <= (others => (others => '0'));
        axis_data <= (others => '0');
        axis_valid <= '0';
        axis_last <= '0';
        frame_count <= (others => '0');
        saturation_count <= (others => '0');
        missed_sample_count <= (others => '0');
        aw_stored <= '0';
        w_stored <= '0';
        bvalid <= '0';
        rvalid <= '0';
        rdata <= (others => '0');
      else
        -- The shadow bank crosses into active operation only while no
        -- frame is in flight, so a frame never mixes generations.  Unless
        -- the committed CONTROL preserves it, the scheduler/phase/framing
        -- state clears so the first generated frame is deterministic
        -- after a source/configuration transaction.
        if apply_pending = '1' and gen_state = GEN_IDLE and axis_valid = '0' then
          active_control <= shadow_control;
          active_sample_rate <= shadow_sample_rate;
          active_frequency <= shadow_frequency;
          active_valid_mask <= shadow_valid_mask and x"7F";
          active_generation <= shadow_generation;
          active_phase_step <= shadow_phase_step;
          active_peak <= shadow_peak;
          active_phase <= shadow_phase;
          active_dc <= shadow_dc;
          active_noise <= shadow_noise;
          active_harmonic <= shadow_harmonic;
          apply_pending <= '0';
          if shadow_control(ADC_SIM_CONTROL_PRESERVE_PHASE_BIT) = '0' then
            sample_accumulator <= (others => '0');
            sample_pending <= '0';
            base_phase <= (others => '0');
            channel_index <= 0;
            packet_frame_index <= 0;
            -- The phase restarts from zero, so a burst timed against the
            -- old accumulator has no meaning: cancel it rather than let
            -- it run out against a discontinuous waveform.  A
            -- preserve-phase APPLY leaves the burst untouched, which is
            -- what makes a mid-event reconfiguration testable.
            event_state <= EVT_IDLE;
          end if;
        elsif active_control(ADC_SIM_CONTROL_SOURCE_BIT) = '1' and
              active_control(ADC_SIM_CONTROL_ENABLE_BIT) = '1' then
          -- Advance the fractional scheduler every PL clock, including
          -- while a frame is computed or emitted.  A one-frame pending
          -- flag absorbs normal latency without biasing the requested
          -- sample rate; every tick beyond it is a counted miss, never a
          -- silent timebase slide.
          start_frame := false;
          next_accumulator := sample_accumulator + resize(unsigned(active_sample_rate), 33);
          if next_accumulator >= to_unsigned(G_ACLK_HZ, 33) then
            sample_accumulator <= next_accumulator - to_unsigned(G_ACLK_HZ, 33);
            if gen_state = GEN_IDLE then
              start_frame := true;
            else
              if sample_pending = '1' then
                missed_sample_count <= missed_sample_count + 1;
              end if;
              sample_pending <= '1';
            end if;
          else
            sample_accumulator <= next_accumulator;
            if sample_pending = '1' and gen_state = GEN_IDLE then
              sample_pending <= '0';
              start_frame := true;
            end if;
          end if;

          if start_frame then
            -- frame_count doubles as the engine's noise sequence index, so
            -- the fluctuation is white across frames yet fully reproducible
            -- from the observable frame counter.
            req_data <= pack_request(base_phase, frame_count, active_valid_mask,
                                     active_peak, active_phase, active_dc,
                                     active_noise, active_harmonic,
                                     event_scale_now, event_mask_now);
            req_valid <= '1';
            gen_state <= GEN_REQUEST;
          end if;

          case gen_state is
            when GEN_IDLE =>
              null;
            when GEN_REQUEST =>
              if req_valid = '1' and req_ready = '1' then
                req_valid <= '0';
                gen_state <= GEN_WAIT;
              end if;
            when GEN_WAIT =>
              if rsp_valid = '1' then
                for lane in 0 to SIM_WAVE_CHANNELS - 1 loop
                  frame_samples(lane) <=
                    rsp_data(SIM_WAVE_RSP_SAMPLE_LSB + (lane * 32) + 31 downto
                             SIM_WAVE_RSP_SAMPLE_LSB + (lane * 32));
                end loop;
                saturation_count <= saturation_count +
                  count_ones(rsp_data(SIM_WAVE_RSP_SATURATED_LSB + 7 downto
                                      SIM_WAVE_RSP_SATURATED_LSB));
                channel_index <= 0;
                gen_state <= GEN_EMIT;
              end if;
            when GEN_EMIT =>
              if axis_valid = '0' then
                axis_data <= frame_samples(channel_index);
                axis_last <= '1' when channel_index = 7 and
                                      packet_frame_index = G_PACKET_FRAMES - 1 else '0';
                axis_valid <= '1';
              elsif m_axis_tready = '1' then
                axis_valid <= '0';
                axis_last <= '0';
                if channel_index = 7 then
                  frame_count <= frame_count + 1;
                  next_phase := base_phase + unsigned(active_phase_step);
                  base_phase <= next_phase;

                  -- Event sequencer.  A half-cycle boundary is the MSB of
                  -- the Q0.32 phase accumulator flipping -- the same
                  -- instant the grid-timing block would see a zero
                  -- crossing on the generated waveform, and the only
                  -- instant the envelope is allowed to change.  Timing is
                  -- counted in boundaries, never in samples, so an
                  -- off-nominal or fractional sample rate never skews an
                  -- event's programmed length.
                  if next_phase(31) /= base_phase(31) then
                    start_burst := false;
                    burst_duration := unsigned(active_event_timing(
                      ADC_SIM_EVENT_DURATION_LSB + 15 downto
                      ADC_SIM_EVENT_DURATION_LSB));
                    burst_period := unsigned(active_event_timing(
                      ADC_SIM_EVENT_PERIOD_LSB + 15 downto
                      ADC_SIM_EVENT_PERIOD_LSB));
                    -- Back-to-back bursts when the programmed period does
                    -- not clear the duration.
                    if burst_period <= burst_duration then
                      burst_period := burst_duration + 1;
                    end if;
                    case event_state is
                      when EVT_ARMED =>
                        start_burst := true;
                      when EVT_RUNNING =>
                        if event_remaining = 0 then
                          event_count <= event_count + 1;
                          if active_event_control(ADC_SIM_EVENT_REPEAT_BIT) = '1' then
                            if event_period = 0 then
                              start_burst := true;
                            else
                              event_state <= EVT_HOLD;
                            end if;
                          else
                            event_state <= EVT_IDLE;
                          end if;
                        else
                          event_remaining <= event_remaining - 1;
                        end if;
                      when EVT_HOLD =>
                        if event_period = 0 then
                          start_burst := true;
                        end if;
                      when EVT_IDLE =>
                        null;
                    end case;
                    if start_burst then
                      event_state <= EVT_RUNNING;
                      event_remaining <= burst_duration - 1;
                      event_period <= burst_period - 1;
                    elsif event_state /= EVT_IDLE and event_period /= 0 then
                      event_period <= event_period - 1;
                    end if;
                  end if;

                  if packet_frame_index = G_PACKET_FRAMES - 1 then
                    packet_frame_index <= 0;
                  else
                    packet_frame_index <= packet_frame_index + 1;
                  end if;
                  gen_state <= GEN_IDLE;
                else
                  channel_index <= channel_index + 1;
                end if;
              end if;
          end case;
        else
          -- Deselected or disabled: stop emitting and rearming, but obey
          -- AXI-Stream on the engine boundary -- an offered request stays
          -- offered until accepted, and its response is drained silently.
          axis_valid <= '0';
          axis_last <= '0';
          sample_accumulator <= (others => '0');
          sample_pending <= '0';
          case gen_state is
            when GEN_REQUEST =>
              if req_valid = '1' and req_ready = '1' then
                req_valid <= '0';
                gen_state <= GEN_WAIT;
              end if;
            when GEN_WAIT =>
              if rsp_valid = '1' then
                gen_state <= GEN_IDLE;
              end if;
            when others =>
              gen_state <= GEN_IDLE;
          end case;
        end if;

        -- AXI-Lite write channel.  Deliberately after the generation
        -- logic in process order: a register write coincident with a
        -- datapath update to the same counter wins, so COUNTER_CLEAR
        -- always leaves the counter observably cleared.
        if s_axi_awvalid = '1' and aw_stored = '0' then
          awaddr <= s_axi_awaddr;
          aw_stored <= '1';
        end if;
        if s_axi_wvalid = '1' and w_stored = '0' then
          wdata <= s_axi_wdata;
          wstrb <= s_axi_wstrb;
          w_stored <= '1';
        end if;
        if bvalid = '1' and s_axi_bready = '1' then
          bvalid <= '0';
        end if;

        if aw_stored = '1' and w_stored = '1' and bvalid = '0' then
          write_address := to_integer(unsigned(awaddr));
          case write_address is
            when ADC_SIM_REG_SHADOW_CONTROL =>
              shadow_control <= merge_strobes(shadow_control, wdata, wstrb);
            when ADC_SIM_REG_SHADOW_SAMPLE_RATE =>
              shadow_sample_rate <= merge_strobes(shadow_sample_rate, wdata, wstrb);
            when ADC_SIM_REG_SHADOW_FREQUENCY =>
              shadow_frequency <= merge_strobes(shadow_frequency, wdata, wstrb);
            when ADC_SIM_REG_SHADOW_VALID_MASK =>
              shadow_valid_mask <= merge_strobes(x"000000" & shadow_valid_mask, wdata, wstrb)(7 downto 0);
            when ADC_SIM_REG_SHADOW_GENERATION =>
              shadow_generation <= merge_strobes(shadow_generation, wdata, wstrb);
            when ADC_SIM_REG_APPLY =>
              if wdata(0) = '1' then
                apply_pending <= '1';
              end if;
            when ADC_SIM_REG_SHADOW_PHASE_STEP =>
              shadow_phase_step <= merge_strobes(shadow_phase_step, wdata, wstrb);
            when ADC_SIM_REG_COUNTER_CLEAR =>
              if wdata(ADC_SIM_CLEAR_SATURATION_BIT) = '1' then
                saturation_count <= (others => '0');
              end if;
              if wdata(ADC_SIM_CLEAR_MISSED_BIT) = '1' then
                missed_sample_count <= (others => '0');
              end if;
              if wdata(ADC_SIM_CLEAR_FRAME_BIT) = '1' then
                frame_count <= (others => '0');
              end if;
            when ADC_SIM_REG_SHADOW_EVENT_CONTROL =>
              shadow_event_control <= merge_strobes(shadow_event_control, wdata, wstrb);
            when ADC_SIM_REG_SHADOW_EVENT_SCALE =>
              shadow_event_scale <= merge_strobes(shadow_event_scale, wdata, wstrb);
            when ADC_SIM_REG_SHADOW_EVENT_TIMING =>
              shadow_event_timing <= merge_strobes(shadow_event_timing, wdata, wstrb);
            when ADC_SIM_REG_EVENT_TRIGGER =>
              -- Write-only strobes, evaluated in order: CANCEL then CLEAR
              -- then ARM, so a single word that both cancels and arms
              -- restarts cleanly instead of racing itself.  Like
              -- COUNTER_CLEAR this branch runs after the generation
              -- logic, so a strobe coincident with a sequencer update
              -- wins and the register is always observably obeyed.
              if wdata(ADC_SIM_EVENT_TRIGGER_CANCEL_BIT) = '1' then
                event_state <= EVT_IDLE;
              end if;
              if wdata(ADC_SIM_EVENT_TRIGGER_CLEAR_BIT) = '1' then
                event_count <= (others => '0');
              end if;
              -- A zero duration has no burst to run: the arm is ignored
              -- rather than committed as a zero-length event.
              if wdata(ADC_SIM_EVENT_TRIGGER_ARM_BIT) = '1' and
                 unsigned(shadow_event_timing(ADC_SIM_EVENT_DURATION_LSB + 15 downto
                                              ADC_SIM_EVENT_DURATION_LSB)) /= 0 then
                active_event_control <= shadow_event_control;
                event_scale_v := unsigned(shadow_event_scale);
                if event_scale_v > to_unsigned(ADC_SIM_EVENT_SCALE_MAX, 32) then
                  event_scale_v := to_unsigned(ADC_SIM_EVENT_SCALE_MAX, 32);
                end if;
                active_event_scale <= std_logic_vector(event_scale_v);
                active_event_timing <= shadow_event_timing;
                event_state <= EVT_ARMED;
              end if;
            when others =>
              if write_address >= ADC_SIM_REG_SHADOW_PEAK_BASE and
                 write_address < ADC_SIM_REG_SHADOW_PEAK_BASE + 32 and
                 (write_address mod 4) = 0 then
                array_index := (write_address - ADC_SIM_REG_SHADOW_PEAK_BASE) / 4;
                shadow_peak(array_index) <= merge_strobes(shadow_peak(array_index), wdata, wstrb);
              elsif write_address >= ADC_SIM_REG_SHADOW_PHASE_BASE and
                    write_address < ADC_SIM_REG_SHADOW_PHASE_BASE + 32 and
                    (write_address mod 4) = 0 then
                array_index := (write_address - ADC_SIM_REG_SHADOW_PHASE_BASE) / 4;
                shadow_phase(array_index) <= merge_strobes(shadow_phase(array_index), wdata, wstrb);
              elsif write_address >= ADC_SIM_REG_SHADOW_DC_BASE and
                    write_address < ADC_SIM_REG_SHADOW_DC_BASE + 32 and
                    (write_address mod 4) = 0 then
                array_index := (write_address - ADC_SIM_REG_SHADOW_DC_BASE) / 4;
                shadow_dc(array_index) <= merge_strobes(shadow_dc(array_index), wdata, wstrb);
              elsif write_address >= ADC_SIM_REG_SHADOW_NOISE_BASE and
                    write_address < ADC_SIM_REG_SHADOW_NOISE_BASE + 32 and
                    (write_address mod 4) = 0 then
                array_index := (write_address - ADC_SIM_REG_SHADOW_NOISE_BASE) / 4;
                shadow_noise(array_index) <= merge_strobes(shadow_noise(array_index), wdata, wstrb);
              elsif write_address >= ADC_SIM_REG_SHADOW_HARMONIC_BASE and
                    write_address < ADC_SIM_REG_SHADOW_HARMONIC_BASE +
                                      SIM_WAVE_HARMONIC_WORDS * 4 and
                    (write_address mod 4) = 0 then
                array_index := (write_address - ADC_SIM_REG_SHADOW_HARMONIC_BASE) / 4;
                shadow_harmonic(array_index) <= merge_strobes(shadow_harmonic(array_index), wdata, wstrb);
              end if;
          end case;
          aw_stored <= '0';
          w_stored <= '0';
          bvalid <= '1';
        end if;

        if rvalid = '1' and s_axi_rready = '1' then
          rvalid <= '0';
        end if;
        if s_axi_arvalid = '1' and rvalid = '0' then
          read_address := to_integer(unsigned(s_axi_araddr));
          case read_address is
            when ADC_SIM_REG_ID => rdata <= ADC_SIMULATOR_ID;
            when ADC_SIM_REG_VERSION => rdata <= ADC_SIMULATOR_VERSION;
            when ADC_SIM_REG_SHADOW_CONTROL => rdata <= shadow_control;
            when ADC_SIM_REG_SHADOW_SAMPLE_RATE => rdata <= shadow_sample_rate;
            when ADC_SIM_REG_SHADOW_FREQUENCY => rdata <= shadow_frequency;
            when ADC_SIM_REG_SHADOW_VALID_MASK => rdata <= x"000000" & shadow_valid_mask;
            when ADC_SIM_REG_SHADOW_GENERATION => rdata <= shadow_generation;
            when ADC_SIM_REG_STATUS =>
              rdata <= (others => '0');
              rdata(0) <= active_control(ADC_SIM_CONTROL_SOURCE_BIT);
              rdata(1) <= active_control(ADC_SIM_CONTROL_ENABLE_BIT);
              rdata(2) <= apply_pending;
              if saturation_count /= 0 then
                rdata(3) <= '1';
              else
                rdata(3) <= '0';
              end if;
              if missed_sample_count /= 0 then
                rdata(4) <= '1';
              else
                rdata(4) <= '0';
              end if;
            when ADC_SIM_REG_ACTIVE_SAMPLE_RATE => rdata <= active_sample_rate;
            when ADC_SIM_REG_ACTIVE_FREQUENCY => rdata <= active_frequency;
            when ADC_SIM_REG_ACTIVE_VALID_MASK => rdata <= x"000000" & active_valid_mask;
            when ADC_SIM_REG_ACTIVE_GENERATION => rdata <= active_generation;
            when ADC_SIM_REG_FRAME_COUNT => rdata <= std_logic_vector(frame_count);
            when ADC_SIM_REG_SATURATION_COUNT => rdata <= std_logic_vector(saturation_count);
            when ADC_SIM_REG_MISSED_SAMPLE_COUNT => rdata <= std_logic_vector(missed_sample_count);
            when ADC_SIM_REG_SHADOW_PHASE_STEP => rdata <= shadow_phase_step;
            when ADC_SIM_REG_ACTIVE_CONTROL => rdata <= active_control;
            when ADC_SIM_REG_ACTIVE_PHASE_STEP => rdata <= active_phase_step;
            when ADC_SIM_REG_SHADOW_EVENT_CONTROL => rdata <= shadow_event_control;
            when ADC_SIM_REG_SHADOW_EVENT_SCALE => rdata <= shadow_event_scale;
            when ADC_SIM_REG_SHADOW_EVENT_TIMING => rdata <= shadow_event_timing;
            when ADC_SIM_REG_ACTIVE_EVENT_CONTROL => rdata <= active_event_control;
            when ADC_SIM_REG_ACTIVE_EVENT_SCALE => rdata <= active_event_scale;
            when ADC_SIM_REG_ACTIVE_EVENT_TIMING => rdata <= active_event_timing;
            when ADC_SIM_REG_EVENT_STATUS =>
              rdata <= (others => '0');
              if event_state = EVT_ARMED then
                rdata(ADC_SIM_EVENT_STATUS_ARMED_BIT) <= '1';
              end if;
              if event_state = EVT_RUNNING then
                rdata(ADC_SIM_EVENT_STATUS_RUNNING_BIT) <= '1';
              end if;
              if event_state = EVT_HOLD then
                rdata(ADC_SIM_EVENT_STATUS_HOLDING_BIT) <= '1';
              end if;
              rdata(ADC_SIM_EVENT_STATUS_COUNT_LSB + 15 downto
                    ADC_SIM_EVENT_STATUS_COUNT_LSB) <= std_logic_vector(event_count);
            when ADC_SIM_REG_EVENT_REMAINING =>
              -- Half cycles left in the burst [15:0] and until the next
              -- repeat [31:16]: the live view a scenario procedure polls.
              rdata <= std_logic_vector(event_period) &
                       std_logic_vector(event_remaining);
            when others =>
              rdata <= (others => '0');
              if read_address >= ADC_SIM_REG_SHADOW_PEAK_BASE and
                 read_address < ADC_SIM_REG_SHADOW_PEAK_BASE + 32 and
                 (read_address mod 4) = 0 then
                array_index := (read_address - ADC_SIM_REG_SHADOW_PEAK_BASE) / 4;
                rdata <= shadow_peak(array_index);
              elsif read_address >= ADC_SIM_REG_SHADOW_PHASE_BASE and
                    read_address < ADC_SIM_REG_SHADOW_PHASE_BASE + 32 and
                    (read_address mod 4) = 0 then
                array_index := (read_address - ADC_SIM_REG_SHADOW_PHASE_BASE) / 4;
                rdata <= shadow_phase(array_index);
              elsif read_address >= ADC_SIM_REG_SHADOW_DC_BASE and
                    read_address < ADC_SIM_REG_SHADOW_DC_BASE + 32 and
                    (read_address mod 4) = 0 then
                array_index := (read_address - ADC_SIM_REG_SHADOW_DC_BASE) / 4;
                rdata <= shadow_dc(array_index);
              elsif read_address >= ADC_SIM_REG_ACTIVE_DC_BASE and
                    read_address < ADC_SIM_REG_ACTIVE_DC_BASE + 32 and
                    (read_address mod 4) = 0 then
                array_index := (read_address - ADC_SIM_REG_ACTIVE_DC_BASE) / 4;
                rdata <= active_dc(array_index);
              elsif read_address >= ADC_SIM_REG_SHADOW_NOISE_BASE and
                    read_address < ADC_SIM_REG_SHADOW_NOISE_BASE + 32 and
                    (read_address mod 4) = 0 then
                array_index := (read_address - ADC_SIM_REG_SHADOW_NOISE_BASE) / 4;
                rdata <= shadow_noise(array_index);
              elsif read_address >= ADC_SIM_REG_ACTIVE_NOISE_BASE and
                    read_address < ADC_SIM_REG_ACTIVE_NOISE_BASE + 32 and
                    (read_address mod 4) = 0 then
                array_index := (read_address - ADC_SIM_REG_ACTIVE_NOISE_BASE) / 4;
                rdata <= active_noise(array_index);
              elsif read_address >= ADC_SIM_REG_SHADOW_HARMONIC_BASE and
                    read_address < ADC_SIM_REG_SHADOW_HARMONIC_BASE +
                                     SIM_WAVE_HARMONIC_WORDS * 4 and
                    (read_address mod 4) = 0 then
                array_index := (read_address - ADC_SIM_REG_SHADOW_HARMONIC_BASE) / 4;
                rdata <= shadow_harmonic(array_index);
              elsif read_address >= ADC_SIM_REG_ACTIVE_HARMONIC_BASE and
                    read_address < ADC_SIM_REG_ACTIVE_HARMONIC_BASE +
                                     SIM_WAVE_HARMONIC_WORDS * 4 and
                    (read_address mod 4) = 0 then
                array_index := (read_address - ADC_SIM_REG_ACTIVE_HARMONIC_BASE) / 4;
                rdata <= active_harmonic(array_index);
              end if;
          end case;
          rvalid <= '1';
        end if;
      end if;
    end if;
  end process;
end architecture;
