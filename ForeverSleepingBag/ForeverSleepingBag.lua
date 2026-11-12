-------------------------------------------------------------------------------
--  Forever Sleeping Bag
--
--  WoW Forever's Cozy Sleeping Bag (item 211527): using it (Unroll Bag, 429961,
--  one hour cooldown) lays a bag down; resting in it (area aura 429960) grants
--  Well-Rested (429959, two hours, up to three stacks).
--
--  Reminds you, below max level, while the bag is in your bags and off
--  cooldown, when Well-Rested is missing, under three stacks, or has less than
--  db.refreshMinutes left. A small movable alert with a "use bag" icon, plus
--  one chat line per reminder.
-------------------------------------------------------------------------------
local addonName = ...

local ITEM = 211527
local BUFF = 429959
local AREA = 429960
local MAX_STACKS = 3
local MAX_LEVEL = 60
local FALLBACK_ICON = 133662
local SNOOZE_MINUTES = 10
local PREFIX = "|cff80d7ffForever Sleeping Bag:|r "

local defaults = {
    enabled = true,
    chat = true,
    refreshMinutes = 20,
    x = 0,
    y = 200,
}

local db
local alert
local currentKey       -- the reminder being shown
local dismissedKey     -- dismissed until the need goes away
local lastChatKey      -- chat once per reminder
local snoozeUntil
local testUntil        -- /fsb test keeps the alert up this long
local evalPending = false

local function Say(message)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. message)
    end
end

-------------------------------------------------------------------------------
--  Status
-------------------------------------------------------------------------------
local function PlayerAura(spellID)
    if C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID then
        local ok, aura = pcall(C_UnitAuras.GetPlayerAuraBySpellID, spellID)
        return ok and aura or nil
    end
    if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
        local index = 1
        while true do
            local aura = C_UnitAuras.GetAuraDataByIndex("player", index, "HELPFUL")
            if not aura then return nil end
            if aura.spellId == spellID then return aura end
            index = index + 1
        end
    end
end

local function BagCount()
    local getCount = C_Item and C_Item.GetItemCount or GetItemCount
    if not getCount then return 0 end
    local ok, count = pcall(getCount, ITEM)
    return ok and type(count) == "number" and count or 0
end

local function CooldownRemaining(now)
    local getCooldown = C_Container and C_Container.GetItemCooldown or GetItemCooldown
    if not getCooldown then return 0 end
    local ok, start, duration, enable = pcall(getCooldown, ITEM)
    if not ok then return 0 end
    if enable == 0 or enable == false then return math.huge end
    if type(start) ~= "number" or type(duration) ~= "number" or start <= 0 or duration <= 1.5 then
        return 0
    end
    return math.max(0, start + duration - now)
end

local function BagIcon()
    local getIcon = C_Item and C_Item.GetItemIconByID or GetItemIcon
    return (getIcon and getIcon(ITEM)) or FALLBACK_ICON
end

local function Status(now)
    local aura = PlayerAura(BUFF)
    local stacks = 0
    if aura then
        stacks = type(aura.applications) == "number" and aura.applications or 0
        if stacks < 1 then stacks = 1 end
    end
    local owned = BagCount() > 0
    local lying = PlayerAura(AREA) ~= nil
    local cooldown = owned and CooldownRemaining(now) or 0
    local expirationTime = aura and aura.expirationTime
    local remaining = stacks > 0 and type(expirationTime) == "number" and expirationTime > 0
        and expirationTime - now or nil
    return {
        owned = owned,
        stacks = stacks,
        remaining = remaining,
        lying = lying,
        cooldown = cooldown,
        ready = owned and not lying and cooldown <= 0,
    }
end

local function FormatMinutes(seconds)
    local minutes = math.max(1, math.ceil(seconds / 60))
    if minutes >= 60 then
        return string.format("%dh %dm", math.floor(minutes / 60), minutes % 60)
    end
    return string.format("%dm", minutes)
end

local function StatusText(s)
    if s.stacks == 0 then return "Well-Rested: not active" end
    local text = string.format("Well-Rested: %d/%d stacks", s.stacks, MAX_STACKS)
    if s.remaining and s.remaining > 0 then
        text = text .. " (" .. FormatMinutes(s.remaining) .. " left)"
    end
    return text
end

-------------------------------------------------------------------------------
--  Alert frame
-------------------------------------------------------------------------------
local function SavePosition(frame)
    local x, y = frame:GetCenter()
    local cx, cy = UIParent:GetCenter()
    if x and cx then
        db.x, db.y = x - cx, y - cy
    end
