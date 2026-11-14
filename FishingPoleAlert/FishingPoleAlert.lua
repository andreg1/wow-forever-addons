--[[
  Fishing Pole Alert

  Warns you when you're in combat with a fishing pole in your main hand:
  a pulsing icon and text near the top of the screen, a raid-warning
  message, a sound and a flashing taskbar icon. The warning repeats every
  few seconds while the pole stays on, and goes away when combat ends or
  the pole comes off.

  Detection: main-hand item (slot 16) with item class Weapon (2) and
  subclass Fishing Pole (20), from C_Item.GetItemInfoInstant. Checked on
  PLAYER_REGEN_DISABLED (combat starts) and PLAYER_EQUIPMENT_CHANGED (pole
  put on during combat).

  Weapon swap key: addons can't change gear in combat, but a key the player
  presses can. A hidden SecureActionButtonTemplate button
  (FishingPoleAlertSwap, key binding in Bindings.xml) runs
  "/equipslot 16 item:<main>" and "/equipslot 17 item:<off>" for the last
  non-pole weapons you wore. They are remembered out of combat on every
  equipment change, and the button's macrotext is only rewritten out of
  combat (attributes are locked in combat, so the last text stays).
  The binding sends both key edges; the button only listens for the down
  edge (RegisterForClicks("AnyDown") + useOnKeyDown), so a press acts once.

  The alert frame is a plain, non-secure frame owned by this addon.
]]

local addonName = ...
local SWAP_BUTTON = "FishingPoleAlertSwap"
local WEAPON, FISHING_POLE = 2, 20
local MAIN, OFF = 16, 17

BINDING_HEADER_FISHINGPOLEALERT = "Fishing Pole Alert"
_G["BINDING_NAME_CLICK " .. SWAP_BUTTON .. ":LeftButton"] = "Put my weapons back on"

local defaults = {
  enabled = true,
  sound = true,
  warning = true,   -- raid-warning message
  flash = true,     -- flash the taskbar icon
  repeatSec = 8,    -- repeat sound + raid warning while the pole stays on (0 = once)
  main = nil,       -- last non-pole main-hand itemID
  off = nil,        -- off-hand worn with it (nil for a two-hander)
}

local db
local alert, swapButton
local lastNag = 0
local swapDirty = false

local function Say(msg)
  DEFAULT_CHAT_FRAME:AddMessage("|cff3fc7ebFishing Pole Alert|r: " .. tostring(msg))
end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function ItemInstant(id)
  local f = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
  if not (f and id) then return end
  local _, _, _, equipLoc, icon, classID, subclassID = f(id)
  return classID, subclassID, icon, equipLoc
end

local function IsPole(id)
  local classID, subclassID = ItemInstant(id)
  return classID == WEAPON and subclassID == FISHING_POLE
end

local function PoleEquipped()
  local id = GetInventoryItemID("player", MAIN)
  if id and IsPole(id) then return id end
end

local function ItemName(id)
  local f = (C_Item and C_Item.GetItemInfo) or GetItemInfo
  return (id and f and f(id)) or (id and ("item " .. id)) or "?"
end

local function SwapKey()
  local key = GetBindingKey("CLICK " .. SWAP_BUTTON .. ":LeftButton")
  return key and (GetBindingText and GetBindingText(key) or key)
end

---------------------------------------------------------------------------
-- Weapon swap button
---------------------------------------------------------------------------

local function SwapText()
  if not db.main then return "" end
  local text = "/equipslot " .. MAIN .. " item:" .. db.main
  if db.off then text = text .. "\n/equipslot " .. OFF .. " item:" .. db.off end
  return text
end

local function UpdateSwapButton()
  if not swapButton then return end
  if InCombatLockdown() then swapDirty = true return end
  swapButton:SetAttribute("macrotext", SwapText())
  swapDirty = false
end

