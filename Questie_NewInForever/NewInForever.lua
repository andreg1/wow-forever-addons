-------------------------------------------------------------------------------
--  Questie - New in Forever
--
--  Puts a small star on Questie's world map icons for quests that are new in
--  WoW Forever, i.e. not part of original 1.12 Classic.
--
--  How "new" is decided: every original Classic quest has an ID below 10000.
--  QuestieDB's Forever data adds ~1630 quests above that: ~1400 in the 90000s
--  (Forever's own zones and stories) and ~230 from 60000-89999 (later
--  Era/SoD-style additions Forever also uses). db.minId sets the cutoff, so
--  "/qnew min 90000" marks only Forever's own block.
--
--  Public surfaces used (Questie modules via the global QuestieLoader):
--    QuestieMap:DrawWorldIcon(data, ...)  -> wrapped; data.Id is the quest ID,
--        data.Type is "available" / "complete" / objective types; it returns
--        the world map icon and the minimap icon.
--    QuestieFramePool:GetFrame()          -> wrapped; Questie recycles icon
--        frames (also for townsfolk/manual icons), so any badge is hidden as
--        soon as a frame is handed out again.
--    MapIconTooltip.ShowOnTooltip(icon, Tooltip, ...) -> wrapped; it collects
--        the hovered cluster's quest givers into Tooltip.npcAndObjectOrder
--        ({[giverName] = {[title] = {title, questId, ...}}}) and objective
--        quests into Tooltip.questOrder ({[questId] = ...}), then renders via
--        Tooltip:_Rebuild(), which re-reads those tables (Questie calls it
--        again on Shift). We prefix new quests' titles with the star, wrap
--        _Rebuild to add a legend line, and re-render.
--  Every call site uses method lookup (QuestieMap:DrawWorldIcon), so the
--  wrappers see all calls. If a function is missing after an update, a chat
--  warning is printed and that part is not hooked.
--
--  Taint: Questie's icons are plain insecure Buttons. The badge is a child
--  frame of our own on the icon (so it follows the icon's show/hide, position
--  and scale); no fields are written to Questie's frames, per-frame state
--  lives in weak-keyed local tables.
-------------------------------------------------------------------------------
local addonName = ...

local PREFIX = "|cffffd100Questie New in Forever:|r "
local STAR = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_1"
local CLASSIC_MAX = 10000

local defaults = {
    enabled = true,
    minimap = false,    -- also badge minimap icons
    turnins = true,     -- also badge "complete" (turn-in) icons
    objectives = false, -- also badge objective icons (mobs, objects, items)
    tooltip = true,     -- mark new quests in Questie's map icon tooltip
    minId = CLASSIC_MAX,
}

local STAR_INLINE = "|T" .. STAR .. ":0|t"
local marked = setmetatable({}, { __mode = "k" }) -- tooltip entry tables already prefixed

local db
local badges = setmetatable({}, { __mode = "k" }) -- icon frame -> badge holder
local drawn = setmetatable({}, { __mode = "k" })  -- icon frame -> true (seen in DrawWorldIcon)

local function Say(message)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. message)
    end
end

-------------------------------------------------------------------------------
--  Rules
-------------------------------------------------------------------------------
local function IsNewQuest(questId)
    return type(questId) == "number" and questId >= db.minId
end

local function WantsIcon(frame)
    local data = frame.data
    if type(data) ~= "table" or not IsNewQuest(data.Id) then return false end
    if frame.miniMapIcon and not db.minimap then return false end
    local t = data.Type
    if t == "available" then return true end
    if t == "complete" then return db.turnins end
    if t == "manual" or t == nil then return false end
    return db.objectives
end

-------------------------------------------------------------------------------
--  Badge
-------------------------------------------------------------------------------
local function RaiseBadge(holder)
    -- Above neighbouring icons stacked on the same spot
    local parent = holder:GetParent()
    if parent then holder:SetFrameLevel(parent:GetFrameLevel() + 5) end
end

local function GetBadge(frame)
    local holder = badges[frame]
    if holder then return holder end
    holder = CreateFrame("Frame", nil, frame)
    holder:EnableMouse(false)
    -- Top-right quadrant of the icon, overhanging a little; scales with the icon
    holder:SetPoint("BOTTOMLEFT", frame, "CENTER", 1, 1)
    holder:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 3, 3)
    local tex = holder:CreateTexture(nil, "OVERLAY")
    tex:SetAllPoints(holder)
    tex:SetTexture(STAR)
    holder:SetScript("OnShow", RaiseBadge)
    holder:Hide()
    badges[frame] = holder
    return holder
