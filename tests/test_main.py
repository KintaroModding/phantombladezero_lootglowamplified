"""Offline test of Scripts/main.lua with lupa (Lua 5.4) and small mocks of UE4SS and the game.

The mocks stand in for the UE4SS functions that the script uses (the game-thread loops LoopInGameThreadWithDelay, the
old LoopAsync, RegisterLoadMapPostHook, StaticFindObject, FName, UEHelpers) and for a small loot world: loot actors
(BP_Rubbish_C, BP_Chest_C) with their Niagara components, and loot effects with emitters, a stateless emitter and
their renderers. A TArray grows by one zeroed entry when the script reads one index past its end, like UE4SS's
(LuaTArray.cpp). Out parameters work as in UE4SS (LuaUObject.cpp): an array fills the table that the script passes,
any other value becomes a key with the parameter's name.

The checks: the loops; what one check changes (lights, glow entries, component scale, the level F piles' light, the
refresh of the material instances) and that a second check changes nothing; live settings (a change, a broken file,
a missing file, a value out of range); groups and Enable off; an effect that reloads (nothing compounds); an entry the
mod did not add; actors that leave; a reused address; the stop after failed checks; a map load; no world; a glow or
an effect that throws. Then the settings files a player may have instead of the shipped config.lua (none, empty or
older, broken, no table, wrong types, unknown setting): main.lua must start, and every setting the file does not give
keeps its default; the shipped config.lua must hold exactly the defaults of main.lua.

Usage:
    python tests/test_main.py        (needs lupa: python -m pip install lupa)

Exit code: 0 = all checks passed, 1 = a check failed.
"""

import json
import sys
import tempfile
from pathlib import Path

from lupa import lua54

ROOT = Path(__file__).resolve().parent.parent
MAIN = ROOT / "src" / "phantombladezero_lootglowamplified" / "Scripts" / "main.lua"
CONFIG = MAIN.parent / "config.lua"

