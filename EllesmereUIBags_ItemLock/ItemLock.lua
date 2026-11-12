-------------------------------------------------------------------------------
--  EllesmereUIBags - Item Lock
--
--  A separate addon, so EllesmereUIBags can update without losing it. It only
--  uses EllesmereUIBags' public surfaces:
--    * EUI_Bags.RegisterItemOverlayIcon: the padlock on locked items, and which
--      bag slot is under the mouse (grid, list and bank views).
--    * EUI_CategoryManager:IsJunk: locked items are never junk, so Sell Junk
--      skips them.
--  Everything else is plain Blizzard API.
--
--  Locks are per character, by item ID (every copy of the item is locked).
--  Alt+Right-click toggles a lock.
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

local function ItemIDFromLink(link)
    return type(link) == "string" and tonumber(link:match("item:(%d+)")) or nil
end

local function ItemText(itemID, link)
    if link then return link end
    local name, itemLink = C_Item.GetItemInfo(itemID)
    return itemLink or name or ("item " .. itemID)
end

-- Public, for other addons or macros: EllesmereUIBags_ItemLock.IsLocked(itemID)
EllesmereUIBags_ItemLock = { IsLocked = IsLocked }

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

local function ShowMark(btn, show)
    if not show then
        if marks[btn] then marks[btn]:Hide() end
        return
    end
    local m = Mark(btn)
    local host = btn._textOverlay or btn
    local width = host:GetWidth() or 0
    local size = width > 0 and math.max(10, math.min(16, math.floor(width * 0.4 + 0.5))) or 14
    m:SetSize(size, size)
    m:Show()
end

local function RepaintAll()
    for btn, s in pairs(slots) do
        ShowMark(btn, IsLocked(s.itemID))
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
                Say(ItemText(s.itemID, C_Container.GetContainerItemLink(s.bag, s.slot))
                    .. " is locked, so right-click is off at merchants. Alt+Right-click to unlock it.")
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
    local want = merchantOpen and s and IsLocked(s.itemID) and not InCombatLockdown()
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
    ShowMark(btn, IsLocked(itemID))
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
        if IsLocked(id) and count > (buybackSnapshot[id] or 0) then
            for i = GetNumBuybackItems(), 1, -1 do
                local link = GetBuybackItemLink(i)
                if ItemIDFromLink(link) == id then
                    BuybackItem(i)
                    buybackSnapshot = counts
                    buybackSnapshot[id] = count - 1
                    Say(ItemText(id, link) .. " is locked, so it was bought back.")
                    return  -- MERCHANT_UPDATE fires again for the next one
                end
            end
        end
    end
    buybackSnapshot = counts
end

-------------------------------------------------------------------------------
--  Locking
-------------------------------------------------------------------------------
local function AfterLockChange()
    SnapshotBuyback()
    RepaintAll()
    UpdateBlocker()
    -- Junk follows the lock (EUI_CategoryManager.IsJunk below)
    if EUI_Bags and EUI_Bags.IsShown and EUI_Bags:IsShown() and EUI_Bags.RefreshInventory
        and not InCombatLockdown() then
        EUI_Bags:RefreshInventory()
    end
end

local function SetLocked(itemID, lock, link)
    if not itemID then return end
    locked[itemID] = lock and true or nil
    if lock then
        Say(ItemText(itemID, link) .. " locked: it can't be sold or destroyed.")
    else
        Say(ItemText(itemID, link) .. " unlocked.")
    end
    AfterLockChange()
end

function Toggle(bag, slot)
    local itemID = C_Container.GetContainerItemID(bag, slot)
    if not itemID then return end
    SetLocked(itemID, not IsLocked(itemID), C_Container.GetContainerItemLink(bag, slot))
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
        if kind == "item" and IsLocked(itemID) then
            StaticPopup_Hide(which)
            ClearCursor()
            Say(ItemText(itemID, link) .. " is locked and can't be destroyed. Alt+Right-click it in your bags to unlock it.")
        end
    end)
end

local function HookTooltip()
    hooksecurefunc(GameTooltip, "SetBagItem", function(tooltip, bag, slot)
        if IsLocked(C_Container.GetContainerItemID(bag, slot)) then
            tooltip:AddLine("Locked: can't be sold or destroyed (Alt+Right-click to unlock)", 1, 0.82, 0.25, true)
            tooltip:Show()
        end
    end)
end

local function PatchJunk()
    local manager = _G.EUI_CategoryManager
    if not manager or type(manager.IsJunk) ~= "function" then return false end
    local isJunk = manager.IsJunk
    manager.IsJunk = function(self, itemID, ...)
        if IsLocked(itemID) then return false end
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
end

local function SlashHandler(message)
    message = message or ""
    local command = message:lower():match("^%s*(%S*)")
    local itemID = ItemIDFromLink(message) or tonumber(message:match("^%s*(%d+)%s*$") or "")
    if itemID then
        SetLocked(itemID, not IsLocked(itemID), message:match("|c.-|r"))
    elseif command == "list" then
        Say("Locked items:")
        ListLocks()
    elseif command == "clear" then
        wipe(locked)
        Say("All locks on this character removed.")
        AfterLockChange()
    else
        Say("Alt+Right-click an item in your bags to lock or unlock it.")
        Say("/itemlock list - show locked items")
        Say("/itemlock <shift-click item> - lock or unlock that item")
        Say("/itemlock clear - remove every lock on this character")
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
    end
end)
