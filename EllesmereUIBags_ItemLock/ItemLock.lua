-------------------------------------------------------------------------------
--  EllesmereUIBags - Item Lock
--
--  A separate addon, so EllesmereUIBags can update without losing it. It only
--  uses EllesmereUIBags' public surfaces:
--    * EUI_Bags.RegisterItemOverlayIcon: the padlock on locked items, and which
--      bag slot is under the mouse (grid, list and bank views).
--    * EUI_CategoryManager:IsJunk: locked items are never junk, so Sell Junk
--      skips them.
--    * EUI_CategoryManager:RegisterVirtualCategory: a runtime-only "Locked"
--      category that claims every padlocked item (before the type and set-gear
--      rules, so they leave Armory / Item Set Gear). /itemlock category sets off
--      leaves gear-set-only items in Ellesmere's set categories.
--      Nothing is saved into Ellesmere's category settings; /itemlock category
--      off unregisters it. Another character's items (offline view, bag nil)
--      are not claimed, since locks are per character.
--  Everything else is plain Blizzard API.
--
--  Locks are per character, by item ID (every copy of the item is locked).
--  Alt+Right-click toggles a lock.
--
--  Gear sets: every item in one of the character's equipment sets is protected
--  the same way, with no lock needed (/itemlock sets off turns this off). It
--  goes by item ID, from C_EquipmentSet.GetItemIDs: GetItemLocations crashes
--  the WoW Forever client for some sets. Taking the item out of the set (or
--  deleting the set) lifts the protection.
--
--  Protection:
--    * Destroy: the delete confirmation is cancelled for a locked item.
--    * Sell by right-click at a merchant: a non-secure blocker covers the
--      hovered locked slot while a merchant is open, so the click never reaches
--      the slot (left-click and drag still pick the item up).
--    * Any other sale (dragging onto the merchant, other addons): the item is
--      bought back at once.
--
--  Taint: nothing is written onto Ellesmere's secure slot buttons. State lives
--  in our own weak tables; slots only get OnEnter / OnLeave hooks (out of
--  combat), and the blocker is placed by coordinates, never anchored to a slot.
-------------------------------------------------------------------------------
local addonName = ...

local LOCK_TEXTURE = "Interface\\AddOns\\" .. addonName .. "\\lock.tga"
local PREFIX = "|cff0cd29fItem Lock:|r "
local DELETE_POPUPS = {
    DELETE_ITEM = true,
    DELETE_GOOD_ITEM = true,
    DELETE_QUEST_ITEM = true,
    DELETE_GOOD_QUEST_ITEM = true,
}

local locked = {}  -- itemID -> true (the saved table once loaded)
local setItems = {}  -- itemID -> name of the first gear set holding it
local protectSets = true
local useCategory = true
local categorySets = true  -- gear-set items (blue padlock) go to Locked too
local CATEGORY_ID = "ItemLock"
local categoryRegistered = false
local categoryRefreshPending = false  -- a lock changed in combat: refresh after
local slots  = setmetatable({}, { __mode = "k" })  -- slot button -> { bag, slot, itemID }
local marks  = setmetatable({}, { __mode = "k" })  -- slot button -> padlock texture
local hooked = setmetatable({}, { __mode = "k" })
local hovered        -- the slot button under the mouse
local merchantOpen = false
local blocker
local buybackSnapshot = {}

local function Say(message)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. message)
    end
end

local function IsLocked(itemID)
    return itemID ~= nil and locked[itemID] == true
end

-- The gear set name when the item is protected by being in a set
local function SetName(itemID)
    return protectSets and itemID ~= nil and setItems[itemID] or nil
end

-- Locked, or in a gear set: can't be sold or destroyed
local function IsProtected(itemID)
    return IsLocked(itemID) or SetName(itemID) ~= nil
end

local function ItemIDFromLink(link)
    return type(link) == "string" and tonumber(link:match("item:(%d+)")) or nil
end

local function ItemText(itemID, link)
    if link then return link end
    local name, itemLink = C_Item.GetItemInfo(itemID)
    return itemLink or name or ("item " .. itemID)
