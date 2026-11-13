-------------------------------------------------------------------------------
--  EllesmereUI Quest Tracker - Quest Items
--
--  Puts a small item icon right of a tracked quest's title when its objective
--  needs you to *use* an item, e.g. "Drive Them Back": use Swineherd's Staff
--  on Young Paletusks. Hover the icon for the item's tooltip. The icon is
--  greyed out while the item is not in your bags.
--
--  Which items count, per quest:
--    1. Blizzard's quest item (GetQuestLogSpecialItemInfo), if the client
--       flags one for the quest; it always counts.
--    2. QuestieDB's sourceItemId (the item the quest hands you) and
--       requiredSourceItems, if the item has a "Use:" spell
--       (C_Item.GetItemSpell). Items you only collect or deliver have no use
--       spell, so they're skipped.
--  Hidden once the quest is complete (Blizzard's item may ask to stay).
--
--  Public surfaces used:
--    EllesmereUI.RegisterQuestTrackerRow(id, fn, width) and
--    EllesmereUI.RefreshQuestTrackerRows() (EllesmereUI PLUGINS_API.md, v5):
--      fn(slot, questID, title) runs for every quest title row of the Custom
--      Quest Tracker; slot is our own frame right of the title.
--    QuestDB.Get(questId, field) (QuestieDB's global), else Questie's
--      QuestieDB.QueryQuestSingle via QuestieLoader.
--    Blizzard item/quest log APIs.
--  If the row API is missing (EllesmereUI update, or not the Forever client)
--  a chat warning is printed and nothing else happens.
--
--  Taint: everything is plain insecure frames on the slot EllesmereUI gives
--  us (its rows are insecure Buttons). No secure frames, nothing written to
--  EllesmereUI's frames; per-slot state lives in a weak-keyed local table.
-------------------------------------------------------------------------------
local addonName = ...

local PREFIX = "|cff0cd29fEUI Quest Items:|r "
local SLOT_WIDTH = 18

local defaults = {
    enabled = true,
    showMissing = true, -- also show the icon (greyed) when the item isn't in your bags
}

local db
local icons = setmetatable({}, { __mode = "k" }) -- slot -> icon frame
local questItems = {}  -- questID -> { itemID, ... } (static data, cached)
local waiting = {}     -- itemID -> true: item data requested, re-check when it loads
local anyShown = false

local function Say(message)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. message)
    end
end

-------------------------------------------------------------------------------
--  Data
-------------------------------------------------------------------------------
local QueryQuestField
do
    local questieDB
    QueryQuestField = function(questID, field)
        if type(QuestDB) == "table" and type(QuestDB.Get) == "function" then
            local ok, value = pcall(QuestDB.Get, questID, field)
            if ok then return value end
        end
        if questieDB == nil and type(QuestieLoader) == "table" and type(QuestieLoader.ImportModule) == "function" then
            local ok, mod = pcall(QuestieLoader.ImportModule, QuestieLoader, "QuestieDB")
            questieDB = ok and type(mod) == "table" and mod or false
        end
        if questieDB and type(questieDB.QueryQuestSingle) == "function" then
            local ok, value = pcall(questieDB.QueryQuestSingle, questID, field)
            if ok then return value end
        end
    end
end

local GetItemSpell = (C_Item and C_Item.GetItemSpell) or GetItemSpell

local function ItemCount(itemID)
    if C_Item and C_Item.GetItemCount then return C_Item.GetItemCount(itemID) or 0 end
    return GetItemCount and GetItemCount(itemID) or 0
end

local function ItemIcon(itemID)
    if C_Item and C_Item.GetItemIconByID then return C_Item.GetItemIconByID(itemID) end
    return GetItemIcon and GetItemIcon(itemID)
end

local function ItemName(itemID)
    if C_Item and C_Item.GetItemNameByID then return C_Item.GetItemNameByID(itemID) end
    return (GetItemInfo(itemID))
end

-- true = has a use spell, false = no, nil = item data not loaded yet (requested)
local function IsUsable(itemID)
    if GetItemSpell and GetItemSpell(itemID) then return true end
    local cached = C_Item and C_Item.IsItemDataCachedByID and C_Item.IsItemDataCachedByID(itemID)
    if cached == false then
        if not waiting[itemID] then
            waiting[itemID] = true
            if C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(itemID) end
        end
        return nil
    end
    return false
end

local function NativeItem(questID)
    if not GetQuestLogSpecialItemInfo or not C_QuestLog.GetLogIndexForQuestID then return end
    local logIndex = C_QuestLog.GetLogIndexForQuestID(questID)
    if not logIndex then return end
    local link, _, _, showWhenComplete = GetQuestLogSpecialItemInfo(logIndex)
    local itemID = link and tonumber(link:match("item:(%d+)"))
    return itemID, showWhenComplete
end

-- The quest's usable items from QuestieDB, cached once all item data loaded.
local function DatabaseItems(questID)
    local cached = questItems[questID]
    if cached then return cached end
    local list, complete, seen = {}, true, {}
    local function Consider(itemID)
        itemID = tonumber(itemID)
        if not itemID or itemID <= 0 or seen[itemID] then return end
        seen[itemID] = true
        local usable = IsUsable(itemID)
        if usable then list[#list + 1] = itemID
        elseif usable == nil then complete = false end
    end
    Consider(QueryQuestField(questID, "sourceItemId"))
    local required = QueryQuestField(questID, "requiredSourceItems")
    if type(required) == "table" then
        for _, itemID in ipairs(required) do Consider(itemID) end
    end
    if complete then questItems[questID] = list end
    return list
end

-- All items to show for the quest right now, Blizzard's first.
local function ItemsFor(questID)
    local out = {}
    local complete = C_QuestLog.IsComplete(questID) == true
    local native, showWhenComplete = NativeItem(questID)
    if native and (not complete or showWhenComplete) then out[1] = native end
    if not complete then
        for _, itemID in ipairs(DatabaseItems(questID)) do
            if itemID ~= native then out[#out + 1] = itemID end
        end
    end
    if not db.showMissing then
        for i = #out, 1, -1 do
            if ItemCount(out[i]) == 0 then table.remove(out, i) end
        end
    end
    return out
end

-------------------------------------------------------------------------------
--  Icon
-------------------------------------------------------------------------------
local function OnEnter(self)
    local list = self.items
    if not list or not list[1] then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetItemByID(list[1])
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Use this item for the quest's objective.", 0.05, 0.82, 0.62, true)
    if ItemCount(list[1]) == 0 then
        GameTooltip:AddLine("Not in your bags.", 1, 0.3, 0.3)
    end
    for i = 2, #list do
        local name = ItemName(list[i]) or ("item " .. list[i])
        GameTooltip:AddLine("Also uses: |T" .. (ItemIcon(list[i]) or 134400) .. ":0|t " .. name, 1, 1, 1, true)
    end
    GameTooltip:Show()
end

local function OnLeave()
    GameTooltip:Hide()
end

local function GetIcon(slot)
    local f = icons[slot]
    if f then return f end
    f = CreateFrame("Frame", nil, slot)
    f:EnableMouse(true)
    f.tex = f:CreateTexture(nil, "ARTWORK")
    f.tex:SetAllPoints()
    f.tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    f:SetScript("OnEnter", OnEnter)
    f:SetScript("OnLeave", OnLeave)
    icons[slot] = f
    return f
end

local function DecorateRow(slot, questID, title)
    local f = icons[slot]
    if not db.enabled or type(questID) ~= "number" then
        if f then f:Hide() end
        return
    end
    local list = ItemsFor(questID)
    if not list[1] then
        if f then f:Hide() end
        return
    end
    f = GetIcon(slot)
    local _, fontSize = title:GetFont()
    local size = math.floor((fontSize or 12) + 2)
    if f.size ~= size then
        f.size = size
        f:SetSize(size, size)
        f:ClearAllPoints()
        f:SetPoint("TOPLEFT", slot, "TOPLEFT", 2, 1)
    end
    f.items = list
    f.tex:SetTexture(ItemIcon(list[1]) or 134400)
    local owned = ItemCount(list[1]) > 0
    f.tex:SetDesaturated(not owned)
    f:SetAlpha(owned and 1 or 0.55)
    f:Show()
    anyShown = true
end

local function Refresh()
    if EllesmereUI and EllesmereUI.RefreshQuestTrackerRows then
        EllesmereUI.RefreshQuestTrackerRows()
    end
end

-------------------------------------------------------------------------------
--  Slash command
-------------------------------------------------------------------------------
local function OnOff(v) return v and "on" or "off" end

local function SlashHandler(message)
    local command, arg = (message or ""):lower():match("^%s*(%S*)%s*(.-)%s*$")
    if command == "on" or command == "off" then
        db.enabled = command == "on"
        Say("Icons " .. OnOff(db.enabled) .. ".")
        Refresh()
    elseif command == "missing" then
        db.showMissing = not db.showMissing
        Say("Show icon when the item isn't in your bags: " .. OnOff(db.showMissing) .. ".")
        Refresh()
    elseif command == "check" and tonumber(arg) then
        local questID = math.floor(tonumber(arg))
        local native = NativeItem(questID)
        Say(string.format("Quest %d: Blizzard quest item: %s.", questID, native and tostring(native) or "none"))
        local src = QueryQuestField(questID, "sourceItemId")
        local req = QueryQuestField(questID, "requiredSourceItems")
        local reqText = type(req) == "table" and table.concat(req, ", ") or "none"
        Say(string.format("QuestieDB: sourceItemId %s, requiredSourceItems %s.", tostring(src or "none"), reqText))
        questItems[questID] = nil
        local list = DatabaseItems(questID)
        if list[1] then
            for _, itemID in ipairs(list) do
                Say(string.format("  usable: %s (%d), in bags: %d", ItemName(itemID) or "?", itemID, ItemCount(itemID)))
            end
        else
            Say("  no usable items found" .. (next(waiting) and " (some item data still loading, try again)" or "") .. ".")
        end
    else
        Say(string.format("Icons: %s; show when not in bags: %s.", OnOff(db.enabled), OnOff(db.showMissing)))
        Say("/eqi on | off - show or hide the quest item icons")
        Say("/eqi missing - toggle showing the (greyed) icon when the item isn't in your bags")
        Say("/eqi check <questID> - which items a quest uses")
        Say("Icons appear in EllesmereUI's Custom Quest Tracker only.")
    end
end

-------------------------------------------------------------------------------
--  Events
-------------------------------------------------------------------------------
local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:SetScript("OnEvent", function(_, event, arg1, arg2)
    if event == "ADDON_LOADED" then
        if arg1 ~= addonName then return end
        events:UnregisterEvent("ADDON_LOADED")
        if type(EUIQuestItemsDB) ~= "table" then EUIQuestItemsDB = {} end
        db = EUIQuestItemsDB
        for k, v in pairs(defaults) do
            if type(db[k]) ~= type(v) then db[k] = v end
        end
        SLASH_EUIQUESTITEMS1 = "/eqi"
        SlashCmdList.EUIQUESTITEMS = SlashHandler
        if not (EllesmereUI and EllesmereUI.RegisterQuestTrackerRow) then
            Say("EllesmereUI.RegisterQuestTrackerRow not found (EllesmereUI update?); no icons.")
            return
        end
        EllesmereUI.RegisterQuestTrackerRow(addonName, DecorateRow, SLOT_WIDTH)
        events:RegisterEvent("BAG_UPDATE_DELAYED")
        events:RegisterEvent("ITEM_DATA_LOAD_RESULT")
    elseif event == "BAG_UPDATE_DELAYED" then
        -- Owned / not owned shading; only worth a redraw if an icon is up.
        -- (With showMissing off, a looted item can make a new icon appear.)
        if anyShown or not db.showMissing then anyShown = false; Refresh() end
    elseif event == "ITEM_DATA_LOAD_RESULT" then
        if waiting[arg1] then
            waiting[arg1] = nil
            -- Lists built while this item was loading weren't cached; rebuild.
            Refresh()
        end
    end
end)
