--Civilwargeeky's Quarry Program--
--https://github.com/civilwargeeky/Civils_Progs--
  VERSION = "3.6.4.5"
--[[
Current local policy:
  Non-interactive quarry execution.
  State persistence is mandatory and compact.
  Fuel is consumed up-front; reserve drift triggers a home refuel return.
  Storage is local chest only; no portable chest automation.
]]
--Defining things
local __baseEnv = _ENV
civilTable = {}
__baseEnv.civilTable = civilTable
setmetatable(civilTable, {__index = __baseEnv})
_ENV = civilTable
originalDay = os.day() --Used in logging
numResumed = 0 --Number of times turtle has been resumed
-------Defaults for Arguments----------
--Arguments assignable by text
x,y,z = 3,3,3 --These are just in case tonumber fails
inverted = false --False goes from top down, true goes from bottom up [Default false]
rednetEnabled = false --Default rednet on or off  [Default false]
--Arguments assignable by tArgs
dropSide = "front" --Side it will eject to when full or done [Default "front"]
storagePhysicalSide = false --Physical adjacent inventory side detected or supplied at launch.
storageAutoDetected = false --True when storage side was inferred by probing adjacent inventories.
careAboutResources = true --Will not stop mining once inventory full if false [Default true]
doCheckFuel = true --Predictive fuel safety is mandatory.
doRefuel = true --On-board coal/charcoal may be consumed automatically.
keepOpen = 1 --Internal reserve slot count; hidden safety constant.
fuelSafety = "moderate" --Startup estimate safety profile.
excessFuelAmount = math.huge --Maximum allowed tank fill.
fuelMultiplier = 1 --Internal legacy multiplier retained only for state compatibility.
stateFilePath = "Civil_Quarry_State" --Compact latest execution snapshot path; override with -state FILE
stateSnapshotLoaded = false --True when runtime was reconstructed from -state
stateRouteMode = "mining" --Current persistence intent: mining, to_storage, to_work, final_return
statePathToNext = "" --Compact movement instructions from current coordinate to active work/route target
statePathToStorage = "" --Compact movement instructions from current coordinate to the home chest
stateNextTarget = nil --{x,z,y,f,label} target used to rebuild the immediate route after interruption
stateStorageTarget = nil --{x,z,y,f,label} target for home collection routing
driveJournal = nil --Pending non-atomic physical drive operation, reconciled before resume routing.
driveJournalSeq = 0 --Monotonic counter for movement journal entries.
stateSnapshotSchema = 6 --Current compact state format; old state files are intentionally rejected.
storageReturnX, storageReturnZ, storageReturnY, storageReturnFacing = nil, nil, nil, nil
homeBaseX, homeBaseZ, homeBaseY = 0, 1, 1
quarryAccessX, quarryAccessZ = 1, 1
uniqueExtras = 8 --Internal estimate for distinct low-stack cargo slots.
maxTries = 200 --How many times turtle will try to dig a block before it "counts" bedrock [Default 200]
logFile = false --Optional final-run log file path.
flatBedrock = false --If true, will go down to bedrock to set startDown [Default false]
startDown = 0 --How many blocks to start down from the top of the mine [Default 0]
preciseTotals = false --If true, will record exact totals and names for all materials [Default false]
goLeftNotRight = false --Quarry to left, not right (parameter is "left") [Default false]
oreQuarry = false --Enables ore quarry functionality [Default false]
oreQuarryBlacklistName = "oreQuarryBlacklist.txt" --This is the file that will be parsed for item names [Default "oreQuarryBlacklist"]
dumpCompareItems = true --If ore quarry, the turtle will dump items compared to (like cobblestone) [Default true]
inventoryMax = 16 --The max number of slots in the turtle inventory [Default 16] (Not assignable by parameter)
returnFuelSafetyBuffer = 0 --Deprecated: reserve policy is derived from 2x maximum home-return cost.
maxHomeReturnCost = 0 --Largest geometric return-to-storage cost within the configured quarry volume.
returnFuelReserveFloor = 0 --Critical fuel floor; normally 2 * maxHomeReturnCost, capped by fuel tank limit.
refuelReturnActive = false --Suppresses recursive reserve checks during a planned home-refuel cycle.
fuelSafetyReturnActive = false --Suppresses recursive reserve checks during forced return-to-base routing
suspendedOperationalState = false --Persisted hard-pause marker for manual operator recovery
storageBlockedPause = false --Persisted marker for saturated home collection storage
driveSystemsDisabled = false --Set true by hard-pause states before script termination
suspendedReason = "" --Human-readable reason persisted in backup state
unmineableRegistryName = "unmineable.txt" --Persistent learned impassable block registry
unmineableBlocks = {} --Runtime lookup of learned unmineable block IDs
--Standard number slots for fuel (you shouldn't care)
fuelTable = { --Will add in this amount of fuel to requirement.
safe = 1000,
moderate = 200,
loose = 0 } --Default 1000, 200, 0
--Standard rednet channels
channels = {
send = os.getComputerID() + 1  ,
receive = os.getComputerID() + 101 ,
confirm = "Turtle Quarry Receiver",
message = "Civil's Quarry",
fingerprint = (os.getComputerLabel and os.getComputerLabel()) or tostring(os.getComputerID())
}

--AVERAGE USER: YOU DON'T CARE BELOW THIS POINT

--Compact help is generated by printCompactHelp() below.
local help = {}

local supportsRednet
if peripheral.find then
  supportsRednet = peripheral.find("modem") or false
else
  supportsRednet = (peripheral.getType("right") == "modem") or false
end

--Pre-defining variables that need to be saved
      xPos,yPos,zPos,facing,percent,mined,moved,relxPos, rowCheck, connected, isInPath, layersDone, attacked, startY, chestFull, gotoDest, fuelLevel, numDropOffs, allowedItems, dumpSlots, selectedSlot, extraDropItems, relzPos, eventInsertionPoint
    = 0,   1,   1,   0,     0,      0,    0,    1,       true   ,  false,     true,     1,          0,        0,      false,     "",       0,         0,           {},           {},      1,            false,          0, 1

local chestID = "minecraft:chest"

local statusString

--Initializing various inventory management tables
for i=1, inventoryMax do
  allowedItems[i] = 0 --Number of items allowed in slot when dropping items
  dumpSlots[i] = false --Does this slot contain junk items?
end
totals = {cobble = 0, fuel = 0, other = 0} -- Total for display (cannot go inside function), this goes up here because many functions use it

function resetDumpSlots()
  for i=1, inventoryMax do dumpSlots[i] = false end
  dumpSlots[1] = true
end

local function copyTable(tab) if type(tab) ~= "table" then error("copyTable received "..type(tab)..", expected table",2) end local toRet = {}; for a, b in pairs(tab) do toRet[a] = b end; return toRet end --This goes up here because it is a basic utility


local function normalizeBlockID(name)
  if type(name) ~= "string" then return nil end
  name = name:match("^%s*(.-)%s*$")
  if not name or name == "" then return nil end
  if name:sub(1,1) == "#" then return nil end
  return name
end

function countUnmineableBlocks()
  local count = 0
  for _ in pairs(unmineableBlocks or {}) do count = count + 1 end
  return count
end

local function loadUnmineableRegistry()
  local loaded = 0
  unmineableBlocks = unmineableBlocks or {}
  local files = {unmineableRegistryName}
  local seenFiles = {}
  for _, fileName in ipairs(files) do
    if fileName and not seenFiles[fileName] and fs and fs.exists and fs.exists(fileName) then
      seenFiles[fileName] = true
      local handle = fs.open(fileName, "r")
      if handle then
        local text = handle.readAll() or ""
        handle.close()
        for line in text:gmatch("[^\r\n]+") do
          local blockName = normalizeBlockID(line)
          if blockName and not unmineableBlocks[blockName] then
            unmineableBlocks[blockName] = true
            loaded = loaded + 1
          end
        end
      end
    end
  end
  return loaded
end

local function appendUnmineableRegistry(blockName)
  if not fs or not fs.open then return false end
  local handle = fs.open(unmineableRegistryName, "a")
  if not handle then return false end
  handle.writeLine(blockName)
  handle.close()
  return true
end

loadUnmineableRegistry()

--NOTE: rowCheck is a bit. true = "right", false = "left"

local foundBedrock = false

local checkFuel, checkFuelLimit
if turtle then --Function inits
  checkFuel = turtle.getFuelLevel
  if turtle.getFuelLevel() == "unlimited" then --Fuel is disabled --Unlimited screws up my calculations
    checkFuel = function() return math.huge end --Infinite Fuel
  end --There is no "else" because it will already return the regular getFuel
  if turtle.getFuelLimit then
    checkFuelLimit = function() return math.min(turtle.getFuelLimit(), excessFuelAmount) end --Return the limiting one
    if turtle.getFuelLimit() == "unlimited" then
      checkFuelLimit = function() return math.huge end
    end
  else
    checkFuelLimit = function() return excessFuelAmount end --If the function doesn't exist
  end


  turtle.select(1) --To ensure this is correct
end


function select(slot)
  slot = tonumber(slot)
  if not slot then return false, selectedSlot end
  if slot ~= selectedSlot and slot > 0 and slot <= inventoryMax then
    selectedSlot = slot
    return turtle.select(slot), selectedSlot
  end
  return true, selectedSlot
end


 -----------------------------------------------------------------
--Input Phase
local function screen(xPos,yPos)
xPos, yPos = xPos or 1, yPos or 1
term.setCursorPos(xPos,yPos); term.clear(); end
local function screenLine(xPos,yPos)
term.setCursorPos(xPos,yPos); term.clearLine(); end

local TERM_COLS, TERM_ROWS, PRINT_MAX_COLS = 39, 13, 38
local __rawPrint = __baseEnv.print
local __luaSelect = __baseEnv.select

local function trimToTerm(text, limit)
  text = tostring(text or "")
  text = text:gsub("[\r\n]+", " ")
  limit = tonumber(limit) or PRINT_MAX_COLS
  if limit > PRINT_MAX_COLS then limit = PRINT_MAX_COLS end
  if #text > limit then
    return text:sub(1, math.max(limit - 1, 1)) .. "~"
  end
  return text
end

local function printBounded(...)
  local out = {}
  for i=1, __luaSelect("#", ...) do
    out[#out+1] = tostring(__luaSelect(i, ...))
  end
  return __rawPrint(trimToTerm(table.concat(out, " ")))
end
print = printBounded

local function printCompactHelp(reason)
  screen(1,1)
  local lines = {}
  if reason and #tostring(reason) > 0 then
    lines[#lines+1] = "ERR "..tostring(reason)
  end
  lines[#lines+1] = "quarry [-chest SIDE] [-dim L,W,H]"
  lines[#lines+1] = "No chest: auto-probe local inv"
  lines[#lines+1] = "SIDE back|top|bottom|left|right"
  lines[#lines+1] = "-dim L,W,H  size; default 3,3,3"
  lines[#lines+1] = "-state FILE  snapshot path"
  lines[#lines+1] = "-invert t|f  vertical order"
  lines[#lines+1] = "-startDown N  initial descent"
  lines[#lines+1] = "-left t|f  quarry left side"
  lines[#lines+1] = "-oreQuarry t|f  use blacklist"
  lines[#lines+1] = "-log FILE  final summary log"
  lines[#lines+1] = "-careAboutResources t|f"
  lines[#lines+1] = "No args: resume default state."
  lines[#lines+1] = "Learned walls: unmineable.txt"
  for i=1, math.min(#lines, TERM_ROWS) do
    print(lines[i])
  end
end

local function boolText(value)
  if value then return "true" end
  return "false"
end

local function countTableKeys(tab)
  local n = 0
  if type(tab) == "table" then
    for _ in pairs(tab) do n = n + 1 end
  end
  return n
end

local function shortPath(path, limit)
  path = tostring(path or "")
  limit = limit or 17
  if #path <= limit then return path end
  return "~"..path:sub(-limit + 1)
end

local function printConfigLine(label, value)
  print(trimToTerm(label..": "..tostring(value)))
end

local function displayConfigurationSummary()
  screen(1,1)
  auditCoalInventory = auditCoalInventory or function() return 0 end
  if not stateSnapshotLoaded and auditCoalInventory then auditCoalInventory() end
  local fuelLimit = (checkFuelLimit and checkFuelLimit()) or excessFuelAmount
  local fuelNow = (checkFuel and checkFuel()) or "?"
  local knownWalls = countUnmineableBlocks and countUnmineableBlocks() or countTableKeys(unmineableBlocks)
  local lines = {
    "Quarry profile",
    "Dim L,Z,Y "..tostring(x)..","..tostring(z)..","..tostring(y),
    "Chest "..tostring(dropSide).." phys "..tostring(storagePhysicalSide or "-"),
    "AutoChest "..boolText(storageAutoDetected).." Left "..boolText(goLeftNotRight),
    "Invert "..boolText(inverted).."  Down "..tostring(startDown),
    "State "..shortPath(stateFilePath, 24),
    "Route "..tostring(stateRouteMode or "mining"),
    "Fuel "..tostring(fuelNow).."/"..tostring(fuelLimit),
    "Fuel floor "..tostring(returnFuelReserveFloor or 0),
    "Ore "..boolText(oreQuarry).."  Log "..shortPath(logFile or "off", 18),
    "No portable chest automation",
    "Walls "..tostring(knownWalls).." in unmineable.txt",
    "Mining starts in 10 seconds."
  }
  for i=1, math.min(#lines, TERM_ROWS) do print(lines[i]) end
  sleep(10)
end

screen(1,1)
print("Quarry init")
print("")

local sides = {top = "top", right = "right", left = "left", bottom = "bottom", front = "front", back = "front"} -- back maps to the same physical chest as drop-side front after return-home facing.
local physicalStorageToDropSide = {back = "front", right = "right", left = "left", top = "top", bottom = "bottom"}

local function sideTypeText(side)
  if not peripheral or not peripheral.getType then return "" end
  local ok, typ = pcall(peripheral.getType, side)
  if not ok or typ == nil then return "" end
  if type(typ) == "table" then
    local parts = {}
    for _, value in pairs(typ) do parts[#parts+1] = tostring(value) end
    return table.concat(parts, ","):lower()
  end
  return tostring(typ):lower()
end

local function isRejectedStorageSide(side)
  local typ = sideTypeText(side)
  if typ:find("ender", 1, true) then return true end
  if turtle then
    local ok, present, data
    if side == "front" and turtle.inspect then ok, present, data = pcall(function() local a,b = turtle.inspect(); return a,b end)
    elseif side == "top" and turtle.inspectUp then ok, present, data = pcall(function() local a,b = turtle.inspectUp(); return a,b end)
    elseif side == "bottom" and turtle.inspectDown then ok, present, data = pcall(function() local a,b = turtle.inspectDown(); return a,b end) end
    if ok and present and type(data) == "table" and type(data.name) == "string" then
      return data.name:lower() == "minecraft:ender_chest" or data.name:lower():find("ender_chest", 1, true) ~= nil
    end
  end
  return false
end

local function isInventorySide(side)
  if isRejectedStorageSide(side) then return false end
  if not peripheral or not peripheral.wrap then return false end
  local ok, wrapped = pcall(peripheral.wrap, side)
  if not ok or type(wrapped) ~= "table" then return false end
  return type(wrapped.size) == "function" or type(wrapped.list) == "function" or type(wrapped.pushItems) == "function" or type(wrapped.pullItems) == "function"
end

local function discoverAdjacentInventorySide()
  -- Deliberately avoid physical rotation here. Front is omitted because it is the quarry access vector.
  for _, physicalSide in ipairs({"back", "right", "left", "top", "bottom"}) do
    if isInventorySide(physicalSide) then
      return physicalSide, physicalStorageToDropSide[physicalSide]
    end
  end
  return nil, nil
end

local tArgs --Will be set in initializeArgs
local originalArgs = {...}
local changedT, tArgsWithUpper = {}, {}
changedT.new = function(key, value, name) table.insert(changedT,{key, value, name}); if name then changedT[name] = #changedT end end --Numeric list of lists
changedT.remove = function(num) changedT[num or #changedT].hidden = true end --Note actually remove, just hide :)
local function capitalize(text) return (string.upper(string.sub(text,1,1))..string.sub(text,2,-1)) end
local function initializeArgs()
  tArgs = copyTable(originalArgs) --"Reset" tArgs
  for i=1, #tArgs do --My signature key-value pair system, now with upper
    tArgsWithUpper[i] = tArgs[i]
    tArgsWithUpper[tArgsWithUpper[i]] = i
    tArgs[i] = tArgs[i]:lower()
    tArgs[tArgs[i]] = i
  end
end
initializeArgs()

local restoreFound, restoreFoundSwitch = false --Initializing so they are in scope
local function getPathValue(path)
  local current = _ENV
  for key in tostring(path):gmatch("[^%.]+") do
    if type(current) ~= "table" then return nil end
    current = current[key]
    if current == nil then return nil end
  end
  return current
end

local function setPathValue(path, value)
  local current = _ENV
  local parts = {}
  for key in tostring(path):gmatch("[^%.]+") do
    parts[#parts + 1] = key
  end
  if #parts == 0 then error("setPathValue received empty path", 2) end
  for i=1,#parts-1 do
    local key = parts[i]
    if type(current[key]) ~= "table" then current[key] = {} end
    current = current[key]
  end
  current[parts[#parts]] = value
end

function parseParam(name, displayText, formatString, _legacyInteractiveIgnored, trigger, variableOverride, variableExists) --Non-interactive CC:T-safe parser
  if variableExists ~= false then variableExists = true end
  if trigger == nil then trigger = true end
  if not trigger then return end
  local toGetText = name:lower()
  local formatType = formatString:match("^%a+"):lower() or error("Format String Unknown: "..formatString)
  local args = formatString:match(" (.+)") or ""..""
  local variable = variableOverride or name
  local originalValue = getPathValue(variable)
  if originalValue == nil and variableExists then error("From addParam, \""..variable.."\" returned nil",2) end
  local givenValue, toRet
  if tArgs["-"..toGetText] then
    givenValue = tArgsWithUpper[tArgs["-"..toGetText]+1]
  end
  if formatType == "force" then
    toRet = (tArgs["-"..toGetText] and true) or false
  end
  if not (givenValue or toRet) or (type(givenValue) == "string" and #givenValue == 0) then return end
  if formatType == "boolean" then
    toRet = givenValue:sub(1,1):lower() ~= "n" and givenValue:sub(1,1):lower() ~= "f"
  elseif formatType == "string" then
    toRet = givenValue:match("^[%w%./_%-]+")
  elseif formatType == "number" or formatType == "float" then
    toRet = tonumber(givenValue)
    if not toRet then return end
    if formatType == "number" then toRet = math.floor(toRet) end
    local startNum, endNum = formatString:match("(%d+)%-(%d+)")
    startNum, endNum = tonumber(startNum), tonumber(endNum)
    if startNum and endNum and not ((toRet >= startNum) and (toRet <= endNum)) then return end
  elseif formatType == "side" then
    local exclusionTab = {}
    for a in args:gmatch("%S+") do exclusionTab[a] = true end
    if not exclusionTab[givenValue] then toRet = sides[givenValue] end
  elseif formatType == "list" then
    toRet = {}
    for a in args:gmatch("[^,]") do
      table.insert(toRet,a)
    end
  elseif formatType == "force" then
    -- already handled
  else error("Improper formatType",2)
  end
  if toRet == nil then return end
  tempParam = toRet
  setPathValue(variable, tempParam)
  tempParam = nil
  if toRet ~= originalValue and displayText ~= "" then
    changedT.new(displayText, tostring(toRet), variable)
  end
  return toRet
end

local paramLookup = {}
local function addParam(...)
  local args = table.pack(...)
  if not paramLookup[args[1]] then
    local toRet = {n = args.n - 1}
    for i=2, args.n do
      toRet[i-1] = args[i]
    end
    paramLookup[args[1]] = toRet
  end
  return parseParam(table.unpack(args, 1, args.n))
end

local function paramAlias(original, alias)
  local a = paramLookup[original]
  if a then
    if a[5] == nil then
      a[5] = original
      if (a.n or 0) < 5 then a.n = 5 end
    end --This is variableOverride because the originals won't put a variable override
    return parseParam(alias, table.unpack(a, 1, a.n or #a))
  else
    error("In paramAlias: '"..original.."' did not exist",2)
  end
end

--Check if it is a turtle
if not(turtle or tArgs["help"] or tArgs["-help"] or tArgs["-?"] or tArgs["?"]) then
  printCompactHelp("This program must run on a turtle")
  error("",0)
end

if tArgs["help"] or tArgs["-help"] or tArgs["-?"] or tArgs["?"] then
  printCompactHelp()
  error("",0)
end

if tArgs["-version"] or tArgs["version"] then
  print("VERSION "..tostring(VERSION))
  error("",0) --Exit not so gracefully
end

--State path and compact resume handling. Generic parameter-file loading was removed.
addParam("state", "State File Path", "string", nil, nil, "stateFilePath")
local noArgsLaunch = (#originalArgs == 0)
local stateOnlyLaunch = (tArgs["-state"] ~= nil and #originalArgs == 2)
local explicitResume = (tArgs["-resume"] or tArgs["-restore"]) ~= nil
local shouldResumeFromState = noArgsLaunch or stateOnlyLaunch or explicitResume
local launchStatePath = stateFilePath
restoreFound = fs.exists(launchStatePath)
restoreFoundSwitch = false
if shouldResumeFromState and restoreFound then
  local temp = shell and copyTable(shell)
  os.run(_ENV, launchStatePath)
  shell = temp
  stateFilePath = launchStatePath
  if stateSnapshotSchema ~= 6 then
    printCompactHelp("state schema mismatch")
    error("",0)
  end
  stateSnapshotLoaded = true
  restoreFoundSwitch = true
  numResumed = numResumed + 1
  events = events or {}
  originalFuel = originalFuel or checkFuel()
  print("State loaded: "..tostring(stateFilePath))
  sleep(1)
elseif explicitResume then
  printCompactHelp("state missing: "..tostring(stateFilePath))
  error("",0)
else
  -- No state means a fresh run. This includes no-argument launch after a completed job.
  events = {} --This is the event queue.
  originalFuel = checkFuel()
end
loadUnmineableRegistry() --State files may overwrite the table; reload persistent registry.

--Home storage side resolution. Restore sessions inherit dropSide from state.
-- Fresh sessions may omit -chest; the script probes adjacent inventory peripherals without moving.
if not restoreFoundSwitch then
  local chestIndex = tArgs["-chest"]
  local rawChest = chestIndex and tArgs[chestIndex + 1]
  local normalizedChest = type(rawChest) == "string" and rawChest:lower() or nil
  if chestIndex then
    if not normalizedChest or not sides[normalizedChest] then
      printCompactHelp("bad -chest "..tostring(rawChest or "nil"))
      error("",0)
    end
    dropSide = sides[normalizedChest]
    storagePhysicalSide = normalizedChest
    storageAutoDetected = false
  else
    local physicalSide, mappedDropSide = discoverAdjacentInventorySide()
    if not mappedDropSide then
      printCompactHelp("no adjacent inventory; use -chest")
      error("",0)
    end
    dropSide = mappedDropSide
    storagePhysicalSide = physicalSide
    storageAutoDetected = true
    changedT.new("Auto Storage", tostring(physicalSide), "dropSide")
  end
end
addParam("chest", "Chest Drop Side", "side", nil, nil, "dropSide")
if not restoreFoundSwitch and storagePhysicalSide == false then storagePhysicalSide = dropSide end

--Dimensions: single comma-separated argument, e.g. -dim 10,6,3
if tArgs["-dim"] and not restoreFoundSwitch then
  local a,b,c = x,y,z
  local num = tArgs["-dim"]
  local rawDim = tArgsWithUpper[num + 1] or tArgs[num + 1] or ""
  local dx, dz, dy = tostring(rawDim):match("^(%d+),(%d+),(%d+)$")
  if not dx then
    printCompactHelp("bad -dim; use L,W,H")
    error("",0)
  end
  x = math.floor(math.abs(tonumber(dx) or x))
  z = math.floor(math.abs(tonumber(dz) or z))
  y = math.floor(math.abs(tonumber(dy) or y))
  if a ~= x then changedT.new("Length", x) end
  if c ~= z then changedT.new("Width", z) end
  if b ~= y then changedT.new("Height", y) end
end
--Params: parameter/variable name, display name, type, ignored legacy field, boolean condition, variable name override
--Invert and core motion flags
addParam("flatBedrock","Go to bedrock", "boolean")
addParam("invert", "Inverted","boolean", nil, not flatBedrock, "inverted")
addParam("startDown","Start Down","number 1-256", nil, not flatBedrock)
addParam("left","Left Quarry","boolean", nil, nil, "goLeftNotRight")
--Inventory
-- -chest parsed earlier after mandatory validation.
-- Experimental telemetry/location flags remain default-off and undocumented.
addParam("rednet", "Rednet Enabled","boolean", nil, supportsRednet, "rednetEnabled")
addParam("sendChannel", "Rednet Send Channel", "number 1-65535", nil, supportsRednet, "channels.send")
addParam("receiveChannel","Rednet Receive Channel", "number 1-65535", nil, supportsRednet, "channels.receive")
channels.fingerprint = (os.getComputerLabel and os.getComputerLabel()) or tostring(os.getComputerID())
-- External position sampling is intentionally not parsed or sampled; localized state is authoritative.
--Fuel: predictive checking and on-board coal refuel are mandatory.
doCheckFuel = true
doRefuel = true
excessFuelAmount = excessFuelAmount or math.huge
addParam("maxFuel", "Max Fuel", "number 1-999999999", nil, checkFuel() ~= math.huge, "excessFuelAmount")
addParam("uniqueSlots", "Unique Cargo Slots", "number 0-15", nil, nil, "uniqueExtras")
--Logging: -log FILE only; absent means no file logging.
do
  local rawLog = tArgs["-log"] and (tArgsWithUpper[tArgs["-log"] + 1] or tArgs[tArgs["-log"] + 1])
  logFile = rawLog and tostring(rawLog):match("^[%w%./_%-]+") or false
end
--Hidden compatibility/safety constants.
addParam("startY", "Start Y","number 1-256")
addParam("maxTries","Tries Before Bedrock", "number 1-9001")
addParam("keepOpen", "Slots to Keep Open", "number 1-15")
addParam("careAboutResources", "Care About Resources","boolean")
addParam("preciseTotals","Precise Totals","boolean", nil, rednetEnabled and turtle.inspect, turtle.getItemDetail ~= nil)
if preciseTotals and not restoreFoundSwitch then
  exactTotals = {}
end
-- Legacy startup-stub and compare-based ore mode are disabled.
extraDropItems = false
--Ore Quarry
addParam("oreQuarry", "Ore Quarry", "boolean" )
if oreQuarry and not turtle.inspect then
  printCompactHelp("oreQuarry needs inspect API")
  error("",0)
end
-- Undocumented blacklist filename override.
addParam("blacklist","", "string", nil, oreQuarry, "oreQuarryBlacklistName")
--Mod Related

--Extra

--for flatBedrock
if flatBedrock then
  inverted = false
end

-- Configuration summary is displayed after function definitions and before any physical motion.

--Startup stub generation removed. Boot this script directly; no-arg launch resumes state.
--oreQuarry blacklist
local blacklist = { "minecraft:air",  "minecraft:bedrock", "minecraft:cobblestone", "minecraft:dirt", "minecraft:ice", "minecraft:ladder", "minecraft:netherrack", "minecraft:sand", "minecraft:sandstone",
  "minecraft:snow", "minecraft:snow_layer", "minecraft:stone", "minecraft:gravel", "minecraft:grass", "minecraft:torch", "minecraft:diorite", "minecraft:andesite", "minecraft:granite", "byg:soapstone", "minecraft:cobbled_deepslate" }
for a,b in pairs(copyTable(blacklist)) do
  blacklist[b], blacklist[a] = true, nil --Switch
end
if fs.exists(oreQuarryBlacklistName) then --Loading user-defined blacklist
  local file = fs.open(oreQuarryBlacklistName, "r")
  blacklist = {}
  for a in file:readAll():gmatch("[^,\n]+") do
    blacklist[a:match("[%w_.]+:[%w_.]+")] = true --Grab only the actual characters, not whitespaces
  end
  file:close()
end
for blockName in pairs(unmineableBlocks or {}) do
  blacklist[blockName] = true
end

--Manual-position and at-chest legacy recovery modes removed; -state is authoritative.


local function serializeStateValue(value)
  if type(value) == "string" then return string.format("%q", value) end
  if type(value) == "number" or type(value) == "boolean" then return tostring(value) end
  if type(value) == "table" then return textutils.serialize(value) end
  if value == nil then return "nil" end
  return "nil"
end

local function appendPathStep(parts, op, count)
  count = tonumber(count) or 0
  if count ~= 0 then parts[#parts+1] = op..tostring(count) end
end

local function compactPathBetween(fromX, fromZ, fromY, fromFacing, toX, toZ, toY, toFacing)
  fromX, fromZ, fromY, fromFacing = tonumber(fromX) or 0, tonumber(fromZ) or 1, tonumber(fromY) or 1, tonumber(fromFacing) or 0
  toX, toZ, toY, toFacing = tonumber(toX) or fromX, tonumber(toZ) or fromZ, tonumber(toY) or fromY, tonumber(toFacing) or fromFacing
  local parts = {}
  appendPathStep(parts, "Y", toY - fromY)
  appendPathStep(parts, "Z", toZ - fromZ)
  appendPathStep(parts, "X", toX - fromX)
  if toFacing ~= fromFacing then parts[#parts+1] = "F"..tostring(coterminal and coterminal(toFacing) or toFacing) end
  if #parts == 0 then return "@" end
  return table.concat(parts, ";")
end

local function refreshPersistedPaths()
  stateStorageTarget = {x = homeBaseX or 0, z = homeBaseZ or 1, y = homeBaseY or 1, f = 2, label = "storage"}
  statePathToStorage = compactPathBetween(xPos, zPos, yPos, facing, stateStorageTarget.x, stateStorageTarget.z, stateStorageTarget.y, stateStorageTarget.f)
  if not stateNextTarget then
    stateNextTarget = {x = xPos, z = zPos, y = yPos, f = facing, label = stateRouteMode or "current"}
  end
  statePathToNext = compactPathBetween(xPos, zPos, yPos, facing, stateNextTarget.x, stateNextTarget.z, stateNextTarget.y, stateNextTarget.f or facing)
end

function setPersistenceTarget(mode, tx, tz, ty, tf, label)
  stateRouteMode = mode or stateRouteMode or "mining"
  stateNextTarget = {x = tx or xPos, z = tz or zPos, y = ty or yPos, f = tf or facing, label = label or mode or "target"}
  refreshPersistedPaths()
  return stateNextTarget
end

function setWorkReturnTarget(tx, tz, ty, tf)
  storageReturnX, storageReturnZ, storageReturnY, storageReturnFacing = tx, tz, ty, tf
  setPersistenceTarget("to_work", tx, tz, ty, tf, "resume work coordinate")
end

function isPersistentRouteMode(mode)
  return mode and mode ~= "" and mode ~= "mining" and mode ~= "motion" and mode ~= "vertical" and mode ~= "rotation"
end

local compactStateKeys = {
  "x", "y", "z", "inverted", "rednetEnabled", "dropSide", "storagePhysicalSide", "storageAutoDetected", "careAboutResources", "doCheckFuel", "doRefuel", "keepOpen",
  "fuelSafety", "excessFuelAmount", "fuelMultiplier", "stateFilePath", "uniqueExtras", "maxTries",
  "logFile", "flatBedrock", "startDown", "preciseTotals", "goLeftNotRight", "oreQuarry", "oreQuarryBlacklistName",
  "dumpCompareItems", "returnFuelSafetyBuffer", "maxHomeReturnCost", "returnFuelReserveFloor", "fuelSafetyReturnActive", "refuelReturnActive", "suspendedOperationalState", "storageBlockedPause",
  "driveSystemsDisabled", "suspendedReason", "unmineableRegistryName", "stateRouteMode", "statePathToNext", "statePathToStorage",
  "driveJournalSeq", "stateSnapshotSchema",
  "homeBaseX", "homeBaseZ", "homeBaseY", "quarryAccessX", "quarryAccessZ", "xPos", "yPos", "zPos", "facing", "percent",
  "mined", "moved", "relxPos", "rowCheck", "connected", "isInPath", "layersDone", "attacked", "startY", "chestFull",
  "gotoDest", "fuelLevel", "numDropOffs", "selectedSlot", "extraDropItems", "relzPos", "eventInsertionPoint",
  "foundBedrock", "toQuit", "isMiningTurtle", "originalFuel", "neededFuel", "layers", "coalFuelTotal", "coalFuelPotential",
  "storageReturnX", "storageReturnZ", "storageReturnY", "storageReturnFacing", "dropCountCommitted"
}

local compactStateTables = {
  "allowedItems", "dumpSlots", "totals", "events", "exactTotals",
  "initialTypes", "initialCount", "coalFuelSlots", "unmineableBlocks", "stateNextTarget", "stateStorageTarget", "driveJournal"
}

local function writeCompactStateFile(path, extras)
  if not path or path == "" then return false end
  refreshPersistedPaths()
  if checkFuel and checkFuel() ~= math.huge then fuelLevel = checkFuel() end
  local lines = {
    "--Compact Civil Quarry state snapshot; overwritten in place.",
    "--Generated by quarry persistence layer.",
    "stateSnapshotSchema = 5",
    "stateSnapshotWrittenAt = "..serializeStateValue(os.clock and os.clock() or 0)
  }
  local env = _ENV
  for _, key in ipairs(compactStateKeys) do
    if env[key] ~= nil then lines[#lines+1] = key.." = "..serializeStateValue(env[key]) end
  end
  for _, key in ipairs(compactStateTables) do
    if env[key] ~= nil then lines[#lines+1] = key.." = "..serializeStateValue(env[key]) end
  end
  if type(extras) == "table" then
    for key, value in pairs(extras) do lines[#lines+1] = tostring(key).." = "..serializeStateValue(value) end
  end
  lines[#lines+1] = "doCheckFuel = true"
  lines[#lines+1] = "doRefuel = true"
  local file = fs.open(path, "w")
  if not file then return false end
  file.write(table.concat(lines, "\n").."\n")
  file.close()
  return true
end

function saveProgress(extras) --Compact mandatory session persistence
    writeCompactStateFile(stateFilePath, extras)
end

local area = x*z
local volume = x*y*z
local lastHeight = y%3
layers = math.ceil(y/3)
local yMult = layers --This is basically a smart y/3 for movement
local moveVolume = (area * yMult) --Kept for display percent
--Calculating Needed Fuel--
do --Because many local variables unneeded elsewhere
  local changeYFuel = 2*(y + startDown)
  local dropOffSupplies = 2*(x + z + y + startDown) --Assumes turtle as far away as possible, and coming back
  local frequency = math.ceil(((moveVolume/(64*(15-uniqueExtras) + uniqueExtras)) ) ) --This is complicated: volume / inventory space of turtle, defined as 64*full stacks + 1 * unique stacks.
                                                                                     --max of 15 full stacks because once one item is picked up, slot is "full". Ceil to count for initial back and forth
  neededFuel = moveVolume + changeYFuel + (frequency * dropOffSupplies) + ((x + z) * layers) --x + z *layers because turtle has to come back from far corner every layer
  neededFuel = neededFuel + fuelTable[fuelSafety] --For safety
end

function calculateMaxHomeReturnCostForJob()
  local maxX = math.max(math.abs(1 - quarryAccessX), math.abs(x - quarryAccessX))
  local maxZ = math.max(math.abs(1 - quarryAccessZ), math.abs(z - quarryAccessZ))
  local maxY = math.max(math.abs(homeBaseY - homeBaseY), math.abs((y + startDown) - homeBaseY))
  local accessCost = math.abs(quarryAccessX - homeBaseX) + math.abs(quarryAccessZ - homeBaseZ)
  return maxX + maxZ + maxY + accessCost
end

maxHomeReturnCost = calculateMaxHomeReturnCostForJob()
if checkFuelLimit and checkFuelLimit() ~= math.huge then
  returnFuelReserveFloor = math.min(checkFuelLimit(), 2 * maxHomeReturnCost)
else
  returnFuelReserveFloor = 2 * maxHomeReturnCost
end

if neededFuel < returnFuelReserveFloor then
  neededFuel = returnFuelReserveFloor
end

if neededFuel > checkFuelLimit() and doCheckFuel then--Checks for if refueling goes over turtle fuel limit
  if not doRefuel then
    screen()
    print("Fuel requirement exceeds tank capacity.")
    print("Rerun with -doRefuel true or reduce quarry size.")
    error("",0)
  end
  neededFuel = checkFuelLimit()-checkFuel()-1
end


--Getting Fuel
local hasRefueled --Startup coal-refuel marker
local function startupCoalSlot(slot)
  if turtle.getItemCount(slot) <= 0 then return false end
  if turtle.getItemDetail then
    local detail = turtle.getItemDetail(slot)
    local name = detail and detail.name and detail.name:lower() or ""
    if not (name == "minecraft:coal" or name == "minecraft:charcoal" or name:match("coal") or name:match("charcoal")) then
      return false
    end
  end
  select(slot)
  local ok = turtle.refuel(0)
  select(1)
  return ok
end

local function consumeStartupCoalFuel()
  local used = false
  for i=1, inventoryMax do
    if checkFuel() >= neededFuel or checkFuel() >= checkFuelLimit() then break end
    if startupCoalSlot(i) then
      select(i)
      local before = checkFuel()
      turtle.refuel(turtle.getItemCount(i))
      if checkFuel() > before then used = true end
    end
  end
  select(1)
  return used
end

local function startupTurnToStorage()
  local originalFacing = facing or 0
  local target = originalFacing
  if storagePhysicalSide == "front" then target = 0
  elseif storagePhysicalSide == "right" then target = 1
  elseif storagePhysicalSide == "back" then target = 2
  elseif storagePhysicalSide == "left" then target = 3 end
  while facing ~= target do
    turtle.turnRight()
    facing = (facing + 1) % 4
  end
  return originalFacing
end

local function startupTurnToFacing(target)
  target = target or 0
  while facing ~= target do
    turtle.turnRight()
    facing = (facing + 1) % 4
  end
end

local function consumeStartupChestFuel()
  if checkFuel() >= neededFuel or checkFuel() >= checkFuelLimit() then return true end
  local originalFacing = startupTurnToStorage()
  local suckFunc, dropFunc = turtle.suck, turtle.drop
  if storagePhysicalSide == "top" then suckFunc, dropFunc = turtle.suckUp, turtle.dropUp
  elseif storagePhysicalSide == "bottom" then suckFunc, dropFunc = turtle.suckDown, turtle.dropDown end
  local attempts, noProgress = 0, 0
  while checkFuel() < neededFuel and checkFuel() < checkFuelLimit() and attempts < inventoryMax * 2 and noProgress < 4 do
    attempts = attempts + 1
    local before = checkFuel()
    if not suckFunc(64) then break end
    consumeStartupCoalFuel()
    for i=1, inventoryMax do
      if turtle.getItemCount(i) > 0 and not startupCoalSlot(i) then
        select(i)
        if not dropFunc() then
          startupTurnToFacing(originalFacing)
          return false
        end
      end
    end
    select(1)
    if checkFuel() <= before then noProgress = noProgress + 1 else noProgress = 0 end
  end
  startupTurnToFacing(originalFacing)
  select(1)
  return checkFuel() >= neededFuel
end

if doCheckFuel and checkFuel() < neededFuel then
  hasRefueled = true
  print("Not enough fuel")
  print("Current: ",checkFuel()," Needed: ",neededFuel)
  print("Scanning on-board coal fuel")
  consumeStartupCoalFuel()
  if checkFuel() < neededFuel then
    print("Checking home chest fuel")
    consumeStartupChestFuel()
  end
  if checkFuel() < neededFuel then
    print("Insufficient coal/charcoal fuel.")
    print("Add fuel to turtle or home chest.")
    error("",0)
  end
end
--Setting which slots are marked as dump slots. Old compare-based ore mode is disabled.
if not oreQuarry then
  dumpCompareItems = false
  resetDumpSlots()
end

--Rednet Handshake
function newMessageID()
  return math.random(1,2000000000)
end
function sendMessage(send, receive, message)
  return modem.transmit(send , receive, {fingerprint = channels.fingerprint, id = newMessageID(), message = message})
end
if rednetEnabled then
  screen(1,1)
  print("Rednet is Enabled")
  print("The Channel to open is "..channels.send)
  if peripheral.find then
    modem = peripheral.find("modem")
  else
    modem = peripheral.wrap("right")
  end
  modem.open(channels.receive)
  local i = 0
    repeat
      local id = os.startTimer(3)
      i=i+1
      print("Sending Initial Message "..i)
      sendMessage(channels.send, channels.receive, channels.message)
      local message = {} --Have to initialize as table to prevent index nil
      repeat
        local event, idCheck, channel,_,locMessage, distance = os.pullEvent()
        if locMessage then message = locMessage end
      until (event == "timer" and idCheck == id) or (event == "modem_message" and channel == channels.receive and type(message) == "table")
    until message.message == channels.confirm
  connected = true
  print("Connection Confirmed!")
  sleep(1.5)
end
function biometrics(isAtBedrock)
  if not rednetEnabled then return end --This function won't work if rednet not enabled :P
  local toSend = { label = os.getComputerLabel() or "No Label", id = os.getComputerID(),
    percent = percent, zPos = relzPos, xPos = relxPos, yPos = yPos,
    layersDone = layersDone, x = x, z = z, layers = layers,
    openSlots = getNumOpenSlots(), mined = mined, moved = moved,
    chestFull = chestFull, isAtChest = (xPos == 0 and yPos == 1 and zPos == 1),
    isGoingToNextLayer = (gotoDest == "layerStart"), foundBedrock = foundBedrock,
    fuel = checkFuel(), volume = volume, status = statusString,
    }
  sendMessage(channels.send, channels.receive, toSend)
  id = os.startTimer(0.1)
  local event, received
  repeat
    local locEvent, idCheck, confirm, _, locMessage, distance = os.pullEvent()
    event, received = locEvent, locMessage or {message = ""}
  until (event == "timer" and idCheck == id) or (event == "modem_message" and confirm == channels.receive and type(received) == "table")
  if event == "modem_message" then connected = true else connected = false end
  local message = received.message:lower()
  if message == "stop" or message == "quit" or message == "kill" then
    count(true)
    display()
    error("Rednet said to stop...",0)
  end
  if message == "return" then
    endingProcedure()
    error('Rednet said go back to start...',0)
  end
  if message == "drop" then
    dropOff()
  end
  if message == "pause" then
    print("\nTurtle is paused. Send resume/unpause over rednet to resume")
    statusString = "Paused"
    toSend.status = statusString
    os.startTimer(3)
    repeat --The turtle sends out periodic messages, which will clear the receiver's queue and send a message (if it exists)
     --This may be a bit overkill, sending the whole message again, but whatever.
      local event, idCheck, confirm, _, message, distance = os.pullEvent()
      if event == "timer" then os.startTimer(3); sendMessage(channels.send, channels.receive, toSend) end --Only send messages on the timer. This prevents ridiculous spam
    until (event == "modem_message" and confirm == channels.receive and (message.message == "resume" or message.message == "unpause" or message.message == "pause"))
    statusString = nil
  end
  if message == "refuel" then
    print("\nEngaging in emergency refueling")
    emergencyRefuel(true)
  end

end
-- Configuration summary was displayed immediately after argument resolution.

----------------------------------------------------------------
--Define ALL THE FUNCTIONS
--Event System Functions
function eventSetInsertionPoint(num)
  eventInsertionPoint = num or 1
end
function eventAddAt(pos, ...)
  return table.insert(events,pos, {...}) or true
end
function eventAdd(...) --Just a wrapper
  return eventAddAt(eventInsertionPoint, ...)
end
function eventGet(pos)
  return events[tonumber(pos) or #events]
end
function eventPop(pos)
  return table.remove(events,tonumber(pos) or #events) or false --This will return value popped, tonumber returns nil if fail, so default to end
end
function eventRun(value, ...)
  local argsList = {...}
  if type(value) == "string" then
    if value:sub(-1) ~= ")" then --So supports both "up()" and "up"
      value = value .. "("
      for a, b in pairs(argsList) do --Appending arguments
        local toAppend
        if type(b) == "table" then toAppend = textutils.serialize(b)
        elseif type(b) == "string" then toAppend = "\""..tostring(b).."\"" --They weren't getting strings around them
        else toAppend = tostring(b) end
        value = value .. (toAppend or "true") .. ", "
      end
      if value:sub(-1) ~= "(" then --If no args, do not want to cut off
        value = value:sub(1,-3)..""
      end
      value = value .. ")"
    end
    --print(value) --Debug
    local func = load(value, "=(quarry-event)", "t", _ENV)
    if not func then error("Failed to compile event: "..tostring(value),2) end
    return func()
  end
end
function eventClear(pos)
  if pos then events[pos] = nil else events = {} end
end
function runAllEvents()
  while #events > 0 do
    local toRun = eventGet()
    --print(toRun[1]) --Debug
    eventRun(table.unpack(toRun))
    eventPop()
  end
end

--Display Related Functions
function display() --This is just the last screen that displays at the end
  screen(1,1)
  print("Total Blocks Mined: "..mined)
  print("Current Fuel Level: "..checkFuel())
  print("Cobble: "..totals.cobble)
  print("Usable Fuel: "..totals.fuel)
  print("Other: "..totals.other)
  if rednetEnabled then
    print("")
    print("Sent Stop Message")
    local finalTable = {mined = mined, cobble = totals.cobble, fuelblocks = totals.fuel,
        other = totals.other, fuel = checkFuel(), isDone = true }
    if preciseTotals then
      finalTable.preciseTotals = exactTotals --This table doubles as a flag.
    end
    sendMessage(channels.send,channels.receive, finalTable)
    modem.close(channels.receive)
  end
  fs.delete(stateFilePath)
end
function updateDisplay() --Runs in Mine(), display information to the screen in a certain place
screen(1,1)
print("Blocks Mined")
print(mined)
print("Percent Complete")
print(percent.."%")
print("Fuel")
print(checkFuel())
  -- screen(1,1)
  -- print("Xpos: ")
  -- print(xPos)
  -- print("RelXPos: ")
  -- print(relxPos)
  -- print("Z Pos: ")
  -- print(zPos)
  -- print("Y pos: ")
  -- print(yPos)
if rednetEnabled then
screenLine(1,7)
print("Connected: "..tostring(connected))
end
end
--Utility functions
function logMiningRun() --Optional final-run logging via -log FILE.
  if not logFile then return end
  local handle = fs.open(logFile,"w")
  if not handle then return false end
  local function write(...)
    for a, b in ipairs({...}) do handle.write(tostring(b)) end
    handle.write("\n")
  end
  local function boolToText(bool) if bool then return "Yes" else return "No" end end
  write("Quarry Log")
  write("Version: ",VERSION)
  write("Dimensions L,Z,Y: ",x,",",z,",", y)
  write("Blocks mined: ", mined)
  write("Cobble: ", totals.cobble)
  write("Usable fuel: ", totals.fuel)
  write("Other: ",totals.other)
  write("Fuel used: ",  (originalFuel or (neededFuel + checkFuel()))- checkFuel())
  write("Expected fuel: ", neededFuel)
  write("Days: ",os.day()-originalDay)
  write("Resumes: ", numResumed)
  write("Ore quarry: ",boolToText(oreQuarry))
  write("Inverted: ",boolToText(inverted))
  write("Rednet: ",boolToText(rednetEnabled))
  write("Chest side: ",dropSide)
  if startDown > 0 then write("StartDown: ",startDown) end
  if exactTotals then
    write("Detailed totals")
    for a,b in pairs(exactTotals) do write(a,":",b) end
  end
  handle.close()
  return true
end
--Inventory related functions
function isFull(slots) --Checks if there are more than "slots" used inventory slots.
  slots = slots or inventoryMax
  local numUsed = 0
  sleep(0)
  for i=1, inventoryMax do
    if turtle.getItemCount(i) > 0 then numUsed = numUsed + 1 end
  end
  if numUsed > slots then
    return true
  end
  return false
end
function countUsedSlots() --Returns number of slots with items in them, as well as a table of item counts
  local toRet, toRetTab = 0, {}
  for i=1, inventoryMax do
    local a = turtle.getItemCount(i)
    if a > 0 then toRet = toRet + 1 end
    table.insert(toRetTab, a)
  end
  return toRet, toRetTab
end
function getSlotsTable() --Just get the table from above
  local _, toRet = countUsedSlots()
  return toRet
end
function getChangedSlots(tab1, tab2) --Returns a table of changed slots. Format is {slotNumber, numberChanged}
  local toRet = {}
  for i=1, math.min(#tab1, #tab2) do
    diff = math.abs(tab2[i]-tab1[i])
    if diff > 0 then
      table.insert(toRet, {i, diff})
    end
  end
  return toRet
end
function getRep(which, list) --Gets a representative slot of a type. Expectation is a sequential table of types
  for a,b in pairs(list) do
    if b == which then return a end
  end
  return false
end
function assignTypes(types, count)
  types, count = types or {1}, count or 1 --Table of types and current highest type
  for i=1, inventoryMax do
    if turtle.getItemCount(i) > 0 then
      select(i)
      for k=1, count do
        if turtle.compareTo(getRep(k, types)) then types[i] = k end
      end
      if not types[i] then
        count = count + 1
        types[i] = count
      end
      if oreQuarry then
        if blacklist[turtle.getItemDetail().name] then
          dumpSlots[i] = true
        else
          dumpSlots[i] = false
        end
      end
    end
  end
  select(1)
  return types, count
end
function getTableOfType(which, list) --Returns a table of all the slots of which type
  local toRet = {}
  for a, b in pairs(list) do
    if b == which then
      table.insert(toRet, a)
    end
  end
  return toRet
end

--Initial type representative table for item categorization.
if not restoreFoundSwitch then
  initialTypes, initialCount = {1}, 1
end

function count(add) --Done any time inventory dropped and at end, true=add, false=nothing, nil=subtract
  local mod = -1
  if add then mod = 1 end
  if add == false then mod = 0 end
  slot = {}        --1: Filler 2: Fuel 3:Other --[1] is type, [2] is number
  for i=1, inventoryMax do
    slot[i] = {}
    slot[i][2] = turtle.getItemCount(i)
  end

  local function iterate(toSet , rawTypes, set)
    for _, a in pairs(getTableOfType(toSet, rawTypes)) do --Get all slots matching type
      slot[a][1] = set --Set official type to "set"
    end
  end

  --This assigns "dumb" types to all slots based on comparing, then based on knowledge of dump type slots, changes all slots matching a dump type to one. Otherwise, if the slot contains fuel, it is 2, else 3
  local rawTypes, numTypes = assignTypes(copyTable(initialTypes), initialCount) --This gets increasingly numbered types, copyTable because assignTypes will modify it

  for i=1, numTypes do
    if (select(getRep(i, rawTypes)) or true) and turtle.refuel(0) then --Selects the rep slot, checks if it is fuel
      iterate(i, rawTypes, 2) --This type is fuel
    elseif dumpSlots[getRep(i,(oreQuarry and rawTypes) or initialTypes)] then --If the rep of this slot is a dump item. This is initial types so that the rep is in dump slots. rawTypes if oreQuarry to get newly assigned dumps
      iterate(i, rawTypes, 1) --This type is cobble/filler
    else
      iterate(i, rawTypes, 3) --This type is other
    end
  end

  for i=1,inventoryMax do
    if exactTotals and slot[i][2] > 0 then
      local data = turtle.getItemDetail(i)
      exactTotals[data.name] = (exactTotals[data.name] or 0) + (data.count * mod)
    end
    if slot[i][1] == 1 then totals.cobble = totals.cobble + (slot[i][2] * mod)
    elseif slot[i][1] == 2 then totals.fuel = totals.fuel + (slot[i][2] * mod)
    elseif slot[i][1] == 3 then totals.other = totals.other + (slot[i][2] * mod) end
  end

  select(1)
end

--Coal inventory audit, path-cost and refuel helpers
coalFuelSlots = {}
coalFuelTotal = 0
coalFuelPotential = 0
homeReturnCost = 0
homeFuelAvailable = 0
local coalFuelValue = 80
homeBaseX, homeBaseZ, homeBaseY = homeBaseX or 0, homeBaseZ or 1, homeBaseY or 1
quarryAccessX, quarryAccessZ = quarryAccessX or 1, quarryAccessZ or 1
local coalNames = {
  ["minecraft:coal"] = true,
  ["minecraft:charcoal"] = true,
}

local function isCoalItemDetail(data)
  if type(data) ~= "table" or type(data.name) ~= "string" then return false end
  local name = data.name:lower()
  if coalNames[name] then return true end
  return name:match("coal") ~= nil or name:match("charcoal") ~= nil
end

function isCoalSlot(slot)
  if not slot or slot < 1 or slot > inventoryMax then return false end
  if turtle.getItemCount(slot) <= 0 then return false end
  if not turtle.getItemDetail then return false end
  if not isCoalItemDetail(turtle.getItemDetail(slot)) then return false end
  local previousSlot = selectedSlot or 1
  select(slot)
  local validFuel = turtle.refuel(0)
  select(previousSlot)
  return validFuel
end

function auditCoalInventory()
  coalFuelSlots = {}
  coalFuelTotal = 0
  coalFuelPotential = 0
  for i=1, inventoryMax do
    local count = turtle.getItemCount(i)
    if count > 0 and isCoalSlot(i) then
      coalFuelTotal = coalFuelTotal + count
      coalFuelPotential = coalFuelPotential + (count * coalFuelValue)
      table.insert(coalFuelSlots, {slot = i, count = count})
    end
  end
  return coalFuelTotal, coalFuelSlots, coalFuelPotential
end

function calculateHomeReturnCost()
  if xPos == homeBaseX and zPos == homeBaseZ and yPos == homeBaseY then
    return 0
  end
  if xPos == homeBaseX and zPos == homeBaseZ then
    return math.abs(yPos - homeBaseY)
  end
  return math.abs(xPos - quarryAccessX)
       + math.abs(zPos - quarryAccessZ)
       + math.abs(yPos - homeBaseY)
       + math.abs(quarryAccessX - homeBaseX)
       + math.abs(quarryAccessZ - homeBaseZ)
end

function getAvailableHomeFuel()
  local currentFuel = checkFuel()
  if currentFuel == math.huge then
    homeFuelAvailable = math.huge
  else
    homeFuelAvailable = currentFuel
  end
  return homeFuelAvailable
end

function consumeCoalFuel(minimumTarget, doAudit)
  if doAudit ~= false then auditCoalInventory() end
  local consumed = false
  minimumTarget = minimumTarget or checkFuelLimit()
  for _, entry in ipairs(coalFuelSlots or {}) do
    if checkFuel() >= checkFuelLimit() or checkFuel() >= minimumTarget then break end
    local slot = entry.slot
    if isCoalSlot(slot) then
      select(slot)
      local before = checkFuel()
      midRunRefuel(slot, 0)
      if checkFuel() > before then consumed = true end
    end
  end
  select(1)
  return consumed
end

local function storageDirectionalFunctions(side)
  side = sides[side] or "front"
  local properFacing = facing
  local suckFunc, dropFunc = turtle.suck, turtle.drop
  if side == "top" then
    suckFunc, dropFunc = turtle.suckUp, turtle.dropUp
  elseif side == "bottom" then
    suckFunc, dropFunc = turtle.suckDown, turtle.dropDown
  elseif side == "right" then
    turnTo(1)
  elseif side == "left" then
    turnTo(3)
  end
  return suckFunc, dropFunc, properFacing
end

local function dropNonCoalToHomeStorage(dropFunc)
  for i=1, inventoryMax do
    if turtle.getItemCount(i) > 0 and not isCoalSlot(i) then
      select(i)
      if not dropFunc() then
        select(1)
        return false
      end
    end
  end
  select(1)
  return true
end

function consumeHomeStorageFuel(minimumTarget)
  if checkFuel() == math.huge then return true end
  minimumTarget = math.min(minimumTarget or checkFuelLimit(), checkFuelLimit())
  if checkFuel() >= minimumTarget then return true end
  auditCoalInventory()
  consumeCoalFuel(minimumTarget, false)
  if checkFuel() >= minimumTarget then return true end
  local suckFunc, dropFunc, properFacing = storageDirectionalFunctions(dropSide)
  local attempts = 0
  local noProgress = 0
  while checkFuel() < minimumTarget and attempts < inventoryMax * 2 and noProgress < 4 do
    attempts = attempts + 1
    local beforeFuel = checkFuel()
    local sucked = suckFunc(64)
    if not sucked then break end
    auditCoalInventory()
    consumeCoalFuel(minimumTarget, false)
    if not dropNonCoalToHomeStorage(dropFunc) then
      turnTo(properFacing)
      enterHardPause("Cannot return non-fuel items while drawing chest fuel", "storage")
    end
    if checkFuel() <= beforeFuel then noProgress = noProgress + 1 else noProgress = 0 end
  end
  turnTo(properFacing)
  select(1)
  return checkFuel() >= minimumTarget
end

function calculateHomeToTargetCost(target)
  if type(target) ~= "table" then return 0 end
  local tx = tonumber(target.x) or homeBaseX
  local tz = tonumber(target.z) or homeBaseZ
  local ty = tonumber(target.y) or homeBaseY
  if tx == homeBaseX and tz == homeBaseZ and ty == homeBaseY then return 0 end
  return math.abs(quarryAccessX - homeBaseX)
       + math.abs(quarryAccessZ - homeBaseZ)
       + math.abs(ty - homeBaseY)
       + math.abs(tx - quarryAccessX)
       + math.abs(tz - quarryAccessZ)
end

function calculateHomeRefuelTarget()
  local target = stateNextTarget or (storageReturnX and {x = storageReturnX, z = storageReturnZ, y = storageReturnY, f = storageReturnFacing}) or nil
  local workCost = calculateHomeToTargetCost(target)
  local desired = math.max(returnFuelReserveFloor or 0, workCost + (returnFuelReserveFloor or 0), 2 * workCost)
  if checkFuelLimit and checkFuelLimit() ~= math.huge then desired = math.min(desired, checkFuelLimit()) end
  return desired
end

function queueReturnHome(destination)
  eventClear()
  destination = destination or "home"
  stateRouteMode = "to_storage"
  setPersistenceTarget("to_storage", homeBaseX, homeBaseZ, homeBaseY, 2, destination)
  saveProgress()
  if xPos == homeBaseX and zPos == homeBaseZ then
    eventAdd("goTo", homeBaseX, homeBaseZ, homeBaseY, 2, destination)
  else
    eventAdd("goTo", quarryAccessX, quarryAccessZ, yPos, 2, destination)
    eventAdd("goTo", homeBaseX, homeBaseZ, homeBaseY, 2, destination)
  end
end

function enterHardPause(reason, pauseKind)
  suspendedOperationalState = true
  suspendedReason = trimToTerm(reason or "manual action required")
  driveSystemsDisabled = true
  if pauseKind == "storage" then
    storageBlockedPause = true
    chestFull = true
  end
  if pauseKind == "fuel" then
    fuelSafetyPause = true
  end
  statusString = suspendedReason
  saveProgress()
  biometrics()
  screen(1,1)
  print("PAUSE: manual action needed")
  print(suspendedReason)
  print("Motors disabled")
  if pauseKind == "storage" then
    print("Storage full/missing")
    print("Clear chest; resume state")
  elseif pauseKind == "fuel" then
    print("Fuel reserve short")
    print("Add coal; resume state")
  else
    print("Fix issue; resume state")
  end
  error("",0)
end

function storageSaturationPause(reason, slot)
  reason = reason or "storage blocked"
  if slot then reason = reason.." slot "..tostring(slot) end
  enterHardPause(reason, "storage")
  return false
end

function returnHomeForFuelRebalance(reason)
  reason = reason or "Fuel reserve fell below computed maximum return floor"
  if fuelSafetyReturnActive or refuelReturnActive then return false end
  if xPos == homeBaseX and zPos == homeBaseZ and yPos == homeBaseY then
    local target = calculateHomeRefuelTarget()
    if consumeHomeStorageFuel(target) then return false end
    enterHardPause("Insufficient fuel in turtle and home chest", "fuel")
  end
  if not (storageReturnX and storageReturnY and storageReturnZ) then
    setWorkReturnTarget(xPos, zPos, yPos, facing)
  end
  refuelReturnActive = true
  fuelSafetyReturnActive = true
  statusString = reason
  eventClear()
  saveProgress()
  queueReturnHome("fuel reserve refuel")
  eventAdd("drop", dropSide, false)
  runAllEvents()
  local targetFuel = calculateHomeRefuelTarget()
  if not consumeHomeStorageFuel(targetFuel) then
    enterHardPause("Home refuel failed before work return", "fuel")
  end
  if storageReturnX and storageReturnY and storageReturnZ then
    stateRouteMode = "to_work"
    setPersistenceTarget("to_work", storageReturnX, storageReturnZ, storageReturnY, storageReturnFacing or 0, "work return")
    saveProgress()
    goTo(quarryAccessX, quarryAccessZ, storageReturnY, 0, "work return")
    goTo(storageReturnX, storageReturnZ, storageReturnY, storageReturnFacing or 0, "work return")
    storageReturnX, storageReturnZ, storageReturnY, storageReturnFacing = nil, nil, nil, nil
  end
  stateRouteMode = "mining"
  refuelReturnActive = false
  fuelSafetyReturnActive = false
  statusString = nil
  saveProgress()
  return true
end

function safePauseAtHome(reason, returnCost, availableFuel)
  reason = reason or "Manual intervention required at home"
  if not (storageReturnX and storageReturnY and storageReturnZ) then
    setWorkReturnTarget(xPos, zPos, yPos, facing)
  end
  fuelSafetyReturnActive = true
  statusString = reason
  eventClear()
  saveProgress()
  queueReturnHome("manual pause")
  eventAdd("drop", dropSide, false)
  eventAdd("turnTo", 0)
  runAllEvents()
  enterHardPause(reason, "state")
end

function checkHomeFuelSafety()
  if fuelSafetyReturnActive or refuelReturnActive or checkFuel() == math.huge then return false end
  homeReturnCost = calculateHomeReturnCost()
  homeFuelAvailable = getAvailableHomeFuel()
  if homeReturnCost > 0 and returnFuelReserveFloor > 0 and homeFuelAvailable <= returnFuelReserveFloor then
    returnHomeForFuelRebalance("Fuel below 2x maximum return-cost floor")
    return true
  end
  return false, homeReturnCost, homeFuelAvailable
end

function preMotionFuelAudit()
  -- Name retained for call-site stability; this no longer scans inventory.
  if not fuelSafetyReturnActive and not refuelReturnActive and checkFuel() ~= math.huge then
    checkHomeFuelSafety()
  end
end

local function poseTable(px, pz, py, pf)
  return {x = px or xPos, z = pz or zPos, y = py or yPos, f = pf or facing}
end

local function sameFiniteFuel(a, b)
  return type(a) == "number" and type(b) == "number" and a == b and a ~= math.huge
end

function beginDriveJournal(kind, action, afterPose)
  driveJournalSeq = (driveJournalSeq or 0) + 1
  local fuelBefore = checkFuel and checkFuel() or math.huge
  driveJournal = {
    schema = 1,
    seq = driveJournalSeq,
    kind = kind,
    action = action,
    before = poseTable(xPos, zPos, yPos, facing),
    after = afterPose or poseTable(xPos, zPos, yPos, facing),
    fuelBefore = fuelBefore,
    fuelAfter = (kind == "translate" and fuelBefore ~= math.huge) and (fuelBefore - 1) or nil,
  }
  saveProgress()
  return driveJournal
end

function clearDriveJournal()
  if driveJournal ~= nil then
    driveJournal = nil
    saveProgress()
  end
end

function commitDriveJournal()
  driveJournal = nil
  saveProgress()
end

local function applyPose(pose)
  if type(pose) ~= "table" then return false end
  xPos = tonumber(pose.x) or xPos
  zPos = tonumber(pose.z) or zPos
  yPos = tonumber(pose.y) or yPos
  facing = coterminal(tonumber(pose.f) or facing)
  relxCalc()
  return true
end

function reconcileDriveJournal()
  if type(driveJournal) ~= "table" then return true end
  local j = driveJournal
  if j.kind == "translate" then
    local fuelNow = checkFuel and checkFuel() or math.huge
    if sameFiniteFuel(fuelNow, j.fuelAfter) then
      applyPose(j.after)
      driveJournal = nil
      saveProgress()
      return true
    elseif sameFiniteFuel(fuelNow, j.fuelBefore) then
      applyPose(j.before)
      driveJournal = nil
      saveProgress()
      return true
    else
      enterHardPause("Pending move cannot be inferred; fuel delta unavailable", "state")
      return false
    end
  elseif j.kind == "rotation" then
    -- Rotation is confined to the turtle's horizontal facing scalar. The
    -- configured home-chest side defines the local quarry frame at deployment,
    -- and a turn has no positional delta or fuel delta to reconcile. Treat a
    -- persisted pending turn as committed to its recorded after-pose instead of
    -- freezing the route engine. This preserves autonomous recovery for the
    -- normal interruption window after the physical turn has occurred.
    applyPose(j.after)
    driveJournal = nil
    saveProgress()
    return true
  else
    enterHardPause("Unknown pending drive journal entry", "state")
    return false
  end
end

--Refuel Functions
function emergencyRefuel(forceBasic)
  local target = calculateHomeRefuelTarget()
  screen()
  print("Emergency fuel check")
  print("Fuel: ", checkFuel())
  print("Target: ", target)
  local initialFuel = checkFuel()
  auditCoalInventory()
  consumeCoalFuel(target, false)
  if checkFuel() > initialFuel then
    print("On-board coal consumed")
    return false
  end
  if xPos == homeBaseX and zPos == homeBaseZ and yPos == homeBaseY then
    if consumeHomeStorageFuel(target) then
      print("Home chest fuel consumed")
      return false
    end
  end
  print("No accessible fuel reserve")
  return true
end

--Mining functions
function dig(doAdd, mineFunc, inspectFunc, suckDir) --Note, turtle will not bother comparing if not given an inspectFunc
  if doAdd == nil then doAdd = true end
  if doAdd and not fuelSafetyReturnActive then
    preMotionFuelAudit()
  end
  mineFunc = mineFunc or turtle.dig
  local mineFlag = false
  local inspectedData = nil
  if inspectFunc then
    local worked, data = inspectFunc()
    if worked and type(data) == "table" then
      inspectedData = data
      if data.name and unmineableBlocks[data.name] then
        return false
      end
      if data.name == chestID then
        emptyChest(suckDir)
      end
    end
  end
  if oreQuarry and inspectFunc and inspectedData then
    mineFlag = not blacklist[inspectedData.name]
  end
  if not oreQuarry or not inspectFunc or mineFlag then --Mines if not oreQuarry, or if the inspect passed
   if mineFunc() then
     if doAdd then
       mined = mined + 1
     end
     return true
   else
     return false
   end
  end
  return true --This only runs if oreQuarry but item is intentionally skipped. true means succeeded in duty, not necessarily dug block
end

function digUp(doAdd, ignoreInspect)--Regular functions :) I switch definitions for optimization (I think)
  return dig(doAdd, turtle.digUp, (not ignoreInspect and turtle.inspectUp) or nil, "up")
end
function digDown(doAdd, ignoreInspect)
  return dig(doAdd, turtle.digDown, (not ignoreInspect and turtle.inspectDown) or nil, "down")
end
if inverted then --If inverted, switch the options
  digUp, digDown = digDown, digUp
end

function relxCalc()
  if layersDone % 2 == 1 then
    relzPos = zPos
  else
    relzPos = (z-zPos) + 1
  end
  if relzPos % 2 == 1 then
    relxPos = xPos
  else
    relxPos = (x-xPos)+1
  end
  if layersDone % 2 == 0 and z % 2 == 1 then
    relxPos = (x-relxPos)+1
  end
end
function horizontalMove(movement, posAdd, doAdd, allowBypass)
  if doAdd == nil then doAdd = true end
  local targetX, targetZ = xPos, zPos
  local isForward = movement == turtle.forward
  local isBack = movement == turtle.back
  if isForward then
    if facing == 0 then targetX = targetX + 1 elseif facing == 1 then targetZ = targetZ + 1 elseif facing == 2 then targetX = targetX - 1 elseif facing == 3 then targetZ = targetZ - 1 end
  elseif isBack then
    if facing == 0 then targetX = targetX - 1 elseif facing == 1 then targetZ = targetZ - 1 elseif facing == 2 then targetX = targetX + 1 elseif facing == 3 then targetZ = targetZ + 1 end
  end
  if (isForward or isBack) and not isPersistentRouteMode(stateRouteMode) then
    setPersistenceTarget("motion", targetX, targetZ, yPos, facing, "next translation")
  end
  preMotionFuelAudit()
  beginDriveJournal("translate", isForward and "forward" or (isBack and "back" or "horizontal"), poseTable(targetX, targetZ, yPos, facing))
  if movement() then
    if doAdd then moved = moved + 1 end
    xPos, zPos = targetX, targetZ
    relxCalc()
    if (isForward or isBack) and not isPersistentRouteMode(stateRouteMode) then
      stateNextTarget = {x = xPos, z = zPos, y = yPos, f = facing, label = "current"}
      stateRouteMode = "mining"
    end
    commitDriveJournal()
    return true
  end
  clearDriveJournal()
  if allowBypass and isForward then
    local blockName = getKnownUnmineableAhead()
    if blockName then
      return attemptFrontObstacleBypass(blockName, doAdd)
    end
  end
  return false
end
function forward(doAdd, allowBypass)
  return horizontalMove(turtle.forward, 1, doAdd, allowBypass)
end
function back(doAdd)
  return horizontalMove(turtle.back, -1, doAdd, false)
end
function verticalMove(moveFunc, yDiff, digFunc, attackFunc, inspectFunc, vectorName)
  local count = 0
  if not isPersistentRouteMode(stateRouteMode) then
    setPersistenceTarget("vertical", xPos, zPos, yPos + yDiff, facing, "next vertical translation")
  end
  preMotionFuelAudit()
  while true do
    beginDriveJournal("translate", vectorName or "vertical", poseTable(xPos, zPos, yPos + yDiff, facing))
    if moveFunc() then
      yPos = yDiff + yPos
      if not isPersistentRouteMode(stateRouteMode) then
        stateNextTarget = {x = xPos, z = zPos, y = yPos, f = facing, label = "current"}
        stateRouteMode = "mining"
      end
      commitDriveJournal()
      biometrics()
      return true
    end
    clearDriveJournal()
    if type(inspectFunc) == "function" then
      local ok, data = inspectFunc()
      if ok and type(data) == "table" and data.name and unmineableBlocks[data.name] then
        return attemptVerticalObstacleBypass(moveFunc, yDiff, digFunc, attackFunc, inspectFunc, vectorName, data.name)
      end
    end
    if not digFunc(true, true) then --True True is doAdd, and ignoreInspect
      attackFunc()
      sleep(0.5)
      count = count + 1
      if count > maxTries then
        local status, blockName = bedrockOnlyShutdown(inspectFunc, vectorName)
        if status == "bedrock" then bedrock() end
        if status == "unmineable" then
          return attemptVerticalObstacleBypass(moveFunc, yDiff, digFunc, attackFunc, inspectFunc, vectorName, blockName)
        end
        bypassUnavailable(blockName, "Vertical obstruction could not be identified")
        return false
      end
    end
  end
end
function up() --Uses other function if inverted
  verticalMove(inverted and turtle.down or turtle.up, -1, digUp, attackUp, inspectRelativeUp, inverted and "down" or "up") --Other functions deal with invert already
end
function down()
  verticalMove(inverted and turtle.up or turtle.down, 1, digDown, attackDown, inspectRelativeDown, inverted and "up" or "down")
end


function right(num)
  num = num or 1
  for i=1, num do
    preMotionFuelAudit()
    local newFacing = coterminal(facing+1)
    if not isPersistentRouteMode(stateRouteMode) then
      setPersistenceTarget("rotation", xPos, zPos, yPos, newFacing, "next rotation")
    end
    beginDriveJournal("rotation", goLeftNotRight and "turnLeft" or "turnRight", poseTable(xPos, zPos, yPos, newFacing))
    local ok = (not goLeftNotRight and turtle.turnRight() or turtle.turnLeft())
    if not ok then
      clearDriveJournal()
      return false
    end
    facing = newFacing
    if not isPersistentRouteMode(stateRouteMode) then
      stateNextTarget = {x = xPos, z = zPos, y = yPos, f = facing, label = "current"}
      stateRouteMode = "mining"
    end
    commitDriveJournal()
  end
  return true
end
function left(num)
  num = num or 1
  for i=1, num do
    preMotionFuelAudit()
    local newFacing = coterminal(facing-1)
    if not isPersistentRouteMode(stateRouteMode) then
      setPersistenceTarget("rotation", xPos, zPos, yPos, newFacing, "next rotation")
    end
    beginDriveJournal("rotation", goLeftNotRight and "turnRight" or "turnLeft", poseTable(xPos, zPos, yPos, newFacing))
    local ok = (not goLeftNotRight and turtle.turnLeft() or turtle.turnRight())
    if not ok then
      clearDriveJournal()
      return false
    end
    facing = newFacing
    if not isPersistentRouteMode(stateRouteMode) then
      stateNextTarget = {x = xPos, z = zPos, y = yPos, f = facing, label = "current"}
      stateRouteMode = "mining"
    end
    commitDriveJournal()
  end
  return true
end

function attack(doAdd, func)
  doAdd = doAdd or true
  func = func or turtle.attack
  if func() then
    if doAdd then
      attacked = attacked + 1
    end
    return true
  end
  return false
end
function attackUp(doAdd)
  if inverted then
    return attack(doAdd, turtle.attackDown)
  else
    return attack(doAdd, turtle.attackUp)
  end
end
function attackDown(doAdd)
  if inverted then
    return attack(doAdd, turtle.attackUp)
  else
    return attack(doAdd, turtle.attackDown)
  end
end

function detect(func)
  func = func or turtle.detect
  return func()
end
function detectUp(ignoreInvert)
  if inverted and not ignoreInvert then return detect(turtle.detectDown)
  else return detect(turtle.detectUp) end
end
function detectDown(ignoreInvert)
  if inverted and not ignoreInvert then return detect(turtle.detectUp)
  else return detect(turtle.detectDown) end
end

function inspectRelativeUp()
  if inverted then return turtle.inspectDown() end
  return turtle.inspectUp()
end

function inspectRelativeDown()
  if inverted then return turtle.inspectUp() end
  return turtle.inspectDown()
end

function learnUnmineableBlock(blockName, vectorName)
  blockName = normalizeBlockID(blockName)
  if not blockName or blockName == "minecraft:bedrock" then return false end
  local isNew = not unmineableBlocks[blockName]
  unmineableBlocks[blockName] = true
  blacklist[blockName] = true
  if isNew then
    appendUnmineableRegistry(blockName)
  end
  screen(1,1)
  print("Learned unmineable block")
  print("Vector: ", vectorName or "unknown")
  print("Block:  ", blockName)
  print("Registry: ", unmineableRegistryName)
  sleep(1)
  return true, isNew
end

function inspectObstruction(inspectFunc, vectorName)
  local blockName = nil
  if type(inspectFunc) == "function" then
    local ok, data = inspectFunc()
    if ok and type(data) == "table" then
      blockName = data.name
    end
  end
  if blockName == "minecraft:bedrock" then
    return "bedrock", blockName
  end
  if blockName then
    learnUnmineableBlock(blockName, vectorName)
    return "unmineable", blockName
  end
  print("Blocked on ", vectorName or "unknown", "; inspection returned no block metadata.")
  return "unknown", nil
end

function bedrockOnlyShutdown(inspectFunc, vectorName)
  local status, blockName = inspectObstruction(inspectFunc, vectorName)
  if status == "bedrock" then bedrock() end
  return status, blockName
end

function getKnownUnmineableAhead()
  if not turtle.inspect then return nil end
  local ok, data = turtle.inspect()
  if ok and type(data) == "table" and data.name and unmineableBlocks[data.name] then
    return data.name
  end
  return nil
end

local function directionDelta(dir)
  dir = coterminal(dir)
  if dir == 0 then return 1, 0 end
  if dir == 1 then return 0, 1 end
  if dir == 2 then return -1, 0 end
  return 0, -1
end

local function projectedCoord(dir, baseX, baseZ, steps)
  local dx, dz = directionDelta(dir)
  steps = steps or 1
  return baseX + dx * steps, baseZ + dz * steps
end

local function isOperationalCoord(nx, nz)
  if nx == homeBaseX and nz == homeBaseZ then return true end
  return nx >= 1 and nx <= x and nz >= 1 and nz <= z
end

local function chooseFrontBypassSide()
  local orig = facing
  local candidates = {coterminal(orig + 1), coterminal(orig - 1)}
  for _, sideDir in ipairs(candidates) do
    local sx, sz = projectedCoord(sideDir, xPos, zPos, 1)
    local f1x, f1z = projectedCoord(orig, sx, sz, 1)
    local f2x, f2z = projectedCoord(orig, sx, sz, 2)
    local bx, bz = projectedCoord(coterminal(sideDir + 2), f2x, f2z, 1)
    if isOperationalCoord(sx, sz) and isOperationalCoord(f1x, f1z) and isOperationalCoord(f2x, f2z) and isOperationalCoord(bx, bz) then
      return sideDir
    end
  end
  return nil
end

local function chooseAdjacentGridDirection()
  local candidates = {coterminal(facing + 1), coterminal(facing - 1), facing, coterminal(facing + 2)}
  for _, dir in ipairs(candidates) do
    local nx, nz = projectedCoord(dir, xPos, zPos, 1)
    if isOperationalCoord(nx, nz) then return dir end
  end
  return nil
end

local function bypassStepForward(doAdd, label)
  local tries = 0
  while not forward(doAdd, false) do
    local known = getKnownUnmineableAhead()
    if known then return false, known end
    if not dig(false, turtle.dig, turtle.inspect, "front") then
      attack(false)
    end
    tries = tries + 1
    if tries > maxTries then
      local status, blockName = bedrockOnlyShutdown(turtle.inspect, label or "bypass")
      if status == "bedrock" then bedrock() end
      return false, blockName
    end
    sleep(0)
  end
  return true
end

function bypassUnavailable(blockName, reason)
  reason = reason or "No local bypass route"
  statusString = reason
  screen(1,1)
  print("Unmineable bypass failed")
  print("Block: ", blockName or "unknown")
  print(reason)
  sleep(1)
  safePauseAtHome(reason, calculateHomeReturnCost(), getAvailableHomeFuel())
end

function attemptFrontObstacleBypass(blockName, doAdd)
  blockName = normalizeBlockID(blockName) or getKnownUnmineableAhead()
  if blockName then learnUnmineableBlock(blockName, "front") end
  local originalFacing = facing
  local sideDir = chooseFrontBypassSide()
  if not sideDir then
    bypassUnavailable(blockName, "No bounded side route around obstacle")
    return false
  end
  statusString = "Bypassing "..tostring(blockName or "obstacle")
  saveProgress()
  turnTo(sideDir)
  if not bypassStepForward(doAdd, "bypass side step") then
    turnTo(originalFacing)
    bypassUnavailable(blockName, "Side step blocked during bypass")
    return false
  end
  turnTo(originalFacing)
  if not bypassStepForward(doAdd, "bypass forward 1") then
    bypassUnavailable(blockName, "First forward bypass leg blocked")
    return false
  end
  if not bypassStepForward(doAdd, "bypass forward 2") then
    bypassUnavailable(blockName, "Second forward bypass leg blocked")
    return false
  end
  turnTo(coterminal(sideDir + 2))
  if not bypassStepForward(doAdd, "bypass return step") then
    bypassUnavailable(blockName, "Return-to-grid bypass leg blocked")
    return false
  end
  turnTo(originalFacing)
  relxCalc()
  statusString = nil
  saveProgress()
  print("Skipped unmineable coordinate: ", blockName or "unknown")
  sleep(0.5)
  return true
end

function attemptVerticalObstacleBypass(moveFunc, yDiff, digFunc, attackFunc, inspectFunc, vectorName, blockName)
  local originalFacing = facing
  local sideDir = chooseAdjacentGridDirection()
  if not sideDir then
    bypassUnavailable(blockName, "No adjacent grid cell for vertical bypass")
    return false
  end
  statusString = "Vertical bypass "..tostring(blockName or "obstacle")
  turnTo(sideDir)
  if not bypassStepForward(true, "vertical side step") then
    turnTo(originalFacing)
    bypassUnavailable(blockName, "Side step blocked during vertical bypass")
    return false
  end
  turnTo(originalFacing)
  local tries = 0
  while not moveFunc() do
    if not digFunc(false, true) then
      attackFunc(false)
    end
    tries = tries + 1
    if tries > maxTries then
      local status, learned = bedrockOnlyShutdown(inspectFunc, vectorName)
      if status == "bedrock" then bedrock() end
      bypassUnavailable(learned or blockName, "Vertical bypass column blocked")
      return false
    end
    sleep(0)
  end
  yPos = yPos + yDiff
  relxCalc()
  statusString = nil
  saveProgress()
  biometrics()
  print("Skipped vertical unmineable coordinate: ", blockName or "unknown")
  sleep(0.5)
  return true
end



function mine(doDigDown, doDigUp, outOfPath,doCheckInv) -- Basic Move Forward
  if doCheckInv == nil then doCheckInv = true end
  if doDigDown == nil then doDigDown = true end
  if doDigUp == nil then doDigUp = true end
  if outOfPath == nil then outOfPath = false end
  isInPath = (not outOfPath) --For rednet
  if not outOfPath then
    checkHomeFuelSafety()
  end
  local count = 0
  if not outOfPath then dig(true, turtle.dig, turtle.inspect, "front") end  --This speeds up the quarry by a decent amount if there are more mineable blocks than air
  while not forward(not outOfPath, true) do
    sleep(0) --Calls coroutine.yield to prevent errors
    local knownBlock = getKnownUnmineableAhead()
    if knownBlock then
      if attemptFrontObstacleBypass(knownBlock, not outOfPath) then break end
      bypassUnavailable(knownBlock, "Known unmineable blocked forward movement")
    end
    count = count + 1
    if not dig(true, turtle.dig, turtle.inspect, "front") then
      attack()
    end
    if count > 10 then
      attack()
      sleep(0.2)
    end
    if count > maxTries then
      if checkFuel() == 0 then --Don't worry about inf fuel because I modified this function
        saveProgress({doCheckFuel = true, doRefuel = true}) --This is emergency because this should never really happen.
        os.reboot()
      else
        local status, blockName = bedrockOnlyShutdown(turtle.inspect, "front")
        if status == "bedrock" then bedrock() end
        if status == "unmineable" then
          if attemptFrontObstacleBypass(blockName, not outOfPath) then break end
          bypassUnavailable(blockName, "Learned unmineable blocked forward movement")
        else
          bypassUnavailable(blockName, "Forward obstruction could not be identified")
        end
      end
    end
  end
  checkSanity() --Not kidding... This is necessary
  saveProgress(tab)
  if not outOfPath then
    checkHomeFuelSafety()
  end

  if doDigUp then--The digging up and down part
    sleep(0) --Calls coroutine.yield
    if not digUp(true) and detectUp() then --This is relative: will dig down first on invert
      if not attackUp() then
        local ok, data = inspectRelativeUp()
        local blockName = ok and type(data) == "table" and data.name or nil
        if blockName == "minecraft:bedrock" then
          bedrock()
        elseif blockName and unmineableBlocks[blockName] then
          print("Leaving learned unmineable overhead: ", blockName)
          sleep(0.5)
        end
      end
    end
  end
  if doDigDown then
   digDown(true)
  end
  percent = math.ceil(moved/moveVolume*100)
  updateDisplay()
  if doCheckInv and careAboutResources then
    if isFull(inventoryMax-keepOpen) then
      if not (oreQuarry and dumpCompareItems) then
        dropOff()
      else
        local currInv = getSlotsTable()
        drop(nil, false, true) --This also takes care of counting.
        if #getChangedSlots(currInv, getSlotsTable()) <= 2 then --This is so if the inventory is full of useful stuff, it still has to drop it
          dropOff()
        end
      end
    end
  end
  biometrics()
end
--Insanity Checking
function checkSanity()
  if not isInPath then --I don't really care if its not in the path.
    return true
  end
  if not (facing == 0 or facing == 2) and #events == 0 then --If mining and not facing proper direction and not in a turn
    turnTo(0)
    rowCheck = true
  end
  if xPos < 0 or xPos > x or zPos < 0 or zPos > z or yPos < 0 then
    saveProgress()
    print("I have gone outside boundaries, attempting to fix (maybe)")
    if xPos > x then goTo(x, zPos, yPos, 2) end --I could do this with some fancy math, but this is much easier
    if xPos < 0 then goTo(1, zPos, yPos, 0) end
    if zPos > z then goTo(xPos, z, yPos, 3) end
    if zPos < 0 then goTo(xPos, 1, yPos, 1) end
    relxCalc() --Get relxPos properly
    eventClear()

    --[[
    print("Oops. Detected that quarry was outside of predefined boundaries.")
    print("Please go to my forum thread and report this with a short description of what happened")
    print("If you could also run \"pastebin put Civil_Quarry_Restore\" and give me that code it would be great")
    error("",0)]]
  end
end

local function fromBoolean(input) --Like a calculator
if input then return 1 end
return 0
end
function coterminal(num, limit) --I knew this would come in handy :D
limit = limit or 4 --This is for facing
return math.abs((limit*fromBoolean(num < 0))-(math.abs(num)%limit))
end
--Direction: Front = 0, Right = 1, Back = 2, Left = 3
function turnTo(num)
  num = num or facing
  num = coterminal(num) --Prevent errors
  local turnRight = true
  if facing-num == 1 or facing-num == -3 then turnRight = false end --0 - 1 = -3, 1 - 0 = 1, 2 - 1 = 1
  while facing ~= num do          --The above is used to smartly turn
    if turnRight then
      right()
    else
      left()
    end
  end
end
function goTo(x,z,y, toFace, destination)
  --Will first go to desired z pos, then x pos, y pos varies
  x = x or 1; y = y or 1; z = z or 1; toFace = toFace or facing
  gotoDest = destination or "" --This is used by biometrics.
  local routeMode = stateRouteMode
  if not (routeMode == "to_storage" or routeMode == "to_work" or routeMode == "final_return") then
    routeMode = destination or "navigation"
  end
  setPersistenceTarget(routeMode, x, z, y, toFace, destination or "navigation target")
  saveProgress()
  statusString = "Going to ".. (destination or "somewhere")
  --Possible destinations: layerStart, quarryStart
  if yPos > y then --Will go up first if below position
    while yPos~=y do up() end
  end
  if zPos > z then
    turnTo(3)
  elseif zPos < z then
    turnTo(1)
  end
  while zPos ~= z do mine(false,false,true,false) end
  if xPos > x then
    turnTo(2)
  elseif xPos < x then
    turnTo(0)
  end
  while xPos ~= x do mine(false,false,true,false) end
  if yPos < y then --Will go down after if above position
    while yPos~=y do down() end
  end
  turnTo(toFace)
  stateNextTarget = {x = xPos, z = zPos, y = yPos, f = facing, label = "current"}
  saveProgress()
  gotoDest = ""
  statusString = nil
end
function getNumOpenSlots()
  local toRet = 0
  for i=1, inventoryMax do
    if turtle.getItemCount(i) == 0 then
      toRet = toRet + 1
    end
  end
  return toRet
end
function emptyChest(suckDirection)
  eventAdd("emptyChest",suckDirection)
  eventSetInsertionPoint(2) --Because dropOff adds events we want to run first
  local suckFunc
  if suckDirection == "up" then
    suckFunc = turtle.suckUp
  elseif suckDirection == "down" then
    suckFunc = turtle.suckDown
  else
    suckFunc = turtle.suck
  end
  repeat
    if inventoryMax - countUsedSlots() <= 0 then --If there are no slots open, need to empty
      dropOff()
    end
  until not suckFunc()
  eventClear()
  eventSetInsertionPoint()
end

--Ideas: Bring in inventory change-checking functions, count blocks that have been put in, so it will wait until all blocks have been put in.
local function waitDrop(slot, allowed, whereDrop) --Single-progress deposit; never loops on a full container.
  allowed = allowed or 0
  while turtle.getItemCount(slot) > allowed do
    local before = turtle.getItemCount(slot)
    local amount = before - allowed
    if not whereDrop(amount) then
      return storageSaturationPause("drop refused", slot)
    end
    if turtle.getItemCount(slot) >= before then
      return storageSaturationPause("drop made no progress", slot)
    end
    chestFull = false
    sleep(0)
  end
  return true
end

function midRunRefuel(i, allowed)
  allowed = allowed or allowedItems[i]
  local numToRefuel = turtle.getItemCount(i)-allowed
  if checkFuel() >= checkFuelLimit() then return true end --If it doesn't need fuel, then signal to not take more
  local firstCheck = checkFuel()
  if numToRefuel > 0 then turtle.refuel(1)  --This is so we can see how many fuel we need.
    else return false end --Bandaid solution: If won't refuel, don't try.
  local singleFuel
  if checkFuel() - firstCheck > 0 then singleFuel = checkFuel() - firstCheck else singleFuel = math.huge end --If fuel is 0, we want it to be huge so the below will result in 0 being taken
  --Refuel      The lesser of   max allowable or         remaining fuel space         /    either inf or a single fuel (which can be 0)
  turtle.refuel(math.min(numToRefuel-1, math.ceil((checkFuelLimit()-checkFuel()) / singleFuel))) --The refueling part of the the doRefuel option
  if checkFuel() >= checkFuelLimit() then return true end --Do not need any more fuel
  return false --Turtle can still be fueled
end


function drop(side, final, compareDump)
  side = sides[side] or "front"
  local dropFunc, detectFunc, dropFacing = turtle.drop, turtle.detect, facing+2
  if side == "top" then dropFunc, detectFunc = turtle.dropUp, turtle.detectUp end
  if side == "bottom" then dropFunc, detectFunc = turtle.dropDown, turtle.detectDown end
  if side == "right" then turnTo(1); dropFacing = 0 end
  if side == "left" then turnTo(3); dropFacing = 0 end
  local properFacing = facing --Capture the proper direction to be facing

  if not dropCountCommitted then
    count(true) --Count number of items once for this drop transaction; preserved across storage pauses.
    dropCountCommitted = true
    saveProgress()
  elseif type(slot) ~= "table" then
    count(false) --Rebuild volatile slot classification after resumed storage pause without changing totals.
  end

  if not compareDump and not detectFunc() then
    return storageSaturationPause("no chest on "..tostring(side))
  end
  chestFull = false

  local fuelSwitch = false --If doRefuel, this can switch so it won't overfuel
  for i=1,inventoryMax do
    --if final then allowedItems[i] = 0 end --0 items allowed in all slots if final ----It is already set to 1, so just remove comment if want change
    if turtle.getItemCount(i) > 0 then --Saves time, stops bugs
      if type(slot) ~= "table" or type(slot[i]) ~= "table" then count(false) end
      local slotKind = (slot[i] and slot[i][1]) or 3
      if slotKind == 1 and dumpCompareItems then turnTo(dropFacing) --Turn around to drop junk, not store it.
      else turnTo(properFacing) --Turn back to proper position... or do nothing if already there
      end
      select(i)
      if slotKind == 2 then --Intelligently refuels to fuel limit from audited coal only
        if doRefuel and not fuelSwitch and isCoalSlot(i) then --Only mined coal/charcoal is consumed as fuel
          fuelSwitch = midRunRefuel(i, 0)
        else
          if not waitDrop(i, allowedItems[i], dropFunc) then return false end
        end
        if fuelSwitch then
          if not waitDrop(i, allowedItems[i], dropFunc) then return false end
        end
      elseif not compareDump or (compareDump and slotKind == 1) then --This stops all wanted items from being dropped off in a compareDump
        if not waitDrop(i, allowedItems[i], dropFunc) then return false end
      end
    end
  end

  if compareDump then
    for i=2, inventoryMax do
      select(i)
    for j=1, i-1 do
      if turtle.getItemCount(i) == 0 then break end
      turtle.transferTo(j)
    end
    end
    select(1)
  end
  if compareDump then count(nil) end--Subtract items still retained after compare dump
  resetDumpSlots() --So that slots gone aren't counted as dump slots next
  dropCountCommitted = false

  select(1) --For fanciness sake

end

function dropOff() --Not local because called in mine()
  local currX,currZ,currY,currFacing = xPos, zPos, yPos, facing
  setWorkReturnTarget(currX, currZ, currY, currFacing)
  stateRouteMode = "to_storage"
  setPersistenceTarget("to_storage", homeBaseX, homeBaseZ, homeBaseY, 2, "drop off")
  saveProgress()
  if careAboutResources then
    eventAdd("goTo", 1,1,currY,2, "drop off") --Need this step for "-startDown"
    eventAdd('goTo(0,1,1,2,"drop off")')
    eventAdd("drop", dropSide,false)
    eventAdd("turnTo(0)")
    eventAdd("mine",false,false,true,false)
    eventAdd("goTo(1,1,1, 0)")
    eventAdd("goTo", 1, 1, currY, 0)
    eventAdd("goTo", currX,currZ,currY,currFacing)
    runAllEvents()
    storageReturnX, storageReturnZ, storageReturnY, storageReturnFacing = nil, nil, nil, nil
    stateRouteMode = "mining"
    stateNextTarget = {x = xPos, z = zPos, y = yPos, f = facing, label = "current"}
    saveProgress()
    numDropOffs = numDropOffs + 1 --Analytics tracking
  end
  return true
end
function endingProcedure() --Used both at the end and in "biometrics"
  eventAdd("goTo",1,1,yPos,2,"quarryStart") --Allows for startDown variable
  eventAdd("goTo",0,1,1,2, "quarryStart") --Go back to base
  runAllEvents()
  --Output to the configured home chest or sit there
  eventAdd("drop",dropSide, true)
  eventAdd("turnTo(0)")

  --Display was moved above to be used in bedrock function
  eventAdd("display")
  --Log current mining run
  eventAdd("logMiningRun")
  toQuit = true --I'll use this flag to clean up (legacy)
  runAllEvents()
end
function bedrock()
  foundBedrock = true --Let everyone know
  if rednetEnabled then biometrics() end
  if checkFuel() == 0 then error("No Fuel",0) end
  local origin = {x = xPos, y = yPos, z = zPos}
  print("Bedrock Detected")
  if turtle.detectUp() and not turtle.digUp() then
    print("Block Above")
    turnTo(facing+2)
    repeat
      if not forward(false) then --Tries to go back out the way it came
        if not attack() then --Just making sure not mob-blocked
          if not dig() then --Now we know its bedrock
            turnTo(facing+1) --Try going a different direction
          end
        end
      end
    until not turtle.detectUp() or turtle.digUp() --These should be absolute and we don't care about about counting resources here.
  end
  up() --Go up two to avoid any bedrock.
  up()
  eventClear() --Get rid of any excess events that may be run. Don't want that.
  endingProcedure()
  print("\nFound bedrock at these coordinates: ")
  print(origin.x," Was position in row\n",origin.z," Was row in layer\n",origin.y," Blocks down from start")
  error("",0)
end

function endOfRowTurn(startZ, wasFacing, mineFunctionTable)
local halfFacing = ((layersDone % 2 == 1) and 1) or 3
local toFace = coterminal(wasFacing + 2) --Opposite side
if zPos == startZ then
  if facing ~= halfFacing then turnTo(halfFacing) end
  mine(table.unpack(mineFunctionTable or {}))
end
if facing ~= toFace then
  turnTo(toFace)
end
end


-------------------------------------------------------------------------------------
--Compact persisted route execution
local function executeAxisSteps(axis, delta, label)
  delta = tonumber(delta) or 0
  if delta == 0 then return true end
  local dir, count = nil, math.abs(delta)
  if axis == "Y" then
    for _=1,count do
      if delta > 0 then down() else up() end
    end
    return true
  elseif axis == "Z" then
    dir = delta > 0 and 1 or 3
  elseif axis == "X" then
    dir = delta > 0 and 0 or 2
  else
    return false
  end
  turnTo(dir)
  for _=1,count do
    mine(false, false, true, false)
  end
  return true
end

function executeCompactPath(path, label)
  path = tostring(path or "")
  if path == "" or path == "@" then return true end
  statusString = "Route "..tostring(label or "state")
  for token in path:gmatch("[^;]+") do
    local op = token:sub(1,1)
    local value = tonumber(token:sub(2)) or 0
    if op == "F" then
      turnTo(value)
    elseif op == "X" or op == "Y" or op == "Z" then
      executeAxisSteps(op, value, label)
    end
    saveProgress()
  end
  statusString = nil
  return true
end

local function targetDiffers(target)
  return type(target) == "table" and (
    tonumber(target.x) ~= xPos or tonumber(target.z) ~= zPos or
    tonumber(target.y) ~= yPos or tonumber(target.f or facing) ~= facing
  )
end

-------------------------------------------------------------------------------------
--State-file resume routing
function resumeFromStateSnapshot()
  if not stateSnapshotLoaded then return end
  reconcileDriveJournal()

  if suspendedOperationalState or driveSystemsDisabled then
    screen(1,1)
    print("Resuming suspended state")
    print(suspendedReason or "Manual intervention was required")
    print("Condition will be rechecked.")
    sleep(2)
    suspendedOperationalState = false
    driveSystemsDisabled = false
    storageBlockedPause = false
    fuelSafetyPause = false
    chestFull = false
    suspendedReason = ""
    saveProgress()
  end

  eventClear()

  -- Use persisted residual path strings as authoritative resume routes.
  -- They are rewritten after every committed move/turn, so an interruption
  -- during a storage-return or work-return route resumes from the last
  -- committed relative coordinate instead of discarding the route ledger.
  local function ensureStoragePath()
    if not statePathToStorage or statePathToStorage == "" then
      stateStorageTarget = {x = homeBaseX or 0, z = homeBaseZ or 1, y = homeBaseY or 1, f = 2, label = "storage"}
      statePathToStorage = compactPathBetween(xPos, zPos, yPos, facing, stateStorageTarget.x, stateStorageTarget.z, stateStorageTarget.y, stateStorageTarget.f)
      saveProgress()
    end
  end

  local function ensureNextPath(target)
    if (not statePathToNext or statePathToNext == "") and type(target) == "table" then
      statePathToNext = compactPathBetween(xPos, zPos, yPos, facing, target.x, target.z, target.y, target.f or facing)
      saveProgress()
    end
  end

  if stateRouteMode == "to_storage" or (storageReturnX and storageReturnY and storageReturnZ) then
    local wx, wz, wy, wf = storageReturnX or xPos, storageReturnZ or zPos, storageReturnY or yPos, storageReturnFacing or facing
    stateRouteMode = "to_storage"
    ensureStoragePath()
    executeCompactPath(statePathToStorage, "state to storage")
    drop(dropSide, false)
    turnTo(0)
    setWorkReturnTarget(wx, wz, wy, wf)
    ensureNextPath(stateNextTarget)
    executeCompactPath(statePathToNext, "state back to work")
    storageReturnX, storageReturnZ, storageReturnY, storageReturnFacing = nil, nil, nil, nil
    stateRouteMode = "mining"
    stateNextTarget = {x = xPos, z = zPos, y = yPos, f = facing, label = "current"}
    saveProgress()
  elseif stateRouteMode == "to_work" and targetDiffers(stateNextTarget) then
    ensureNextPath(stateNextTarget)
    executeCompactPath(statePathToNext, "state to work")
    stateRouteMode = "mining"
    stateNextTarget = {x = xPos, z = zPos, y = yPos, f = facing, label = "current"}
    saveProgress()
  elseif targetDiffers(stateNextTarget) then
    ensureNextPath(stateNextTarget)
    executeCompactPath(statePathToNext, "state resume target")
    stateRouteMode = "mining"
    stateNextTarget = {x = xPos, z = zPos, y = yPos, f = facing, label = "current"}
    saveProgress()
  end
  if stateRouteMode == "motion" or stateRouteMode == "vertical" or stateRouteMode == "rotation" or stateRouteMode == "resume" then
    stateRouteMode = "mining"
    stateNextTarget = {x = xPos, z = zPos, y = yPos, f = facing, label = "current"}
    saveProgress()
  end
  stateSnapshotLoaded = false
end

displayConfigurationSummary()
resumeFromStateSnapshot()

-------------------------------------------------------------------------------------
--Pre-Mining Stuff dealing with session persistence
runAllEvents()
if toQuit then error("",0) end --This means that it was stopped coming for its last drop

local doDigDown, doDigUp = (lastHeight ~= 1), (lastHeight == 0) --Used in lastHeight
if not restoreFoundSwitch then --Regularly
  --Check if it is a mining turtle
  if not isMiningTurtle then
    local a, b = turtle.dig()
    if a then
      mined = mined + 1
      isMiningTurtle = true
    elseif b == "Nothing to dig with" or b == "No tool to dig with" then
      print("This is not a mining turtle. To make a mining turtle, craft me together with a diamond pickaxe")
      error("",0)
    end
  end
  
  if checkFuel() == 0 then --Some people forget to start their turtles with fuel
    screen(1,1)
    print("I have no fuel.")
    print("Starting emergency fueling procedures!\n")
    emergencyRefuel()
    if checkFuel() == 0 then
      print("I have no fuel and can't get more!")
      print("Add coal to inventory")
      print("I have no choice but to quit.")
      error("",0)
    end
  end
  
  mine(false,false,true) --Get into quarry by going forward one
  for i = 1, startDown do
    eventAdd("down") --Add a bunch of down events to get to where it needs to be.
  end
  runAllEvents()
  if flatBedrock then
    while (detectDown() and digDown(false, true)) or not detectDown() do --None of these functions are non-invert protected because inverse always false here
      down()
      startDown = startDown + 1
    end
    startDown = startDown - y + 1
    for i=1, y-2 do
      up() --It has hit bedrock, now go back up for proper 3 wide mining
    end
  elseif not(y == 1 or y == 2) then
    down() --Go down to align properly. If y is one or two, it doesn't need to do this.
  end
else --restore found
  if not(layersDone == layers and not doDigDown) then digDown() end
  if not(layersDone == layers and not doDigUp) then digUp() end  --Get blocks missed before stopped
end
--Mining Loops--------------------------------------------------------------------------
select(1)
while layersDone <= layers do -------------Height---------
local lastLayer = layersDone == layers --If this is the last layer
local secondToLastLayer = (layersDone + 1) == layers --This is a check for going down at the end of a layer.
moved = moved + 1 --To account for the first position in row as "moved"
if not(layersDone == layers and not doDigDown) then digDown() end --This is because it doesn't mine first block in layer
if not restoreFoundSwitch and layersDone % 2 == 1 then rowCheck = true end
relxCalc()
while relzPos <= z do -------------Width----------
while relxPos < x do ------------Length---------
mine(not lastLayer or (doDigDown and lastLayer), not lastLayer or (doDigUp and lastLayer)) --This will be the idiom that I use for the mine function
end ---------------Length End-------
if relzPos ~= z then --If not on last row of section
  local func
  if rowCheck == true then --Switching to next row
  func = "right"; rowCheck = false; else func = false; rowCheck = true end --Which way to turn
    eventAdd("endOfRowTurn", zPos, facing , {not lastLayer or (doDigDown and lastLayer), not lastLayer or (doDigUp and lastLayer)}) --The table is passed to the mine function
    runAllEvents()
else break
end
end ---------------Width End--------
if layersDone % 2 == 0 then --Will only go back to start on non-even layers
  eventAdd("goTo",1,1,yPos,0, "layerStart") --Goto start of layer
else
  eventAdd("turnTo",coterminal(facing-2))
end
if not lastLayer then --If there is another layer
  for i=1, 2+fromBoolean(not(lastHeight~=0 and secondToLastLayer)) do eventAdd("down()") end --The fromBoolean stuff means that if lastheight is 1 and last and layer, will only go down two
end
eventAdd("relxCalc")
layersDone = layersDone + 1
restoreFoundSwitch = false --This is done so that rowCheck works properly upon restore
runAllEvents()
end ---------------Height End-------

endingProcedure() --This takes care of getting to start, dropping in chest, and displaying ending screen
