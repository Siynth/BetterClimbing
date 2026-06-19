-- BetterClimbing for Deliver Us Mars
-- UE4SS Lua mod
--
-- Modes:
--   vanilla  - no changes
--   painted  - repairs PaintedClimbable surfaces only
--   open     - makes all registered climbable surfaces Solid
--
-- Objects without a climbable component are never changed.

local MOD_NAME = "BetterClimbing"
local VERSION = "0.2.0"

-------------------------------------------------------------------------------
-- GAME ENUM VALUES
-------------------------------------------------------------------------------

-- EClimbableType
local TYPE_ADAMANT = 0
local TYPE_SOLID = 1
local TYPE_WEAK = 2

-------------------------------------------------------------------------------
-- DEFAULT CONFIGURATION
-------------------------------------------------------------------------------

local DEFAULT_CONFIG = {
    surface_mode = "painted",

    scan_interval_ms = 1500,
    copy_solid_fx_and_audio = true,

    enable_movement_improvements = true,
    start_with_one_button = true,

    standing_detection_distance = 22.0,
    falling_detection_distance = 55.0,
    coyote_time = 0.30,
    grab_pickaxe_distance = 600.0,
    max_pickaxe_velocity = 205.0,
    pickaxe_acceleration = 750.0,
    maximum_step_duration_multiplier = 0.90,

    enable_climbing_jump = false,
    allow_jump_with_one_pickaxe = true,
    keep_air_control_after_jump = true,

    verbose_logging = false,
}

-------------------------------------------------------------------------------
-- FEEDBACK FIELDS
-------------------------------------------------------------------------------

-- These fields are copied from a known Solid behaviour when a surface is
-- converted. The behaviour's owner pointer is deliberately not copied.

local FEEDBACK_FIELDS = {
    "PickaxeImpactParticles",
    "SlideRicochetParticles",
    "SlideStoppedParticles",
    "PickaxePullOutParticles",
    "PickaxeSlideParticles",
    "PickaxeSnapsOutOfWallParticles",
    "FootPlantedParticles",
    "FootLiftedParticles",

    "PickaxeSwingVoiceOver",
    "PickaxeSlideAudio",
    "SlideStoppedAudio",
    "SlideRicochetAudio",
    "SlideRicochetVoiceOver",
}

-------------------------------------------------------------------------------
-- CONFIG LOADING
-------------------------------------------------------------------------------

local function get_mod_directory()
    local ok, source = pcall(function()
        return debug.getinfo(1, "S").source
    end)

    if not ok or source == nil then
        return nil
    end

    if string.sub(source, 1, 1) == "@" then
        source = string.sub(source, 2)
    end

    return string.match(
        source,
        "^(.*)[/\\]scripts[/\\][^/\\]+$"
    )
end

local function load_config()
    local config = {}

    for key, value in pairs(DEFAULT_CONFIG) do
        config[key] = value
    end

    local mod_directory = get_mod_directory()

    if mod_directory == nil then
        return config
    end

    local config_path =
        mod_directory .. "\\config.lua"

    local ok, user_config =
        pcall(dofile, config_path)

    if ok and type(user_config) == "table" then
        for key, value in pairs(user_config) do
            if DEFAULT_CONFIG[key] ~= nil then
                config[key] = value
            end
        end
    else
        print(string.format(
            "[%s] Could not load config.lua: %s\n",
            MOD_NAME,
            tostring(user_config)
        ))
    end

    return config
end

local Config = load_config()

-------------------------------------------------------------------------------
-- MODE VALIDATION
-------------------------------------------------------------------------------

local function normalize_mode(value)
    local mode =
        string.lower(tostring(value or ""))

    if mode == "vanilla" then
        return "vanilla"
    end

    if mode == "painted"
        or mode == "painted_only" then

        return "painted"
    end

    if mode == "open"
        or mode == "all"
        or mode == "all_climbable" then

        return "open"
    end

    print(string.format(
        "[%s] Unknown surface mode '%s'. Using painted mode.\n",
        MOD_NAME,
        tostring(value)
    ))

    return "painted"
end

local ActiveMode =
    normalize_mode(Config.surface_mode)

-------------------------------------------------------------------------------
-- RUNTIME STATE
-------------------------------------------------------------------------------

local processed_painted = {}
local processed_standard = {}
local processed_climbers = {}

local scan_running = false

-------------------------------------------------------------------------------
-- LOGGING
-------------------------------------------------------------------------------