end

-- Why an item is protected, for chat: "is locked" / "is in your gear set X"
local function Reason(itemID)
    if IsLocked(itemID) then return "is locked" end
    return "is in your gear set " .. (SetName(itemID) or "?")
end

-- How to lift the protection, for chat
local function UnlockHint(itemID)
    if IsLocked(itemID) then return "Alt+Right-click it in your bags to unlock it." end
    return "Remove it from the set first."
end

-- Public, for other addons or macros:
--   EllesmereUIBags_ItemLock.IsLocked(itemID)     locked with Alt+Right-click
--   EllesmereUIBags_ItemLock.IsProtected(itemID)  locked, or in a gear set
EllesmereUIBags_ItemLock = { IsLocked = IsLocked, IsProtected = IsProtected }

-------------------------------------------------------------------------------
--  Gear sets
-------------------------------------------------------------------------------
-- True when the set contents changed
local function RebuildSetItems()
    local fresh = {}
    local api = C_EquipmentSet
    if api and api.GetEquipmentSetIDs and api.GetItemIDs then
        local ok, setIDs = pcall(api.GetEquipmentSetIDs)
        for _, setID in ipairs(ok and setIDs or {}) do
            local name = api.GetEquipmentSetInfo and api.GetEquipmentSetInfo(setID)
            local okIDs, ids = pcall(api.GetItemIDs, setID)
            for _, itemID in pairs(okIDs and ids or {}) do
                if type(itemID) == "number" and itemID > 0 and not fresh[itemID] then
                    fresh[itemID] = name or ("set " .. setID)
                end
            end
        end
    end
    local changed = false
    for id, name in pairs(fresh) do
        if setItems[id] ~= name then changed = true break end
    end
    if not changed then
        for id in pairs(setItems) do
            if not fresh[id] then changed = true break end
        end
    end
    setItems = fresh
    return changed
end

-------------------------------------------------------------------------------
--  Padlocks
-------------------------------------------------------------------------------
local function Mark(btn)
    local m = marks[btn]
    if m then return m end
    local host = btn._textOverlay or btn
    m = host:CreateTexture(nil, "OVERLAY", nil, 7)
    m:SetTexture(LOCK_TEXTURE)
    m:SetPoint("BOTTOMLEFT", host, "BOTTOMLEFT", 1, 1)
    marks[btn] = m
    return m
end

local function ShowMark(btn, itemID)
    if not IsProtected(itemID) then
        if marks[btn] then marks[btn]:Hide() end
        return
    end
    local m = Mark(btn)
    -- Gold padlock for a lock, blue for gear-set protection only
    if IsLocked(itemID) then
        m:SetDesaturated(false)
        m:SetVertexColor(1, 1, 1)
    else
        m:SetDesaturated(true)
        m:SetVertexColor(0.55, 0.8, 1)
    end
    local host = btn._textOverlay or btn
    local width = host:GetWidth() or 0
    local size = width > 0 and math.max(10, math.min(16, math.floor(width * 0.4 + 0.5))) or 14
    m:SetSize(size, size)
    m:Show()
end

local function RepaintAll()
    for btn, s in pairs(slots) do
        ShowMark(btn, s.itemID)
    end
end

-------------------------------------------------------------------------------
--  The merchant blocker
-------------------------------------------------------------------------------
local Toggle  -- defined below

local function HideBlocker()
    if blocker and blocker:IsShown() then
        if GameTooltip:IsOwned(blocker) then GameTooltip:Hide() end
        blocker:Hide()
    end
    if blocker then blocker.owner = nil end
end

local function BlockerSlot()
    local s = blocker and blocker.owner and slots[blocker.owner]
    return s
end

local function BlockerPickup()
    local s = BlockerSlot()
    if s and not InCombatLockdown() then
        C_Container.PickupContainerItem(s.bag, s.slot)
    end
end