local function BuildSwapButton()
  swapButton = CreateFrame("Button", SWAP_BUTTON, UIParent, "SecureActionButtonTemplate")
  swapButton:SetAttribute("type", "macro")
  swapButton:SetAttribute("useOnKeyDown", true)
  swapButton:RegisterForClicks("AnyDown")
  swapButton:SetSize(1, 1)
  swapButton:Hide()
  UpdateSwapButton()
end

-- Remember the weapons you wear when they aren't a pole (out of combat only,
-- so the button text matches what we remember).
local function RememberWeapons()
  if InCombatLockdown() then return end
  local main = GetInventoryItemID("player", MAIN)
  if not main or IsPole(main) then return end
  local off = GetInventoryItemID("player", OFF)
  if db.main ~= main or db.off ~= off then
    db.main, db.off = main, off
    UpdateSwapButton()
  end
end

---------------------------------------------------------------------------
-- Alert
---------------------------------------------------------------------------

local function BuildAlert()
  local f = CreateFrame("Frame", "FishingPoleAlertFrame", UIParent)
  f:SetSize(420, 64)
  f:SetPoint("TOP", 0, -150)
  f:SetFrameStrata("HIGH")
  f:Hide()

  f.icon = f:CreateTexture(nil, "ARTWORK")
  f.icon:SetSize(52, 52)
  f.icon:SetPoint("LEFT", 0, 0)

  f.border = f:CreateTexture(nil, "OVERLAY")
  f.border:SetPoint("TOPLEFT", f.icon, -3, 3)
  f.border:SetPoint("BOTTOMRIGHT", f.icon, 3, -3)
  f.border:SetColorTexture(1, 0.1, 0.1, 0.35)
  f.border:SetDrawLayer("BACKGROUND")

  f.text = f:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
  f.text:SetPoint("TOPLEFT", f.icon, "TOPRIGHT", 10, -4)
  f.text:SetTextColor(1, 0.25, 0.25)
  f.text:SetText("Fishing pole equipped!")

  f.sub = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  f.sub:SetPoint("TOPLEFT", f.text, "BOTTOMLEFT", 0, -4)
  f.sub:SetJustifyH("LEFT")

  local ag = f:CreateAnimationGroup()
  ag:SetLooping("BOUNCE")
  local a = ag:CreateAnimation("Alpha")
  a:SetFromAlpha(1)
  a:SetToAlpha(0.35)
  a:SetDuration(0.45)
  f.pulse = ag

  alert = f
end

local function SubText()
  if not db.main then
    return "Unequip it! (wear your weapon once so the swap key knows it)"
  end
  local key = SwapKey()
  local weapons = ItemName(db.main) .. (db.off and (" + " .. ItemName(db.off)) or "")
  if key then return string.format("Press |cffffff00%s|r for %s", key, weapons) end
  return "Swap to " .. weapons .. "  |cffaaaaaa(bind a key: Keybindings > AddOns > Fishing Pole Alert)|r"
end

local function Nag()
  lastNag = GetTime()
  if db.sound then
    PlaySound((SOUNDKIT and SOUNDKIT.RAID_WARNING) or 8959, "Master")
  end
  if db.warning and RaidNotice_AddMessage and RaidWarningFrame then
    RaidNotice_AddMessage(RaidWarningFrame, "FISHING POLE EQUIPPED!", ChatTypeInfo and ChatTypeInfo["RAID_WARNING"] or { r = 1, g = 0.3, b = 0.1 })
  end
  if db.flash and FlashClientIcon then pcall(FlashClientIcon) end
end

local function ShowAlert(poleID)
  if not alert then BuildAlert() end
  local _, _, icon = ItemInstant(poleID)
  alert.icon:SetTexture(icon or 132932)
  alert.sub:SetText(SubText())
  if not alert:IsShown() then
    alert:Show()
    alert.pulse:Play()
    Nag()
  end
end

local function HideAlert()
  if alert and alert:IsShown() then
    alert.pulse:Stop()
    alert:Hide()
  end
end

