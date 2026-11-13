-------------------------------------------------------------------------------
--  QuestieDB - Search
--
--  A search window over the quest database that QuestieDB ships.
--
--    Search text      quests whose name or objective text contains every word
--    Leads into zone  quests that start outside a zone and either end at an
--                     NPC/object standing in it, or whose text names it
--    All / Alliance / Horde   faction filter on the results
--
--  /qs opens the window; "/qs <words>" and "/qs to <zone>" open it and search.
--
--  Public surfaces used:
--    QuestDB / NpcDB / ObjectDB globals (QuestieDB src/api.lua): GetAllIds(),
--        Get(id, fieldName). Quest fields: name, objectivesText, startedBy
--        {npcs, objects, items}, finishedBy {npcs, objects}, questLevel,
--        requiredRaces. NPC fields: name, spawns, friendlyToFaction ("A",
--        "H", "AH"). Object fields: name, spawns.
--    LibQuestieDB.Enum.zoneIDs / raceMaskById / factionRaceMasks.
--    Questie (optional): ZoneDB:GetAreaIdByName / GetUiMapIdByAreaId (so
--        subzones such as Powderfuse Port count as Riverglades) and
--        QuestieLink:GetQuestHyperLink for shift-click links.
--    Questie_NewInForever (optional): QuestieNewInForeverDB.minId for the
--        star on new quests (default: quest ID >= 10000).
--
--  Faction: a quest's requiredRaces decides when it restricts races. Many
--  Forever quests don't, so otherwise the quest givers' (else finishers')
--  friendlyToFaction decides; anything unclear counts for both sides.
--
--  Nothing is hooked or written; scans run a slice per frame so a pass over
--  ~6000 quests doesn't freeze the client. The window is our own insecure
--  frame and hides when combat starts.
-------------------------------------------------------------------------------
local addonName = ...

local PREFIX = "|cff7fd4ffQuest Search:|r "
local SLICE = 200        -- quests per frame while scanning
local ROWS = 20          -- visible result rows
local ROW_HEIGHT = 18
local STAR = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_1:0|t"

local defaults = {
    faction = "player", -- "player" (resolved at login), "All", "Alliance", "Horde"
    x = 0,
    y = 60,
    lastQuery = "",
}

local db
local ui
local allRows = {}       -- { id = questId, why = string? } from the last search
local viewRows = {}      -- allRows after the faction filter
local offset = 0
local scanToken = 0
local lastMode = "text"

local function Say(message)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. message)
    end
end

-------------------------------------------------------------------------------
--  Database access
-------------------------------------------------------------------------------
local function DBReady()
    return type(QuestDB) == "table" and type(QuestDB.GetAllIds) == "function"
        and type(QuestDB.Get) == "function"
end

local function EntityGet(entityDB, id, key)
    if type(entityDB) ~= "table" or type(entityDB.Get) ~= "function" then return nil end
    local ok, value = pcall(entityDB.Get, id, key)
    if ok then return value end
end

local function QGet(id, key) return EntityGet(QuestDB, id, key) end

local function QuestieModule(name)
    if type(QuestieLoader) == "table" and type(QuestieLoader.ImportModule) == "function" then
        local ok, module = pcall(QuestieLoader.ImportModule, QuestieLoader, name)
        if ok and type(module) == "table" then return module end
    end
end

local function IsNewQuest(questId)
    local minId = type(QuestieNewInForeverDB) == "table" and tonumber(QuestieNewInForeverDB.minId) or 10000
    return questId >= minId
end

-------------------------------------------------------------------------------
--  Zones
-------------------------------------------------------------------------------
local function UiMapOf(areaId)
    local ZoneDB = QuestieModule("ZoneDB")
    if ZoneDB and type(ZoneDB.GetUiMapIdByAreaId) == "function" then
        local ok, uiMapId = pcall(ZoneDB.GetUiMapIdByAreaId, ZoneDB, areaId)
        if ok then return uiMapId end
    end