local function BuildBlocker()
    blocker = CreateFrame("Button", nil, UIParent)
    blocker:SetFrameStrata("TOOLTIP")
    blocker:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    blocker:RegisterForDrag("LeftButton")
    local tint = blocker:CreateTexture(nil, "OVERLAY")
    tint:SetAllPoints()
    tint:SetColorTexture(1, 0.25, 0.25, 0.15)
    blocker:SetScript("OnClick", function(_, button)
        local s = BlockerSlot()
        if not s then return end
        if button == "RightButton" then
            if IsAltKeyDown() then
                Toggle(s.bag, s.slot)
            else
                Say(ItemText(s.itemID, C_Container.GetContainerItemLink(s.bag, s.slot)) .. " "
                    .. Reason(s.itemID) .. ", so right-click is off at merchants. " .. UnlockHint(s.itemID))
            end
        elseif IsModifiedClick() then
            local link = C_Container.GetContainerItemLink(s.bag, s.slot)
            if link then HandleModifiedItemClick(link) end
        else
            BlockerPickup()
        end
    end)
    blocker:SetScript("OnDragStart", BlockerPickup)
    blocker:SetScript("OnReceiveDrag", BlockerPickup)
    blocker:SetScript("OnEnter", function(self)
        local s = BlockerSlot()
        if not s then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetBagItem(s.bag, s.slot)
        GameTooltip:Show()
    end)
    blocker:SetScript("OnLeave", function()
        HideBlocker()
        if hovered and not hovered:IsMouseOver() then hovered = nil end
    end)
    blocker:Hide()
end

local function UpdateBlocker()
    local btn = hovered
    local s = btn and slots[btn]
    local want = merchantOpen and s and IsProtected(s.itemID) and not InCombatLockdown()
        and btn:IsVisible() and btn:IsMouseOver()
    if not want then
        HideBlocker()
        return
    end
    if not blocker then BuildBlocker() end
    local left, bottom, width, height = btn:GetLeft(), btn:GetBottom(), btn:GetWidth(), btn:GetHeight()
    if not (left and bottom and width and height) then
        HideBlocker()
        return
    end
    -- Placed by coordinates: anchoring to the secure slot would make the
    -- blocker part of its protected anchor family.
    local scale = btn:GetEffectiveScale() / blocker:GetEffectiveScale()
    blocker.owner = btn
    blocker:ClearAllPoints()
    blocker:SetSize(width * scale, height * scale)
    blocker:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", left * scale, bottom * scale)
    blocker:Show()
    if GameTooltip:IsOwned(btn) then
        blocker:GetScript("OnEnter")(blocker)
    end
end

-------------------------------------------------------------------------------
--  Hover tracking, from EllesmereUIBags' overlay painter
-------------------------------------------------------------------------------
local function OnSlotEnter(btn)
    hovered = btn
    UpdateBlocker()
end

local function OnSlotLeave(btn)
    if hovered == btn and not (blocker and blocker:IsShown() and blocker.owner == btn) then
        hovered = nil
    end
end

local function Paint(btn, data)
    local info = data and data.info
    local itemID = info and info.itemID
    if itemID and data.bag and data.slot and data.slot > 0 then
        local s = slots[btn] or {}
        s.bag, s.slot, s.itemID = data.bag, data.slot, itemID
        slots[btn] = s
        if not hooked[btn] and not InCombatLockdown() then
            hooked[btn] = true
            btn:HookScript("OnEnter", OnSlotEnter)
            btn:HookScript("OnLeave", OnSlotLeave)
        end
    else
        slots[btn] = nil
    end
    ShowMark(btn, itemID)
    if blocker and blocker.owner == btn then UpdateBlocker() end
end

-------------------------------------------------------------------------------
--  Buyback safety net
-------------------------------------------------------------------------------
local function BuybackCounts()
    local counts = {}
    local total = GetNumBuybackItems and GetNumBuybackItems() or 0
    for i = 1, total do
        local id = ItemIDFromLink(GetBuybackItemLink(i))
        if id then counts[id] = (counts[id] or 0) + 1 end
    end
    return counts
end

local function SnapshotBuyback()
    buybackSnapshot = BuybackCounts()
end

