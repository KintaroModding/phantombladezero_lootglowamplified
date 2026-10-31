-- Loot Glow Amplified for Phantom Blade Zero.
--
-- Brighter and larger glow over world loot: loot piles (BP_Rubbish and its children, which also hold notes and pages)
-- and chests (BP_Chest). Everything is done in memory: nothing reaches the save, and no game file is replaced. A port
-- of the earlier JavaScript version of the mod, which ran inside a replaced game script.
--
-- What changes (Brightness and Size come from config.lua):
-- 1. Glow. Each sprite and mesh renderer of a loot effect (Niagara system) listed in SYSTEMS gets one material
--    parameter more: the emissive scalar of its material (Emissive_Multiplier, or Emissive_Intensity on the XMVFX
--    Mat_Universal; both 1 in every material chain) set to Brightness. Niagara copies these values into each
--    component's own material instances. A renderer that had no material parameters had no such instances either, so
--    each loot component is asked once to build them: SetVariableMaterial on a user parameter that no loot effect has
--    (REFRESH_PARAMETER).
-- 2. Light. Each loot effect has one light renderer: DiffuseScale and SpecularScale x Brightness, RadiusScale
--    x (1 + Brightness) / 2.
-- 3. NS_Item_WhiteDust_001 (the glow of the lowest loot level) is also used by 9 NPC Blueprints and the player
--    Blueprint, so none of its renderers is changed; each pile gets the effect's own User.UE_LightIntensity
--    x Brightness instead.
-- 4. Size. Each loot actor's own Niagara component is scaled by Size; the shared effects stay as they are.
-- The game's own distance culling (about 45 m, the nearest 3 or 4 glows) still decides which glows draw, and the mod
-- never starts or shows a glow: taken piles and opened chests stay dark as the game leaves them.
--
-- How: every CHECK_INTERVAL_MS, on the game thread, the mod lists the loot actors (GameplayStatics:GetAllActorsOfClass)
-- and reaches each actor's effect (Niagara component -> GetAsset). It walks the effect's emitters to their renderers
-- (EmitterHandles -> VersionedInstance.Emitter -> VersionData -> RendererProperties, and StatelessEmitter) and changes
-- the ones listed in SYSTEMS. No search by name on the timer: only the two loot classes are searched, at start, after a
-- map load and while one is missing (a search costs a few milliseconds). Effects and renderers are taken fresh from
-- the actors on every check and never kept: an effect unloads when its loot streams out, and UE4SS's IsValid only
-- checks that an address holds a live object, not that it is the same one. A kept component is used again only after
-- its address and full name both match.
-- A light value or glow entry that still holds the value the mod wrote is the mod's; any other value is the game's own
-- (a first load, or a reload after an unload), so nothing compounds. After STOP_AFTER_FAILED_CHECKS failed checks in a
-- row the mod stops and puts back what it changed. LogDetail logs every change and a status line, for game tests.
--
-- Settings: the player edits Scripts\config.lua. The mod reads it at start and again every CONFIG_INTERVAL_MS, so a
-- change shows without a restart (live settings, user decision 2026-10-31); a broken or half-saved file keeps the
-- last settings. DEFAULTS holds every setting with its default. A player (or a mod manager) keeps their config.lua
-- across updates, so a new main.lua can meet an older file: a setting that the file lacks, or has with another type,
-- keeps its default, and the log says so. Read a setting only from Settings, never as `config.X or default`: for a
-- true/false setting, `false or true` is true.

local UEHelpers = require("UEHelpers")