MOCKS = r"""
LOG = {}
print = function(...) LOG[#LOG + 1] = table.concat({...}, "") end

local FNameMeta = { __index = { ToString = function(self) return self.text end } }
EFindName = { FNAME_Find = 0, FNAME_Add = 1 }
function FName(text, findType) return setmetatable({ text = text }, FNameMeta) end

LOOPS = {}
DELAYS = {}
ASYNC_LOOPS = 0
function LoopInGameThreadWithDelay(ms, callback) LOOPS[#LOOPS + 1] = callback DELAYS[#DELAYS + 1] = ms return #LOOPS end
function LoopAsync(ms, callback) ASYNC_LOOPS = ASYNC_LOOPS + 1 LOOPS[#LOOPS + 1] = callback DELAYS[#DELAYS + 1] = ms end
function ExecuteInGameThread(callback) callback() end
MAP_HOOKS = {}
function RegisterLoadMapPostHook(callback) MAP_HOOKS[#MAP_HOOKS + 1] = callback end
-- Runs the loops with this delay (2000: the check, 5000: the config read).
function RUN(ms) for i = 1, #LOOPS do if DELAYS[i] == ms then LOOPS[i]() end end end
function CHECK(n) for _ = 1, n or 1 do RUN(2000) end end
function CONFIG() RUN(5000) end

-- Objects: fields are properties, plus the UObject methods the script uses.
NEXT_ADDRESS = 4096
local ObjectMeta = { __index = {
    IsValid = function(self) return self.valid ~= false end,
    GetAddress = function(self) return self.address end,
    GetFullName = function(self) return self.class .. " " .. self.path end,
    GetFName = function(self) return FName(self.name) end,
    GetOuter = function(self) return self.outer end,
    GetClass = function(self) return { GetFName = function() return FName(self.class) end } end,
} }
FINDALL = 0
function FindAllOf(name) FINDALL = FINDALL + 1 return nil end
function Object(class, path, fields)
    local object = fields or {}
    object.class, object.path, object.name = class, path, path:match("[^.:/]+$")
    NEXT_ADDRESS = NEXT_ADDRESS + 16
    object.address = NEXT_ADDRESS
    return setmetatable(object, ObjectMeta)
end
INVALID = setmetatable({ valid = false, class = "None", path = "None", name = "None", address = 0 }, ObjectMeta)

-- A TArray: # gives the count; reading one index past the end adds a zeroed entry (zero()) like UE4SS.
local ArrayMeta = {
    __len = function(self) return #self.items end,
    __index = function(self, i)
        if type(i) == "number" and i == #self.items + 1 and self.zero then
            self.items[i] = self.zero()
        end
        return self.items[i]
    end,
}
function TArray(items, zero) return setmetatable({ items = items or {}, zero = zero }, ArrayMeta) end
local function ZeroScalar() return { MaterialParameterName = FName("None"), Value = 0 } end

-- A renderer: "L" a light renderer, "S<n>" a sprite and "M<n>" a mesh renderer with material parameters.
function Renderer(emitter, spec)
    if spec == "L" then
        return Object("NiagaraLightRendererProperties", emitter.path .. ".NiagaraLightRendererProperties_0",
            { outer = emitter, RadiusScale = 1, DiffuseScale = 3, SpecularScale = 2 })
    end
    local kind, n = spec:match("^(%a)(%d+)$")
    local class = kind == "S" and "NiagaraSpriteRendererProperties" or "NiagaraMeshRendererProperties"
    return Object(class, emitter.path .. "." .. class .. "_" .. n,
        { outer = emitter, MaterialParameters = { ScalarParameters = TArray({}, ZeroScalar) } })
end

-- A loot effect: emitters { name, { renderer specs } } and stateless emitters; system.R["<emitter>.<spec>"] is each
-- renderer.
function System(package, emitters, stateless)
    local name = package:match("[^/]+$")
    local system = Object("NiagaraSystem", package .. "." .. name, { R = {} })
    local handles = {}
    for _, e in ipairs(emitters) do
        local emitter = Object("NiagaraEmitter", system.path .. ":" .. e[1], {})
        local list = {}
        for _, spec in ipairs(e[2]) do
            list[#list + 1] = Renderer(emitter, spec)
            system.R[e[1] .. "." .. spec] = list[#list]
        end
        emitter.VersionData = TArray({ { RendererProperties = TArray(list) } })
        handles[#handles + 1] = { VersionedInstance = { Emitter = emitter }, StatelessEmitter = INVALID }
    end
    for _, e in ipairs(stateless or {}) do
        local emitter = Object("NiagaraStatelessEmitter", system.path .. ":" .. e[1], {})
        local list = {}
        for _, spec in ipairs(e[2]) do
            list[#list + 1] = Renderer(emitter, spec)
            system.R[e[1] .. "." .. spec] = list[#list]
        end
        emitter.RendererProperties = TArray(list)
        handles[#handles + 1] = { VersionedInstance = { Emitter = INVALID }, StatelessEmitter = emitter }
    end
    system.EmitterHandles = TArray(handles)
    return system
end

function Component(actorPath, system, scale, vars)
    return Object("PBZNiagaraComponent", actorPath .. ".Niagara", {
        asset = system, RelativeScale3D = { X = scale, Y = scale, Z = scale }, vars = vars or {},
        scaleCalls = 0, floatCalls = 0, pokes = 0,
        GetAsset = function(self) return self.asset end,
        SetRelativeScale3D = function(self, v)
            self.scaleCalls = self.scaleCalls + 1
            self.RelativeScale3D = { X = v.X, Y = v.Y, Z = v.Z }
        end,
        GetVariableFloat = function(self, name, out)
            local value = self.vars[name:ToString()]
            out.bIsValid = value ~= nil
            return value or 0
        end,
        SetVariableFloat = function(self, name, value)
            self.floatCalls = self.floatCalls + 1
            self.vars[name:ToString()] = value
        end,
        SetVariableMaterial = function(self, name, material)
            self.pokes = self.pokes + 1
            self.pokedWith = name:ToString() .. " " .. material.path
        end,
    })
end

local LEVEL = "/Game/Maps/B02/PBZ_Xigu_WP.PBZ_Xigu_WP:PersistentLevel."
function Pile(name, system, scale, vars, taken)
    return Object("BP_Rubbish_C", LEVEL .. name, { Niagara = Component(LEVEL .. name, system, scale, vars),
        ["Not Interact"] = taken or false, bDestroyed = false })
end
function Chest(name, system)
    return Object("BP_Chest_C", LEVEL .. name, { Niagara = Component(LEVEL .. name, system, 1), CurSwitchState = false })
end

C = "/Game/PBZContent/VFX/SceneFX/Common/"
OBJECTS = {}
SEARCHES = 0
function StaticFindObject(path) SEARCHES = SEARCHES + 1 return OBJECTS[path] or INVALID end
PILE = Object("BlueprintGeneratedClass", "/Game/PBZContent/Blueprint/Item/Device/BP_Rubbish.BP_Rubbish_C")
CHEST = Object("BlueprintGeneratedClass", "/Game/PBZContent/Blueprint/Item/Device/BP_Chest.BP_Chest_C")
MATERIAL = Object("Material", "/Engine/EngineMaterials/WorldGridMaterial.WorldGridMaterial")
for _, object in ipairs({ PILE, CHEST, MATERIAL }) do OBJECTS[object.path] = object end

-- The world: a chest, a pile, a taken pile, a pile with a stateless emitter, a level F pile (shared effect).
W = {}
W.blue = System(C .. "NS_BlueLightBeam_301",
    { { "Minimal", { "L", "M0" } }, { "Sparks_7", { "S1", "S3" } }, { "NE_BlackSmoke_0", { "S0" } } })
W.green = System(C .. "NS_Item_Green_301", { { "NE_BeamLight_OPT001_0", { "L", "M0" } }, { "Curve_0", { "M0" } } })
W.dust2 = System(C .. "NS_Item_WhiteDust_002", { { "NE_BeamLight_OPT001_0", { "L", "M0" } } },
    { { "NiagaraStatelessEmitter_0", { "M2" } } })
W.dust1 = System(C .. "NS_Item_WhiteDust_001", { { "NE_BeamLight_OPT001_0", { "L", "M0" } } })
W.chest = Chest("BP_Chest_C_1", W.blue)
W.pile = Pile("BP_Rubbish_C_1", W.green, 0.5)
W.taken = Pile("BP_Rubbish_C_2", W.green, 1, nil, true)
W.pile2 = Pile("BP_Rubbish_C_3", W.dust2, 1)
W.levelF = Pile("BP_Rubbish_C_4", W.dust1, 1, { UE_LightIntensity = 10 })
ACTORS = { [PILE] = { W.pile, W.taken, W.pile2, W.levelF }, [CHEST] = { W.chest } }

-- UE4SS gives each item of an array out parameter as a RemoteUnrealParam (:get() is the object); RAW_ITEMS = true
-- gives the objects themselves, as another UE4SS build might. A Param has no UObject methods (IsValid fails).
STATICS = { calls = 0 }
local ParamMeta = { __index = function(self, key)
    if key == "get" then return function(param) return param.object end end
    error("Param has no member " .. tostring(key))
end }
function STATICS:GetAllActorsOfClass(context, class, out)
    self.calls = self.calls + 1
    if self.fail then error("GetAllActorsOfClass failed") end
    for _, actor in ipairs(ACTORS[class] or {}) do
        out[#out + 1] = RAW_ITEMS and actor or setmetatable({ object = actor }, ParamMeta)
    end
end
CONTROLLER = Object("PlayerController", LEVEL .. "PlayerController_0")
CONTROLLER_CALLS = 0
package.preload["UEHelpers"] = function()
    return {
        GetPlayerController = function() CONTROLLER_CALLS = CONTROLLER_CALLS + 1 return CONTROLLER end,
        GetGameplayStatics = function() return STATICS end,
    }
end

-- Short texts for the checks.
function ENTRIES(r)
    local parts = {}
    for _, e in ipairs(r.MaterialParameters.ScalarParameters.items) do
        parts[#parts + 1] = e.MaterialParameterName:ToString() .. "=" .. string.format("%g", e.Value)
    end
    return table.concat(parts, ",")
end
function LIGHT(r) return string.format("%g/%g/%g", r.RadiusScale, r.DiffuseScale, r.SpecularScale) end
function SCALE(actor) return string.format("%g", actor.Niagara.RelativeScale3D.X) end
function CALLS(actor) local c = actor.Niagara return c.scaleCalls + c.floatCalls + c.pokes end

-- The settings line of main.lua for any table: every name=value, sorted by name.
function DESCRIBE(t)
    local names = {}
    for name in pairs(t) do names[#names + 1] = tostring(name) end
    table.sort(names)
    local parts = {}
    for i, name in ipairs(names) do parts[i] = name .. "=" .. tostring(t[name]) end
    return table.concat(parts, ", ")
end
"""

