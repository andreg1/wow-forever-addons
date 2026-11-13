-------------------------------------------------------------------------------
--  Questie - Rare Objectives
--
--  Watches for rare quest mobs you still need (e.g. Ghostpaw, who roams all
--  over the Riverglades) while you're in their zone, and when one shows up:
--  raid-warning text + sound + taskbar flash, a raid marker on it, and a map
--  waypoint when its position is known.
--
--  What gets watched: for every incomplete quest in your log, from QuestieDB
--  (the QuestDB / NpcDB / ItemDB globals of the QuestieDB addon):
--    * kill objectives (objectives[1] creatures, [5] kill credit) and
--    * item objectives (objectives[3]) whose item drops from few NPCs
--      (ItemDB npcDrops),
--  where the NPC is "rare": NpcDB rank 2 (rare elite) or 4 (rare), or a
--  one-off named target (the log objective needs exactly 1 kill, or 1 item
--  that only that NPC drops). The log objective whose text names the
--  mob / item must still be unfinished. Only mobs whose zone (spawns and
--  waypoints, else the quest's zone) contains your current map are active.
--  /qrare add <name> watches any mob by name, anywhere.
--
--  How it looks (addons can't target or search units by themselves):
--    * every db.interval seconds, and on the matching events: nameplates
--      (enemy nameplates must be on; /qrare nameplates raises their range),
--      target, mouseover, and minimap vignettes (C_VignetteInfo, which also
--      give a map position for the waypoint);
--    * the "Scan for rare quest mobs" key binding (or /click
--      QuestieRareObjectivesScan) runs /targetexact for every active mob.
--      That reaches further than nameplates; a hit targets it, and the
--      target check above raises the alert.
--  A mob alerts once, then again only after it was out of sight for
--  db.realert seconds. Dead mobs are ignored.
--
--  Public surfaces used: QuestieDB's globals, Questie's ZoneDB via
--  QuestieLoader (area ID -> map ID; optional), Blizzard API.
--
--  Taint: the scan button is our own SecureActionButton, unanchored and
--  hidden; its macro text only changes out of combat. Nothing touches other
--  addons' frames.
-------------------------------------------------------------------------------
local addonName = ...

local PREFIX = "|cffff7f3fQuestie Rare Objectives:|r "
local SCAN_BUTTON = "QuestieRareObjectivesScan"
local RAID_MARKS = { "Star", "Circle", "Diamond", "Triangle", "Moon", "Square", "Cross", "Skull" }

BINDING_HEADER_QUESTIERAREOBJECTIVES = "Questie Rare Objectives"
_G["BINDING_NAME_CLICK " .. SCAN_BUTTON .. ":LeftButton"] = "Scan for rare quest mobs"

local defaults = {
    enabled = true,
    interval = 1,      -- seconds between scans
    realert = 120,     -- seconds out of sight before the same mob alerts again
    marker = 8,        -- raid marker (1-8), 0 = none
    sound = true,
    flash = true,
    waypoint = true,
    manual = {},       -- [lowercase name] = display name, watched anywhere
}

local db
local watched = {}  -- [npcId] = { name, quests = {[questId] = title}, maps = {[uiMapId] = true} | nil }
local active = {}   -- [npcId] = entry (watched and in your area)
local activeByName = {} -- [lowercase name] = { name, quests } (active + manual)
local lastSeen = {} -- [guid] = GetTime()
local playerMaps = {}
local scanButton, macroPending = nil, false
local rebuildPending = false
local zoneDB

local function Say(message)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. message)
    end
end

-------------------------------------------------------------------------------
--  Data
-------------------------------------------------------------------------------
local function Get(dbTable, id, field)
    if type(dbTable) ~= "table" or type(dbTable.Get) ~= "function" then return end
    local ok, value = pcall(dbTable.Get, id, field)
    if ok then return value end
end

local function NpcIdFromGuid(guid)
    if type(guid) ~= "string" or (issecretvalue and issecretvalue(guid)) then return end
    local kind, _, _, _, _, id = strsplit("-", guid)
    if kind ~= "Creature" and kind ~= "Vehicle" then return end
    return tonumber(id)
end

local function IsRareRank(npcId)
    local rank = Get(NpcDB, npcId, "rank")
    return rank == 2 or rank == 4
end

-- Rare by rank, or a one-off named target: the objective needs exactly one
-- (one kill, or one item from a single dropper - see ScanQuest). Spawn counts
-- are no use here: QuestieDB records many points for named roamers and for
-- WANTED targets like Trapclaw.
local function IsRareTarget(npcId, needed)
    return needed == 1 or IsRareRank(npcId)
end

local function UiMapForArea(areaId)
    if zoneDB == nil and type(QuestieLoader) == "table" and type(QuestieLoader.ImportModule) == "function" then
        local ok, mod = pcall(QuestieLoader.ImportModule, QuestieLoader, "ZoneDB")
        zoneDB = ok and type(mod) == "table" and type(mod.GetUiMapIdByAreaId) == "function" and mod or false
    end
    if not zoneDB then return end
    local ok, uiMap = pcall(zoneDB.GetUiMapIdByAreaId, zoneDB, areaId)
    if ok and type(uiMap) == "number" and uiMap > 0 then return uiMap end
end

-- The NPC's maps, or nil when unknown (then it counts as everywhere).
local function MapsFor(npcId, questId)
    local maps, any = {}, false
    for _, field in ipairs({ "spawns", "waypoints" }) do
        local byZone = Get(NpcDB, npcId, field)
        if type(byZone) == "table" then
            for areaId in pairs(byZone) do
                local uiMap = UiMapForArea(areaId)
                if uiMap then maps[uiMap] = true; any = true end
            end
        end
    end
    if not any then
        local zone = Get(QuestDB, questId, "zoneOrSort")
        local uiMap = type(zone) == "number" and zone > 0 and UiMapForArea(zone)
        if uiMap then maps[uiMap] = true; any = true end
    end
    return any and maps or nil
end

local function ItemName(itemId)
    local name = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(itemId)
    return name or Get(ItemDB, itemId, "name")
end

-- The log objective naming `name`: returns finished, numRequired (nil if none names it)
local function LogObjective(objectives, name)
    if not name or not objectives then return end
    local needle = name:lower()
    for _, o in ipairs(objectives) do
        if type(o.text) == "string" and o.text:lower():find(needle, 1, true) then
            return o.finished, o.numRequired
        end
    end
end

-------------------------------------------------------------------------------
--  Watch list
-------------------------------------------------------------------------------
local function Watch(npcId, questId, title)
    local entry = watched[npcId]
    if not entry then
        entry = { name = Get(NpcDB, npcId, "name") or ("NPC " .. npcId), quests = {}, maps = MapsFor(npcId, questId) }
        watched[npcId] = entry
    end
    entry.quests[questId] = title
end

local function ScanQuest(questId, title)
    local objectives = Get(QuestDB, questId, "objectives")
    if type(objectives) ~= "table" then return end
    local logObjectives = C_QuestLog.GetQuestObjectives(questId)

    local function ConsiderNpc(npcId, objectiveName)
        if type(npcId) ~= "number" then return end
        local name = objectiveName or Get(NpcDB, npcId, "name")
        local finished, needed = LogObjective(logObjectives, name)
        if finished then return end
        if IsRareTarget(npcId, needed) then Watch(npcId, questId, title) end
    end

    for _, o in ipairs(objectives[1] or {}) do ConsiderNpc(o[1]) end
    for _, o in ipairs(objectives[5] or {}) do
        -- Kill credit: any of o[1] counts; the log names the credit (o[3] or o[2]'s name)
        local creditName = o[3] or Get(NpcDB, o[2], "name")
        for _, npcId in ipairs(type(o[1]) == "table" and o[1] or {}) do ConsiderNpc(npcId, creditName) end
    end
    for _, o in ipairs(objectives[3] or {}) do
        local itemId = o[1]
        local drops = type(itemId) == "number" and Get(ItemDB, itemId, "npcDrops")
        if type(drops) == "table" and #drops > 0 and #drops <= 3 then
            local finished, needed = LogObjective(logObjectives, ItemName(itemId))
            if not finished then
                -- One item from one mob: that mob is the target (e.g. Trapclaw's Pincer).
                -- From several mobs: only the rare ones.
                if #drops > 1 and needed == 1 then needed = nil end
                for _, npcId in ipairs(drops) do
                    if IsRareTarget(npcId, needed) then Watch(npcId, questId, title) end
                end
            end
        end
    end
end

-- Zone-level maps only: a continent or the world contains every zone, so two
-- zones on one continent must not match through it.
local ZONE_TYPE = Enum and Enum.UIMapType and Enum.UIMapType.Zone or 3

-- Calls fn(map) for the map and each parent down to zone level (stops above it).
local function WalkToZone(m, fn)
    local guard = 0
    while m and m > 0 and guard < 10 do
        local info = C_Map.GetMapInfo(m)
        if not info or (info.mapType and info.mapType < ZONE_TYPE) then return end
        if fn(m) then return true end
        m = info.parentMapID
        guard = guard + 1
    end
end

-- Your map and the zone holding it (e.g. a sub-zone or a city map and its zone)
local function UpdatePlayerMaps()
    wipe(playerMaps)
    WalkToZone(C_Map.GetBestMapForUnit("player"), function(m) playerMaps[m] = true end)
end

-- The mob's map is your map, the zone you're in, or a sub-map of it
local function InArea(entry)
    if not entry.maps then return true end
    for uiMap in pairs(entry.maps) do
        if WalkToZone(uiMap, function(m) return playerMaps[m] end) then return true end
    end
    return false
end

local UpdateMacro -- defined below

local function Rebuild()
    rebuildPending = false
    wipe(watched)
    for i = 1, C_QuestLog.GetNumQuestLogEntries() do
        local info = C_QuestLog.GetInfo(i)
        if info and not info.isHeader and info.questID and not C_QuestLog.IsComplete(info.questID) then
            ScanQuest(info.questID, info.title)
        end
    end
    UpdatePlayerMaps()
    wipe(active)
    wipe(activeByName)
    for npcId, entry in pairs(watched) do
        if InArea(entry) then
            active[npcId] = entry
            activeByName[entry.name:lower()] = entry
        end
    end
    for key, name in pairs(db.manual) do
        if not activeByName[key] then activeByName[key] = { name = name, quests = {} } end
    end
    UpdateMacro()
end

local function QueueRebuild()
    if rebuildPending then return end
    rebuildPending = true
    C_Timer.After(1, Rebuild)
end

-------------------------------------------------------------------------------
--  Alert
-------------------------------------------------------------------------------
local function QuestText(entry)
    local titles = {}
    for _, title in pairs(entry.quests) do titles[#titles + 1] = title end
    table.sort(titles)
    return #titles > 0 and (" (" .. table.concat(titles, ", ") .. ")") or ""
end

local function CanMark()
    if not IsInGroup() then return true end
    return UnitIsGroupLeader("player") or UnitIsGroupAssistant("player")
end

local function Mark(unit)
    if not unit or db.marker < 1 or db.marker > 8 then return end
    if GetRaidTargetIndex(unit) or not CanMark() then return end
    pcall(SetRaidTarget, unit, db.marker)
end

local function SetWaypoint(pos)
    if not (db.waypoint and pos and C_Map.SetUserWaypoint and UiMapPoint) then return end
    pcall(function()
        if C_Map.CanSetUserWaypointOnMap and not C_Map.CanSetUserWaypointOnMap(pos[1]) then return end
        C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(pos[1], pos[2], pos[3]))
        if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
            C_SuperTrack.SetSuperTrackedUserWaypoint(true)
        end
    end)
end

local function Alert(entry, unit, pos)
    local where = ""
    if pos then where = string.format(" at %.1f, %.1f", pos[2] * 100, pos[3] * 100) end
    local tapped = unit and UnitIsTapDenied and UnitIsTapDenied(unit) and " |cffaaaaaa(tapped by someone else)|r" or ""
    local text = "|cffff5050" .. entry.name .. "|r is nearby" .. where .. "!" .. tapped
    if RaidNotice_AddMessage and RaidWarningFrame then
        RaidNotice_AddMessage(RaidWarningFrame, text, ChatTypeInfo and ChatTypeInfo.RAID_WARNING or { r = 1, g = 0.3, b = 0.1 })
    end
    Say(text .. QuestText(entry))
    if db.sound then
        PlaySound(SOUNDKIT and SOUNDKIT.RAID_WARNING or 8959, "Master")
    end
    if db.flash and FlashClientIcon then FlashClientIcon() end
end

-- entry: active entry; guid: the mob's GUID; unit: a unit token if we have one
local function Found(entry, guid, unit, pos)
    local now = GetTime()
    local seen = lastSeen[guid]
    lastSeen[guid] = now
    if unit then Mark(unit) end
    if seen and now - seen < db.realert then return end
    Alert(entry, unit, pos)
    SetWaypoint(pos)
end

local function EntryForUnit(unit)
    if not UnitExists(unit) or UnitIsDead(unit) or UnitIsPlayer(unit) then return end
    local npcId = NpcIdFromGuid(UnitGUID(unit))
    if npcId and active[npcId] then return active[npcId] end
    local name = UnitName(unit)
    if name and not (issecretvalue and issecretvalue(name)) then
        local entry = activeByName[name:lower()]
        if entry then return entry end
    end
end

local function CheckUnit(unit)
    local entry = EntryForUnit(unit)
    if entry then Found(entry, UnitGUID(unit), unit, nil) end
end

local function CheckVignettes()
    if not (C_VignetteInfo and C_VignetteInfo.GetVignettes) then return end
    local uiMap = C_Map.GetBestMapForUnit("player")
    for _, vignetteGUID in ipairs(C_VignetteInfo.GetVignettes() or {}) do
        local info = C_VignetteInfo.GetVignetteInfo(vignetteGUID)
        local npcId = info and NpcIdFromGuid(info.objectGUID)
        local entry = npcId and active[npcId] or (info and info.name and activeByName[info.name:lower()])
        if entry and not info.isDead then
            local pos
            if uiMap and C_VignetteInfo.GetVignettePosition then
                local v = C_VignetteInfo.GetVignettePosition(vignetteGUID, uiMap)
                if v then pos = { uiMap, v.x, v.y } end
            end
            Found(entry, info.objectGUID or vignetteGUID, nil, pos)
        end
    end
end

local function Scan()
    if not db.enabled or next(activeByName) == nil then return end
    if C_NamePlate and C_NamePlate.GetNamePlates then
        for _, plate in ipairs(C_NamePlate.GetNamePlates() or {}) do
            local unit = plate.namePlateUnitToken or (plate.UnitFrame and plate.UnitFrame.unit)
            if unit then CheckUnit(unit) end
        end
    end
    CheckUnit("target")
    CheckUnit("mouseover")
    CheckVignettes()
end

-------------------------------------------------------------------------------
--  Scan key binding: /targetexact every active mob
-------------------------------------------------------------------------------
function UpdateMacro()
    if not scanButton then return end
    if InCombatLockdown() then macroPending = true; return end
    macroPending = false
    local lines, length = {}, 0
    local names = {}
    for _, entry in pairs(activeByName) do names[#names + 1] = entry.name end
    table.sort(names)
    for _, name in ipairs(names) do
        local line = "/targetexact " .. name
        if length + #line + 1 > 1000 then break end
        lines[#lines + 1] = line
        length = length + #line + 1
    end
    scanButton:SetAttribute("macrotext", table.concat(lines, "\n"))
end

local function BuildScanButton()
    scanButton = CreateFrame("Button", SCAN_BUTTON, UIParent, "SecureActionButtonTemplate")
    scanButton:SetAttribute("type", "macro")
    scanButton:SetAttribute("macrotext", "")
    scanButton:RegisterForClicks("AnyUp", "AnyDown")
    scanButton:SetSize(1, 1)
    scanButton:Hide()
end

-------------------------------------------------------------------------------
--  Slash command
-------------------------------------------------------------------------------
local function OnOff(v) return v and "on" or "off" end

local function ListWatched()
    local any = false
    for npcId, entry in pairs(watched) do
        any = true
        local state
        if not entry.maps then
            state = "|cffffd100zone unknown, watched everywhere|r"
        elseif active[npcId] then
            state = "|cff40ff40watching here|r"
        else
            state = "|cffaaaaaanot in this zone|r"
        end
        Say(string.format("  %s (%d)%s - %s", entry.name, npcId, QuestText(entry), state))
    end
    for _, name in pairs(db.manual) do
        any = true
        Say("  " .. name .. " - |cff40ff40added by you, watched everywhere|r")
    end
    if not any then Say("No rare quest mobs to watch for (none in your incomplete quests).") end
end

local function SlashHandler(message)
    local raw = message or ""
    local command, rest = raw:match("^%s*(%S*)%s*(.-)%s*$")
    command = (command or ""):lower()
    if command == "on" or command == "off" then
        db.enabled = command == "on"
        Say("Watching " .. OnOff(db.enabled) .. ".")
    elseif command == "list" or command == "" then
        Say(string.format("Watching: %s; marker: %s; sound: %s; flash: %s; waypoint: %s; every %ss.",
            OnOff(db.enabled), db.marker > 0 and RAID_MARKS[db.marker] or "none", OnOff(db.sound),
            OnOff(db.flash), OnOff(db.waypoint), db.interval))
        ListWatched()
        if command == "" then
            Say("/qrare on | off, /qrare list")
            Say("/qrare add <name> | remove <name> - watch any mob by name, everywhere")
            Say("/qrare mark <0-8> - raid marker to put on it (0 = none)")
            Say("/qrare sound | flash | waypoint - toggle that part of the alert")
            Say("/qrare nameplates - turn on enemy nameplates and raise their range (better detection)")
            Say("/qrare test - show a test alert")
            Say("Key binding: Options > Keybindings > AddOns > \"Scan for rare quest mobs\".")
        end
    elseif command == "add" and rest ~= "" then
        db.manual[rest:lower()] = rest
        Say("Watching for " .. rest .. " everywhere.")
        Rebuild()
    elseif command == "remove" and rest ~= "" then
        db.manual[rest:lower()] = nil
        Say("Stopped watching for " .. rest .. " (quest mobs are still watched while needed).")
        Rebuild()
    elseif command == "mark" and tonumber(rest) then
        db.marker = math.max(0, math.min(8, math.floor(tonumber(rest))))
        Say("Raid marker: " .. (db.marker > 0 and RAID_MARKS[db.marker] or "none") .. ".")
    elseif command == "sound" or command == "flash" or command == "waypoint" then
        db[command] = not db[command]
        Say(command .. ": " .. OnOff(db[command]) .. ".")
    elseif command == "nameplates" then
        if InCombatLockdown() then Say("Not in combat.") return end
        SetCVar("nameplateShowEnemies", 1)
        -- Only ever raise it (EllesmereUINameplates sets 60); the client clamps to its own max.
        local current = tonumber(GetCVar("nameplateMaxDistance")) or 0
        if current < 60 then pcall(SetCVar, "nameplateMaxDistance", 60) end
        Say(string.format("Enemy nameplates on, range %s yards (the game's limit applies).",
            tostring(GetCVar("nameplateMaxDistance"))))
    elseif command == "test" then
        Alert({ name = "Test Rare", quests = { [0] = "Test Quest" } }, nil, nil)
    else
        SlashHandler("")
    end
end

-------------------------------------------------------------------------------
--  Events
-------------------------------------------------------------------------------
local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= addonName then return end
        events:UnregisterEvent("ADDON_LOADED")
        if type(QuestieRareObjectivesDB) ~= "table" then QuestieRareObjectivesDB = {} end
        db = QuestieRareObjectivesDB
        for k, v in pairs(defaults) do
            if type(db[k]) ~= type(v) then db[k] = type(v) == "table" and {} or v end
        end
        SLASH_QUESTIERAREOBJECTIVES1 = "/qrare"
        SlashCmdList.QUESTIERAREOBJECTIVES = SlashHandler
        if type(QuestDB) ~= "table" or type(NpcDB) ~= "table" then
            Say("QuestieDB's data (QuestDB / NpcDB) was not found; only mobs added with /qrare add are watched.")
        end
        BuildScanButton()
        for _, e in ipairs({ "PLAYER_ENTERING_WORLD", "QUEST_LOG_UPDATE", "QUEST_ACCEPTED", "QUEST_REMOVED",
            "ZONE_CHANGED", "ZONE_CHANGED_NEW_AREA", "ZONE_CHANGED_INDOORS", "PLAYER_REGEN_ENABLED",
            "NAME_PLATE_UNIT_ADDED", "PLAYER_TARGET_CHANGED", "UPDATE_MOUSEOVER_UNIT" }) do
            events:RegisterEvent(e)
        end
        pcall(events.RegisterEvent, events, "VIGNETTES_UPDATED")
        pcall(events.RegisterEvent, events, "VIGNETTE_MINIMAP_UPDATED")
        C_Timer.NewTicker(db.interval, function()
            local ok, err = pcall(Scan)
            if not ok then Say("error: " .. tostring(err)) end
        end)
    elseif event == "NAME_PLATE_UNIT_ADDED" then
        if db.enabled then pcall(CheckUnit, arg1) end
    elseif event == "PLAYER_TARGET_CHANGED" then
        if db.enabled then pcall(CheckUnit, "target") end
    elseif event == "UPDATE_MOUSEOVER_UNIT" then
        if db.enabled then pcall(CheckUnit, "mouseover") end
    elseif event == "VIGNETTES_UPDATED" or event == "VIGNETTE_MINIMAP_UPDATED" then
        if db.enabled and next(activeByName) then pcall(CheckVignettes) end
    elseif event == "PLAYER_REGEN_ENABLED" then
        if macroPending then UpdateMacro() end
    else
        -- Quest log or zone changed
        QueueRebuild()
    end
end)
