-------------------------------------------------------------------------------
--  Questie - Sub-Quest Filter
--
--  Problem: while a parent quest is in the log, Questie draws its child quests
--  (QuestieDB "childQuests" / "parentQuest") as available, skipping almost
--  all requirement checks:
--    * AvailableQuests' local _DrawChildQuests only checks race, completion,
--      exclusiveTo and pre-quests, then draws the child right away;
--    * AvailableQuests.IsLevelRequirementsFulfilled returns true for any
--      quest whose parent is active, so the level check is skipped as well.
--  So a sub-quest shows on the map and in NPC tooltips even when you are too
--  low level, lack the reputation/profession/class, or a follow-up is done.
--
--  Fix: a sub-quest (parent quest in the log) is drawn only if
--    1. its required level <= your level (and you're not above its max level),
--    2. QuestieDB.IsDoable(questId) is true (Questie's full requirement check:
--       class, race, rep, skill, pre-quests, follow-ups, breadcrumbs, spells,
--       exclusive quests, dailies...).
--  Quests an NPC actually offers you (seen in gossip / quest detail) are
--  always allowed this session, since the game itself says you can take them.
--  Nothing is hidden permanently: every check is re-run on each Questie pass.
--
--  Public surfaces used (Questie modules via the global QuestieLoader):
--    AvailableQuests.DrawAvailableQuest(quest) -> wrapped; every starter icon
--        and starter tooltip goes through it, so blocking it hides both.
--    AvailableQuests.CalculateAndDrawAll(cb)   -> wrapped to pass an extra
--        callback that, after each pass, removes sub-quests already drawn
--        that are no longer ready (AvailableQuests.RemoveQuest).
--    QuestieDB.IsDoable / QueryQuestSingle / activeChildQuests,
--    QuestieLib.GetEffectiveQuestLevel, ActiveQuests.Get.
--  Every Questie call site uses the module table, so the wrappers see all
--  calls. If something is missing after an update, a chat warning is printed
--  and Questie keeps working unfiltered.
--
--  Taint: Questie's map icons are insecure frames and we never touch them;
--  we only filter Lua calls. No secure frames involved.
-------------------------------------------------------------------------------
local addonName = ...

local PREFIX = "|cffffd100Questie Sub-Quest Filter:|r "

local defaults = {
    enabled = true,
}

local db
local AvailableQuests, QuestieDB, QuestieLib, ActiveQuests
local hooked = false

local blocked = {} -- [questId] = reason string (sub-quests currently hidden)
local offered = {} -- [questId] = true (an NPC offered it this session)

local function Say(message)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. message)
    end
end

-------------------------------------------------------------------------------
--  Rules
-------------------------------------------------------------------------------
local function Query(questId, field)
    local ok, value = pcall(QuestieDB.QueryQuestSingle, questId, field)
    if ok then return value end
end

local function PlayerLevel()
    return UnitLevel("player") or 1
end

-- A sub-quest is a quest Questie treats as available because its parent is in
-- the log (either from _DrawChildQuests or from the parent level bypass).
local function IsSubQuest(questId)
    if type(questId) ~= "number" then return false end
    if QuestieDB.activeChildQuests and QuestieDB.activeChildQuests[questId] then
        return true
    end
    local parent = Query(questId, "parentQuest")
    return parent and parent ~= 0 and ActiveQuests.Get(parent) ~= nil or false
end

-- Returns nil if the quest is ready to pick up, else a short reason.
local function NotReadyReason(questId)
    local level = PlayerLevel()
    local ok, _, requiredLevel, requiredMaxLevel = pcall(QuestieLib.GetEffectiveQuestLevel, questId, level)
    if ok then
        if requiredLevel and requiredLevel > level then
            return "requires level " .. requiredLevel
        end
        if requiredMaxLevel and requiredMaxLevel ~= 0 and level > requiredMaxLevel then
            return "max level " .. requiredMaxLevel
        end
    end
    local okDoable, doable = pcall(QuestieDB.IsDoable, questId, false)
    if okDoable and doable == false then
        return "requirements not met"
    end
    return nil
end

-- true = let Questie draw it
local function ShouldShow(questId)
    if not db.enabled or offered[questId] or not IsSubQuest(questId) then
        blocked[questId] = nil
        return true
    end
    local reason = NotReadyReason(questId)
    blocked[questId] = reason
    return reason == nil
end

