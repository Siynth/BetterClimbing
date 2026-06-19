-- BetterClimbing for Deliver Us Mars
-- UE4SS Lua mod
--
-- Modes:
--   vanilla  - no changes
--   painted  - repairs PaintedClimbable surfaces only
--   open     - makes all registered climbable surfaces Solid
--
-- The mod performs one startup scan, then relies on NotifyOnNewObject for
-- streamed-in objects. There is no repeating FindAllOf polling loop.

local MOD_NAME = "BetterClimbing"
local VERSION = "0.3.0-beta"

-- EClimbableType
local TYPE_ADAMANT = 0
local TYPE_SOLID = 1

local DEFAULT_CONFIG = {
    surface_mode = "painted",

    initial_scan_delay_ms = 1500,
    new_object_delay_ms = 250,
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

-- The owning Climbable pointer and ConveyorVelocity are intentionally omitted.
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
-- Configuration
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

    return string.match(source, "^(.*)[/\\]scripts[/\\][^/\\]+$")
end

local function load_config()
    local config = {}

    for key, value in pairs(DEFAULT_CONFIG) do
        config[key] = value
    end

    local directory = get_mod_directory()
    if directory == nil then
        return config
    end

    local ok, user_config = pcall(dofile, directory .. "\\config.lua")

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

local function normalize_mode(value)
    local mode = string.lower(tostring(value or ""))

    if mode == "vanilla" then
        return "vanilla"
    elseif mode == "painted" or mode == "painted_only" then
        return "painted"
    elseif mode == "open" or mode == "all" or mode == "all_climbable" then
        return "open"
    end

    print(string.format(
        "[%s] Unknown surface mode '%s'. Using painted mode.\n",
        MOD_NAME,
        tostring(value)
    ))

    return "painted"
end

local ActiveMode = normalize_mode(Config.surface_mode)

-------------------------------------------------------------------------------
-- Runtime state and safe helpers
-------------------------------------------------------------------------------

local processed_painted = {}
local processed_standard = {}
local processed_climbers = {}
local startup_scan_running = false

-- Store the donor owner and property name rather than a long-lived struct proxy.
local solid_donor_owner = nil
local solid_donor_field = nil

local function log(message, force)
    if force or Config.verbose_logging then
        print(string.format("[%s] %s\n", MOD_NAME, message))
    end
end

local function is_valid(object)
    if object == nil then
        return false
    end

    local ok, result = pcall(function()
        return object:IsValid()
    end)

    return ok and result
end

local function get_full_name(object)
    if not is_valid(object) then
        return "Invalid"
    end

    local ok, name = pcall(function()
        return object:GetFullName()
    end)

    return ok and tostring(name) or "Unknown"
end

local function object_key(object)
    if not is_valid(object) then
        return nil
    end

    local ok, address = pcall(function()
        return object:GetAddress()
    end)

    if not ok or type(address) ~= "number" then
        return nil
    end

    -- Including the name protects against address reuse after level unloads.
    return string.format("%X|%s", address, get_full_name(object))
end

local function safe_read(object, property_name)
    local ok, value = pcall(function()
        return object[property_name]
    end)

    return ok and value or nil
end

local function safe_write(object, property_name, value)
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

local function run_on_game_thread(callback)
    if type(ExecuteInGameThread) == "function" then
        ExecuteInGameThread(callback)
    else
        callback()
    end
end

local function set_boolean(object, property_name, value)
    local current = safe_read(object, property_name)

    if type(current) ~= "boolean" or current == value then
        return
    end

    safe_write(object, property_name, value)
end

local function set_minimum(object, property_name, value)
    local current = safe_read(object, property_name)

    if type(current) ~= "number" or current >= value then
        return
    end

    safe_write(object, property_name, value)
end

local function set_maximum(object, property_name, value)
    local current = safe_read(object, property_name)

    if type(current) ~= "number" or current <= value then
        return
    end

    safe_write(object, property_name, value)
end

-------------------------------------------------------------------------------
-- One-time object discovery
-------------------------------------------------------------------------------

local function collect_instances(class_name)
    local ok, instances = pcall(function()
        return FindAllOf(class_name)
    end)

    if not ok or instances == nil then
        return {}
    end

    local results = {}

    for _, instance in pairs(instances) do
        if is_valid(instance) then
            table.insert(results, instance)
        end
    end

    return results
end

-------------------------------------------------------------------------------
-- Solid feedback donor
-------------------------------------------------------------------------------

local function remember_solid_donor(component)
    if not is_valid(component) then
        return false
    end

    for _, field_name in ipairs({
        "PaintedBehaviour",
        "UnPaintedBehaviour",
        "Behaviour",
    }) do
        local behaviour = safe_read(component, field_name)

        if behaviour ~= nil then
            local ok, behaviour_type = pcall(function()
                return behaviour.Type
            end)

            if ok and behaviour_type == TYPE_SOLID then
                solid_donor_owner = component
                solid_donor_field = field_name
                return true
            end
        end
    end

    return false
end

local function get_solid_donor()
    if not is_valid(solid_donor_owner) or solid_donor_field == nil then
        solid_donor_owner = nil
        solid_donor_field = nil
        return nil
    end

    local behaviour = safe_read(solid_donor_owner, solid_donor_field)

    if behaviour == nil then
        return nil
    end

    local ok, behaviour_type = pcall(function()
        return behaviour.Type
    end)

    if not ok or behaviour_type ~= TYPE_SOLID then
        solid_donor_owner = nil
        solid_donor_field = nil
        return nil
    end

    return behaviour
end

local function copy_feedback(source_behaviour, target_behaviour)
    if not Config.copy_solid_fx_and_audio
        or source_behaviour == nil
        or target_behaviour == nil then

        return
    end

    for _, field_name in ipairs(FEEDBACK_FIELDS) do
        local read_ok, value = pcall(function()
            return source_behaviour[field_name]
        end)

        if read_ok then
            pcall(function()
                target_behaviour[field_name] = value
            end)
        end
    end
end

-------------------------------------------------------------------------------
-- Surface processing
-------------------------------------------------------------------------------

-- Returns complete, changed. A false complete value asks the new-object handler
-- to retry after Unreal has had more time to initialize the component.
local function process_painted_component(component)
    local key = object_key(component)

    if key == nil then
        return false, false
    elseif processed_painted[key] then
        return true, false
    end

    local ok, complete, changed = pcall(function()
        local painted = component.PaintedBehaviour
        local unpainted = component.UnPaintedBehaviour

        if painted == nil or unpainted == nil then
            return false, false
        end

        local painted_type = painted.Type
        local unpainted_type = unpainted.Type

        if type(painted_type) ~= "number"
            or type(unpainted_type) ~= "number" then

            return false, false
        end

        -- Preserve a genuine Solid behaviour before changing anything.
        if painted_type == TYPE_SOLID
            or unpainted_type == TYPE_SOLID then

            remember_solid_donor(component)
        end

        if ActiveMode == "painted" then
            -- Tested Vanilla+ repair. Only the usual Solid-painted / Adamant-
            -- unpainted pairing is changed; unusual or special pairings remain.
            if painted_type == TYPE_SOLID
                and unpainted_type == TYPE_ADAMANT then

                copy_feedback(painted, unpainted)
                unpainted.Type = TYPE_SOLID

                if component.UnPaintedBehaviour.Type ~= TYPE_SOLID then
                    error("Painted surface repair verification failed")
                end

                return true, true
            end

            return true, false
        end

        if ActiveMode == "open" then
            local donor = get_solid_donor()

            if painted_type == TYPE_SOLID then
                donor = painted
            elseif unpainted_type == TYPE_SOLID then
                donor = unpainted
            end

            local was_changed =
                painted_type ~= TYPE_SOLID
                or unpainted_type ~= TYPE_SOLID

            if donor ~= nil then
                if painted_type ~= TYPE_SOLID then
                    copy_feedback(donor, painted)
                end

                if unpainted_type ~= TYPE_SOLID then
                    copy_feedback(donor, unpainted)
                end
            end

            painted.Type = TYPE_SOLID
            unpainted.Type = TYPE_SOLID

            if component.PaintedBehaviour.Type ~= TYPE_SOLID
                or component.UnPaintedBehaviour.Type ~= TYPE_SOLID then

                error("Open-mode painted surface verification failed")
            end

            return true, was_changed
        end

        return true, false
    end)

    if not ok then
        log(string.format(
            "Could not process painted component %s: %s",
            get_full_name(component),
            tostring(complete)
        ))

        return false, false
    end

    if complete then
        processed_painted[key] = true

        if changed then
            log(
                "Updated painted climbable: "
                .. get_full_name(component)
            )
        end
    end

    return complete, changed
end

local function process_standard_climbable(component)
    if ActiveMode ~= "open" then
        return true, false
    end

    local key = object_key(component)

    if key == nil then
        return false, false
    elseif processed_standard[key] then
        return true, false
    end

    local ok, complete, changed = pcall(function()
        local behaviour = component.Behaviour

        if behaviour == nil then
            return false, false
        end

        local behaviour_type = behaviour.Type

        if type(behaviour_type) ~= "number" then
            return false, false
        end

        -- Only remember a donor that was genuinely Solid before conversion.
        if behaviour_type == TYPE_SOLID then
            remember_solid_donor(component)
        end

        local was_changed =
            behaviour_type ~= TYPE_SOLID

        if was_changed then
            copy_feedback(
                get_solid_donor(),
                behaviour
            )

            behaviour.Type = TYPE_SOLID
        end

        if component.Behaviour.Type ~= TYPE_SOLID then
            error("Open-mode standard surface verification failed")
        end

        return true, was_changed
    end)

    if not ok then
        log(string.format(
            "Could not process climbable component %s: %s",
            get_full_name(component),
            tostring(complete)
        ))

        return false, false
    end

    if complete then
        processed_standard[key] = true

        if changed then
            log(
                "Converted registered climbable to Solid: "
                .. get_full_name(component)
            )
        end
    end

    return complete, changed
end

-------------------------------------------------------------------------------
-- Climber processing
-------------------------------------------------------------------------------

local function tune_climber(climber)
    if not Config.enable_movement_improvements
        and not Config.enable_climbing_jump then

        return true
    end

    local key = object_key(climber)

    if key == nil then
        return false
    elseif processed_climbers[key] then
        return true
    end

    if Config.enable_movement_improvements then
        pcall(function()
            climber:SetClimbingAllowed(true)
        end)

        if Config.start_with_one_button then
            pcall(function()
                climber:SetStartClimbingWithOneButton(true)
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
    end

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
        "Applied climbing settings to: "
        .. get_full_name(climber)
    )

    return true
end

-------------------------------------------------------------------------------
-- Event-driven processing
-------------------------------------------------------------------------------

local function schedule_object_processing(object, processor)
    local first_delay =
        tonumber(Config.new_object_delay_ms)
        or 250

    first_delay =
        math.max(0, first_delay)

    local retry_delay =
        math.max(250, first_delay)

    local max_attempts = 3

    local function attempt(number)
        local delay =
            number == 1
            and first_delay
            or retry_delay

        ExecuteWithDelay(delay, function()
            run_on_game_thread(function()
                if not is_valid(object) then
                    return
                end

                local complete =
                    processor(object)

                if not complete
                    and number < max_attempts then

                    attempt(number + 1)
                end
            end)
        end)
    end

    attempt(1)
end

local function register_new_object_listener(
    class_path,
    processor
)
    local ok, error_message = pcall(function()
        NotifyOnNewObject(
            class_path,

            function(object)
                schedule_object_processing(
                    object,
                    processor
                )

                -- Keep listening for future objects.
                return false
            end
        )
    end)

    if not ok then
        log(string.format(
            "Could not register listener for %s: %s",
            class_path,
            tostring(error_message)
        ), true)
    end
end

local function process_new_painted(component)
    remember_solid_donor(component)
    return process_painted_component(component)
end

local function process_new_standard(component)
    remember_solid_donor(component)
    return process_standard_climbable(component)
end

-------------------------------------------------------------------------------
-- One startup pass for objects that predate the listeners
-------------------------------------------------------------------------------

local function run_startup_scan()
    if startup_scan_running
        or ActiveMode == "vanilla" then

        return
    end

    startup_scan_running = true

    local ok, error_message = pcall(function()
        local painted_components =
            collect_instances(
                "PaintedClimbable"
            )

        local standard_components =
            ActiveMode == "open"
            and collect_instances("Climbable")
            or {}

        local climbers =
            collect_instances(
                "ClimberComponent"
            )

        -- Locate a genuine Solid donor before converting anything.
        for _, component in ipairs(
            painted_components
        ) do
            if remember_solid_donor(component) then
                break
            end
        end

        if get_solid_donor() == nil then
            for _, component in ipairs(
                standard_components
            ) do
                if remember_solid_donor(component) then
                    break
                end
            end
        end

        local painted_changed = 0
        local standard_changed = 0

        for _, component in ipairs(
            painted_components
        ) do
            local _, changed =
                process_painted_component(component)

            if changed then
                painted_changed =
                    painted_changed + 1
            end
        end

        for _, component in ipairs(
            standard_components
        ) do
            local _, changed =
                process_standard_climbable(component)

            if changed then
                standard_changed =
                    standard_changed + 1
            end
        end

        for _, climber in ipairs(climbers) do
            tune_climber(climber)
        end

        log(string.format(
            "Startup pass complete: %d painted updated, "
            .. "%d standard updated, %d climber(s) found.",
            painted_changed,
            standard_changed,
            #climbers
        ), true)
    end)

    startup_scan_running = false

    if not ok then
        log(
            "Startup scan failed: "
            .. tostring(error_message),
            true
        )
    end
end

-------------------------------------------------------------------------------
-- Startup
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

-- NotifyOnNewObject covers Blueprint subclasses of these native base classes.
register_new_object_listener(
    "/Script/DeliverUsMars.PaintedClimbable",
    process_new_painted
)

if ActiveMode == "open" then
    register_new_object_listener(
        "/Script/DeliverUsMars.Climbable",
        process_new_standard
    )
end

if Config.enable_movement_improvements
    or Config.enable_climbing_jump then

    register_new_object_listener(
        "/Script/DeliverUsMars.ClimberComponent",
        tune_climber
    )
end

local startup_delay =
    tonumber(Config.initial_scan_delay_ms)
    or 1500

startup_delay =
    math.max(0, startup_delay)

ExecuteWithDelay(startup_delay, function()
    run_on_game_thread(
        run_startup_scan
    )
end)

print(string.format(
    "[%s] Event-driven climbing improvements enabled: %s\n",
    MOD_NAME,
    ActiveMode
))