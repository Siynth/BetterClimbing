-- BetterClimbing configuration
--
-- Restart the game after changing these settings.
-- A full restart is recommended instead of "Restart All Mods" because the
-- mod changes objects that are already in memory.

return {
    ---------------------------------------------------------------------------
    -- SURFACE MODE
    ---------------------------------------------------------------------------

    -- Available modes:
    --
    -- "vanilla"
    --     BetterClimbing makes no changes.
    --
    -- "painted"
    --     Recommended Vanilla+ mode.
    --
    --     Repairs the game's PaintedClimbable components while leaving
    --     dedicated Adamant, Weak, and other special climbables unchanged.
    --
    -- "open"
    --     Relaxed climbing mode.
    --
    --     Converts every surface already registered by the game as climbable
    --     to Solid. Ordinary scenery without a climbable component remains
    --     non-climbable.
    --
    surface_mode = "painted",

    ---------------------------------------------------------------------------
    -- EVENT-DRIVEN STARTUP
    ---------------------------------------------------------------------------

    -- One delayed discovery pass finds climbing objects that existed before
    -- the new-object callbacks were registered. It only queues those objects;
    -- it does not update all of them in one frame.
    initial_scan_delay_ms = 1500,

    -- Newly constructed surfaces are allowed to finish applying Blueprint
    -- defaults before the queue considers them ready.
    new_object_warmup_ms = 300,

    ---------------------------------------------------------------------------
    -- PERFORMANCE QUEUE
    ---------------------------------------------------------------------------

    -- The queue has one worker. Do not create a timer for every surface.
    --
    -- One update every 30 ms gives a theoretical maximum of about 33 surface
    -- updates per second while work exists, without continuous polling.
    queue_cycle_interval_ms = 30,

    -- Number of surfaces modified during one queue cycle.
    -- One is the safest setting for avoiding large frame spikes.
    queue_updates_per_cycle = 1,

    -- Number of newly queued surfaces whose distance may be classified during
    -- one cycle. Classification is lighter than modifying a surface, but this
    -- stays deliberately small to avoid adding work during level streaming.
    queue_classifications_per_cycle = 4,

    -- Surfaces within this distance are processed first.
    -- Unreal distances are normally measured in centimetres.
    near_priority_distance = 4000.0,

    -- Surfaces beyond the near distance but within this distance use medium
    -- priority. More distant or unlocatable surfaces remain background work.
    medium_priority_distance = 12000.0,

    -- Recheck a small rotating sample of queued surfaces periodically so that
    -- a surface can move to a higher priority as the player approaches it.
    priority_refresh_interval_cycles = 10,
    priority_probe_count = 4,

    -- Prevent medium and far work from being permanently starved while many
    -- nearby surfaces are loading.
    process_medium_every_cycles = 4,
    process_far_every_cycles = 12,

    -- Incompletely initialized objects are retried with queue-based backoff.
    -- No separate retry timer is created for each object.
    max_update_attempts = 3,
    retry_backoff_cycles = 10,

    -- Copies the Solid region's impact, sliding, particle, and audio references
    -- into repaired or converted regions when a known Solid behaviour exists.
    copy_solid_fx_and_audio = true,

    ---------------------------------------------------------------------------
    -- MOVEMENT IMPROVEMENTS
    ---------------------------------------------------------------------------

    -- Applies conservative climbing responsiveness improvements in Painted
    -- and Open modes. Vanilla mode ignores all settings below.
    enable_movement_improvements = true,

    -- Allows climbing to start with a single climbing input.
    start_with_one_button = true,

    -- How far the game checks for a climbing surface while standing.
    standing_detection_distance = 22.0,

    -- How far the game checks for a climbing surface while falling.
    falling_detection_distance = 55.0,

    -- Extra time allowed to grab a wall after moving past an edge.
    coyote_time = 0.30,

    -- Maximum distance at which a pickaxe can be recovered or grabbed.
    grab_pickaxe_distance = 600.0,

    -- Pickaxe movement responsiveness.
    max_pickaxe_velocity = 205.0,
    pickaxe_acceleration = 750.0,

    -- Values above this are reduced to the configured value.
    -- Lower values make stepping slightly quicker.
    maximum_step_duration_multiplier = 0.90,

    ---------------------------------------------------------------------------
    -- CLIMBING JUMP
    ---------------------------------------------------------------------------

    -- Enables the game's existing climbing-jump flags.
    --
    -- Disabled by default until it has been tested throughout the game.
    -- This does not create a new jump system.
    enable_climbing_jump = false,

    -- Allows jumping while only one pickaxe is attached.
    allow_jump_with_one_pickaxe = true,

    -- Keeps normal air control after leaving the wall.
    keep_air_control_after_jump = true,

    ---------------------------------------------------------------------------
    -- LOGGING
    ---------------------------------------------------------------------------

    -- Writes per-object and queue details to UE4SS.log.
    -- Leave false for normal play.
    verbose_logging = false,
}