local function CheckBuyback()
    if not merchantOpen then return end
    local counts = BuybackCounts()
    for id, count in pairs(counts) do
        if IsProtected(id) and count > (buybackSnapshot[id] or 0) then
            for i = GetNumBuybackItems(), 1, -1 do
                local link = GetBuybackItemLink(i)
                if ItemIDFromLink(link) == id then
                    BuybackItem(i)
                    buybackSnapshot = counts
                    buybackSnapshot[id] = count - 1
                    Say(ItemText(id, link) .. " " .. Reason(id) .. ", so it was bought back.")
                    return  -- MERCHANT_UPDATE fires again for the next one
                end
            end
        end
    end
    buybackSnapshot = counts
end

-------------------------------------------------------------------------------
--  "Locked" category
-------------------------------------------------------------------------------
-- Runs inside Ellesmere's classify pass (securecallfunction): reads only.
-- Every padlocked item: locked ones, and gear-set ones unless categorySets is off.
local function ClaimLocked(_, itemID, bag)
    if bag == nil then return false end
    if categorySets then return IsProtected(itemID) end
    return IsLocked(itemID)
end

local function CategoryManager()
    local manager = _G.EUI_CategoryManager
    if manager and type(manager.RegisterVirtualCategory) == "function" then return manager end
end

-- Registers or unregisters the category to match useCategory.
-- Returns false when Ellesmere's API is missing.
local function ApplyCategory()
    local manager = CategoryManager()
    if not manager then return false end
    if useCategory and not categoryRegistered then
        categoryRegistered = manager:RegisterVirtualCategory(CATEGORY_ID, {
            name = "Locked",
            icon = LOCK_TEXTURE,
            order = 0,
            classify = ClaimLocked,
        }) and true or false
    elseif not useCategory and categoryRegistered then
        manager:UnregisterVirtualCategory(CATEGORY_ID)
        categoryRegistered = false
    end
    return true
end

-------------------------------------------------------------------------------
--  Locking
-------------------------------------------------------------------------------
local function AfterLockChange()
    SnapshotBuyback()
    RepaintAll()
    UpdateBlocker()
    -- Junk and the Locked category follow the lock (IsJunk patch, ClaimLocked)
    if InCombatLockdown() then
        categoryRefreshPending = true
        return
    end
    local manager = categoryRegistered and CategoryManager()
    if manager and manager.RefreshVirtualCategories then
        -- Repaints the bags and an open bank on the next frame
        manager:RefreshVirtualCategories()
    elseif EUI_Bags and EUI_Bags.IsShown and EUI_Bags:IsShown() and EUI_Bags.RefreshInventory then
        EUI_Bags:RefreshInventory()
    end
end

local function SetLocked(itemID, lock, link)
    if not itemID then return end
    locked[itemID] = lock and true or nil
    local set = SetName(itemID)
    if lock then
        Say(ItemText(itemID, link) .. " locked: it can't be sold or destroyed.")
    elseif set then
        Say(ItemText(itemID, link) .. " unlocked, but it is still protected by your gear set " .. set .. ".")
    else
        Say(ItemText(itemID, link) .. " unlocked.")
    end
    AfterLockChange()
end

-- A gear-set item needs no lock: say so instead of locking it
local function ToggleItem(itemID, link)
    if not IsLocked(itemID) and SetName(itemID) then
        Say(ItemText(itemID, link) .. " is in your gear set " .. SetName(itemID)
            .. ", so it is already protected. Remove it from the set to sell or destroy it.")
        return
    end
    SetLocked(itemID, not IsLocked(itemID), link)
end

function Toggle(bag, slot)
    local itemID = C_Container.GetContainerItemID(bag, slot)
    if not itemID then return end
    ToggleItem(itemID, C_Container.GetContainerItemLink(bag, slot))
end

local function OnSetsChanged()
    if RebuildSetItems() then AfterLockChange() end
end

-------------------------------------------------------------------------------
--  Hooks
-------------------------------------------------------------------------------
local function MouseFocus()
    if GetMouseFoci then
        local foci = GetMouseFoci()
        return foci and foci[1]
    end
    return GetMouseFocus and GetMouseFocus()
end