local function log(message, force)
    if force or Config.verbose_logging then
        print(string.format(
            "[%s] %s\n",
            MOD_NAME,
            message
        ))
    end
end

-------------------------------------------------------------------------------
-- SAFE OBJECT HELPERS
-------------------------------------------------------------------------------

local function is_valid(object)
    if object == nil then
        return false
    end

    local ok, result = pcall(function()
        return object:IsValid()
    end)

    return ok and result
end

local function get_address(object)
    if not is_valid(object) then
        return nil
    end

    local ok, address = pcall(function()
        return object:GetAddress()
    end)

    if ok and type(address) == "number" then
        return address
    end

    return nil
end

local function get_full_name(object)
    if not is_valid(object) then
        return "Invalid"
    end

    local ok, name = pcall(function()
        return object:GetFullName()
    end)

    if ok then
        return name
    end

    return "Unknown"
end

local function is_default_object(object)
    return string.find(
        get_full_name(object),
        "Default__",
        1,
        true
    ) ~= nil
end

local function object_key(object)
    local address = get_address(object)

    if address == nil then
        return nil
    end

    -- The name is included because Unreal may reuse an address after a level
    -- unloads and another level is streamed in.
    return string.format(
        "%X|%s",
        address,
        get_full_name(object)
    )
end

local function safe_read(object, property_name)
    local ok, value = pcall(function()
        return object[property_name]
    end)

    if ok then
        return value
    end

    return nil
end

local function safe_write(
    object,
    property_name,
    value
)
    local ok, error_message = pcall(function()
        object[property_name] = value
    end)

    if not ok then
        log(string.format(
            "Could not write %s on %s: %s",
            property_name,
            get_full_name(object),
            tostring(error_message)
        ))
    end

    return ok
end

-------------------------------------------------------------------------------
-- VALUE HELPERS
-------------------------------------------------------------------------------

local function set_boolean(
    object,
    property_name,
    desired_value
)
    local current =
        safe_read(object, property_name)

    if type(current) ~= "boolean" then
        return false
    end

    if current == desired_value then
        return true
    end

    return safe_write(
        object,
        property_name,
        desired_value
    )
end

local function set_minimum(
    object,
    property_name,
    minimum
)
    local current =
        safe_read(object, property_name)

    if type(current) ~= "number" then
        return false
    end

    if current >= minimum then
        return true
    end

    return safe_write(
        object,
        property_name,
        minimum
    )
end

local function set_maximum(
    object,
    property_name,
    maximum
)
    local current =
        safe_read(object, property_name)

    if type(current) ~= "number" then
        return false
    end

    if current <= maximum then
        return true
    end

    return safe_write(
        object,
        property_name,
        maximum
    )
end

-------------------------------------------------------------------------------
-- OBJECT DISCOVERY
-------------------------------------------------------------------------------

local function collect_instances(class_names)
    local results = {}
    local seen_addresses = {}

    for _, class_name in ipairs(class_names) do
        local ok, instances = pcall(function()
            return FindAllOf(class_name)
        end)

        if ok and instances ~= nil then
            for _, instance in pairs(instances) do
                if is_valid(instance)
                    and not is_default_object(instance) then

                    local address =
                        get_address(instance)

                    if address ~= nil
                        and not seen_addresses[address] then

                        seen_addresses[address] = true

                        table.insert(
                            results,
                            instance
                        )
                    end
                end
            end
        end
    end

    return results
end

-------------------------------------------------------------------------------
-- FX AND AUDIO COPYING
-------------------------------------------------------------------------------

local function copy_feedback(
    source_behaviour,
    target_behaviour
)
    if not Config.copy_solid_fx_and_audio
        or source_behaviour == nil
        or target_behaviour == nil then

        return
    end

    for _, field_name in ipairs(
        FEEDBACK_FIELDS
    ) do
        local read_ok, value = pcall(function()
            return source_behaviour[field_name]
        end)

        if read_ok then
            pcall(function()
                target_behaviour[field_name] =
                    value
            end)
        end
    end
end

-------------------------------------------------------------------------------
-- FIND A SOLID FEEDBACK DONOR
-------------------------------------------------------------------------------