end

local areaNames = {}
local function AreaName(areaId)
    local name = areaNames[areaId]
    if name == nil then
        name = false
        if C_Map and C_Map.GetAreaInfo then
            local ok, n = pcall(C_Map.GetAreaInfo, areaId)
            if ok and type(n) == "string" and n ~= "" then name = n end
        end
        areaNames[areaId] = name
    end
    return name or nil
end

-- Returns areaId and a display name for what the user typed
local function ResolveZone(input)
    local n = tonumber(input)
    if n then return n, AreaName(n) or tostring(n) end

    local enum = LibQuestieDB and LibQuestieDB.Enum and LibQuestieDB.Enum.zoneIDs
    local key = input:upper():gsub("^THE%s+", ""):gsub("'", ""):gsub("[^%w]+", "_")
    if type(enum) == "table" and type(enum[key]) == "number" then
        return enum[key], AreaName(enum[key]) or input
    end

    local ZoneDB = QuestieModule("ZoneDB")
    if ZoneDB and type(ZoneDB.GetAreaIdByName) == "function" then
        -- Names are case-sensitive here: try as typed, then Title Case
        local titled = input:lower():gsub("(%a)([%w']*)", function(a, b) return a:upper() .. b end)
        for _, name in ipairs({ input, titled, "The " .. titled }) do
            local ok, areaId = pcall(ZoneDB.GetAreaIdByName, ZoneDB, name)
            if ok and areaId then return areaId, name end
        end
    end

    -- Last resort: an enum key that contains the term (lowest ID wins)
    if type(enum) == "table" then
        local best
        for k, v in pairs(enum) do
            if type(v) == "number" and k:find(key, 1, true) and (not best or v < best) then
                best = v
            end
        end
        if best then return best, AreaName(best) or input end
    end
end

-- Builds a predicate: does this areaId belong to the target zone?
local function ZoneMatcher(targetArea)
    local targetMap = UiMapOf(targetArea)
    local cache = {}
    return function(areaId)
        if type(areaId) ~= "number" then return false end
        local hit = cache[areaId]
        if hit == nil then
            hit = areaId == targetArea or (targetMap ~= nil and UiMapOf(areaId) == targetMap)
            cache[areaId] = hit
        end
        return hit
    end
end

-------------------------------------------------------------------------------
--  Quest facts
-------------------------------------------------------------------------------
local GIVER_DBS = { "NpcDB", "ObjectDB" }

-- Calls fn(entityDB, id, isNpc) for each NPC/object in a startedBy/finishedBy table
local function EachGiver(givers, fn)
    if type(givers) ~= "table" then return end
    for index = 1, 2 do
        local entityDB = _G[GIVER_DBS[index]]
        for _, id in ipairs(type(givers[index]) == "table" and givers[index] or {}) do
            fn(entityDB, id, index == 1)
        end
    end
end

local function GiverAreas(givers)
    local areas = {}
    EachGiver(givers, function(entityDB, id)
        local spawns = EntityGet(entityDB, id, "spawns")
        if type(spawns) == "table" then
            for areaId in pairs(spawns) do areas[areaId] = true end
        end
    end)
    return areas
end

local function AnyIn(areas, inZone)
    for areaId in pairs(areas) do
        if inZone(areaId) then return true end
    end
    return false
end

-- "Name (Zone)" for the first NPC/object of a startedBy/finishedBy table
local function GiverLabel(givers)
    local label
    EachGiver(givers, function(entityDB, id)
        if label then return end
        local name = EntityGet(entityDB, id, "name")
        if type(name) ~= "string" then return end
        local spawns = EntityGet(entityDB, id, "spawns")
        local zone
        if type(spawns) == "table" then
            for areaId in pairs(spawns) do
                zone = AreaName(areaId)
                if zone then break end
            end
        end
        label = zone and (name .. " (" .. zone .. ")") or name
    end)
    if not label and type(givers) == "table" and type(givers[3]) == "table" and givers[3][1] then
        local itemName = EntityGet(ItemDB, givers[3][1], "name")
        label = "item: " .. (type(itemName) == "string" and itemName or ("#" .. givers[3][1]))
    end
    return label