local function OnAltRightClick()
    local btn = hovered
    local s = btn and slots[btn]
    if not s or not btn:IsVisible() or not btn:IsMouseOver() then return end
    -- Another frame over the slot took the click (the blocker handles its own;
    -- Ellesmere's Quick Actions cast button means that click was a cast).
    local focus = MouseFocus()
    if focus and focus ~= btn then return end
    Toggle(s.bag, s.slot)
end

local function HookDestroy()
    hooksecurefunc("StaticPopup_Show", function(which)
        if not DELETE_POPUPS[which] then return end
        local kind, itemID, link = GetCursorInfo()
        if kind == "item" and IsProtected(itemID) then
            StaticPopup_Hide(which)
            ClearCursor()
            Say(ItemText(itemID, link) .. " " .. Reason(itemID) .. " and can't be destroyed. " .. UnlockHint(itemID))
        end
    end)
end

local function HookTooltip()
    hooksecurefunc(GameTooltip, "SetBagItem", function(tooltip, bag, slot)
        local itemID = C_Container.GetContainerItemID(bag, slot)
        if IsLocked(itemID) then
            tooltip:AddLine("Locked: can't be sold or destroyed (Alt+Right-click to unlock)", 1, 0.82, 0.25, true)
            tooltip:Show()
        elseif SetName(itemID) then
            tooltip:AddLine("In gear set " .. SetName(itemID) .. ": can't be sold or destroyed", 0.55, 0.8, 1, true)
            tooltip:Show()
        end
    end)
end

local function PatchJunk()
    local manager = _G.EUI_CategoryManager
    if not manager or type(manager.IsJunk) ~= "function" then return false end
    local isJunk = manager.IsJunk
    manager.IsJunk = function(self, itemID, ...)
        if IsProtected(itemID) then return false end
        return isJunk(self, itemID, ...)
    end
    return true
end

-------------------------------------------------------------------------------
--  Slash command
-------------------------------------------------------------------------------
local function ListLocks()
    local any = false
    for itemID in pairs(locked) do
        any = true
        Say("  " .. ItemText(itemID))
    end
    if not any then Say("No items are locked on this character.") end
    local count = 0
    for _ in pairs(setItems) do count = count + 1 end
    if not protectSets then
        Say("Gear set items are not protected (/itemlock sets on).")
    elseif count > 0 then
        Say(string.format("Plus %d item%s in your gear sets.", count, count == 1 and "" or "s"))
    end
end

local function SlashHandler(message)
    message = message or ""
    local command, arg = message:lower():match("^%s*(%S*)%s*(%S*)")
    local itemID = ItemIDFromLink(message) or tonumber(message:match("^%s*(%d+)%s*$") or "")
    if itemID then
        ToggleItem(itemID, message:match("|c.-|r"))
    elseif command == "list" then
        Say("Locked items:")
        ListLocks()
    elseif command == "sets" then
        if arg == "on" or arg == "off" then
            protectSets = arg == "on"
        else
            protectSets = not protectSets
        end
        EllesmereUIBags_ItemLockDB.protectSets = protectSets
        Say("Gear set items are " .. (protectSets and "protected." or "no longer protected."))
        AfterLockChange()
    elseif command == "category" and arg == "sets" then
        local value = message:lower():match("sets%s+(%S+)")
        if value == "on" or value == "off" then
            categorySets = value == "on"
        else
            categorySets = not categorySets
        end
        EllesmereUIBags_ItemLockDB.categorySets = categorySets
        Say(categorySets and "Gear set items go to the \"Locked\" category too."
            or "Gear set items stay in EllesmereUI's set categories; only locked items go to \"Locked\".")
        AfterLockChange()
    elseif command == "category" then
        if arg == "on" or arg == "off" then
            useCategory = arg == "on"
        else
            useCategory = not useCategory
        end
        EllesmereUIBags_ItemLockDB.useCategory = useCategory
        if not ApplyCategory() then
            Say("EllesmereUIBags' category API was not found (did it change?).")
        else
            Say(useCategory and "Locked items get their own \"Locked\" category."
                or "Locked items stay in their normal categories.")
        end
    elseif command == "clear" then
        wipe(locked)
        Say("All locks on this character removed.")
        AfterLockChange()
    else
        Say("Alt+Right-click an item in your bags to lock or unlock it.")
        Say("/itemlock list - show locked items")
        Say("/itemlock <shift-click item> - lock or unlock that item")
        Say("/itemlock clear - remove every lock on this character")
        Say("/itemlock sets on | off - protect gear set items (now "
            .. (protectSets and "on" or "off") .. ")")
        Say("/itemlock category on | off - put locked items in their own category (now "
            .. (useCategory and "on" or "off") .. ")")
        Say("/itemlock category sets on | off - gear set items go there too (now "
            .. (categorySets and "on" or "off") .. ")")
    end
end

-------------------------------------------------------------------------------
--  Events
-------------------------------------------------------------------------------
local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("MERCHANT_SHOW")
events:RegisterEvent("MERCHANT_CLOSED")
events:RegisterEvent("MERCHANT_UPDATE")
events:RegisterEvent("PLAYER_REGEN_DISABLED")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
pcall(events.RegisterEvent, events, "EQUIPMENT_SETS_CHANGED")
local hasMouseUp = pcall(events.RegisterEvent, events, "GLOBAL_MOUSE_UP")

events:SetScript("OnEvent", function(_, event, arg1)
    if event == "GLOBAL_MOUSE_UP" then
        if arg1 == "RightButton" and IsAltKeyDown() then OnAltRightClick() end
    elseif event == "ADDON_LOADED" then
        if arg1 ~= addonName then return end
        events:UnregisterEvent("ADDON_LOADED")
        if type(EllesmereUIBags_ItemLockDB) ~= "table" then EllesmereUIBags_ItemLockDB = {} end
        if type(EllesmereUIBags_ItemLockDB.items) ~= "table" then EllesmereUIBags_ItemLockDB.items = {} end
        locked = EllesmereUIBags_ItemLockDB.items
        protectSets = EllesmereUIBags_ItemLockDB.protectSets ~= false
        useCategory = EllesmereUIBags_ItemLockDB.useCategory ~= false
        categorySets = EllesmereUIBags_ItemLockDB.categorySets ~= false
        RebuildSetItems()
        if not ApplyCategory() then
            Say("EllesmereUIBags' category API was not found (did it change?). Locked items stay in their normal categories.")
        end

        if EUI_Bags and EUI_Bags.RegisterItemOverlayIcon then
            EUI_Bags.RegisterItemOverlayIcon("ItemLock", Paint)
        else
            Say("EllesmereUIBags' overlay API was not found (did it change?). Padlocks and Alt+Right-click are off; /itemlock <item> still locks items.")
        end
        if not PatchJunk() then
            Say("EllesmereUIBags' junk check was not found: Sell Junk may sell locked junk (it is bought back).")
        end
        HookDestroy()
        HookTooltip()
        if not hasMouseUp then
            Say("Alt+Right-click is unavailable on this client; use /itemlock <shift-click item>.")
        end

        SLASH_ELLESMEREUIBAGSITEMLOCK1 = "/itemlock"
        SLASH_ELLESMEREUIBAGSITEMLOCK2 = "/eil"
        SlashCmdList.ELLESMEREUIBAGSITEMLOCK = SlashHandler
    elseif event == "MERCHANT_SHOW" then
        merchantOpen = true
        SnapshotBuyback()
        UpdateBlocker()
    elseif event == "MERCHANT_CLOSED" then
        merchantOpen = false
        HideBlocker()
    elseif event == "MERCHANT_UPDATE" then
        CheckBuyback()
    elseif event == "PLAYER_REGEN_DISABLED" then
        HideBlocker()
    elseif event == "PLAYER_REGEN_ENABLED" then
        if categoryRefreshPending then
            categoryRefreshPending = false
            AfterLockChange()
        end
    elseif event == "PLAYER_ENTERING_WORLD" or event == "EQUIPMENT_SETS_CHANGED" then
        OnSetsChanged()
    end
end)
