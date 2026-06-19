-- BetterClimbing configuration
--
-- Restart the game after changing these settings.
-- A full restart is recommended instead of "Restart All Mods",
-- because changes are applied directly to objects already in memory.

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
    --     Recommended mode.
    --
    --     Automatically repairs registered PaintedClimbable components that
    --     use a Solid painted region and an Adamant unpainted region.
    --
    --     Dedicated Adamant, Weak, and other special climbable components
    --     remain unchanged.
    --
    -- "open"
    --     Relaxed climbing mode.
    --
    --     Converts every surface already registered by the game as climbable
    --     to Solid.
    --
    --     Ordinary scenery and objects without a climbable component remain
    --     non-climbable.
    --
    surface_mode = "painted",

    ---------------------------------------------------------------------------
    -- AUTOMATIC PATCHING
    ---------------------------------------------------------------------------

    -- How frequently the mod checks for climbing components loaded through
    -- level streaming.
    scan_interval_ms = 1500,

    -- Copies the Solid region's impact, sliding, particle, and audio references
    -- into repaired or converted regions.
    copy_solid_fx_and_audio = true,

    ---------------------------------------------------------------------------
    -- MOVEMENT IMPROVEMENTS
    ---------------------------------------------------------------------------

    -- Applies conservative climbing responsiveness improvements in Painted
    -- and Open modes.
    --
    -- Vanilla mode ignores all settings below.
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
    -- This is disabled by default until it has been tested throughout the
    -- entire game. It does not create a new jump system.
    enable_climbing_jump = false,

    -- Allows jumping while only one pickaxe is attached.
    allow_jump_with_one_pickaxe = true,

    -- Keeps normal air control after leaving the wall.
    keep_air_control_after_jump = true,

    ---------------------------------------------------------------------------
    -- LOGGING
    ---------------------------------------------------------------------------

    -- Writes additional information to UE4SS.log.
    verbose_logging = false,
}