end

local function QuestText(questId)
    local parts = { QGet(questId, "name") or "" }
    local objectives = QGet(questId, "objectivesText")
    if type(objectives) == "table" then
        for _, line in ipairs(objectives) do parts[#parts + 1] = tostring(line) end
    end
    return table.concat(parts, "\n"):lower()
end

-- Faction: "A", "H" or "both"
local factionCache = {}

local function HasBit(value, bitValue)
    return math.floor(value / bitValue) % 2 == 1
end

local function RaceSide(races)
    local enum = LibQuestieDB and LibQuestieDB.Enum
    if type(races) ~= "number" or races == 0 or not (enum and enum.raceMaskById and enum.factionRaceMasks) then
        return nil
    end
    -- Arithmetic bit tests: Forever's race bits 32/33 overflow the bit library
    local function Overlaps(mask)
        if type(mask) ~= "number" then return false end
        for _, bitValue in pairs(enum.raceMaskById) do
            if HasBit(races, bitValue) and HasBit(mask, bitValue) then return true end
        end
        return false
    end
    local a, h = Overlaps(enum.factionRaceMasks.Alliance), Overlaps(enum.factionRaceMasks.Horde)
    if a and not h then return "A" end
    if h and not a then return "H" end
    return "both"
end

local function NpcSide(givers)
    local npcs = type(givers) == "table" and type(givers[1]) == "table" and givers[1] or nil
    if not npcs then return nil end
    local a, h, known = false, false, false
    for _, npcId in ipairs(npcs) do
        local friendly = EntityGet(NpcDB, npcId, "friendlyToFaction")
        if type(friendly) == "string" and friendly ~= "" then
            known = true
            a = a or friendly:find("A", 1, true) ~= nil
            h = h or friendly:find("H", 1, true) ~= nil
        end
    end
    if not known then return nil end
    if a and not h then return "A" end
    if h and not a then return "H" end
    return "both"
end

local function QuestSide(questId)
    local side = factionCache[questId]
    if side then return side end
    side = RaceSide(QGet(questId, "requiredRaces"))
        or NpcSide(QGet(questId, "startedBy"))
        or NpcSide(QGet(questId, "finishedBy"))
        or "both"
    factionCache[questId] = side
    return side
end

local function PassesFilter(questId)
    local f = db.faction
    if f == "All" then return true end
    local side = QuestSide(questId)
    return side == "both" or (f == "Alliance" and side == "A") or (f == "Horde" and side == "H")
end

local function QuestLink(questId)
    local QuestieLink = QuestieModule("QuestieLink")
    if QuestieLink and type(QuestieLink.GetQuestHyperLink) == "function" and Questie and Questie.started then
        local ok, link = pcall(QuestieLink.GetQuestHyperLink, QuestieLink, questId)
        if ok and type(link) == "string" then return link end
    end
    return "[" .. tostring(QGet(questId, "name") or ("Quest " .. questId)) .. "] (#" .. questId .. ")"
end

local function LevelColor(level)
    if type(level) == "number" and level > 0 and GetQuestDifficultyColor then
        local ok, c = pcall(GetQuestDifficultyColor, level)
        if ok and type(c) == "table" and c.r then return c.r, c.g, c.b end
    end
    return 1, 1, 1
end

-------------------------------------------------------------------------------
--  Results view
-------------------------------------------------------------------------------
local SetStatus -- defined with the UI

local function SortByLevel(a, b)
    local la, lb = QGet(a.id, "questLevel") or 0, QGet(b.id, "questLevel") or 0
    if la ~= lb then return la < lb end
    return a.id < b.id
end

local function RenderRows()
    if not ui then return end
    for i = 1, ROWS do
        local row = ui.rows[i]
        local data = viewRows[offset + i]
        if data then
            local id = data.id
            local level = QGet(id, "questLevel")
            local side = QuestSide(id)
            row.questId = id
            row.why = data.why
            row.level:SetText(type(level) == "number" and level > 0 and level or "?")
            row.level:SetTextColor(LevelColor(level))
            row.name:SetText((IsNewQuest(id) and (STAR .. " ") or "") .. tostring(QGet(id, "name") or ("Quest " .. id)))
            row.side:SetText(side == "A" and "|cff4a9effAlliance|r" or side == "H" and "|cffff4040Horde|r" or "|cff999999Both|r")
            row.idText:SetText(id)
            row.start:SetText(GiverLabel(QGet(id, "startedBy")) or "|cff777777unknown|r")
            row:Show()
        else
            row.questId = nil
            row:Hide()
        end
    end
end

local function ApplyFilter()
    viewRows = {}
    for _, row in ipairs(allRows) do
        if PassesFilter(row.id) then viewRows[#viewRows + 1] = row end
    end
    if not ui then return end
    local maxOffset = math.max(0, #viewRows - ROWS)
    offset = math.min(offset, maxOffset)
    ui.scroll:SetMinMaxValues(0, maxOffset)
    ui.scroll:SetValue(offset)
    if maxOffset > 0 then ui.scroll:Show() else ui.scroll:Hide() end
    local hidden = #allRows - #viewRows
    ui.count:SetText(string.format("%d result%s%s", #viewRows, #viewRows == 1 and "" or "s",
        hidden > 0 and string.format(" |cff999999(%d hidden by the faction filter)|r", hidden) or ""))
    RenderRows()
end

local function Publish(rows, message)
    table.sort(rows, SortByLevel)
    allRows, offset = rows, 0
    ApplyFilter()
    SetStatus(message)
end

-------------------------------------------------------------------------------
--  Searches (sliced over frames; a new search cancels the running one)
-------------------------------------------------------------------------------
local function Scan(test, onDone, label)
    if not DBReady() then
        SetStatus("|cffff6060QuestieDB's QuestDB global was not found (QuestieDB update?).|r")
        return
    end
    scanToken = scanToken + 1
    local token = scanToken
    local ids = QuestDB.GetAllIds()
    local rows, i = {}, 0
    local function Step()
        if token ~= scanToken then return end
        local stop = math.min(#ids, i + SLICE)
        for j = i + 1, stop do
            local ok, keep, why = pcall(test, ids[j])
            if ok and keep then rows[#rows + 1] = { id = ids[j], why = why } end
        end
        i = stop
        if i < #ids then
            SetStatus(string.format("%s %d%%", label, math.floor(i * 100 / #ids)))
            C_Timer.After(0, Step)
        else
            onDone(rows)
        end
    end
    Step()
end

local function TextSearch(text)
    local words = {}
    for word in text:lower():gmatch("%S+") do words[#words + 1] = word end
    if #words == 0 then
        SetStatus("Type one or more words to search quest names and objectives.")
        return
    end
    Scan(function(id)
        local haystack = QuestText(id)
        for _, word in ipairs(words) do
            if not haystack:find(word, 1, true) then return false end
        end
        return true
    end, function(rows)
        Publish(rows, string.format("Quests whose name or objectives contain \"%s\".", text))
    end, "Searching...")
end

local function LeadsToSearch(input)
    if input == "" then
        SetStatus("Type a zone name (e.g. Riverglades) or area ID, then click Leads into zone.")
        return
    end
    local areaId, zoneName = ResolveZone(input)
    if not areaId then
        SetStatus("|cffff6060Unknown zone \"" .. input .. "\". Try the exact zone name or its area ID.|r")
        return
    end
    local inZone = ZoneMatcher(areaId)
    local needle = (zoneName or input):lower():gsub("^the%s+", "")
    Scan(function(id)
        if AnyIn(GiverAreas(QGet(id, "startedBy")), inZone) then return false end
        local endsInside = AnyIn(GiverAreas(QGet(id, "finishedBy")), inZone)
        local mentions = QuestText(id):find(needle, 1, true) ~= nil
        if endsInside and mentions then return true, "Ends in " .. zoneName .. " and names it" end
        if endsInside then return true, "Ends in " .. zoneName end
        if mentions then return true, "Objectives name " .. zoneName end
        return false
    end, function(rows)
        Publish(rows, string.format("Quests that start outside %s (area %d) and lead into it.", zoneName, areaId))
    end, "Scanning quests for " .. zoneName .. "...")
end

local function RunSearch(mode)
    if not ui then return end
    lastMode = mode or lastMode
    local text = ui.edit:GetText():match("^%s*(.-)%s*$")
    db.lastQuery = text
    ui.edit:ClearFocus()
    if lastMode == "zone" then LeadsToSearch(text) else TextSearch(text) end
end

-------------------------------------------------------------------------------
--  UI
-------------------------------------------------------------------------------
local COLUMNS = {
    { key = "level",  title = "Lvl",          x = 0,   width = 30,  justify = "CENTER" },
    { key = "name",   title = "Quest",        x = 34,  width = 230, justify = "LEFT" },
    { key = "side",   title = "Side",         x = 268, width = 60,  justify = "LEFT" },
    { key = "idText", title = "ID",           x = 330, width = 50,  justify = "LEFT" },
    { key = "start",  title = "Starts at",    x = 384, width = 250, justify = "LEFT" },
}

local function SavePosition(frame)
    local x, y = frame:GetCenter()
    local cx, cy = UIParent:GetCenter()
    if x and cx then db.x, db.y = x - cx, y - cy end
end

local function ShowRowTooltip(row)
    local id = row.questId
    if not id then return end
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:AddLine(tostring(QGet(id, "name") or ("Quest " .. id)), 1, 0.82, 0)
    local level, required = QGet(id, "questLevel"), QGet(id, "requiredLevel")
    local side = QuestSide(id)
    GameTooltip:AddLine(string.format("Level %s%s  -  Quest ID %d  -  %s",
        tostring(level or "?"), required and required > 0 and (" (requires " .. required .. ")") or "", id,
        side == "A" and "Alliance" or side == "H" and "Horde" or "Both factions"), 0.8, 0.8, 0.8)
    if IsNewQuest(id) then GameTooltip:AddLine(STAR .. " New in WoW Forever", 1, 0.82, 0) end
    if row.why then GameTooltip:AddLine(row.why, 0.5, 1, 0.5) end
    local objectives = QGet(id, "objectivesText")
    if type(objectives) == "table" and objectives[1] then
        GameTooltip:AddLine(" ")
        for _, line in ipairs(objectives) do GameTooltip:AddLine(tostring(line), 1, 1, 1, true) end
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddDoubleLine("Starts:", GiverLabel(QGet(id, "startedBy")) or "unknown", 0.6, 0.6, 0.6, 1, 1, 1)
    GameTooltip:AddDoubleLine("Ends:", GiverLabel(QGet(id, "finishedBy")) or "unknown", 0.6, 0.6, 0.6, 1, 1, 1)
    GameTooltip:AddLine("Shift-click to link in chat", 0.5, 0.5, 0.5)
    GameTooltip:Show()
end

local function OnRowClick(row)
    if not row.questId or not IsShiftKeyDown() then return end
    local link = QuestLink(row.questId)
    if not (ChatEdit_InsertLink and ChatEdit_InsertLink(link)) and ChatFrame_OpenChat then
        ChatFrame_OpenChat(link)
    end
end

local function UpdateFactionButtons()
    for name, button in pairs(ui.factionButtons) do
        if name == db.faction then button:LockHighlight() else button:UnlockHighlight() end
    end
end

local function MakeButton(parent, text, width)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width, 22)
    b:SetText(text)
    return b
end

local function BuildUI()
    local f = CreateFrame("Frame", "QuestieDBSearchFrame", UIParent, "BackdropTemplate")
    f:SetSize(680, 108 + ROWS * ROW_HEIGHT + 36)
    f:SetFrameStrata("HIGH")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePosition(self)
    end)
    f:SetBackdrop({
        bgFile = "Interface/Tooltips/UI-Tooltip-Background",
        edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    f:SetBackdropColor(0.04, 0.05, 0.07, 0.96)
    f:SetBackdropBorderColor(0.5, 0.83, 1, 0.9)
    f:SetPoint("CENTER", UIParent, "CENTER", db.x, db.y)
    tinsert(UISpecialFrames, "QuestieDBSearchFrame") -- Escape closes it

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 14, -12)
    title:SetText("Quest Search")

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 0, 0)

    -- Search row
    local edit = CreateFrame("EditBox", "QuestieDBSearchEditBox", f, "InputBoxTemplate")
    edit:SetSize(260, 22)
    edit:SetPoint("TOPLEFT", 20, -40)
    edit:SetAutoFocus(false)
    edit:SetText(db.lastQuery or "")
    edit:SetScript("OnEnterPressed", function() RunSearch() end)
    edit:SetScript("OnEscapePressed", edit.ClearFocus)

    local textButton = MakeButton(f, "Search text", 100)
    textButton:SetPoint("LEFT", edit, "RIGHT", 8, 0)
    textButton:SetScript("OnClick", function() RunSearch("text") end)

    local zoneButton = MakeButton(f, "Leads into zone", 120)
    zoneButton:SetPoint("LEFT", textButton, "RIGHT", 4, 0)
    zoneButton:SetScript("OnClick", function() RunSearch("zone") end)

    -- Faction filter
    local factionLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    factionLabel:SetPoint("TOPLEFT", edit, "BOTTOMLEFT", -4, -10)
    factionLabel:SetText("Show quests for:")
    ui = { frame = f, edit = edit, factionButtons = {}, rows = {} }
    local anchor = factionLabel
    for _, name in ipairs({ "All", "Alliance", "Horde" }) do
        local b = MakeButton(f, name, 74)
        b:SetPoint("LEFT", anchor, "RIGHT", anchor == factionLabel and 8 or 2, 0)
        b:SetScript("OnClick", function()
            db.faction = name
            UpdateFactionButtons()
            offset = 0
            ApplyFilter()
        end)
        ui.factionButtons[name] = b
        anchor = b
    end

    ui.count = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ui.count:SetPoint("LEFT", anchor, "RIGHT", 12, 0)
    ui.count:SetJustifyH("LEFT")

    -- Column headers
    local listTop = -100
    for _, col in ipairs(COLUMNS) do
        local h = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        h:SetPoint("TOPLEFT", 16 + col.x, listTop)
        h:SetWidth(col.width)
        h:SetJustifyH(col.justify)
        h:SetText(col.title)
    end

    -- Result rows
    local list = CreateFrame("Frame", nil, f)
    list:SetPoint("TOPLEFT", 12, listTop - 14)
    list:SetPoint("RIGHT", f, "RIGHT", -30, 0)
    list:SetHeight(ROWS * ROW_HEIGHT)
    list:EnableMouseWheel(true)
    for i = 1, ROWS do
        local row = CreateFrame("Button", nil, list)
        row:SetHeight(ROW_HEIGHT)
        row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_HEIGHT)
        row:SetPoint("RIGHT", list, "RIGHT", 0, 0)
        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        if i % 2 == 0 then
            local stripe = row:CreateTexture(nil, "BACKGROUND")
            stripe:SetAllPoints()
            stripe:SetColorTexture(1, 1, 1, 0.04)
        end
        for _, col in ipairs(COLUMNS) do
            local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            fs:SetPoint("LEFT", 4 + col.x, 0)
            fs:SetWidth(col.width)
            fs:SetJustifyH(col.justify)
            fs:SetWordWrap(false)
            row[col.key] = fs
        end
        row:SetScript("OnEnter", ShowRowTooltip)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        row:SetScript("OnClick", OnRowClick)
        row:Hide()
        ui.rows[i] = row
    end

    -- Scroll bar
    local scroll = CreateFrame("Slider", nil, f)
    scroll:SetOrientation("VERTICAL")
    scroll:SetPoint("TOPLEFT", list, "TOPRIGHT", 6, 0)
    scroll:SetPoint("BOTTOMLEFT", list, "BOTTOMRIGHT", 6, 0)
    scroll:SetWidth(14)
    local track = scroll:CreateTexture(nil, "BACKGROUND")
    track:SetAllPoints()
    track:SetColorTexture(1, 1, 1, 0.06)
    scroll:SetThumbTexture("Interface\\Buttons\\UI-ScrollBar-Knob")
    scroll:SetMinMaxValues(0, 0)
    scroll:SetValueStep(1)
    if scroll.SetObeyStepOnDrag then scroll:SetObeyStepOnDrag(true) end
    scroll:SetScript("OnValueChanged", function(_, value)
        local v = math.floor(value + 0.5)
        if v ~= offset then
            offset = v
            RenderRows()
        end
    end)
    list:SetScript("OnMouseWheel", function(_, delta)
        local minV, maxV = scroll:GetMinMaxValues()
        scroll:SetValue(math.max(minV, math.min(maxV, offset - delta * 3)))
    end)
    ui.scroll = scroll

    -- Status line
    ui.status = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    ui.status:SetPoint("BOTTOMLEFT", 16, 14)
    ui.status:SetPoint("RIGHT", f, "RIGHT", -16, 0)
    ui.status:SetJustifyH("LEFT")
    ui.status:SetWordWrap(false)

    f:Hide()
    UpdateFactionButtons()
    ApplyFilter()
    SetStatus("Search quest names and objectives, or type a zone and click Leads into zone. Hover a quest for details.")
end

SetStatus = function(message)
    if ui then ui.status:SetText(message or "") end
end

local function OpenUI(query, mode)
    if InCombatLockdown() then
        Say("Not available in combat.")
        return
    end
    if not ui then BuildUI() end
    ui.frame:Show()
    if query and query ~= "" then
        ui.edit:SetText(query)
        RunSearch(mode)
    end
end

-------------------------------------------------------------------------------
--  Slash command
-------------------------------------------------------------------------------
local function SlashHandler(message)
    message = (message or ""):match("^%s*(.-)%s*$")
    local command, rest = message:match("^(%S+)%s*(.-)$")
    if command and command:lower() == "to" and rest ~= "" then
        OpenUI(rest, "zone")
    elseif message ~= "" then
        OpenUI(message, "text")
    elseif ui and ui.frame:IsShown() then
        ui.frame:Hide()
    else
        OpenUI()
    end
end

-------------------------------------------------------------------------------
--  Events
-------------------------------------------------------------------------------
local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_REGEN_DISABLED")
events:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= addonName then return end
        events:UnregisterEvent("ADDON_LOADED")
        if type(QuestieDBSearchDB) ~= "table" then QuestieDBSearchDB = {} end
        db = QuestieDBSearchDB
        for k, v in pairs(defaults) do
            if type(db[k]) ~= type(v) then db[k] = v end
        end
        SLASH_QUESTIEDBSEARCH1 = "/qs"
        SLASH_QUESTIEDBSEARCH2 = "/questsearch"
        SlashCmdList.QUESTIEDBSEARCH = SlashHandler
    elseif event == "PLAYER_LOGIN" then
        if db.faction == "player" then
            local faction = UnitFactionGroup("player")
            db.faction = (faction == "Alliance" or faction == "Horde") and faction or "All"
        end
    elseif event == "PLAYER_REGEN_DISABLED" then
        if ui and ui.frame:IsShown() then ui.frame:Hide() end
    end
end)