end

local function PlaceAlert()
    alert:ClearAllPoints()
    alert:SetPoint("CENTER", UIParent, "CENTER", db.x, db.y)
end

local function HideAlert()
    if alert and alert:IsShown() then alert:Hide() end
end

local function BuildAlert()
    local f = CreateFrame("Frame", "ForeverSleepingBagAlert", UIParent, "BackdropTemplate")
    f:SetSize(360, 78)
    f:SetFrameStrata("MEDIUM")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePosition(self)
        PlaceAlert()
    end)
    f:SetBackdrop({
        bgFile = "Interface/Tooltips/UI-Tooltip-Background",
        edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    f:SetBackdropColor(0.04, 0.05, 0.07, 0.94)
    f:SetBackdropBorderColor(0.5, 0.84, 1, 0.9)

    -- The bag itself: a click uses it (a macro, so out of combat only; the
    -- alert never shows in combat).
    local use = CreateFrame("Button", "ForeverSleepingBagUseButton", f, "InsecureActionButtonTemplate")
    use:SetSize(46, 46)
    use:SetPoint("LEFT", f, "LEFT", 14, 0)
    use:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    use:SetAttribute("useOnKeyDown", false)
    use:SetAttribute("type", "macro")
    use:SetAttribute("macrotext", "/use item:" .. ITEM)
    local icon = use:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints()
    icon:SetTexture(BagIcon())
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    use.icon = icon
    use:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    use:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetItemByID(ITEM)
        GameTooltip:AddLine("Click to use", 0.5, 0.84, 1)
        GameTooltip:Show()
    end)
    use:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f.use = use

    f.text = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.text:SetPoint("TOPLEFT", use, "TOPRIGHT", 12, 2)
    f.text:SetPoint("RIGHT", f, "RIGHT", -12, 0)
    f.text:SetJustifyH("LEFT")
    f.text:SetJustifyV("TOP")
    f.text:SetWordWrap(true)
    f.text:SetHeight(30)

    f.status = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    f.status:SetPoint("BOTTOMLEFT", use, "BOTTOMRIGHT", 12, 0)
    f.status:SetJustifyH("LEFT")

    local dismiss = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    dismiss:SetSize(70, 20)
    dismiss:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -10, 8)
    dismiss:SetText("Dismiss")
    dismiss:SetScript("OnClick", function()
        dismissedKey = currentKey
        HideAlert()
    end)

    local snooze = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    snooze:SetSize(80, 20)
    snooze:SetPoint("RIGHT", dismiss, "LEFT", -4, 0)
    snooze:SetText(string.format("Snooze %dm", SNOOZE_MINUTES))
    snooze:SetScript("OnClick", function()
        snoozeUntil = GetTime() + SNOOZE_MINUTES * 60
        HideAlert()
    end)

    f:Hide()
    alert = f
    PlaceAlert()
end

local function ShowAlert(message, s)
    if not alert then BuildAlert() end
    alert.use.icon:SetTexture(BagIcon())
    alert.text:SetText(message)
    alert.status:SetText(StatusText(s))
    alert:Show()
end

-------------------------------------------------------------------------------
--  Evaluation
-------------------------------------------------------------------------------
local function Blocked()
    local level = UnitLevel("player")
    return (type(level) == "number" and level >= MAX_LEVEL)
        or UnitAffectingCombat("player")
        or (InCombatLockdown and InCombatLockdown())
        or UnitIsDeadOrGhost("player")
        or (IsFlying and IsFlying())
        or (UnitOnTaxi and UnitOnTaxi("player"))
end

local function Evaluate()
    if not db then return end
    local now = GetTime()
    if testUntil then
        if now < testUntil and not InCombatLockdown() then return end
        testUntil = nil
    end
    local s = Status(now)

    local key, message
    if db.enabled and s.ready then
        if s.stacks == 0 then
            key = "missing"
            message = "Your Cozy Sleeping Bag is ready, but Well-Rested is not active."
        elseif s.remaining and s.remaining <= db.refreshMinutes * 60 then
            key = "refresh"
            message = string.format("Well-Rested ends in about %d min. Use your Cozy Sleeping Bag to refresh it.",
                math.max(1, math.ceil(s.remaining / 60)))
        elseif s.stacks < MAX_STACKS then
            key = "stacks:" .. s.stacks
            message = string.format("Your Cozy Sleeping Bag is ready: Well-Rested is at %d/%d stacks.",
                s.stacks, MAX_STACKS)
        end
    end

    if not key then
        -- Nothing to do (bag used, on cooldown, buff full): start fresh next time
        currentKey, dismissedKey, lastChatKey = nil, nil, nil
        HideAlert()
        return
    end
    currentKey = key
    if Blocked() or dismissedKey == key or (snoozeUntil and now < snoozeUntil) then
        HideAlert()
        return
    end
    snoozeUntil = nil
    if db.chat and lastChatKey ~= key then
        lastChatKey = key
        Say(message)
    end
    ShowAlert(message, s)