-------------------------------------------------------------------------------
--  Sweep: remove sub-quests that were drawn but are no longer ready
-------------------------------------------------------------------------------
local function Sweep()
    if not db.enabled then return end
    local drawn = AvailableQuests.__availableQuests
    if type(drawn) ~= "table" then return end
    local toRemove = {}
    for questId in pairs(drawn) do
        if not ShouldShow(questId) then
            toRemove[#toRemove + 1] = questId
        end
    end
    for i = 1, #toRemove do
        pcall(AvailableQuests.RemoveQuest, toRemove[i])
    end
end

-------------------------------------------------------------------------------
--  Offered quests (the game says you can take them)
-------------------------------------------------------------------------------
local function MarkOffered(questId)
    if type(questId) ~= "number" or questId <= 0 or offered[questId] then return end
    offered[questId] = true
    if blocked[questId] then
        blocked[questId] = nil
        local ok, quest = pcall(QuestieDB.GetQuest, questId)
        if ok and quest then pcall(AvailableQuests.DrawAvailableQuest, quest) end
    end
end

local function OnGossipShow()
    if C_GossipInfo and C_GossipInfo.GetAvailableQuests then
        local ok, list = pcall(C_GossipInfo.GetAvailableQuests)
        if ok and type(list) == "table" then
            for _, info in pairs(list) do MarkOffered(info.questID) end
        end
    end
end

local function OnQuestDetail()
    if GetQuestID then MarkOffered(GetQuestID()) end
end

-------------------------------------------------------------------------------
--  Hooks
-------------------------------------------------------------------------------
local function InstallHooks()
    if type(QuestieLoader) ~= "table" or type(QuestieLoader.ImportModule) ~= "function" then
        Say("Questie's QuestieLoader was not found; sub-quests won't be filtered.")
        return
    end
    AvailableQuests = QuestieLoader:ImportModule("AvailableQuests")
    QuestieDB = QuestieLoader:ImportModule("QuestieDB")
    QuestieLib = QuestieLoader:ImportModule("QuestieLib")
    ActiveQuests = QuestieLoader:ImportModule("ActiveQuests")
    if type(AvailableQuests) ~= "table" or type(AvailableQuests.DrawAvailableQuest) ~= "function"
        or type(AvailableQuests.CalculateAndDrawAll) ~= "function" or type(AvailableQuests.RemoveQuest) ~= "function"
        or type(QuestieDB) ~= "table" or type(QuestieDB.IsDoable) ~= "function" or type(QuestieDB.QueryQuestSingle) ~= "function"
        or type(QuestieLib) ~= "table" or type(QuestieLib.GetEffectiveQuestLevel) ~= "function"
        or type(ActiveQuests) ~= "table" or type(ActiveQuests.Get) ~= "function" then
        Say("A Questie function this addon needs was not found (Questie update?); sub-quests won't be filtered.")
        return
    end

    local origDraw = AvailableQuests.DrawAvailableQuest
    AvailableQuests.DrawAvailableQuest = function(quest, ...)
        local ok, show = pcall(ShouldShow, type(quest) == "table" and quest.Id)
        if ok and not show then return end
        return origDraw(quest, ...)
    end

    local origCalc = AvailableQuests.CalculateAndDrawAll
    AvailableQuests.CalculateAndDrawAll = function(callback, ...)
        local function after()
            local ok, err = pcall(Sweep)
            if not ok then Say("error: " .. tostring(err)) end
            if callback then callback() end
        end
        return origCalc(after, ...)
    end

    hooked = true
end

local function Redraw()
    if hooked then AvailableQuests.CalculateAndDrawAll() end
end

-------------------------------------------------------------------------------
--  Slash command
-------------------------------------------------------------------------------
local function QuestLabel(questId)
    local name = QuestieDB and Query(questId, "name")
    return string.format("%s (%d)", name or "?", questId)
end

local function SlashHandler(message)
    local command, arg = (message or ""):lower():match("^%s*(%S*)%s*(.-)%s*$")
    if command == "on" or command == "off" then
        db.enabled = command == "on"
        if not db.enabled then wipe(blocked) end
        Say("Filter " .. (db.enabled and "on" or "off") .. ".")
        Redraw()
    elseif command == "list" then
        local n = 0
        for questId, reason in pairs(blocked) do
            n = n + 1
            Say(QuestLabel(questId) .. ": " .. reason)
        end
        if n == 0 then Say("No sub-quests hidden right now.") end
    elseif command == "check" and tonumber(arg) then
        if not hooked then Say("Not active (Questie hooks missing).") return end
        local id = math.floor(tonumber(arg))
        if not IsSubQuest(id) then
            Say(QuestLabel(id) .. " is not a sub-quest of a quest in your log; Questie's normal rules apply.")
        elseif offered[id] then
            Say(QuestLabel(id) .. " was offered by an NPC, so it is shown.")
        else
            local reason = NotReadyReason(id)
            Say(QuestLabel(id) .. ": " .. (reason and ("hidden, " .. reason) or "ready, shown"))
        end
    elseif command == "refresh" then
        Redraw()
        Say("Redrawing Questie's available quests.")
    else
        Say(string.format("Filter is %s%s.", db.enabled and "on" or "off", hooked and "" or " (inactive: Questie hooks missing)"))
        Say("/qsub on | off - hide sub-quests until you can pick them up")
        Say("/qsub list - sub-quests hidden right now, and why")
        Say("/qsub check <questId> - why a quest is shown or hidden")
        Say("/qsub refresh - redraw Questie's available quests")
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
        if type(QuestieSubQuestFilterDB) ~= "table" then QuestieSubQuestFilterDB = {} end
        db = QuestieSubQuestFilterDB
        for k, v in pairs(defaults) do
            if type(db[k]) ~= type(v) then db[k] = v end
        end
        -- Settings of the removed "hide quests NPCs didn't offer" feature
        db.talkFilter, db.verbose = nil, nil
        SLASH_QUESTIESUBQUESTFILTER1 = "/qsub"
        SlashCmdList.QUESTIESUBQUESTFILTER = SlashHandler
        InstallHooks()
        if hooked then
            events:RegisterEvent("GOSSIP_SHOW")
            events:RegisterEvent("QUEST_DETAIL")
        end
    elseif event == "GOSSIP_SHOW" then
        pcall(OnGossipShow)
    elseif event == "QUEST_DETAIL" then
        pcall(OnQuestDetail)
    end
end)