-- combatStarting: called from PLAYER_REGEN_DISABLED, where InCombatLockdown()
-- isn't true yet.
local function Check(combatStarting)
  if not db.enabled then HideAlert() return end
  local pole = PoleEquipped()
  if pole and (combatStarting or InCombatLockdown() or UnitAffectingCombat("player")) then
    ShowAlert(pole)
  else
    HideAlert()
  end
end

-- repeat the sound / raid warning while the alert stays up
local ticker = CreateFrame("Frame")
ticker:SetScript("OnUpdate", function(_, elapsed)
  if not (alert and alert:IsShown()) then return end
  if db.repeatSec and db.repeatSec > 0 and GetTime() - lastNag >= db.repeatSec then
    Nag()
  end
end)

---------------------------------------------------------------------------
-- Slash
---------------------------------------------------------------------------

local function OnOff(v) return v and "|cff00ff00on|r" or "|cffff4040off|r" end

local function Slash(msg)
  msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
  local cmd, arg = msg:match("^(%S*)%s*(.*)$")
  if cmd == "" or cmd == "status" then
    Say(string.format("%s. Sound %s, raid warning %s, flash %s, repeat %s.", OnOff(db.enabled), OnOff(db.sound),
      OnOff(db.warning), OnOff(db.flash), db.repeatSec > 0 and ("every " .. db.repeatSec .. " s") or "off"))
    Say("swap key: " .. (SwapKey() or "not bound") .. ", weapons: " ..
      (db.main and (ItemName(db.main) .. (db.off and (" + " .. ItemName(db.off)) or "")) or "none remembered yet"))
    Say("/fpa on|off | sound | warning | flash | repeat <seconds, 0 = once> | test")
  elseif cmd == "on" or cmd == "off" then
    db.enabled = (cmd == "on")
    Say("alert " .. OnOff(db.enabled))
    Check()
  elseif cmd == "sound" or cmd == "warning" or cmd == "flash" then
    db[cmd] = not db[cmd]
    Say(cmd .. " " .. OnOff(db[cmd]))
  elseif cmd == "repeat" then
    local n = tonumber(arg)
    if not n or n < 0 then Say("usage: /fpa repeat <seconds> (0 = only once per fight)") return end
    db.repeatSec = n
    Say(n > 0 and ("repeating every " .. n .. " s") or "warning once per fight")
  elseif cmd == "test" then
    ShowAlert(PoleEquipped() or 6256) -- 6256 = Fishing Pole
    C_Timer.After(5, function() Check() end)
  else
    Say("unknown command. /fpa for help.")
  end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:SetScript("OnEvent", function(_, event, arg1)
  if event == "ADDON_LOADED" then
    if arg1 ~= addonName then return end
    FishingPoleAlertDB = FishingPoleAlertDB or {}
    db = FishingPoleAlertDB
    for k, v in pairs(defaults) do
      if db[k] == nil then db[k] = v end
    end
    SLASH_FISHINGPOLEALERT1, SLASH_FISHINGPOLEALERT2 = "/fpa", "/fishingpolealert"
    SlashCmdList.FISHINGPOLEALERT = Slash
    BuildSwapButton()
    ev:RegisterEvent("PLAYER_ENTERING_WORLD")
    ev:RegisterEvent("PLAYER_REGEN_DISABLED")
    ev:RegisterEvent("PLAYER_REGEN_ENABLED")
    ev:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
    ev:RegisterEvent("UPDATE_BINDINGS")
  elseif event == "PLAYER_ENTERING_WORLD" then
    RememberWeapons()
    Check()
  elseif event == "PLAYER_EQUIPMENT_CHANGED" then
    if arg1 == MAIN or arg1 == OFF then
      RememberWeapons()
      Check()
    end
  elseif event == "PLAYER_REGEN_DISABLED" then
    Check(true)
  elseif event == "PLAYER_REGEN_ENABLED" then
    if swapDirty then UpdateSwapButton() end
    RememberWeapons()
    HideAlert()
  elseif event == "UPDATE_BINDINGS" then
    if alert and alert:IsShown() then alert.sub:SetText(SubText()) end
  end
end)