end

local function ScheduleEvaluate()
    if evalPending then return end
    evalPending = true
    C_Timer.After(0.3, function()
        evalPending = false
        Evaluate()
    end)
end

-------------------------------------------------------------------------------
--  Slash command
-------------------------------------------------------------------------------
local function SlashHandler(message)
    local command, arg = (message or ""):lower():match("^%s*(%S*)%s*(.-)%s*$")
    if command == "on" or command == "off" then
        db.enabled = command == "on"
        Say("Reminders " .. (db.enabled and "on." or "off."))
    elseif command == "chat" then
        db.chat = not db.chat
        Say("Chat messages " .. (db.chat and "on." or "off."))
    elseif command == "refresh" and tonumber(arg) then
        db.refreshMinutes = math.max(1, math.min(119, math.floor(tonumber(arg))))
        Say(string.format("Refresh reminder %d min before Well-Rested ends.", db.refreshMinutes))
    elseif command == "reset" then
        db.x, db.y = defaults.x, defaults.y
        if alert then PlaceAlert() end
        Say("Alert position reset.")
    elseif command == "test" then
        if InCombatLockdown() then return end
        testUntil = GetTime() + 20
        ShowAlert("Test: drag this alert to move it. It closes in 20 seconds.", Status(GetTime()))
        return
    elseif command == "status" then
        local s = Status(GetTime())
        Say(string.format("%s; bag in bags: %s; in bag: %s; cooldown: %s.", StatusText(s),
            s.owned and "yes" or "no", s.lying and "yes" or "no",
            s.cooldown <= 0 and "ready" or s.cooldown == math.huge and "pending" or FormatMinutes(s.cooldown)))
        return
    else
        Say(string.format("Reminders: %s; chat: %s; refresh at %d min left.",
            db.enabled and "on" or "off", db.chat and "on" or "off", db.refreshMinutes))
        Say("/fsb on | off - turn reminders on or off")
        Say("/fsb chat - toggle chat messages")
        Say("/fsb refresh <minutes> - when to remind before Well-Rested ends")
        Say("/fsb test - show the alert to move it;  /fsb reset - reset its position")
        Say("/fsb status - show the bag and buff state")
        return
    end
    dismissedKey, lastChatKey = nil, nil
    Evaluate()
end

-------------------------------------------------------------------------------
--  Events
-------------------------------------------------------------------------------
local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("PLAYER_LEVEL_UP")
events:RegisterEvent("PLAYER_REGEN_DISABLED")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:RegisterEvent("PLAYER_DEAD")
events:RegisterEvent("PLAYER_ALIVE")
events:RegisterEvent("PLAYER_UNGHOST")
events:RegisterEvent("BAG_UPDATE_DELAYED")
events:RegisterEvent("BAG_UPDATE_COOLDOWN")
events:RegisterEvent("PLAYER_MOUNT_DISPLAY_CHANGED")
if events.RegisterUnitEvent then
    events:RegisterUnitEvent("UNIT_AURA", "player")
else
    events:RegisterEvent("UNIT_AURA")
end

events:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= addonName then return end
        events:UnregisterEvent("ADDON_LOADED")
        if type(ForeverSleepingBagDB) ~= "table" then ForeverSleepingBagDB = {} end
        db = ForeverSleepingBagDB
        for k, v in pairs(defaults) do
            if type(db[k]) ~= type(v) then db[k] = v end
        end
        SLASH_FOREVERSLEEPINGBAG1 = "/fsb"
        SLASH_FOREVERSLEEPINGBAG2 = "/sleepingbag"
        SlashCmdList.FOREVERSLEEPINGBAG = SlashHandler
    elseif event == "PLAYER_LOGIN" then
        -- Catches the refresh window, cooldown ends, flight and taxi changes
        C_Timer.NewTicker(5, Evaluate)
        ScheduleEvaluate()
    elseif event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_DEAD" then
        HideAlert()
    elseif event == "UNIT_AURA" then
        if arg1 == "player" then ScheduleEvaluate() end
    else
        ScheduleEvaluate()
    end
end)