# The files a player may have instead of the shipped config.lua: (case, content or None for no file, a text that
# main.lua must log). "wrong types" is made from the shipped file: every value gets another type.
PLAYER_CONFIGS = [
    ("no config.lua", None, "No config.lua"),
    ("an empty or older config.lua", "return {}\n", None),
    ("a broken config.lua", "return {\n    Enable =\n", "config.lua not read"),
    ("a config.lua without a table", "-- nothing here\n", "does not return a table"),
    ("a config.lua with wrong types", "wrong types", "must be a"),
    ("a config.lua with an unknown setting", "return { NoSuchSetting = 1 }\n", "unknown setting NoSuchSetting"),
]


def lua_path(path: Path) -> str:
    return "[[" + path.as_posix() + "]]"


class Run:
    """main.lua in a fresh Lua state, with config.lua read from config_folder."""

    def __init__(self, config_folder: Path, before: str = ""):
        self.folder = config_folder
        self.lua = lua54.LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(MOCKS)
        self.lua.execute(f'package.path = {lua_path(config_folder)} .. "/?.lua"; package.cpath = ""')
        if before:
            self.lua.execute(before)
        self.g = self.lua.globals()
        self.do(MAIN.read_text(encoding="utf-8"))

    def do(self, code: str):
        """Runs Lua code; a Lua error that stops it becomes an "Error" line in the log, so the checks fail."""
        try:
            return self.lua.execute(code)
        except lua54.LuaError as error:
            self.g.LOG[len(self.g.LOG) + 1] = "Error: main.lua stopped: " + str(error).splitlines()[0]

    def eval(self, expression: str):
        return self.lua.eval(expression)

    def log(self):
        return [self.g.LOG[i].rstrip() for i in range(1, len(self.g.LOG) + 1)]

    def write_config(self, text: str):
        (self.folder / "config.lua").write_text(text, encoding="utf-8")


