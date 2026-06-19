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
    -- EVENT-DRIVEN INITIALIZATION
    ---------------------------------------------------------------------------

    -- The mod does one delayed scan after startup for objects that existed
    -- before its callbacks were registered. This is not a repeating scan.
    initial_scan_delay_ms = 1500,

    -- Newly constructed climbing objects are processed after a short delay so
    -- Unreal can finish applying their Blueprint defaults and construction data.
    new_object_delay_ms = 250,

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

    -- Writes per-object details to UE4SS.log.
    -- Leave false for normal play.
    verbose_logging = false,
}