local function find_solid_behaviour(
    painted_components,
    standard_components
)
    for _, component in ipairs(
        painted_components
    ) do
        local ok, behaviour = pcall(function()
            if component.PaintedBehaviour.Type
                == TYPE_SOLID then

                return component.PaintedBehaviour
            end

            if component.UnPaintedBehaviour.Type
                == TYPE_SOLID then

                return component.UnPaintedBehaviour
            end

            return nil
        end)

        if ok and behaviour ~= nil then
            return behaviour
        end
    end

    for _, component in ipairs(
        standard_components
    ) do
        local ok, behaviour = pcall(function()
            if component.Behaviour.Type
                == TYPE_SOLID then

                return component.Behaviour
            end

            return nil
        end)

        if ok and behaviour ~= nil then
            return behaviour
        end
    end

    return nil
end

-------------------------------------------------------------------------------
-- PAINTED SURFACE MODE
-------------------------------------------------------------------------------

local function process_painted_component(
    component,
    global_solid_donor
)
    local key = object_key(component)

    if key == nil or processed_painted[key] then
        return
    end

    local ok, changed_or_error = pcall(function()
        local painted =
            component.PaintedBehaviour

        local unpainted =
            component.UnPaintedBehaviour

        -----------------------------------------------------------------------
        -- PAINTED MODE
        -----------------------------------------------------------------------

        if ActiveMode == "painted" then
            -- This is the tested Vanilla+ repair:
            --
            -- Solid painted region + Adamant unpainted region.
            --
            -- Only PaintedClimbable components are affected. Dedicated
            -- Adamant and Weak climbables are not touched.

            if painted.Type ~= TYPE_SOLID then
                return false
            end

            if unpainted.Type ~= TYPE_ADAMANT then
                return false
            end

            copy_feedback(
                painted,
                unpainted
            )

            unpainted.Type = TYPE_SOLID

            if component.UnPaintedBehaviour.Type
                ~= TYPE_SOLID then

                error(
                    "Painted surface repair verification failed"
                )
            end

            return true
        end

        -----------------------------------------------------------------------
        -- OPEN MODE
        -----------------------------------------------------------------------

        if ActiveMode == "open" then
            local donor = global_solid_donor

            if painted.Type == TYPE_SOLID then
                donor = painted
            elseif unpainted.Type == TYPE_SOLID then
                donor = unpainted
            end

            local changed =
                painted.Type ~= TYPE_SOLID
                or unpainted.Type ~= TYPE_SOLID

            if donor ~= nil then
                if painted.Type ~= TYPE_SOLID then
                    copy_feedback(
                        donor,
                        painted
                    )
                end

                if unpainted.Type ~= TYPE_SOLID then
                    copy_feedback(
                        donor,
                        unpainted
                    )
                end
            end

            painted.Type = TYPE_SOLID
            unpainted.Type = TYPE_SOLID

            return changed
        end

        return false
    end)

    if not ok then
        log(string.format(
            "Could not process painted component %s: %s",
            get_full_name(component),
            tostring(changed_or_error)
        ))

        return
    end

    processed_painted[key] = true

    if changed_or_error then
        log(
            "Updated painted climbable: "
            .. get_full_name(component),
            true
        )
    end
end

-------------------------------------------------------------------------------
-- OPEN MODE STANDARD CLIMBABLES
-------------------------------------------------------------------------------

local function process_standard_climbable(
    component,
    global_solid_donor
)
    if ActiveMode ~= "open" then
        return
    end

    local key = object_key(component)

    if key == nil or processed_standard[key] then
        return
    end

    local ok, changed_or_error = pcall(function()
        local behaviour =
            component.Behaviour

        local changed =
            behaviour.Type ~= TYPE_SOLID

        if changed
            and global_solid_donor ~= nil then

            copy_feedback(
                global_solid_donor,
                behaviour
            )
        end

        behaviour.Type = TYPE_SOLID

        if component.Behaviour.Type
            ~= TYPE_SOLID then

            error(
                "Open-mode surface verification failed"
            )
        end

        return changed
    end)

    if not ok then
        log(string.format(
            "Could not process climbable component %s: %s",
            get_full_name(component),
            tostring(changed_or_error)
        ))

        return
    end

    processed_standard[key] = true

    if changed_or_error then
        log(
            "Converted registered climbable to Solid: "
            .. get_full_name(component),
            true
        )
    end
end

-------------------------------------------------------------------------------
-- MOVEMENT IMPROVEMENTS
-------------------------------------------------------------------------------