local MOD_NAME = "Loot Glow Amplified"
local VERSION = "1.2"
local CHECK_INTERVAL_MS = 2000
local CONFIG_INTERVAL_MS = 5000
-- While a loot class is missing, search for it on every n-th check only.
local CLASS_SEARCH_EVERY = 5
-- An effect is walked again only when its address or the settings changed, and on every n-th check, which catches one
-- that unloaded and came back at the same address (its renderers are then the game's again).
local FULL_WALK_EVERY = 15
local STOP_AFTER_FAILED_CHECKS = 10
-- Log at most this many error lines in total.
local MAX_ERROR_LOGS = 5
-- LogDetail: at most this many lines per game start, and a status line on every n-th check.
local MAX_DETAIL_LOGS = 400
local STATUS_EVERY = 15

-- Every setting with its default; config.lua ships the same names and values (tests\test_main.py checks it).
local DEFAULTS = {
    Enable = true,
    Brightness = 2,
    Size = 2,
    Chests = true,
    Items = true,
    LogDetail = false,
}
-- Number settings outside their range are clamped.
local LIMITS = {
    Brightness = { 1, 5 },
    Size = { 1, 5 },
}

local PILE_CLASS = "/Game/PBZContent/Blueprint/Item/Device/BP_Rubbish.BP_Rubbish_C"
local CHEST_CLASS = "/Game/PBZContent/Blueprint/Item/Device/BP_Chest.BP_Chest_C"
local SHARED_SYSTEM = "/Game/PBZContent/VFX/SceneFX/Common/NS_Item_WhiteDust_001.NS_Item_WhiteDust_001"
local SHARED_PARAMETER = "UE_LightIntensity"
-- A material user parameter that no loot effect has, and a material that is always loaded (the engine default).
local REFRESH_PARAMETER = "LootGlowAmplifiedRefresh"
local REFRESH_MATERIAL = "/Engine/EngineMaterials/WorldGridMaterial.WorldGridMaterial"
local LIGHT_FIELDS = { "RadiusScale", "DiffuseScale", "SpecularScale" }

local C = "/Game/PBZContent/VFX/SceneFX/Common/"
local X = "/XMVFX/VFXs/Scene/"
-- The loot effects, from the construction scripts of BP_Chest (by chest type) and BP_Rubbish (by item level), as
-- { package, chest, light emitter, glow renderers }. chest: true for the chest group (setting Chests), false for the
-- pile group (Items). Light emitter: the emitter object that holds the light renderer. Glow renderers: the sprite
-- (S<n>) and mesh (M<n>) renderers whose material has an emissive scalar, as "<emitter object>.<S|M><n>"; "|I" means
-- Emissive_Intensity, else Emissive_Multiplier. NS_Item_WhiteDust_001 is left out (see 3. above).
local SYSTEMS = {
    { C .. "NS_BlueLightBeam_301", true, "Minimal", { "Sparks_7.S3|I", "NE_BlackSmoke_0.S0", "NE_BlackSmoke003_0.S0",
        "Minimal.M0", "Minimal002_0.M0", "NE_Airflow_0.M0", "Minimal006.S0" } },
    { C .. "NS_GreenLightBeam_301", true, "Minimal", { "Sparks_7.S3|I", "NE_BlackSmoke_0.S0", "NE_BlackSmoke003_0.S0",
        "Minimal.M0", "Minimal002_0.M0", "NE_Airflow_0.M0", "Minimal006.S0" } },
    { C .. "NS_OrangeLightBeam_301", true, "Minimal", { "Sparks_7.S3|I", "NE_BlackSmoke001_0.S0",
        "NE_BlackSmoke002_0.S0", "Minimal.M0", "Minimal002_0.M0", "NE_Airflow_0.M0", "Minimal006.S0" } },
    { C .. "NS_PurpleLightBeam_301", true, "Minimal", { "Sparks001_0.S3|I", "NE_BlackSmoke003_0.S0",
        "NE_BlackSmoke004_0.S0", "Minimal.M0", "Minimal002_0.M0", "NE_Airflow_0.M0", "Minimal006.S0" } },
    { C .. "NS_Item_Green_301", false, "NE_BeamLight_OPT001_0", { "NiagaraEmitter_1.M0", "NiagaraEmitter_1.S1",
        "NE_BeamLight_OPT001_0.M0|I", "Curve_0.M0", "EN_Smoke003_OPT_0.S0", "NE_LootCenterSmoke_OPT001_1.S4" } },
    { C .. "NS_Item_Technicolor_101", false, "EN_Line002_OPT001_0", { "Center001_4.S4", "Smoke_6.S0", "Sparks001_5.S3",
        "Ball001_10.M0", "Empty001_0.S0", "EN_Line002_OPT001_0.M0|I", "EN_Line002_OPT001_0.M1|I", "NiagaraEmitter_3.M0",
        "Minimal.M1", "NE_Flare_0.S0", "Minimal002_1.M0" } },
    { C .. "NS_Item_WhiteDust_002", false, "NE_BeamLight_OPT001_0", { "NiagaraEmitter_1.S0",
        "NiagaraStatelessEmitter_0.M2", "NiagaraStatelessEmitter_1.S0", "NiagaraStatelessEmitter_1.S4",
        "NE_LootCenterSmoke_OPT_3.S4", "NE_BeamLight_OPT001_0.M0|I" } },
    { C .. "NS_Item_WhiteDust_003", false, "NE_BeamLight_OPT001_0", { "NiagaraEmitter_0.M0", "NiagaraEmitter_0.S0",
        "NiagaraEmitter_0.S1", "NE_Curves_OPT_0.M2", "NE_LootCenterSmoke_OPT001_1.S0", "NE_LootCenterSmoke_OPT001_1.S4",
        "NE_BeamLight_OPT001_0.M0|I", "Minimal.S0" } },
    { X .. "NS_BlueLight", false, "Smoke002_0", { "Smoke002_0.M0|I", "Smoke003_0.S0|I" } },
    { X .. "NS_BlueLight_Big", false, "Smoke002_0", { "Smoke002_0.M0|I", "Smoke003_0.S0|I" } },
    { X .. "NS_BlueLight_Small", false, "Smoke002_0", { "Smoke002_0.M0|I", "Smoke003_0.S0|I" } },
    { X .. "NS_GreenFlameS", false, "EN_Ball001_OPT_0", { "EN_Ball001_OPT_0.M0|I", "EN_Ball001_OPT_0.S0|I",
        "EN_Line002_OPT_0.M0|I", "EN_Line002_OPT_0.M1|I", "EN_Smoke002_OPT_0.S0|I", "EN_Smoke003_OPT_0.S0|I" } },
    { X .. "NS_OrangeLightBeam", false, "EN_Line002_OPT_0", { "EN_Line002_OPT_0.M0|I", "EN_Line002_OPT_0.M1|I",
        "Minimal.M1", "NE_Flare_0.S0", "Minimal001.M0", "Minimal003_0.M0", "Minimal002_1.M0" } },
    { X .. "NS_OrangeLightBeam_Big", false, "EN_Line002_OPT_0", { "EN_Line002_OPT_0.M0|I", "EN_Line002_OPT_0.M1|I",
        "Minimal.M1", "NE_Flare_0.S0", "Minimal001.M0", "Minimal003_0.M0", "Minimal002_1.M0" } },
    { X .. "NS_OrangeLightBeam_Small", false, "EN_Line002_OPT_0", { "EN_Line002_OPT_0.M0|I", "EN_Line002_OPT_0.M1|I",
        "Minimal.M1", "NE_Flare_0.S0", "Minimal001.M0", "Minimal003_0.M0", "Minimal002_1.M0" } },
    { X .. "NS_PurpleLightBeam", false, "EN_Line002_OPT_0", { "Curves_0.M2|I", "EN_Line002_OPT_0.M0|I",
        "EN_Line002_OPT_0.M1|I", "Smoke002_0.S0|I" } },
    { X .. "NS_PurpleLightBeam_Big", false, "EN_Line002_OPT_0", { "Curves_0.M2|I", "EN_Line002_OPT_0.M0|I",
        "EN_Line002_OPT_0.M1|I", "Smoke002_0.S0|I" } },
    { X .. "NS_PurpleLightBeam_Small", false, "EN_Line002_OPT_0", { "Curves_0.M2|I", "EN_Line002_OPT_0.M0|I",
        "EN_Line002_OPT_0.M1|I", "Smoke002_0.S0|I" } },
}

-- System object path -> { name, chest, count, renderers = { ["<emitter object>.<renderer object>"] = { light = true }
-- or { param = "<material parameter>" } } }.
local EFFECTS = {}
for _, entry in ipairs(SYSTEMS) do
    local package, chest, lightEmitter, glow = entry[1], entry[2], entry[3], entry[4]
    local name = package:match("[^/]+$")
    local renderers = { [lightEmitter .. ".NiagaraLightRendererProperties_0"] = { light = true } }
    local count = 1
    for _, item in ipairs(glow) do
        local path, intensity = item:match("^([^|]+)(.*)$")
        path = path:gsub("%.S(%d+)$", ".NiagaraSpriteRendererProperties_%1")
        path = path:gsub("%.M(%d+)$", ".NiagaraMeshRendererProperties_%1")
        renderers[path] = { param = intensity == "|I" and "Emissive_Intensity" or "Emissive_Multiplier" }
        count = count + 1
    end
    EFFECTS[package .. "." .. name] = { name = name, chest = chest, count = count, renderers = renderers }
end

local SHARED_FNAME = FName(SHARED_PARAMETER, EFindName.FNAME_Add)
local REFRESH_FNAME = FName(REFRESH_PARAMETER, EFindName.FNAME_Add)

local errors = 0
local details = 0

local function Log(message)
    print(string.format("[%s] %s\n", MOD_NAME, message))
end

local function LogError(message)
    errors = errors + 1
    if errors <= MAX_ERROR_LOGS then
        Log(message)
    end
end

local Settings = {}

-- LogDetail lines; message is a function, so nothing is built while LogDetail is off.
local function Detail(message)
    if Settings.LogDetail and details < MAX_DETAIL_LOGS then
        details = details + 1
        Log(message())
    end
end

local function Valid(object)
    if object == nil then
        return false
    end
    local ok, valid = pcall(function()
        return object:IsValid()
    end)
    return ok and valid == true
end

-- The object's path without its class ("NiagaraSystem /Game/...NS_X.NS_X" -> "/Game/...NS_X.NS_X").
local function PathOf(object)
    local full = object:GetFullName()
    return full:match("^%S+%s+(.+)$") or full
end

local function Near(a, b)
    return math.abs(a - b) <= 1e-4 * math.max(1, math.abs(a), math.abs(b))
end

local function Round(value)
    return string.format("%.3g", value)
end

---------------------------------------------------------------------------------------------------------------------
-- Settings
---------------------------------------------------------------------------------------------------------------------

local function CopyDefaults()
    local settings = {}
    for name, value in pairs(DEFAULTS) do
        settings[name] = value
    end
    return settings
end

-- One line for the log: every setting, sorted by name.
local function Describe(settings)
    local names = {}
    for name in pairs(settings) do
        names[#names + 1] = name
    end
    table.sort(names)
    local parts = {}
    for i, name in ipairs(names) do
        parts[i] = name .. "=" .. tostring(settings[name])
    end
    return table.concat(parts, ", ")
end

-- Lua's line number and reason, without the chunk name.
local function Reason(message)
    message = tostring(message)
    local line, reason = message:match("config%.lua:(%d+): ([^\n]*)")
    return line and ("line " .. line .. ": " .. reason) or (message:gsub("%s*\n%s*", " "))
end

-- DEFAULTS with the values of config.lua's text over them; nil and the reason when the text is not a usable file.
local function ParseConfig(text)
    local chunk, problem = load(text, "=config.lua", "t", {})
    if not chunk then
        return nil, "config.lua not read (" .. Reason(problem) .. ")"
    end
    local ok, config = pcall(chunk)
    if not ok then
        return nil, "config.lua not read (" .. Reason(config) .. ")"
    end
    if type(config) ~= "table" then
        return nil, "config.lua does not return a table"
    end
    local settings = CopyDefaults()
    for name, value in pairs(config) do
        local default = DEFAULTS[name]
        local limit = LIMITS[name]
        if default == nil then
            Log("config.lua: unknown setting " .. tostring(name) .. " ignored.")
        elseif type(value) ~= type(default) then
            Log(string.format("config.lua: %s must be a %s; the default %s is used.", name, type(default),
                tostring(default)))
        elseif limit and value ~= value then
            Log(string.format("config.lua: %s is not a number; the default %s is used.", name, tostring(default)))
        elseif limit and (value < limit[1] or value > limit[2]) then
            local clamped = math.min(limit[2], math.max(limit[1], value))
            Log(string.format("config.lua: %s = %s is outside %s to %s; %s is used.", name, tostring(value),
                tostring(limit[1]), tostring(limit[2]), tostring(clamped)))
            settings[name] = clamped
        else
            settings[name] = value
        end
    end
    return settings
end

local configPath = nil
-- The text of the last read; false: no file at the last read; nil: not read yet.
local configText = nil

-- Reads config.lua when its text changed since the last read. At start, a missing or broken file means the defaults;
-- later, a broken file keeps the last settings (a half-saved file), and a missing one means the defaults.
local function ReadConfig()
    local atStart = configText == nil
    configPath = configPath or package.searchpath("config", package.path)
    local text = false
    if configPath then
        local file = io.open(configPath, "rb")
        if file then
            text = file:read("a") or false
            file:close()
        end
    end
    if text == configText then
        return
    end
    configText = text
    local settings, problem
    if text == false then
        settings, problem = CopyDefaults(), nil
        Log("No config.lua; every setting uses its default.")
    else
        settings, problem = ParseConfig(text)
    end
    if not settings then
        if atStart then
            Log(problem .. "; every setting uses its default.")
            settings = CopyDefaults()
        else
            Log(problem .. "; the last settings stay.")
            return
        end
    end
    local line = Describe(settings)
    if atStart or line ~= Describe(Settings) then
        Log("Settings: " .. line)
    end
    Settings = settings
end

---------------------------------------------------------------------------------------------------------------------
-- Renderers
---------------------------------------------------------------------------------------------------------------------

-- renderer key ("<system path>:<emitter object>.<renderer object>") -> { stock = {3 values}, set = {what the mod
-- last wrote or read} }
local lights = {}
-- renderer key -> { address = the renderer object the mod wrote, v = the value it wrote } or { foreign = true }
local glows = {}
-- system path -> { address, state }: the last walk, so an unchanged effect is not walked on every check
local walked = {}

-- The light renderer at stock x Brightness (on) or back at stock (off).
local function ScaleLight(key, renderer, on)
    local now = {}
    for i, field in ipairs(LIGHT_FIELDS) do
        local value = renderer[field]
        if type(value) ~= "number" or value ~= value then
            if not lights[key] then
                lights[key] = { skip = true }
                Detail(function() return "light " .. key .. " has no number " .. field .. "; left alone" end)
            end
            return
        end
        now[i] = value
    end
    local record = lights[key]
    if record == nil or record.skip then
        record = { stock = { now[1], now[2], now[3] }, set = { now[1], now[2], now[3] } }
        lights[key] = record
    end
    -- Per field: a value still equal to what the mod wrote is the mod's; any other is the game's own (a first load, a
    -- reload after an unload, or a write that did not land), so it becomes the stock value. Nothing compounds.
    for i = 1, 3 do
        if not Near(now[i], record.set[i]) then
            record.stock[i] = now[i]
        end
    end
    local b = Settings.Brightness
    local want = { record.stock[1], record.stock[2], record.stock[3] }
    if on then
        want = { record.stock[1] * (1 + b) / 2, record.stock[2] * b, record.stock[3] * b }
    end
    local change = false
    for i = 1, 3 do
        if not Near(now[i], want[i]) then
            change = true
        end
    end
    if change then
        for i, field in ipairs(LIGHT_FIELDS) do
            -- Recorded first, so a write that throws halfway is still known as the mod's.
            record.set[i] = want[i]
            renderer[field] = want[i]
        end
        Detail(function()
            return string.format("light %s: %s/%s/%s -> %s/%s/%s", key:match("[^/]+$"), Round(now[1]), Round(now[2]),
                Round(now[3]), Round(want[1]), Round(want[2]), Round(want[3]))
        end)
    end
    for i, field in ipairs(LIGHT_FIELDS) do
        record.set[i] = renderer[field]
    end
end

-- The index of the material parameter entry with this name, or nil.
local function EntryIndex(list, param)
    local at = nil
    local wanted = param:lower()
    for i = 1, #list do
        if list[i].MaterialParameterName:ToString():lower() == wanted then
            at = i
        end
    end
    return at
end

-- The mod's emissive entry on the renderer at Brightness (on) or at 1, the material's own value (off).
local function ScaleGlow(key, renderer, param, on)
    local record = glows[key]
    if record and record.foreign then
        return
    end
    local list = renderer.MaterialParameters.ScalarParameters
    local at = EntryIndex(list, param)
    local before = at and list[at].Value or nil
    local address = renderer:GetAddress()
    -- An entry the mod never added (a game update or another mod), or one on another renderer object than the one the
    -- mod wrote that does not hold the mod's value: leave this renderer alone.
    if at and (record == nil or (record.address ~= address and not Near(before, record.v or -1))) then
        glows[key] = { foreign = true }
        Detail(function() return "glow " .. key:match("[^/]+$") .. " already has " .. param .. " " .. Round(before)
            .. "; left alone" end)
        return
    end
    local value = on and Settings.Brightness or 1
    if at == nil then
        -- First sight, or a reload dropped the entry. Nothing to add when the value is the material's own.
        if Near(value, 1) then
            return
        end
        record = { address = address }
        -- Recorded first, so an entry that lands before a throw is still known as the mod's.
        glows[key] = record
        -- Reading one index past the end grows a UE4SS TArray by one zeroed entry.
        local entry = list[#list + 1]
        entry.MaterialParameterName = FName(param, EFindName.FNAME_Add)
        entry.Value = value
    else
        record.address = address
        if Near(before, value) then
            return
        end
        list[at].Value = value
    end
    local check = EntryIndex(list, param)
    record.v = check and list[check].Value or nil
    Detail(function() return "glow " .. key:match("[^/]+$") .. " " .. param .. " " .. tostring(before and Round(before))
        .. " -> " .. tostring(record.v and Round(record.v)) end)
end

-- Calls fn(renderer) for each renderer of the system: its emitters' renderers and its stateless emitters'.
local function ForEachRenderer(system, fn)
    local handles = system.EmitterHandles
    for i = 1, #handles do
        local handle = handles[i]
        local emitter = handle.VersionedInstance.Emitter
        if Valid(emitter) then
            local versions = emitter.VersionData
            for j = 1, #versions do
                local list = versions[j].RendererProperties
                for k = 1, #list do
                    fn(list[k])
                end
            end
        end
        local stateless = handle.StatelessEmitter
        if Valid(stateless) then
            local list = stateless.RendererProperties
            for k = 1, #list do
                fn(list[k])
            end
        end
    end
end

-- Puts the listed renderers of one loot effect on (Brightness) or off (the game's values). A light that throws counts
-- as a failed check; a glow entry that throws, or an effect that UE4SS cannot walk, is only logged and tried again at
-- the next walk: the mod's other changes (Size, the level F piles) keep working, and stopping could not undo it.
local function ApplyEffect(systemPath, system, effect, on, full)
    local state = tostring(on) .. "/" .. tostring(Settings.Brightness)
    local address = system:GetAddress()
    local last = walked[systemPath]
    if not full and last and last.address == address and last.state == state then
        return
    end
    local failed = nil
    local found = 0
    local walkedOk, walkError = pcall(ForEachRenderer, system, function(renderer)
        if not Valid(renderer) then
            return
        end
        local name = renderer:GetOuter():GetFName():ToString() .. "." .. renderer:GetFName():ToString()
        local spec = effect.renderers[name]
        if not spec then
            return
        end
        found = found + 1
        local key = systemPath .. ":" .. name
        if spec.light then
            local ok, err = pcall(ScaleLight, key, renderer, on)
            if not ok then
                failed = failed or err
            end
        else
            local ok, err = pcall(ScaleGlow, key, renderer, spec.param, on)
            if not ok then
                LogError("Glow " .. effect.name .. " " .. name .. ": " .. tostring(err))
            end
        end
    end)
    if not walkedOk then
        LogError("Could not walk the renderers of " .. effect.name .. ": " .. tostring(walkError))
        return
    end
    if found == 0 and not (last and last.empty) then
        -- A game update renamed the emitters, or UE4SS could not walk this effect: it stays as the game has it.
        LogError(effect.name .. ": none of its " .. effect.count .. " listed renderers found; left as the game has it.")
    end
    if failed then
        error(failed, 0)
    end
    walked[systemPath] = { address = address, state = state, empty = found == 0 }
end

---------------------------------------------------------------------------------------------------------------------
-- Loot actors
---------------------------------------------------------------------------------------------------------------------

-- actor address -> { comp, compAddress, compName, base = {x, y, z}, v }: the component scale the mod set
local scaled = {}
-- actor address -> { comp, compAddress, compName, base, v }: the UE_LightIntensity the mod set on a level F pile
local shared = {}
-- component address -> true: asked once to build its material instances (REFRESH_PARAMETER)
local poked = {}

local pileClass, chestClass, refreshMaterial, controller = nil, nil, nil, nil
local checks = 0
local failures = 0
local stopped = false
local classSearchDue = true
local idle = false
-- LogDetail: the last count of listed actors per class, and the reasons for skipped actors already logged.
local listed = {}
local skipped = {}

-- The kept component is still the one the record was made for: same address, same full name.
local function Same(record)
    return Valid(record.comp) and record.comp:GetAddress() == record.compAddress
        and record.comp:GetFullName() == record.compName
end

local function GroupOn(chest)
    if not Settings.Enable then
        return false
    end
    if chest then
        return Settings.Chests
    end
    return Settings.Items
end

local function Unscale(key)
    local record = scaled[key]
    if record and not Near(record.v, 1) and Same(record) then
        record.comp:SetRelativeScale3D({ X = record.base[1], Y = record.base[2], Z = record.base[3] })
    end
    -- Only after the call, so a throw leaves it listed for the next try.
    scaled[key] = nil
end

-- The component's own scale x Size (on) or its own scale back (off).
local function SetScale(key, comp, on)
    local record = scaled[key]
    if not record then
        if not on or Near(Settings.Size, 1) then
            return
        end
        local scale = comp.RelativeScale3D
        local base = { scale.X, scale.Y, scale.Z }
        for i = 1, 3 do
            if type(base[i]) ~= "number" then
                return
            end
        end
        record = { comp = comp, compAddress = comp:GetAddress(), compName = comp:GetFullName(), base = base, v = 1 }
        scaled[key] = record
    end
    local value = on and Settings.Size or 1
    if Near(record.v, value) then
        return
    end
    comp:SetRelativeScale3D({ X = record.base[1] * value, Y = record.base[2] * value, Z = record.base[3] * value })
    record.v = value
end

local function Unshare(key)
    local record = shared[key]
    if record and not Near(record.v, record.base) and Same(record) then
        record.comp:SetVariableFloat(SHARED_FNAME, record.base)
    end
    shared[key] = nil
end

-- The pile's own UE_LightIntensity x Brightness (on) or its own value back (off).
local function SetShared(key, comp, on)
    local record = shared[key]
    if not record then
        if not on then
            return
        end
        local out = {}
        local base = comp:GetVariableFloat(SHARED_FNAME, out)
        if out.bIsValid ~= true or type(base) ~= "number" then
            -- No such parameter (a game update changed the effect): leave it alone.
            return
        end
        record = { comp = comp, compAddress = comp:GetAddress(), compName = comp:GetFullName(), base = base, v = base }
        shared[key] = record
    end
    local value = on and record.base * Settings.Brightness or record.base
    if Near(record.v, value) then
        return
    end
    comp:SetVariableFloat(SHARED_FNAME, value)
    record.v = value
end

-- A renderer that had no material parameters draws with the shared material, not an instance per component. A changed
-- material user parameter makes Niagara build the component's instances again, and the new ones take the mod's
-- entries. No loot effect has this parameter, so nothing else changes. Once per component.
local function Poke(compAddress, comp)
    if poked[compAddress] then
        return
    end
    if not Valid(refreshMaterial) then
        return
    end
    comp:SetVariableMaterial(REFRESH_FNAME, refreshMaterial)
    poked[compAddress] = true
end

local function FindClasses()
    if Valid(pileClass) and Valid(chestClass) then
        classSearchDue = false
        return
    end
    if not classSearchDue and checks % CLASS_SEARCH_EVERY ~= 0 then
        return
    end
    classSearchDue = false
    if not Valid(pileClass) then
        pileClass = StaticFindObject(PILE_CLASS)
    end
    if not Valid(chestClass) then
        chestClass = StaticFindObject(CHEST_CLASS)
    end
    if not Valid(refreshMaterial) then
        refreshMaterial = StaticFindObject(REFRESH_MATERIAL)
    end
    Detail(function() return "classes: BP_Rubbish " .. (Valid(pileClass) and "found" or "not loaded") .. ", BP_Chest "
        .. (Valid(chestClass) and "found" or "not loaded") end)
end

-- An item of an array out parameter as the object. UE4SS (1188, LuaUObject.cpp push_arrayproperty) gives each item as
-- a RemoteUnrealParam, like a hook parameter, so :get() is the object; an item that is already an object stays. The
-- items point into the array that the call filled; UE4SS never frees it, so :get() can read it after the call.
local function Unwrap(item)
    if type(item) ~= "userdata" and type(item) ~= "table" then
        return item
    end
    local ok, object = pcall(function()
        return item:get()
    end)
    if ok and object ~= nil then
        return object
    end
    return item
end

-- What a value is, for the LogDetail lines about skipped actors.
local function Kind(ok, value)
    if not ok then
        return "an error (" .. tostring(value):gsub("%s*\n.*", "") .. ")"
    end
    if value == nil then
        return "missing (nil)"
    end
    if type(value) == "userdata" or type(value) == "table" then
        local valid = Valid(value)
        return type(value) .. (valid and " (valid)" or " (not valid)")
    end
    return type(value) .. " " .. tostring(value)
end

-- One loot actor as a table for the check; nil and the reason when the mod leaves it alone.
local function Inspect(actor, chest, systemPaths)
    if not Valid(actor) then
        return nil, "the listed actor is not valid"
    end
    local okComp, comp = pcall(function()
        return actor.Niagara
    end)
    if not okComp or not Valid(comp) then
        -- An opened chest loses its glow component at load.
        return nil, "Niagara is " .. Kind(okComp, comp)
    end
    -- The game's own "taken" flags: a pile sets Not Interact and then stops its glow; a chest sets CurSwitchState. A
    -- flag that a game update renamed is not a boolean: leave that actor alone rather than guess.
    local looted = false
    for _, field in ipairs(chest and { "CurSwitchState" } or { "Not Interact", "bDestroyed" }) do
        local ok, flag = pcall(function()
            return actor[field]
        end)
        if not ok or type(flag) ~= "boolean" then
            return nil, field .. " is " .. Kind(ok, flag)
        end
        looted = looted or flag
    end
    local system = comp:GetAsset()
    local systemPath = ""
    if Valid(system) then
        local address = system:GetAddress()
        systemPath = systemPaths[address]
        if not systemPath then
            systemPath = PathOf(system)
            systemPaths[address] = systemPath
        end
    end
    return { key = actor:GetAddress(), comp = comp, compAddress = comp:GetAddress(), chest = chest, looted = looted,
        system = system, systemPath = systemPath }
end

-- The check: all loot actors, their effects' renderers, and what the mod set on actors that are gone.
local function Check(forceOff)
    local failed = nil
    local function Part(fn, ...)
        local ok, err = pcall(fn, ...)
        if not ok then
            failed = failed or err
        end
    end
    local pilesOn = not forceOff and GroupOn(false)
    local chestsOn = not forceOff and GroupOn(true)
    -- Both groups off, and the last check (also off) put everything back without an error: nothing to look at. The
    -- records that are left hold the game's values; they are used again when a group is turned on.
    if not pilesOn and not chestsOn and idle then
        return nil
    end

    Part(FindClasses)
    if not Valid(controller) then
        controller = UEHelpers.GetPlayerController()
    end

    if not Valid(controller) then
        -- No world (loading): no list of actors, but a group turned off still gets its scale and light back now, and
        -- what went with the old world is dropped.
        for key, record in pairs(shared) do
            if not Same(record) or not GroupOn(false) or forceOff then
                Part(Unshare, key)
            end
        end
        for key, record in pairs(scaled) do
            if not Same(record) or forceOff or not GroupOn(record.chest) then
                Part(Unscale, key)
            else
                Part(SetScale, key, record.comp, true)
            end
        end
        idle = false
        return failed
    end

    local actors = {}
    local systemPaths = {}
    local statics = UEHelpers.GetGameplayStatics()
    for _, group in ipairs({ { pileClass, false, "BP_Rubbish" }, { chestClass, true, "BP_Chest" } }) do
        local class, chest, label = group[1], group[2], group[3]
        if Valid(class) then
            Part(function()
                local out = {}
                statics:GetAllActorsOfClass(controller, class, out)
                if listed[label] ~= #out then
                    listed[label] = #out
                    Detail(function() return string.format("listed %s: %d actors", label, #out) end)
                end
                for _, entry in ipairs(out) do
                    local actor = Unwrap(entry)
                    local item, why = Inspect(actor, chest, systemPaths)
                    if item then
                        actors[#actors + 1] = item
                        if not skipped[label .. "#first"] then
                            skipped[label .. "#first"] = true
                            Detail(function()
                                return string.format("first %s: %s, effect %s%s, taken %s", label,
                                    actor:GetClass():GetFName():ToString(), item.systemPath ~= "" and item.systemPath
                                    or "none", EFFECTS[item.systemPath] and "" or (item.systemPath == SHARED_SYSTEM
                                    and " (shared, light only)" or " (not in SYSTEMS)"), tostring(item.looted))
                            end)
                        end
                    elseif not skipped[label .. why] then
                        -- Each reason once per game start.
                        skipped[label .. why] = true
                        Detail(function()
                            local ok, name = pcall(function() return actor:GetFullName() end)
                            return "skipped " .. (ok and tostring(name) or label) .. ": " .. why
                        end)
                    end
                end
            end)
            if Settings.LogDetail and listed[label] == 0 and checks % STATUS_EVERY == 0 and type(FindAllOf) == "function" then
                -- An empty list: does the game have such actors at all? A search by name, only for the test log.
                local found = FindAllOf(label .. "_C")
                Detail(function() return string.format("FindAllOf(%s_C): %d objects", label, found and #found or 0) end)
            end
        end
    end

    -- The effects first, so the components asked to build their material instances (below) find the new entries.
    local full = checks % FULL_WALK_EVERY == 0
    local done = {}
    for _, item in ipairs(actors) do
        local effect = EFFECTS[item.systemPath]
        if effect and not done[item.systemPath] then
            done[item.systemPath] = true
            local on = (effect.chest and chestsOn) or (not effect.chest and pilesOn)
            Part(ApplyEffect, item.systemPath, item.system, effect, on, full)
        end
    end

    local seen = {}
    local seenComps = {}
    local looted = { [false] = 0, [true] = 0 }
    local counts = { [false] = 0, [true] = 0 }
    for _, item in ipairs(actors) do
        local key, comp = item.key, item.comp
        local on = (item.chest and chestsOn) or (not item.chest and pilesOn)
        seen[key] = true
        seenComps[item.compAddress] = true
        counts[item.chest] = counts[item.chest] + 1
        if item.looted then
            looted[item.chest] = looted[item.chest] + 1
        end
        local share = shared[key]
        if share and (share.compAddress ~= item.compAddress or item.systemPath ~= SHARED_SYSTEM) then
            -- A new component or effect for the same actor: the old one gets its own value back.
            Part(Unshare, key)
        end
        if item.systemPath == SHARED_SYSTEM then
            Part(SetShared, key, comp, on)
        end
        local scale = scaled[key]
        if scale and scale.compAddress ~= item.compAddress then
            Part(Unscale, key)
        end
        Part(SetScale, key, comp, on)
        if scaled[key] then
            scaled[key].chest = item.chest
        end
        if on and not item.looted and Settings.Brightness > 1 and EFFECTS[item.systemPath] then
            Part(Poke, item.compAddress, comp)
        end
    end
    -- Actors that are gone or no longer listed: their own values back where the component still lives.
    for key in pairs(shared) do
        if not seen[key] then
            Part(Unshare, key)
        end
    end
    for key in pairs(scaled) do
        if not seen[key] then
            Part(Unscale, key)
        end
    end
    for address in pairs(poked) do
        if not seenComps[address] then
            -- Gone with its cell; when it streams in again, its new component is asked again.
            poked[address] = nil
        end
    end
    idle = not pilesOn and not chestsOn and failed == nil

    if checks % STATUS_EVERY == 0 then
        Detail(function()
            local boosted, entries, skipped = 0, 0, 0
            for _, record in pairs(lights) do
                if record.set and record.stock and not Near(record.set[2], record.stock[2]) then
                    boosted = boosted + 1
                end
            end
            for _, record in pairs(glows) do
                if record.foreign then
                    skipped = skipped + 1
                else
                    entries = entries + 1
                end
            end
            local refreshed = 0
            for _ in pairs(poked) do
                refreshed = refreshed + 1
            end
            local scaledCount, sharedCount = 0, 0
            for _ in pairs(scaled) do
                scaledCount = scaledCount + 1
            end
            for _ in pairs(shared) do
                sharedCount = sharedCount + 1
            end
            return string.format("status: piles %d (taken %d), chests %d (opened %d), scaled %d, level F piles %d, "
                .. "lights boosted %d, glow entries %d (left alone %d), refreshed %d", counts[false], looted[false],
                counts[true], looted[true], scaledCount, sharedCount, boosted, entries, skipped, refreshed)
        end)
    end
    return failed
end

-- Puts back everything the mod can still reach, and stops the checks.
local function Stop(why)
    stopped = true
    Log("Stopped (" .. why .. "); putting back the game's values.")
    local ok, err = pcall(Check, true)
    if not ok then
        LogError("Error while putting back: " .. tostring(err))
    end
end

---------------------------------------------------------------------------------------------------------------------
-- Start
---------------------------------------------------------------------------------------------------------------------

Settings = CopyDefaults()
Log(VERSION .. " loaded.")
local read, problem = pcall(ReadConfig)
if not read then
    LogError("Error while reading config.lua: " .. tostring(problem))
end
if not Settings.Enable then
    Log("Enable = false in config.lua: the mod does nothing until it is true.")
end

local function CheckStep()
    if stopped then
        return
    end
    checks = checks + 1
    local started = os.clock()
    -- Check returns its first error (nil when all went well); pcall gives the error of a throw.
    local _, err = pcall(Check, false)
    if err ~= nil then
        failures = failures + 1
        LogError("Check failed (" .. failures .. " in a row): " .. tostring(err))
        if failures >= STOP_AFTER_FAILED_CHECKS then
            Stop(STOP_AFTER_FAILED_CHECKS .. " failed checks in a row")
        end
    else
        failures = 0
    end
    if checks % STATUS_EVERY == 0 then
        Detail(function() return string.format("check took %.0f ms", (os.clock() - started) * 1000) end)
    end
end

local function ConfigStep()
    local ok, err = pcall(ReadConfig)
    if not ok then
        LogError("Error while reading config.lua: " .. tostring(err))
    end
end

RegisterLoadMapPostHook(function()
    local ok, err = pcall(function()
        -- The old world's actors and components are gone: drop their records without touching them. Every effect is
        -- walked again (one that unloaded may be back at the same address with the game's values).
        controller = nil
        classSearchDue = true
        scaled, shared, poked, walked = {}, {}, {}, {}
        idle = false
    end)
    if not ok then
        LogError("Error after the map load: " .. tostring(err))
    end
end)

-- Both loops run on the game thread (UE4SS's Delayed Action API): no Lua on a second thread (Witch Time's crash
-- lesson, knowledge\engine\ue4ss.md). A UE4SS without it gets the old LoopAsync loops, and the log says so.
if type(LoopInGameThreadWithDelay) == "function" then
    LoopInGameThreadWithDelay(CHECK_INTERVAL_MS, CheckStep)
    LoopInGameThreadWithDelay(CONFIG_INTERVAL_MS, ConfigStep)
else
    Log("This UE4SS has no game-thread loops (LoopInGameThreadWithDelay): the older LoopAsync is used; a newer UE4SS "
        .. "is safer.")
    LoopAsync(CHECK_INTERVAL_MS, function()
        ExecuteInGameThread(CheckStep)
        -- false keeps the loop running.
        return false
    end)
    LoopAsync(CONFIG_INTERVAL_MS, function()
        ExecuteInGameThread(ConfigStep)
        return false
    end)
end