end

local function HideBadge(frame)
    local holder = badges[frame]
    if holder then holder:Hide() end
end

local function Apply(frame)
    if not frame then return end
    if db.enabled and WantsIcon(frame) then
        local holder = GetBadge(frame)
        holder:Show()
        RaiseBadge(holder)
    else
        HideBadge(frame)
    end
end

local function RefreshAll()
    for frame in pairs(drawn) do
        if frame.data then Apply(frame) else HideBadge(frame) end
    end
end

-------------------------------------------------------------------------------
--  Tooltip
-------------------------------------------------------------------------------
local function QuestName(questId)
    if type(QuestDB) == "table" and type(QuestDB.Get) == "function" then
        local ok, name = pcall(QuestDB.Get, questId, "name")
        if ok and type(name) == "string" then return name end
    end
    return "Quest " .. tostring(questId)
end

-- Prefixes new quests among the givers/turn-ins; returns whether any were marked
-- and the names of new quests shown only through objective icons.
local function MarkTooltipData(Tooltip)
    local anyMarked = false
    for _, quests in pairs(type(Tooltip.npcAndObjectOrder) == "table" and Tooltip.npcAndObjectOrder or {}) do
        for _, entry in pairs(quests) do
            if type(entry) == "table" and IsNewQuest(entry.questId) and type(entry.title) == "string" then
                if not marked[entry] then
                    marked[entry] = true
                    entry.title = STAR_INLINE .. " " .. entry.title
                end
                anyMarked = true
            end
        end
    end
    local objectiveNames = {}
    for questId in pairs(type(Tooltip.questOrder) == "table" and Tooltip.questOrder or {}) do
        if IsNewQuest(questId) then objectiveNames[#objectiveNames + 1] = QuestName(questId) end
    end
    table.sort(objectiveNames)
    return anyMarked, objectiveNames
end

local function AddLegend(Tooltip, anyMarked, objectiveNames)
    if anyMarked and #objectiveNames == 0 then
        Tooltip:AddLine(STAR_INLINE .. " New in WoW Forever", 1, 0.82, 0)
    elseif #objectiveNames > 0 then
        Tooltip:AddLine(STAR_INLINE .. " New in WoW Forever: " .. table.concat(objectiveNames, ", "), 1, 0.82, 0, true)
    end
end

local function AfterShowOnTooltip(Tooltip, rebuildBefore)
    if not (db.enabled and db.tooltip) or type(Tooltip) ~= "table" then return end
    local rebuild = Tooltip._Rebuild
    -- Questie returns early (icon faded, hovered too fast) without a new _Rebuild
    if type(rebuild) ~= "function" or rebuild == rebuildBefore then return end
    local anyMarked, objectiveNames = MarkTooltipData(Tooltip)
    if not anyMarked and #objectiveNames == 0 then return end

    -- Questie's Shift handler calls Tooltip:_Rebuild() again; keep the legend there too
    Tooltip._Rebuild = function(self, ...)
        rebuild(self, ...)
        AddLegend(self, anyMarked, objectiveNames)
    end
    if Tooltip:IsShown() then
        Tooltip:ClearLines()
        Tooltip:_Rebuild()
        Tooltip:Show()
    end
end

-------------------------------------------------------------------------------
--  Hooks
-------------------------------------------------------------------------------
local function InstallTooltipHook()
    local MapIconTooltip = QuestieLoader:ImportModule("MapIconTooltip")
    if type(MapIconTooltip) ~= "table" or type(MapIconTooltip.ShowOnTooltip) ~= "function" then
        Say("MapIconTooltip.ShowOnTooltip not found (Questie update?); tooltips won't be marked.")
        return
    end
    local origShow = MapIconTooltip.ShowOnTooltip
    MapIconTooltip.ShowOnTooltip = function(icon, Tooltip, ...)
        local rebuildBefore = type(Tooltip) == "table" and Tooltip._Rebuild or nil
        origShow(icon, Tooltip, ...)
        local ok, err = pcall(AfterShowOnTooltip, Tooltip, rebuildBefore)
        if not ok then Say("tooltip error: " .. tostring(err)) end
    end
end

local function InstallHooks()
    if type(QuestieLoader) ~= "table" or type(QuestieLoader.ImportModule) ~= "function" then
        Say("Questie's QuestieLoader was not found; icons won't be marked.")
        return
    end
    local QuestieMap = QuestieLoader:ImportModule("QuestieMap")
    local QuestieFramePool = QuestieLoader:ImportModule("QuestieFramePool")
    if type(QuestieMap) ~= "table" or type(QuestieMap.DrawWorldIcon) ~= "function"
        or type(QuestieFramePool) ~= "table" or type(QuestieFramePool.GetFrame) ~= "function" then
        Say("QuestieMap:DrawWorldIcon or QuestieFramePool:GetFrame not found (Questie update?); icons won't be marked.")
        return
    end

    local origGetFrame = QuestieFramePool.GetFrame
    QuestieFramePool.GetFrame = function(...)
        local frame = origGetFrame(...)
        if frame then HideBadge(frame) end
        return frame
    end

    local origDraw = QuestieMap.DrawWorldIcon
    QuestieMap.DrawWorldIcon = function(...)
        local iconMap, iconMinimap = origDraw(...)
        if iconMap then
            drawn[iconMap] = true
            local ok, err = pcall(Apply, iconMap)
            if not ok then Say("error: " .. tostring(err)) end
        end
        if iconMinimap then
            drawn[iconMinimap] = true
            pcall(Apply, iconMinimap)
        end
        return iconMap, iconMinimap
    end

    InstallTooltipHook()
end

-------------------------------------------------------------------------------
--  Slash command
-------------------------------------------------------------------------------
local function OnOff(value) return value and "on" or "off" end

local function SlashHandler(message)
    local command, arg = (message or ""):lower():match("^%s*(%S*)%s*(.-)%s*$")
    if command == "on" or command == "off" then
        db.enabled = command == "on"
        Say("Stars " .. OnOff(db.enabled) .. ".")
    elseif command == "minimap" or command == "turnins" or command == "objectives" or command == "tooltip" then
        db[command] = not db[command]
        Say(command .. ": " .. OnOff(db[command]) .. ".")
    elseif command == "min" and tonumber(arg) then
        db.minId = math.max(1, math.floor(tonumber(arg)))
        Say(string.format("Quests with ID %d and up count as new.", db.minId))
    elseif command == "min" then
        db.minId = CLASSIC_MAX
        Say(string.format("Cutoff reset: quests with ID %d and up (everything not in original Classic).", db.minId))
    elseif command == "check" and tonumber(arg) then
        local id = math.floor(tonumber(arg))
        Say(string.format("Quest %d is %s.", id, IsNewQuest(id) and "|cff40ff40new|r" or "original Classic"))
        return
    else
        Say(string.format("Stars: %s; minimap: %s; turn-ins: %s; objectives: %s; tooltip: %s; new = quest ID >= %d.",
            OnOff(db.enabled), OnOff(db.minimap), OnOff(db.turnins), OnOff(db.objectives), OnOff(db.tooltip), db.minId))
        Say("/qnew on | off - show or hide the stars")
        Say("/qnew minimap | turnins | objectives | tooltip - toggle where stars are shown")
        Say("/qnew min <id> - cutoff (90000 = only Forever's own quests); /qnew min - reset to 10000")
        Say("/qnew check <questId> - is this quest new?")
        return
    end
    RefreshAll()
end

-------------------------------------------------------------------------------
--  Events
-------------------------------------------------------------------------------
local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:SetScript("OnEvent", function(_, event, arg1)
    if event ~= "ADDON_LOADED" or arg1 ~= addonName then return end
    events:UnregisterEvent("ADDON_LOADED")
    if type(QuestieNewInForeverDB) ~= "table" then QuestieNewInForeverDB = {} end
    db = QuestieNewInForeverDB
    for k, v in pairs(defaults) do
        if type(db[k]) ~= type(v) then db[k] = v end
    end
    SLASH_QUESTIENEWINFOREVER1 = "/qnew"
    SLASH_QUESTIENEWINFOREVER2 = "/questienew"
    SlashCmdList.QUESTIENEWINFOREVER = SlashHandler
    InstallHooks()
end)