def settings_lines(log):
    return [line.split("] Settings: ", 1)[1] for line in log if "] Settings: " in line]


def main() -> None:
    version = json.loads((ROOT / "mod.json").read_text(encoding="utf-8"))["version"]
    failures = []

    def check(condition, text):
        print(("ok    " if condition else "FAIL  ") + text)
        if not condition:
            failures.append(text)

    with tempfile.TemporaryDirectory() as temp:
        temp = Path(temp)
        shipped_folder = temp / "shipped"
        shipped_folder.mkdir()
        shipped_text = CONFIG.read_text(encoding="utf-8")
        (shipped_folder / "config.lua").write_text(shipped_text, encoding="utf-8")

        # --- The mod as players get it.
        r = Run(shipped_folder)
        log = r.log()
        for line in log:
            print("      log: " + line)
        check(list(r.g.DELAYS.values()) == [2000, 5000] and r.g.ASYNC_LOOPS == 0,
              "two game-thread loops: the check every 2 s, the config read every 5 s; no LoopAsync")
        check(len(r.g.MAP_HOOKS) == 1, "one map load hook")
        check(any(f"{version} loaded." in line for line in log), f"load line with the version {version} of mod.json")
        shipped = r.eval(f"DESCRIBE(dofile({lua_path(CONFIG)}))")
        check(settings_lines(log) == [shipped], "one settings line with the values of the shipped config.lua")
        check(not any("config.lua" in line for line in log), "the shipped config.lua is read without a warning")

        r.do("CHECK()")
        e = r.eval
        check(e("LIGHT(W.blue.R['Minimal.L'])") == "1.5/6/4",
              "chest light: RadiusScale x (1 + 2) / 2, DiffuseScale and SpecularScale x 2")
        check(e("ENTRIES(W.blue.R['Minimal.M0'])") == "Emissive_Multiplier=2", "chest mesh renderer: Emissive_Multiplier 2")
        check(e("ENTRIES(W.blue.R['Sparks_7.S3'])") == "Emissive_Intensity=2", "chest sprite renderer |I: Emissive_Intensity 2")
        check(e("ENTRIES(W.blue.R['NE_BlackSmoke_0.S0'])") == "Emissive_Multiplier=2", "a second listed emitter")
        check(e("ENTRIES(W.blue.R['Sparks_7.S1'])") == "", "a renderer that is not listed stays as it is")
        check(e("LIGHT(W.green.R['NE_BeamLight_OPT001_0.L'])") == "1.5/6/4", "pile light boosted")
        check(e("ENTRIES(W.green.R['NE_BeamLight_OPT001_0.M0'])") == "Emissive_Intensity=2"
              and e("ENTRIES(W.green.R['Curve_0.M0'])") == "Emissive_Multiplier=2", "pile glow entries")
        check(e("ENTRIES(W.dust2.R['NiagaraStatelessEmitter_0.M2'])") == "Emissive_Multiplier=2",
              "a stateless emitter's renderer gets its entry")
        check(e("LIGHT(W.dust1.R['NE_BeamLight_OPT001_0.L'])") == "1/3/2"
              and e("ENTRIES(W.dust1.R['NE_BeamLight_OPT001_0.M0'])") == "",
              "the shared NS_Item_WhiteDust_001 keeps its renderers")
        check(e("W.levelF.Niagara.vars.UE_LightIntensity") == 20, "level F pile: UE_LightIntensity 10 -> 20")
        check(e("SCALE(W.chest)") == "2" and e("SCALE(W.pile)") == "1" and e("SCALE(W.pile2)") == "2",
              "components scaled x2 from their own scale (chest 1 -> 2, pile 0.5 -> 1)")
        check(e("W.chest.Niagara.pokes") == 1 and e("W.pile.Niagara.pokes") == 1 and e("W.pile2.Niagara.pokes") == 1
              and e("W.chest.Niagara.pokedWith") == "LootGlowAmplifiedRefresh " + "/Engine/EngineMaterials/"
              "WorldGridMaterial.WorldGridMaterial", "each untaken loot component is asked once to build its instances")
        check(e("W.taken.Niagara.pokes") == 0 and e("W.levelF.Niagara.pokes") == 0,
              "no refresh for a taken pile or the shared effect")
        searches = e("SEARCHES")
        calls = {name: e(f"CALLS(W.{name})") for name in ("chest", "pile", "taken", "pile2", "levelF")}
        r.do("CHECK(20)")
        check(e("SEARCHES") == searches, "no search by name once the classes are found")
        check({name: e(f"CALLS(W.{name})") for name in calls} == calls and e("ENTRIES(W.blue.R['Minimal.M0'])")
              == "Emissive_Multiplier=2" and e("LIGHT(W.blue.R['Minimal.L'])") == "1.5/6/4",
              "20 more checks (with full walks) change nothing: no second entry, no compounding")
        check(e("CONTROLLER_CALLS") == 1, "the controller is searched once and kept")

        raw = Run(shipped_folder, "RAW_ITEMS = true")
        raw.do("CHECK()")
        check(raw.eval("SCALE(W.chest)") == "2" and raw.eval("LIGHT(W.blue.R['Minimal.L'])") == "1.5/6/4",
              "list items that are already objects (another UE4SS build) work too")

        # --- Live settings.
        r.write_config(shipped_text.replace("Brightness = 2,", "Brightness = 3,").replace("Size = 2,", "Size = 1,"))
        r.do("CONFIG()")
        check(any("Brightness=3" in line and "Size=1" in line for line in settings_lines(r.log())),
              "a changed config.lua is read at the next config step and logged")
        r.do("CHECK()")
        check(e("LIGHT(W.blue.R['Minimal.L'])") == "2/9/6" and e("ENTRIES(W.blue.R['Minimal.M0'])")
              == "Emissive_Multiplier=3", "Brightness 3: light from stock (not from the boosted value), entry 3")
        check(e("SCALE(W.chest)") == "1" and e("SCALE(W.pile)") == "0.5", "Size 1: each component's own scale back")
        check(e("W.levelF.Niagara.vars.UE_LightIntensity") == 30, "level F pile: 10 x 3")
        lines = len(settings_lines(r.log()))
        r.do("CONFIG() CONFIG()")
        check(len(settings_lines(r.log())) == lines, "an unchanged file is not applied or logged again")

        r.write_config("return {\n    Brightness = 4,\n")
        r.do("CONFIG() CHECK()")
        check(any("config.lua not read (line" in line and "the last settings stay" in line for line in r.log())
              and e("ENTRIES(W.blue.R['Minimal.M0'])") == "Emissive_Multiplier=3",
              "a broken (half-saved) file keeps the last settings")
        r.write_config("return { Brightness = 9 }\n")
        r.do("CONFIG() CHECK()")
        check(any("Brightness = 9 is outside 1 to 5; 5 is used" in line for line in r.log())
              and e("ENTRIES(W.blue.R['Minimal.M0'])") == "Emissive_Multiplier=5", "a value out of range is clamped")
        (r.folder / "config.lua").unlink()
        r.do("CONFIG() CHECK()")
        check(sum("No config.lua" in line for line in r.log()) == 1 and e("ENTRIES(W.blue.R['Minimal.M0'])")
              == "Emissive_Multiplier=2", "a deleted config.lua means the defaults")
        r.write_config(shipped_text)
        r.do("CONFIG() CHECK()")

        # --- Groups and Enable.
        r.write_config(shipped_text.replace("Chests = true,", "Chests = false,"))
        r.do("CONFIG() CHECK()")
        check(e("LIGHT(W.blue.R['Minimal.L'])") == "1/3/2" and e("ENTRIES(W.blue.R['Minimal.M0'])")
              == "Emissive_Multiplier=1" and e("SCALE(W.chest)") == "1",
              "Chests = false: chest light at stock, entry at 1 (the material's own), scale back")
        check(e("LIGHT(W.green.R['NE_BeamLight_OPT001_0.L'])") == "1.5/6/4" and e("SCALE(W.pile)") == "1",
              "Chests = false leaves the piles on")
        r.write_config(shipped_text.replace("Enable = true,", "Enable = false,"))
        r.do("CONFIG() CHECK()")
        check(e("LIGHT(W.green.R['NE_BeamLight_OPT001_0.L'])") == "1/3/2" and e("SCALE(W.pile)") == "0.5"
              and e("W.levelF.Niagara.vars.UE_LightIntensity") == 10 and e("ENTRIES(W.green.R['Curve_0.M0'])")
              == "Emissive_Multiplier=1", "Enable = false: everything back to the game's values")
        calls_before = e("STATICS.calls")
        r.do("CHECK(3)")
        check(e("STATICS.calls") == calls_before, "with everything off and put back, the checks list no actors")
        r.write_config(shipped_text)
        r.do("CONFIG() CHECK()")
        check(e("LIGHT(W.blue.R['Minimal.L'])") == "1.5/6/4" and e("SCALE(W.chest)") == "2"
              and e("ENTRIES(W.blue.R['Minimal.M0'])") == "Emissive_Multiplier=2", "Enable = true again: on again")

        # --- An effect that reloads: a new object with the game's values, at another address or the same one.
        r.do("""
            local old = W.blue
            W.blue = System(C .. "NS_BlueLightBeam_301",
                { { "Minimal", { "L", "M0" } }, { "Sparks_7", { "S1", "S3" } }, { "NE_BlackSmoke_0", { "S0" } } })
            W.chest.Niagara.asset = W.blue
        """)
        r.do("CHECK()")
        check(e("LIGHT(W.blue.R['Minimal.L'])") == "1.5/6/4" and e("ENTRIES(W.blue.R['Minimal.M0'])")
              == "Emissive_Multiplier=2", "a reloaded effect (new address) is boosted once from its stock values")
        r.do("""
            local light = W.blue.R['Minimal.L']
            light.RadiusScale, light.DiffuseScale, light.SpecularScale = 1, 3, 2
        """)
        r.do("CHECK(15)")
        check(e("LIGHT(W.blue.R['Minimal.L'])") == "1.5/6/4",
              "a reload at the same address is caught by the full walk (every 15 checks), without compounding")

        # --- An entry the mod did not add.
        r2 = Run(shipped_folder, """
            local list = W.blue.R['Minimal.M0'].MaterialParameters.ScalarParameters
            list.items[1] = { MaterialParameterName = FName("emissive_multiplier"), Value = 7 }
        """)
        r2.do("CHECK(2)")
        check(r2.eval("ENTRIES(W.blue.R['Minimal.M0'])") == "emissive_multiplier=7"
              and r2.eval("ENTRIES(W.blue.R['Sparks_7.S3'])") == "Emissive_Intensity=2",
              "an entry the mod did not add (any case) is left alone; the other renderers work")

        # --- Actors that leave, and a reused address.
        r.do("ACTORS[PILE] = { W.taken, W.pile2, W.levelF } CHECK()")
        check(e("SCALE(W.pile)") == "0.5", "a pile no longer listed gets its own scale back")
        r.do("""
            ACTORS[PILE] = { W.pile, W.taken, W.pile2, W.levelF } CHECK()
            W.pile.Niagara.path = W.pile.Niagara.path .. "_reused"
            ACTORS[PILE] = { W.taken, W.pile2, W.levelF } CHECK()
        """)
        check(e("SCALE(W.pile)") == "1" and e("W.pile.Niagara.pokes") == 2,
              "a component whose name changed at the same address is not touched; a pile that comes back is asked "
              "again to build its instances")

        # --- A map load and no world.
        r.do("MAP_HOOKS[1]() CONTROLLER.valid = false")
        controller_calls = e("CONTROLLER_CALLS")
        r.do("CHECK()")
        check(not any("Error" in line or "failed" in line for line in r.log()) and e("CONTROLLER_CALLS")
              == controller_calls + 1, "after a map load and without a world: no error, the controller is searched")
        r.do("CONTROLLER.valid = true")

        # --- Throws: a glow, an effect that cannot be walked, and the stop after failed checks.
        r3 = Run(shipped_folder, """
            W.green.R['Curve_0.M0'].MaterialParameters = setmetatable({}, { __index = function() error("no struct") end })
            local handles = W.dust2.EmitterHandles
            W.dust2.EmitterHandles = setmetatable({}, { __len = function() error("cannot walk") end })
        """)
        r3.do("CHECK(3)")
        log3 = r3.log()
        check(any("Glow NS_Item_Green_301 Curve_0.NiagaraMeshRendererProperties_0" in line for line in log3)
              and any("Could not walk the renderers of NS_Item_WhiteDust_002" in line for line in log3)
              and not any("Check failed" in line for line in log3)
              and r3.eval("LIGHT(W.green.R['NE_BeamLight_OPT001_0.L'])") == "1.5/6/4"
              and r3.eval("SCALE(W.pile2)") == "2",
              "a glow or an effect that throws is logged, not counted as a failed check; the rest works")
        r4 = Run(shipped_folder)
        r4.do("CHECK() STATICS.fail = true CHECK(10)")
        log4 = r4.log()
        check(any("Stopped (10 failed checks in a row)" in line for line in log4)
              and r4.eval("SCALE(W.chest)") == "1" and r4.eval("SCALE(W.pile)") == "0.5"
              and r4.eval("W.levelF.Niagara.vars.UE_LightIntensity") == 10,
              "10 failed checks in a row: the mod stops and puts the scales and the level F light back")
        calls_stopped = r4.eval("STATICS.calls")
        r4.do("CHECK(5)")
        check(r4.eval("STATICS.calls") == calls_stopped, "after the stop, no more checks")
        check(sum("Check failed" in line for line in log4) <= 5, "at most 5 error lines")

        # --- LogDetail: every change and a status line, without an error.
        detail_folder = temp / "detail"
        detail_folder.mkdir()
        (detail_folder / "config.lua").write_text(shipped_text.replace("LogDetail = false,", "LogDetail = true,"),
                                                  encoding="utf-8")
        r5 = Run(detail_folder, """
            local list = W.green.R['Curve_0.M0'].MaterialParameters.ScalarParameters
            list.items[1] = { MaterialParameterName = FName("Emissive_Multiplier"), Value = 7 }
            W.odd = Object("BP_Rubbish_A_C", "/Game/Maps/B02/PBZ_Xigu_WP.PBZ_Xigu_WP:PersistentLevel.BP_Rubbish_A_C_9",
                { Niagara = Component("odd", W.green, 1), bDestroyed = false })
            table.insert(ACTORS[PILE], W.odd)
        """)
        r5.do("CHECK(15)")
        log5 = r5.log()
        for line in log5[-4:]:
            print("      log: " + line)
        check(any("listed BP_Rubbish: 5 actors" in line for line in log5)
              and any("listed BP_Chest: 1 actors" in line for line in log5)
              and sum("skipped BP_Rubbish_A_C /Game/Maps/B02/PBZ_Xigu_WP.PBZ_Xigu_WP:PersistentLevel.BP_Rubbish_A_C_9: "
                      "Not Interact is missing (nil)" in line for line in log5) == 1
              and any("first BP_Rubbish: BP_Rubbish_C, effect " + "/Game/PBZContent/VFX/SceneFX/Common/NS_Item_Green_301"
                      ".NS_Item_Green_301, taken false" in line for line in log5)
              and r5.eval("CALLS(W.odd)") == 0,
              "LogDetail: the listed counts, each skip reason once, the first actor per class; a skipped actor is "
              "not touched")
        r5.do("ACTORS[CHEST] = {} CHECK(15)")
        log5 = r5.log()
        check(any("listed BP_Chest: 0 actors" in line for line in log5)
              and any("FindAllOf(BP_Chest_C): 0 objects" in line for line in log5) and r5.eval("FINDALL") == 1,
              "LogDetail: an empty list logs a FindAllOf count on the status check only")
        check(any("light NS_BlueLightBeam_301.NS_BlueLightBeam_301:Minimal.NiagaraLightRendererProperties_0: 1/3/2 "
                  "-> 1.5/6/4" in line for line in log5)
              and any("glow NS_BlueLightBeam_301.NS_BlueLightBeam_301:Minimal.NiagaraMeshRendererProperties_0 "
                      "Emissive_Multiplier nil -> 2" in line for line in log5)
              and any("already has Emissive_Multiplier 7; left alone" in line for line in log5)
              and any("classes: BP_Rubbish found, BP_Chest found" in line for line in log5)
              and any("status: piles 4 (taken 1), chests 1 (opened 0), scaled 5, level F piles 1, lights boosted 3, "
                      "glow entries 6 (left alone 1), refreshed 3" in line for line in log5)
              and any("check took" in line for line in log5)
              and not any("Error" in line or "failed" in line for line in log5),
              "LogDetail: the changes, the classes and the status line, without an error")

        # --- The settings files a player may have.
        folders = {}
        for case, content, _ in PLAYER_CONFIGS + [("Enable = false", "return { Enable = false }\n", None)]:
            folder = temp / str(len(folders))
            folder.mkdir()
            if content == "wrong types":
                content = r.eval(f"""(function()
                    local lines = {{}}
                    for name, value in pairs(dofile({lua_path(CONFIG)})) do
                        lines[#lines + 1] = string.format("    [%q] = %s,", name, type(value) == "string" and "0" or '"wrong"')
                    end
                    return "return {{\\n" .. table.concat(lines, "\\n") .. "\\n}}\\n"
                end)()""")
            if content is not None:
                (folder / "config.lua").write_text(content, encoding="utf-8")
            folders[case] = folder

        defaults = settings_lines(Run(folders["an empty or older config.lua"]).log())
        check(defaults == [shipped], f"config.lua ships exactly the defaults of main.lua ({defaults})")
        count = len(list(r.eval(f"dofile({lua_path(CONFIG)})").keys()))
        for case, _, expected in PLAYER_CONFIGS:
            run = Run(folders[case])
            run.do("CHECK(2) CONFIG()")
            log = run.log()
            fine = (settings_lines(log) == defaults and len(run.g.LOOPS) == 2
                    and not any("Error" in line for line in log))
            if expected is None:
                fine = fine and not any("config.lua" in line for line in log)
            else:
                fine = fine and sum(expected in line for line in log) == (count if case.endswith("wrong types") else 1)
            check(fine, f"{case}: starts, every setting at its default"
                  + (f", logs '{expected}' once per setting" if case.endswith("wrong types")
                     else (f", logs '{expected}' once" if expected else ", no warning")))
            if not fine:
                for line in log:
                    print("      log: " + line)

        run = Run(folders["Enable = false"])
        run.do("CHECK(3)")
        log = run.log()
        check(len(run.g.LOOPS) == 2 and any("does nothing until it is true" in line for line in log)
              and run.eval("SCALE(W.chest)") == "1" and run.eval("LIGHT(W.blue.R['Minimal.L'])") == "1/3/2"
              and run.eval("STATICS.calls") == 2,
              "Enable = false at start: the loops run (live settings), nothing changes, the actors are listed once")

    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