local function tune_climber(climber)
    if not Config.enable_movement_improvements then
        return
    end

    local key = object_key(climber)

    if key == nil or processed_climbers[key] then
        return
    end

    -- Use the game's public setters when available.
    pcall(function()
        climber:SetClimbingAllowed(true)
    end)

    if Config.start_with_one_button then
        pcall(function()
            climber:SetStartClimbingWithOneButton(
                true
            )
        end)
    end

    set_boolean(
        climber,
        "bClimbingAllowed",
        true
    )

    set_boolean(
        climber,
        "bStartClimbingWithOneButton",
        Config.start_with_one_button
    )

    set_minimum(
        climber,
        "ClimbableDetectionDistStanding",
        Config.standing_detection_distance
    )

    set_minimum(
        climber,
        "ClimbableDetectionDistFalling",
        Config.falling_detection_distance
    )

    set_minimum(
        climber,
        "CoyoteTime",
        Config.coyote_time
    )

    set_minimum(
        climber,
        "GrabPickaxeDistance",
        Config.grab_pickaxe_distance
    )

    set_minimum(
        climber,
        "MaxPickaxeVelocity",
        Config.max_pickaxe_velocity
    )

    set_minimum(
        climber,
        "PickaxeAcceleration",
        Config.pickaxe_acceleration
    )

    set_maximum(
        climber,
        "StepDurationMultiplier",
        Config.maximum_step_duration_multiplier
    )

    ---------------------------------------------------------------------------
    -- OPTIONAL CLIMBING JUMP
    ---------------------------------------------------------------------------

    if Config.enable_climbing_jump then
        set_boolean(
            climber,
            "bAllowJumping",
            true
        )

        set_boolean(
            climber,
            "bAllowJumpingWithOnePickaxe",
            Config.allow_jump_with_one_pickaxe
        )

        set_boolean(
            climber,
            "bDisableAirControlOnJump",
            not Config.keep_air_control_after_jump
        )
    end

    processed_climbers[key] = true

    log(
        "Applied climbing movement settings to: "
        .. get_full_name(climber)
    )
end

-------------------------------------------------------------------------------
-- MAIN SCAN
-------------------------------------------------------------------------------

local function scan_game()
    if scan_running
        or ActiveMode == "vanilla" then

        return
    end

    scan_running = true

    local ok, error_message = pcall(function()
        local painted_components =
            collect_instances({
                "PaintedClimbable",
                "BP_PaintedClimbable_Mars_C",
            })

        local standard_components = {}

        if ActiveMode == "open" then
            standard_components =
                collect_instances({
                    "Climbable",

                    "BP_AdamantClimbable_Mars_C",
                    "BP_AdamantClimbable_Metal_C",

                    "BP_SolidClimbable_Mars_C",
                    "BP_SolidClimbable_Cloth_C",
                })
        end

        local solid_donor =
            find_solid_behaviour(
                painted_components,
                standard_components
            )

        for _, component in ipairs(
            painted_components
        ) do
            process_painted_component(
                component,
                solid_donor
            )
        end

        if ActiveMode == "open" then
            for _, component in ipairs(
                standard_components
            ) do
                process_standard_climbable(
                    component,
                    solid_donor
                )
            end
        end

        local climbers =
            collect_instances({
                "ClimberComponent",
                "BP_Climber_C",
            })

        for _, climber in ipairs(climbers) do
            tune_climber(climber)
        end
    end)

    scan_running = false

    if not ok then
        log(
            "Automatic scan failed: "
            .. tostring(error_message),
            true
        )
    end
end

-------------------------------------------------------------------------------
-- SCHEDULING
-------------------------------------------------------------------------------

local function scan_on_game_thread()
    if type(ExecuteInGameThread)
        == "function" then

        ExecuteInGameThread(scan_game)
    else
        scan_game()
    end
end

local function schedule_next_scan()
    local interval =
        tonumber(Config.scan_interval_ms)
        or 1500

    if interval < 500 then
        interval = 500
    end

    ExecuteWithDelay(interval, function()
        scan_on_game_thread()
        schedule_next_scan()
    end)
end

-------------------------------------------------------------------------------
-- STARTUP
-------------------------------------------------------------------------------

print(string.format(
    "[%s] v%s loading with mode: %s\n",
    MOD_NAME,
    VERSION,
    ActiveMode
))

if ActiveMode == "vanilla" then
    print(string.format(
        "[%s] Vanilla mode selected. No changes will be applied.\n",
        MOD_NAME
    ))

    return
end

ExecuteWithDelay(1000, function()
    scan_on_game_thread()
end)

schedule_next_scan()

print(string.format(
    "[%s] Automatic climbing improvements enabled: %s\n",
    MOD_NAME,
    ActiveMode
))