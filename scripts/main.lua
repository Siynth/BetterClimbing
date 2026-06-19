-- BetterClimbing for Deliver Us Mars
-- UE4SS Lua mod
--
-- Modes:
--   vanilla  - no changes
--   painted  - repairs PaintedClimbable surfaces only
--   open     - makes all registered climbable surfaces Solid
--
-- Performance design:
--   * One startup discovery pass.
--   * NotifyOnNewObject for streamed-in objects.
--   * One paced queue worker.
--   * Distance-based priority using the current ClimberComponent.
--   * No repeating FindAllOf scan.
--   * No timer per surface.

local MOD_NAME = "BetterClimbing"
local VERSION = "0.4.0"

-------------------------------------------------------------------------------
-- GAME ENUM VALUES
-------------------------------------------------------------------------------

-- EClimbableType
local TYPE_ADAMANT = 0
local TYPE_SOLID = 1

-------------------------------------------------------------------------------
-- DEFAULT CONFIGURATION
-------------------------------------------------------------------------------

local DEFAULT_CONFIG = {
    surface_mode = "painted",

    initial_scan_delay_ms = 1500,
    new_object_warmup_ms = 300,

    queue_cycle_interval_ms = 30,
    queue_updates_per_cycle = 1,
    queue_classifications_per_cycle = 4,

    near_priority_distance = 4000.0,
    medium_priority_distance = 12000.0,

    priority_refresh_interval_cycles = 10,
    priority_probe_count = 4,

    process_medium_every_cycles = 4,
    process_far_every_cycles = 12,

    max_update_attempts = 3,
    retry_backoff_cycles = 10,

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
-- CONFIGURATION
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

    local mod_directory = get_mod_directory()

    if mod_directory == nil then
        return config
    end

    local ok, user_config =
        pcall(dofile, mod_directory .. "\\config.lua")

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

local ActiveMode = normalize_mode(Config.surface_mode)

-------------------------------------------------------------------------------
-- NORMALIZED PERFORMANCE SETTINGS
-------------------------------------------------------------------------------

local QUEUE_INTERVAL_MS =
    math.max(
        10,
        math.floor(
            tonumber(Config.queue_cycle_interval_ms)
            or 30
        )
    )

local UPDATES_PER_CYCLE =
    math.max(
        1,
        math.floor(
            tonumber(Config.queue_updates_per_cycle)
            or 1
        )
    )

local CLASSIFICATIONS_PER_CYCLE =
    math.max(
        1,
        math.floor(
            tonumber(Config.queue_classifications_per_cycle)
            or 4
        )
    )

local PRIORITY_REFRESH_INTERVAL =
    math.max(
        1,
        math.floor(
            tonumber(Config.priority_refresh_interval_cycles)
            or 10
        )
    )

local PRIORITY_PROBE_COUNT =
    math.max(
        0,
        math.floor(
            tonumber(Config.priority_probe_count)
            or 4
        )
    )

local MEDIUM_EVERY_CYCLES =
    math.max(
        0,
        math.floor(
            tonumber(Config.process_medium_every_cycles)
            or 4
        )
    )

local FAR_EVERY_CYCLES =
    math.max(
        0,
        math.floor(
            tonumber(Config.process_far_every_cycles)
            or 12
        )
    )

local MAX_UPDATE_ATTEMPTS =
    math.max(
        1,
        math.floor(
            tonumber(Config.max_update_attempts)
            or 3
        )
    )

local RETRY_BACKOFF_CYCLES =
    math.max(
        1,
        math.floor(
            tonumber(Config.retry_backoff_cycles)
            or 10
        )
    )

local NEW_OBJECT_WARMUP_CYCLES =
    math.max(
        0,
        math.ceil(
            math.max(
                0,
                tonumber(Config.new_object_warmup_ms)
                or 300
            ) / QUEUE_INTERVAL_MS
        )
    )

local NEAR_DISTANCE =
    math.max(
        0,
        tonumber(Config.near_priority_distance)
        or 4000.0
    )

local MEDIUM_DISTANCE =
    math.max(
        NEAR_DISTANCE,
        tonumber(Config.medium_priority_distance)
        or 12000.0
    )

local NEAR_DISTANCE_SQUARED =
    NEAR_DISTANCE * NEAR_DISTANCE

local MEDIUM_DISTANCE_SQUARED =
    MEDIUM_DISTANCE * MEDIUM_DISTANCE

-------------------------------------------------------------------------------
-- RUNTIME STATE
-------------------------------------------------------------------------------

local processed_painted = {}
local processed_standard = {}
local processed_climbers = {}

local queued_keys = {}

local current_climber = nil

-- Store the donor owner and field name instead of retaining a long-lived
-- reference to a reflected struct proxy.
local solid_donor_owner = nil
local solid_donor_field = nil

local queue_cycle = 0
local queue_worker_running = false
local startup_scan_running = false

local queue_totals = {
    enqueued = 0,
    completed = 0,
    dropped = 0,
    retried = 0,
}

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
        return tostring(name)
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

    -- Including the path protects against common address-reuse cases after a
    -- streamed level unloads and a different object occupies the same address.
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

local function run_on_game_thread(callback)
    if type(ExecuteInGameThread) == "function" then
        ExecuteInGameThread(callback)
    else
        callback()
    end
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
-- COMPACT FIFO QUEUES
-------------------------------------------------------------------------------

-- Using a head index avoids table.remove(queue, 1), which shifts every entry.
local function new_fifo()
    return {
        items = {},
        head = 1,
    }
end

local function fifo_size(queue)
    local count =
        #queue.items - queue.head + 1

    if count < 0 then
        return 0
    end

    return count
end

local function fifo_push(queue, value)
    queue.items[#queue.items + 1] = value
end

local function fifo_compact(queue)
    local old_items = queue.items
    local old_count = #old_items
    local new_items = {}
    local new_index = 1

    for index = queue.head, old_count do
        new_items[new_index] = old_items[index]
        new_index = new_index + 1
    end

    queue.items = new_items
    queue.head = 1
end

local function fifo_pop(queue)
    if queue.head > #queue.items then
        queue.items = {}
        queue.head = 1
        return nil
    end

    local value =
        queue.items[queue.head]

    queue.head =
        queue.head + 1

    if queue.head > #queue.items then
        queue.items = {}
        queue.head = 1
    elseif queue.head > 256
        and queue.head > (#queue.items / 2) then

        fifo_compact(queue)
    end

    return value
end

local incoming_live = new_fifo()
local incoming_startup = new_fifo()

local near_queue = new_fifo()
local medium_queue = new_fifo()
local far_queue = new_fifo()

local function total_queue_size()
    return
        fifo_size(incoming_live)
        + fifo_size(incoming_startup)
        + fifo_size(near_queue)
        + fifo_size(medium_queue)
        + fifo_size(far_queue)
end

-------------------------------------------------------------------------------
-- ONE-TIME OBJECT DISCOVERY
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
        if is_valid(instance)
            and not is_default_object(instance) then

            table.insert(
                results,
                instance
            )
        end
    end

    return results
end

-------------------------------------------------------------------------------
-- POSITION AND DISTANCE HELPERS
-------------------------------------------------------------------------------

local function vector_components(vector)
    if vector == nil then
        return nil
    end

    local ok, x, y, z = pcall(function()
        return vector.X, vector.Y, vector.Z
    end)

    if not ok
        or type(x) ~= "number"
        or type(y) ~= "number"
        or type(z) ~= "number" then

        return nil
    end

    return x, y, z
end

local function call_location_function(
    object,
    function_name
)
    if not is_valid(object) then
        return nil
    end

    local ok, location = pcall(function()
        return object[function_name](object)
    end)

    if not ok then
        return nil
    end

    local x, y, z =
        vector_components(location)

    if x == nil then
        return nil
    end

    return {
        X = x,
        Y = y,
        Z = z,
    }
end

local function get_owner(object)
    if not is_valid(object) then
        return nil
    end

    local ok, owner = pcall(function()
        return object:GetOwner()
    end)

    if ok and is_valid(owner) then
        return owner
    end

    return nil
end

local function get_actor_location(actor)
    local location =
        call_location_function(
            actor,
            "K2_GetActorLocation"
        )

    if location ~= nil then
        return location
    end

    return call_location_function(
        actor,
        "GetActorLocation"
    )
end

local function get_climber_location()
    if not is_valid(current_climber) then
        current_climber = nil
        return nil
    end

    local location =
        call_location_function(
            current_climber,
            "K2_GetComponentLocation"
        )

    if location ~= nil then
        return location
    end

    local owner =
        get_owner(current_climber)

    if owner ~= nil then
        return get_actor_location(owner)
    end

    return nil
end

local function get_surface_location(component)
    if not is_valid(component) then
        return nil
    end

    -- PaintedClimbable and Climbable are ActorComponents, so the owning actor
    -- is the cheapest reliable approximation for scheduling priority.
    local owner =
        get_owner(component)

    if owner ~= nil then
        return get_actor_location(owner)
    end

    return nil
end

local function squared_distance(a, b)
    if a == nil or b == nil then
        return nil
    end

    local dx = a.X - b.X
    local dy = a.Y - b.Y
    local dz = a.Z - b.Z

    return
        dx * dx
        + dy * dy
        + dz * dz
end

-------------------------------------------------------------------------------
-- SOLID FEEDBACK DONOR
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
        local behaviour =
            safe_read(component, field_name)

        if behaviour ~= nil then
            local ok, behaviour_type = pcall(function()
                return behaviour.Type
            end)

            if ok
                and behaviour_type == TYPE_SOLID then

                solid_donor_owner = component
                solid_donor_field = field_name
                return true
            end
        end
    end

    return false
end

local function get_solid_donor()
    if not is_valid(solid_donor_owner)
        or solid_donor_field == nil then

        solid_donor_owner = nil
        solid_donor_field = nil
        return nil
    end

    local behaviour =
        safe_read(
            solid_donor_owner,
            solid_donor_field
        )

    if behaviour == nil then
        solid_donor_owner = nil
        solid_donor_field = nil
        return nil
    end

    local ok, behaviour_type = pcall(function()
        return behaviour.Type
    end)

    if not ok
        or behaviour_type ~= TYPE_SOLID then

        solid_donor_owner = nil
        solid_donor_field = nil
        return nil
    end

    return behaviour
end

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
-- SURFACE PROCESSING
-------------------------------------------------------------------------------

-- Returns complete, changed.
--
-- complete=false means the component may still be initializing and can be
-- retried later by the queue. Errors are also retried up to the configured cap.
local function process_painted_component(component)
    local key = object_key(component)

    if key == nil then
        return false, false
    end

    if processed_painted[key] then
        return true, false
    end

    local ok, complete, changed = pcall(function()
        local painted =
            component.PaintedBehaviour

        local unpainted =
            component.UnPaintedBehaviour

        if painted == nil
            or unpainted == nil then

            return false, false
        end

        local painted_type =
            painted.Type

        local unpainted_type =
            unpainted.Type

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
            -- Tested Vanilla+ repair:
            --
            -- Solid painted region + Adamant unpainted region.
            --
            -- Dedicated Adamant, Weak, and unusual special pairings remain
            -- untouched because only this common PaintedClimbable pairing is
            -- changed.
            if painted_type == TYPE_SOLID
                and unpainted_type == TYPE_ADAMANT then

                copy_feedback(
                    painted,
                    unpainted
                )

                unpainted.Type =
                    TYPE_SOLID

                if component.UnPaintedBehaviour.Type
                    ~= TYPE_SOLID then

                    error(
                        "Painted surface repair verification failed"
                    )
                end

                return true, true
            end

            return true, false
        end

        if ActiveMode == "open" then
            local donor =
                get_solid_donor()

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
                    copy_feedback(
                        donor,
                        painted
                    )
                end

                if unpainted_type ~= TYPE_SOLID then
                    copy_feedback(
                        donor,
                        unpainted
                    )
                end
            end

            painted.Type =
                TYPE_SOLID

            unpainted.Type =
                TYPE_SOLID

            if component.PaintedBehaviour.Type
                ~= TYPE_SOLID
                or component.UnPaintedBehaviour.Type
                ~= TYPE_SOLID then

                error(
                    "Open-mode painted surface verification failed"
                )
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
    end

    if processed_standard[key] then
        return true, false
    end

    local ok, complete, changed = pcall(function()
        local behaviour =
            component.Behaviour

        if behaviour == nil then
            return false, false
        end

        local behaviour_type =
            behaviour.Type

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

            behaviour.Type =
                TYPE_SOLID
        end

        if component.Behaviour.Type
            ~= TYPE_SOLID then

            error(
                "Open-mode standard surface verification failed"
            )
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
-- CLIMBER PROCESSING
-------------------------------------------------------------------------------

local function tune_climber(climber)
    if not is_valid(climber)
        or is_default_object(climber) then

        return false
    end

    -- Keep the newest valid climber for distance-priority decisions even when
    -- movement changes are disabled.
    current_climber = climber

    if not Config.enable_movement_improvements
        and not Config.enable_climbing_jump then

        return true
    end

    local key =
        object_key(climber)

    if key == nil then
        return false
    end

    if processed_climbers[key] then
        return true
    end

    if Config.enable_movement_improvements then
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
-- DISTANCE-PRIORITY QUEUE
-------------------------------------------------------------------------------

local PRIORITY_NEAR = 1
local PRIORITY_MEDIUM = 2
local PRIORITY_FAR = 3

local function queue_for_priority(priority)
    if priority == PRIORITY_NEAR then
        return near_queue
    end

    if priority == PRIORITY_MEDIUM then
        return medium_queue
    end

    return far_queue
end

local function classify_surface(
    component,
    player_location
)
    local surface_location =
        get_surface_location(component)

    local distance_squared =
        squared_distance(
            surface_location,
            player_location
        )

    if distance_squared == nil then
        return PRIORITY_FAR
    end

    if distance_squared <= NEAR_DISTANCE_SQUARED then
        return PRIORITY_NEAR
    end

    if distance_squared <= MEDIUM_DISTANCE_SQUARED then
        return PRIORITY_MEDIUM
    end

    return PRIORITY_FAR
end

local function release_record(record)
    if record ~= nil
        and record.key ~= nil then

        queued_keys[record.key] = nil
    end
end

local function enqueue_priority_record(
    record,
    priority
)
    record.priority = priority

    fifo_push(
        queue_for_priority(priority),
        record
    )
end

local schedule_queue_tick

local function queue_has_work()
    return total_queue_size() > 0
end

local function ensure_queue_worker()
    if queue_worker_running then
        return
    end

    queue_worker_running = true
    schedule_queue_tick()
end

local function enqueue_surface(
    component,
    kind,
    startup_record
)
    if component == nil then
        return false
    end

    -- Keep the construction callback deliberately cheap. Validation, naming,
    -- deduplication, and distance work happen later in the single queue worker.
    local record = {
        object = component,
        kind = kind,
        key = nil,
        base_key = nil,
        attempts = 0,
        ready_cycle =
            startup_record
            and queue_cycle
            or (
                queue_cycle
                + NEW_OBJECT_WARMUP_CYCLES
            ),
    }

    if startup_record then
        fifo_push(
            incoming_startup,
            record
        )
    else
        fifo_push(
            incoming_live,
            record
        )
    end

    queue_totals.enqueued =
        queue_totals.enqueued + 1

    ensure_queue_worker()

    return true
end

local function prepare_record(record)
    if record == nil
        or not is_valid(record.object)
        or is_default_object(record.object) then

        return false
    end

    -- A retry has already passed validation and owns its queue key.
    if record.key ~= nil then
        return true
    end

    local base_key =
        object_key(record.object)

    if base_key == nil then
        return false
    end

    if record.kind == "painted"
        and processed_painted[base_key] then

        return false
    end

    if record.kind == "standard"
        and processed_standard[base_key] then

        return false
    end

    local key =
        record.kind .. "|" .. base_key

    if queued_keys[key] then
        return false
    end

    queued_keys[key] = true
    record.key = key
    record.base_key = base_key

    return true
end

local function classify_ready_records(
    source_queue,
    maximum,
    player_location
)
    local classified = 0
    local inspected = 0

    -- Inspect at most the number of records that existed when this pass began.
    -- Not-yet-ready records are rotated to the back, so one retry cannot block
    -- newer records with an earlier ready time.
    local available =
        fifo_size(source_queue)

    while classified < maximum
        and inspected < available do

        local record =
            fifo_pop(source_queue)

        if record == nil then
            break
        end

        inspected =
            inspected + 1

        if queue_cycle < record.ready_cycle then
            fifo_push(
                source_queue,
                record
            )
        elseif not prepare_record(record) then
            release_record(record)

            queue_totals.dropped =
                queue_totals.dropped + 1
        else
            local priority =
                classify_surface(
                    record.object,
                    player_location
                )

            enqueue_priority_record(
                record,
                priority
            )

            classified =
                classified + 1
        end
    end

    return classified
end

local function reclassify_records(
    source_queue,
    maximum,
    player_location
)
    local checked = 0

    while checked < maximum do
        local record =
            fifo_pop(source_queue)

        if record == nil then
            break
        end

        if not is_valid(record.object) then
            release_record(record)

            queue_totals.dropped =
                queue_totals.dropped + 1
        else
            local priority =
                classify_surface(
                    record.object,
                    player_location
                )

            enqueue_priority_record(
                record,
                priority
            )
        end

        checked =
            checked + 1
    end

    return checked
end

local function pop_valid_record(queue)
    while true do
        local record =
            fifo_pop(queue)

        if record == nil then
            return nil
        end

        if is_valid(record.object) then
            return record
        end

        release_record(record)

        queue_totals.dropped =
            queue_totals.dropped + 1
    end
end

local function choose_next_record()
    -- Guaranteed background progress.
    if FAR_EVERY_CYCLES > 0
        and queue_cycle % FAR_EVERY_CYCLES == 0 then

        local far =
            pop_valid_record(far_queue)

        if far ~= nil then
            return far
        end
    end

    -- Medium work also receives a reserved share.
    if MEDIUM_EVERY_CYCLES > 0
        and queue_cycle % MEDIUM_EVERY_CYCLES == 0 then

        local medium =
            pop_valid_record(medium_queue)

        if medium ~= nil then
            return medium
        end
    end

    local near =
        pop_valid_record(near_queue)

    if near ~= nil then
        return near
    end

    local medium =
        pop_valid_record(medium_queue)

    if medium ~= nil then
        return medium
    end

    return pop_valid_record(far_queue)
end

local function process_queue_record(record)
    if record == nil then
        return
    end

    if not is_valid(record.object) then
        release_record(record)

        queue_totals.dropped =
            queue_totals.dropped + 1

        return
    end

    record.attempts =
        record.attempts + 1

    local complete = false

    if record.kind == "painted" then
        remember_solid_donor(
            record.object
        )

        complete =
            process_painted_component(
                record.object
            )
    elseif record.kind == "standard" then
        remember_solid_donor(
            record.object
        )

        complete =
            process_standard_climbable(
                record.object
            )
    else
        complete = true
    end

    if complete then
        release_record(record)

        queue_totals.completed =
            queue_totals.completed + 1

        return
    end

    if record.attempts >= MAX_UPDATE_ATTEMPTS then
        log(string.format(
            "Dropping uninitialized surface after %d attempts: %s",
            record.attempts,
            get_full_name(record.object)
        ))

        release_record(record)

        queue_totals.dropped =
            queue_totals.dropped + 1

        return
    end

    record.ready_cycle =
        queue_cycle
        + RETRY_BACKOFF_CYCLES

    record.priority = nil

    fifo_push(
        incoming_live,
        record
    )

    queue_totals.retried =
        queue_totals.retried + 1
end

local function queue_tick_on_game_thread()
    queue_cycle =
        queue_cycle + 1

    local player_location =
        get_climber_location()

    local classified_live =
        classify_ready_records(
            incoming_live,
            CLASSIFICATIONS_PER_CYCLE,
            player_location
        )

    local classification_remaining =
        CLASSIFICATIONS_PER_CYCLE
        - classified_live

    if classification_remaining > 0 then
        classify_ready_records(
            incoming_startup,
            classification_remaining,
            player_location
        )
    end

    -- Recheck only a small rotating sample instead of sorting the full queue.
    if PRIORITY_PROBE_COUNT > 0
        and queue_cycle
            % PRIORITY_REFRESH_INTERVAL
            == 0 then

        local medium_probe =
            math.floor(
                PRIORITY_PROBE_COUNT / 2
            )

        local far_probe =
            PRIORITY_PROBE_COUNT
            - medium_probe

        reclassify_records(
            medium_queue,
            medium_probe,
            player_location
        )

        reclassify_records(
            far_queue,
            far_probe,
            player_location
        )
    end

    for _ = 1, UPDATES_PER_CYCLE do
        local record =
            choose_next_record()

        if record == nil then
            break
        end

        process_queue_record(record)
    end

    if queue_has_work() then
        schedule_queue_tick()
    else
        queue_worker_running = false

        log(string.format(
            "Queue drained: %d completed, %d retried, %d dropped.",
            queue_totals.completed,
            queue_totals.retried,
            queue_totals.dropped
        ))
    end
end

schedule_queue_tick = function()
    ExecuteWithDelay(
        QUEUE_INTERVAL_MS,

        function()
            run_on_game_thread(
                queue_tick_on_game_thread
            )
        end
    )
end

-------------------------------------------------------------------------------
-- NEW-OBJECT LISTENERS
-------------------------------------------------------------------------------

local function register_new_object_listener(
    class_path,
    callback
)
    local ok, error_message = pcall(function()
        NotifyOnNewObject(
            class_path,

            function(object)
                callback(object)

                -- Returning false keeps this single listener registered.
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

local function on_new_painted(component)
    enqueue_surface(
        component,
        "painted",
        false
    )
end

local function on_new_standard(component)
    enqueue_surface(
        component,
        "standard",
        false
    )
end

local function on_new_climber(climber)
    -- A climber is rare and cheap to tune, so it does not share the surface
    -- queue. It also supplies the player position used by the queue.
    run_on_game_thread(function()
        tune_climber(climber)
    end)
end

-------------------------------------------------------------------------------
-- ONE STARTUP PASS
-------------------------------------------------------------------------------

local function run_startup_scan()
    if startup_scan_running
        or ActiveMode == "vanilla" then

        return
    end

    startup_scan_running = true

    local ok, error_message = pcall(function()
        -- Establish the current player reference before classifying surfaces.
        local climbers =
            collect_instances(
                "ClimberComponent"
            )

        for _, climber in ipairs(climbers) do
            tune_climber(climber)
        end

        local painted_components =
            collect_instances(
                "PaintedClimbable"
            )

        local standard_components = {}

        if ActiveMode == "open" then
            standard_components =
                collect_instances(
                    "Climbable"
                )
        end

        -- Find one genuine Solid donor before queued conversions begin.
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

        local queued_painted = 0
        local queued_standard = 0

        for _, component in ipairs(
            painted_components
        ) do
            if enqueue_surface(
                component,
                "painted",
                true
            ) then
                queued_painted =
                    queued_painted + 1
            end
        end

        for _, component in ipairs(
            standard_components
        ) do
            if enqueue_surface(
                component,
                "standard",
                true
            ) then
                queued_standard =
                    queued_standard + 1
            end
        end

        log(string.format(
            "Startup discovery queued %d painted, %d standard, "
            .. "and found %d climber(s).",
            queued_painted,
            queued_standard,
            #climbers
        ), true)
    end)

    startup_scan_running = false

    if not ok then
        log(
            "Startup discovery failed: "
            .. tostring(error_message),
            true
        )
    end
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

-- Each native base class gets one listener. Blueprint subclasses are covered by
-- inheritance, so the mod does not register duplicate listeners for each BP.
register_new_object_listener(
    "/Script/DeliverUsMars.PaintedClimbable",
    on_new_painted
)

if ActiveMode == "open" then
    register_new_object_listener(
        "/Script/DeliverUsMars.Climbable",
        on_new_standard
    )
end

register_new_object_listener(
    "/Script/DeliverUsMars.ClimberComponent",
    on_new_climber
)

local startup_delay =
    math.max(
        0,
        math.floor(
            tonumber(Config.initial_scan_delay_ms)
            or 1500
        )
    )

ExecuteWithDelay(
    startup_delay,

    function()
        run_on_game_thread(
            run_startup_scan
        )
    end
)

print(string.format(
    "[%s] Distance-prioritized queue enabled: "
    .. "%d update(s) every %d ms.\n",
    MOD_NAME,
    UPDATES_PER_CYCLE,
    QUEUE_INTERVAL_MS
))
