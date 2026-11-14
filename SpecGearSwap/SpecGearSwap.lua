--[[
  Spec Gear Swap

  Equips a gear set (the game's equipment manager sets) when you switch
  talent spec (dual spec, talent group 1 / 2).

  Why a separate addon: EllesmereUI's character sheet has a similar
  feature, but it listens for the retail PLAYER_SPECIALIZATION_CHANGED /
  GetSpecialization, which this client's dual spec never fires.

  Surfaces used (all Blizzard API, no other addon):
    - ACTIVE_TALENT_GROUP_CHANGED, GetActiveTalentGroup (fallback
      C_SpecializationInfo.GetActiveSpecGroup), GetNumTalentGroups
    - C_EquipmentSet.GetEquipmentSetIDs / GetEquipmentSetInfo /
      GetEquipmentSetID, EquipmentManager_EquipSet (fallback
      C_EquipmentSet.UseEquipmentSet), EQUIPMENT_SWAP_FINISHED

  Which set a spec gets, in order:
    1. the set you linked to it (/specgear set, /specgear link, or learned:
       the first set you equip by hand while in a spec with no link);
    2. a set named like that spec's main talent tree ("Holy", "Feral"...).
  Links are stored by set name (and ID as a fallback, so a renamed set
  still works), per character.

  Gear auto-save: while you wear a gear set and replace any piece of it
  (slots 1-18 except shirt/tabard, and slots the set ignores), the set is
  re-saved with the new piece (C_EquipmentSet.SaveEquipmentSet).
  Safeguards, because a save stores every slot you're wearing:
    - the set is the one you last put on (EQUIPMENT_SWAP_FINISHED, or the
      set the game reports fully equipped), never a guess between sets
      that share pieces;
    - no save if a slot the set filled is now empty (taking gear off,
      mid-swap; the off hand may empty for a two-handed main hand), if the
      main hand is a fishing pole, or if your gear now fully matches
      another set (that's switching sets, not changing a piece);
    - more than 4 slots changed in one go looks like other gear, not an
      upgrade: not saved, with a chat note (/specgear save forces it);
    - changes are debounced 0.7 s (a swap fires several events), our own
      and the equipment manager's swaps are skipped, and a change made in
      combat is checked again when combat ends.
  Set contents come from C_EquipmentSet.GetItemIDs (GetItemLocations
  crashes the Forever client).

  Action bar restore: the client sometimes empties one of your action bars
  when you switch spec after a relog. Each spec's bars are backed up
  (db.bars[group][slot] = spell ID + name / item ID / macro name /
  equipment set name, or false for empty), kept current from
  ACTIONBAR_SLOT_CHANGED. On a spec change, recording pauses 4 s (the bars
  are loading the other layout; a change seen while GetActiveTalentGroup
  no longer matches the group we last handled is skipped too), and at
  1 s and 3 s every slot that is empty now but has something in the
  backup is refilled (PickupSpell/PickupItem/PickupMacro/
  C_EquipmentSet.PickupEquipmentSet + PlaceAction, out of combat, only
  with an empty cursor). Slots that hold something are never replaced.
  Up to 15 s after a switch, 6+ slots emptied within 1 s count as the bug
  and are refilled; otherwise an emptied slot is your change and is
  recorded. (That check is limited to after a switch because
  ActionBarSaverReloaded's restore also empties many slots at once.)

  Taint/combat: gear can't be swapped in combat, so a switch made in
  combat is queued and done on PLAYER_REGEN_ENABLED. No secure frames or
  other addons' frames are touched.
]]

local addonName = ...

local defaults = {
  enabled = true,
  learn = true,     -- link the first hand-equipped set to an unlinked spec
  byName = true,    -- fall back to a set named like the main talent tree
  autoSave = true,  -- re-save the worn set when you replace a piece of it
  barRestore = true, -- back up each spec's action bars, refill emptied slots on spec change
  links = {},       -- [group] = { name = "Set", id = n }
  bars = {},        -- [group][slot] = { type, id, name } | false (empty)
}

local db
local lastGroup
local pendingEquip   -- group to equip after combat
local selfSwap = 0   -- GetTime() of our own last swap (ignored by learn)
local wornSet        -- setID of the set you last put on
local swapPending = false -- equipment manager swap in progress
local pendingSave = false -- gear changed in combat, check after
local saveTimer

local function Say(msg)
  DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffSpec Gear|r: " .. tostring(msg))
end

---------------------------------------------------------------------------
-- Spec helpers
---------------------------------------------------------------------------

local function ActiveGroup()
  if GetActiveTalentGroup then
    local ok, g = pcall(GetActiveTalentGroup)
    if ok and g then return g end
  end
  if C_SpecializationInfo and C_SpecializationInfo.GetActiveSpecGroup then
    local ok, g = pcall(C_SpecializationInfo.GetActiveSpecGroup)
    if ok and g then return g end
  end
  return 1
end

local function NumGroups()
  if GetNumTalentGroups then
    local ok, n = pcall(GetNumTalentGroups)
    if ok and n and n > 0 then return n end
  end
  return 2
end

-- Name of the talent tree with the most points in `group`, or nil.
local function MainTree(group)
  if not (GetNumTalentTabs and GetTalentTabInfo) then return nil end
  local bestName, bestPts = nil, 0
  for tab = 1, (GetNumTalentTabs() or 0) do
    local ok, a, b, c, d, e = pcall(GetTalentTabInfo, tab, false, false, group)
    if not ok then ok, a, b, c, d, e = pcall(GetTalentTabInfo, tab) end
    if ok then
      local name, pts
      if type(a) == "number" then name, pts = b, e   -- id, name, desc, icon, points
      else name, pts = a, c end                       -- name, icon, points, file
      pts = tonumber(pts) or 0
      if name and pts > bestPts then bestName, bestPts = name, pts end
    end
  end
  return bestName
end

local function SpecLabel(group)
  local tree = MainTree(group)
  return string.format("Spec %d%s", group, tree and (" (" .. tree .. ")") or "")
end

---------------------------------------------------------------------------
-- Gear set helpers
---------------------------------------------------------------------------

local function SetIDs()
  if not (C_EquipmentSet and C_EquipmentSet.GetEquipmentSetIDs) then return {} end
  local ok, ids = pcall(C_EquipmentSet.GetEquipmentSetIDs)
  return (ok and ids) or {}
end

-- name, setID, isEquipped, numLost
local function SetInfo(id)
  local ok, name, _, setID, isEquipped, _, _, _, numLost = pcall(C_EquipmentSet.GetEquipmentSetInfo, id)
  if ok and name then return name, setID or id, isEquipped, numLost or 0 end
end

local function FindSetByName(name)
  if not name then return nil end
  if C_EquipmentSet.GetEquipmentSetID then
    local ok, id = pcall(C_EquipmentSet.GetEquipmentSetID, name)
    if ok and id then return id end
  end
  local lower = name:lower()
  for _, id in ipairs(SetIDs()) do
    local n = SetInfo(id)
    if n and n:lower() == lower then return id end
  end
end

local function EquippedSet()
  for _, id in ipairs(SetIDs()) do
    local name, setID, isEquipped = SetInfo(id)
    if isEquipped then return setID, name end
  end
end

-- The set for `group`: setID, name, how ("linked" / "tree name").
local function SetForGroup(group)
  local link = db.links[group]
  if link then
    local id = FindSetByName(link.name)
    if not id and link.id and SetInfo(link.id) then id = link.id end
    if id then
      local name = SetInfo(id)
      if name ~= link.name then link.name = name end -- follow a rename
      return id, name, "linked"
    end
  end
  if db.byName then
    local tree = MainTree(group)
    local id = tree and FindSetByName(tree)
    if id then return id, SetInfo(id), "tree name" end
  end
end

local function EquipForGroup(group, quiet)
  local id, name = SetForGroup(group)
  if not id then
    if not quiet then
      Say(SpecLabel(group) .. " has no gear set. Link one: |cffffffff/specgear link|r (equips nothing until then).")
    end
    return
  end
  local _, _, isEquipped, numLost = SetInfo(id)
  if isEquipped then
    if not quiet then Say(string.format("%s: |cffffffff%s|r is already on.", SpecLabel(group), name)) end
    return
  end
  if InCombatLockdown() or UnitAffectingCombat("player") then
    pendingEquip = group
    Say(string.format("in combat: |cffffffff%s|r goes on when combat ends.", name))
    return
  end
  selfSwap = GetTime()
  local ok, err
  if EquipmentManager_EquipSet then
    ok, err = pcall(EquipmentManager_EquipSet, id)
  else
    ok, err = pcall(C_EquipmentSet.UseEquipmentSet, id)
  end
  if ok then
    Say(string.format("%s: equipping |cffffffff%s|r.", SpecLabel(group), name))
    if numLost and numLost > 0 then
      Say(string.format("|cffff8080%d item%s of %s %s not in your bags.|r", numLost, numLost == 1 and "" or "s",
        name, numLost == 1 and "is" or "are"))
    end
  else
    Say("couldn't equip " .. name .. ": " .. tostring(err))
  end
end

local function Link(group, id)
  local name = SetInfo(id)
  if not name then return end
  db.links[group] = { name = name, id = id }
  Say(string.format("%s now uses |cffffffff%s|r.", SpecLabel(group), name))
end

---------------------------------------------------------------------------
-- Gear auto-save
---------------------------------------------------------------------------

local SKIP_SLOTS = { [4] = true, [19] = true } -- shirt, tabard: cosmetic, never a reason to save
local MAX_AT_ONCE = 4 -- more slots changed in one go than this = a different outfit, not an upgrade
local SLOT_LABEL = {
  [1] = "head", [2] = "neck", [3] = "shoulder", [5] = "chest", [6] = "waist", [7] = "legs",
  [8] = "feet", [9] = "wrist", [10] = "hands", [11] = "ring", [12] = "ring", [13] = "trinket",
  [14] = "trinket", [15] = "back", [16] = "main hand", [17] = "off hand", [18] = "ranged",
}

local function Norm(id) return (type(id) == "number" and id > 1) and id or nil end

local function SetItems(setID)
  if not C_EquipmentSet.GetItemIDs then return nil end
  local ok, ids = pcall(C_EquipmentSet.GetItemIDs, setID)
  if not (ok and type(ids) == "table") then return nil end
  local ignored = {}
  if C_EquipmentSet.GetIgnoredSlots then
    local okI, ig = pcall(C_EquipmentSet.GetIgnoredSlots, setID)
    if okI and type(ig) == "table" then ignored = ig end
  end
  return ids, ignored
end

local function Instant(id)
  local f = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
  if not (f and id) then return end
  local _, _, _, equipLoc, _, classID, subclassID = f(id)
  return equipLoc, classID, subclassID
end

local function ItemName(id)
  local f = (C_Item and C_Item.GetItemInfo) or GetItemInfo
  local name, link = f(id)
  return link or name or ("item " .. id)
end

-- Changed slots ({slot = newID or false}, count) if `setID` should be
-- re-saved, else nil + reason. `force` skips the many-slots limit.
local function GearChanges(setID, force)
  local ids, ignored = SetItems(setID)
  if not ids then return nil, "can't read the set" end
  local main = Norm(GetInventoryItemID("player", 16))
  if main then
    local _, classID, subclassID = Instant(main)
    if classID == 2 and subclassID == 20 then return nil, "a fishing pole is in your main hand" end
  end
  local mainIs2H = main and Instant(main) == "INVTYPE_2HWEAPON"
  local changes, n = {}, 0
  for slot = 1, 18 do
    if not SKIP_SLOTS[slot] and not ignored[slot] then
      local want, have = Norm(ids[slot]), Norm(GetInventoryItemID("player", slot))
      if want ~= have then
        -- an emptied slot is taking gear off (repairs, mid-swap), not a new piece
        if not have and want and not (slot == 17 and mainIs2H) then
          return nil, "your " .. (SLOT_LABEL[slot] or ("slot " .. slot)) .. " slot is empty"
        end
        changes[slot] = have or false
        n = n + 1
      end
    end
  end
  if n == 0 then return nil, "you're wearing exactly the set" end
  if n > MAX_AT_ONCE and not force then
    return nil, string.format("%d slots changed at once (looks like different gear, not an upgrade; /specgear save saves it anyway)", n)
  end
  return changes, n
end

local function SaveWorn(force)
  local name = SetInfo(wornSet)
  local changes, why = GearChanges(wornSet, force)
  if not changes then
    if force then Say("not saved: " .. why .. ".")
    elseif why:find("slots changed at once") then Say(name .. " not updated: " .. why .. ".") end
    return
  end
  local ok, err = pcall(C_EquipmentSet.SaveEquipmentSet, wornSet)
  if not ok then Say("couldn't update " .. name .. ": " .. tostring(err)) return end
  local parts = {}
  for slot = 1, 18 do
    if changes[slot] ~= nil then
      table.insert(parts, (SLOT_LABEL[slot] or ("slot " .. slot)) .. " " ..
        (changes[slot] and ItemName(changes[slot]) or "|cff808080empty|r"))
    end
  end
  Say(string.format("updated |cffffffff%s|r: %s.", name, table.concat(parts, ", ")))
end

local function CheckGearSave()
  saveTimer = nil
  -- a set that fully matches now is simply the set you're wearing
  local equipped = EquippedSet()
  if equipped then wornSet = equipped return end
  if not (db.autoSave and wornSet and SetInfo(wornSet)) then return end
  if swapPending or GetTime() - selfSwap < 2 then return end
  if InCombatLockdown() then pendingSave = true return end
  if not C_EquipmentSet.SaveEquipmentSet then return end
  SaveWorn(false)
end

local function QueueGearSave()
  if saveTimer then saveTimer:Cancel() end
  saveTimer = C_Timer.NewTimer(0.7, CheckGearSave)
end

---------------------------------------------------------------------------
-- Action bar backup
---------------------------------------------------------------------------

local MAX_SLOTS = 120
for _, n in ipairs({ 180, 132 }) do
  if pcall(GetActionInfo, n) then MAX_SLOTS = n break end
end
local WIPE_COUNT = 6       -- this many slots emptied within WIPE_WINDOW = a wipe, not you
local WIPE_WINDOW = 1.0
local WIPE_AFTER_SWITCH = 15 -- ...but only this soon after a spec switch (ActionBarSaver
                             -- restores also empty many slots at once, and are wanted)
local barGuardUntil = 0    -- no recording until then (spec switch in progress)
local lastSpecSwitch = -100
local clearedSlots = {}    -- [slot] = true, emptied slots waiting to be judged
local clearTimer
local restorePending = false
local barsReady = false    -- first login snapshot taken

local function Bars(group)
  db.bars[group] = db.bars[group] or {}
  return db.bars[group]
end

-- What a slot holds, as stored: { type, id, name } or nil.
local function ReadSlot(slot)
  local kind, id = GetActionInfo(slot)
  if not kind then return nil end
  local e = { type = kind, id = id }
  if kind == "macro" then
    e.name = GetActionText(slot)
    if not e.name then return nil end
  elseif kind == "spell" then
    local f = (C_Spell and C_Spell.GetSpellName) or GetSpellInfo
    e.name = id and f and f(id) or nil
  elseif kind ~= "item" and kind ~= "equipmentset" then
    return nil -- companions, flyouts...: not restorable here
  end
  return e
end

local function Record(slot)
  Bars(ActiveGroup())[slot] = ReadSlot(slot) or false
end

local function SnapshotAll(group, keepEmpties)
  local bars = Bars(group)
  for slot = 1, MAX_SLOTS do
    local e = ReadSlot(slot)
    if e then bars[slot] = e
    elseif not keepEmpties then bars[slot] = false end
  end
end

local PickupSpellF = (C_Spell and C_Spell.PickupSpell) or PickupSpell
local PickupItemF = (C_Item and C_Item.PickupItem) or PickupItem

local function PickupEntry(e)
  if e.type == "spell" then
    pcall(PickupSpellF, e.id)
    if not GetCursorInfo() and e.name then pcall(PickupSpellF, e.name) end
  elseif e.type == "item" then
    pcall(PickupItemF, e.id)
  elseif e.type == "macro" then
    pcall(PickupMacro, e.name)
  elseif e.type == "equipmentset" then
    local setID = C_EquipmentSet.GetEquipmentSetID and C_EquipmentSet.GetEquipmentSetID(e.id)
    if setID then pcall(C_EquipmentSet.PickupEquipmentSet, setID) end
  end
  return GetCursorInfo() == e.type
end

-- Fill the empty slots the backup has something for. Returns restored, failed.
local function RestoreBars(onlySlots)
  if InCombatLockdown() then restorePending = true return 0, 0 end
  if GetCursorInfo() then -- you're holding something: try again shortly
    C_Timer.After(1, function() RestoreBars(onlySlots) end)
    return 0, 0
  end
  local bars = Bars(ActiveGroup())
  local restored, failed = 0, {}
  for slot = 1, MAX_SLOTS do
    local e = bars[slot]
    if e and (not onlySlots or onlySlots[slot]) and not GetActionInfo(slot) then
      if PickupEntry(e) then
        PlaceAction(slot)
        restored = restored + 1
      else
        table.insert(failed, e.name or tostring(e.id))
      end
      ClearCursor()
    end
  end
  if restored > 0 then
    Say(string.format("restored %d action bar slot%s.", restored, restored == 1 and "" or "s"))
  end
  if #failed > 0 then
    Say("couldn't restore: " .. table.concat(failed, ", ") .. ".")
  end
  return restored, #failed
end

-- Emptied slots are judged together: a handful is you, a whole bar at once is the bug.
local function JudgeCleared()
  clearTimer = nil
  local slots, n = {}, 0
  for slot in pairs(clearedSlots) do
    if not GetActionInfo(slot) then slots[slot] = true n = n + 1 else Record(slot) end
  end
  wipe(clearedSlots)
  if n == 0 then return end
  if n >= WIPE_COUNT and db.barRestore and GetTime() - lastSpecSwitch < WIPE_AFTER_SWITCH then
    Say(string.format("%d action slots emptied at once; putting them back.", n))
    RestoreBars(slots)
  else
    for slot in pairs(slots) do Record(slot) end
  end
end

local function OnSlotChanged(slot)
  if not (db.barRestore and barsReady) then return end
  if not slot or slot < 1 or slot > MAX_SLOTS then return end
  -- mid-switch: the bars are loading the other spec's layout
  if GetTime() < barGuardUntil or ActiveGroup() ~= lastGroup then return end
  if GetActionInfo(slot) then
    clearedSlots[slot] = nil
    Record(slot)
  else
    clearedSlots[slot] = true
    if not clearTimer then clearTimer = C_Timer.NewTimer(WIPE_WINDOW, JudgeCleared) end
  end
end

local function BarsAfterSpecChange(group)
  if not db.barRestore then return end
  wipe(clearedSlots)
  lastSpecSwitch = GetTime()
  barGuardUntil = GetTime() + 4
  -- two passes: bars can arrive a little after the switch
  C_Timer.After(1.0, function() if ActiveGroup() == group then RestoreBars() end end)
  C_Timer.After(3.0, function()
    if ActiveGroup() ~= group then return end
    RestoreBars()
    -- the new spec's own layout counts from here: record what's set
    SnapshotAll(group, true)
  end)
end

local function BarsAtLogin()
  C_Timer.After(3, function()
    local g = ActiveGroup()
    local first = next(Bars(g)) == nil
    -- first time: full backup; later: add what's set, keep the rest
    SnapshotAll(g, not first)
    barsReady = true
  end)
end

---------------------------------------------------------------------------
-- Spec change
---------------------------------------------------------------------------

local function OnSpecChanged()
  local g = ActiveGroup()
  if g == lastGroup then return end
  lastGroup = g
  BarsAfterSpecChange(g)
  if not db.enabled then return end
  -- let the talent swap settle (spells, stats) before swapping gear
  C_Timer.After(0.3, function()
    if ActiveGroup() == g then EquipForGroup(g) end
  end)
end

---------------------------------------------------------------------------
-- Slash
---------------------------------------------------------------------------

local function Status()
  Say(string.format("%s, now in %s. Learn: %s, tree-name match: %s, gear auto-save: %s.",
    db.enabled and "|cff00ff00on|r" or "|cffff4040off|r", SpecLabel(ActiveGroup()),
    db.learn and "on" or "off", db.byName and "on" or "off", db.autoSave and "on" or "off"))
  local worn = wornSet and SetInfo(wornSet)
  DEFAULT_CHAT_FRAME:AddMessage("  Wearing: " .. (worn and ("|cffffffff" .. worn .. "|r" ..
    (EquippedSet() == wornSet and "" or " (gear changed since)")) or "|cff808080no set|r"))
  for g = 1, NumGroups() do
    local id, name, how = SetForGroup(g)
    local line = id and string.format("|cffffffff%s|r (%s)", name, how) or "|cff808080no set|r"
    if db.links[g] and not id then line = string.format("|cffff8080%s (set not found)|r", db.links[g].name) end
    DEFAULT_CHAT_FRAME:AddMessage(string.format("  %s%s: %s", SpecLabel(g), g == ActiveGroup() and " *" or "", line))
  end
end

local function ParseGroup(s)
  local g = tonumber(s)
  if g and g >= 1 and g <= NumGroups() then return g end
end

local function Slash(msg)
  msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
  local cmd, rest = msg:match("^(%S*)%s*(.*)$")
  cmd = cmd:lower()
  if cmd == "" or cmd == "status" then
    Status()
  elseif cmd == "on" or cmd == "off" then
    db.enabled = (cmd == "on")
    Say("auto swap " .. (db.enabled and "on" or "off"))
  elseif cmd == "sets" or cmd == "list" then
    local ids = SetIDs()
    if #ids == 0 then Say("you have no gear sets.") return end
    Say("your gear sets:")
    for _, id in ipairs(ids) do
      local name, _, isEquipped, numLost = SetInfo(id)
      DEFAULT_CHAT_FRAME:AddMessage(string.format("  %s%s%s", name, isEquipped and " |cff00ff00(equipped)|r" or "",
        numLost > 0 and string.format(" |cffff8080(%d missing)|r", numLost) or ""))
    end
  elseif cmd == "link" then
    local g = ParseGroup(rest) or ActiveGroup()
    local id = EquippedSet()
    if not id then Say("you aren't wearing a complete gear set. Equip one first, or use |cffffffff/specgear set <spec> <set name>|r.") return end
    Link(g, id)
  elseif cmd == "set" then
    local gs, name = rest:match("^(%d)%s+(.+)$")
    local g = ParseGroup(gs)
    if not g then Say("usage: /specgear set <1-" .. NumGroups() .. "> <set name>") return end
    local id = FindSetByName(name)
    if not id then Say("no gear set named \"" .. name .. "\". /specgear sets lists them.") return end
    Link(g, id)
    if g == ActiveGroup() and db.enabled then EquipForGroup(g, true) end
  elseif cmd == "clear" then
    local g = ParseGroup(rest)
    if not g then Say("usage: /specgear clear <1-" .. NumGroups() .. ">") return end
    db.links[g] = nil
    Say(SpecLabel(g) .. " link cleared.")
  elseif cmd == "equip" then
    EquipForGroup(ActiveGroup())
  elseif cmd == "learn" then
    db.learn = (rest == "on") or (rest ~= "off" and not db.learn)
    Say("learn " .. (db.learn and "on: the first set you equip in an unlinked spec gets linked to it." or "off"))
  elseif cmd == "byname" then
    db.byName = (rest == "on") or (rest ~= "off" and not db.byName)
    Say("tree-name match " .. (db.byName and "on" or "off"))
  elseif cmd == "autosave" then
    db.autoSave = (rest == "on") or (rest ~= "off" and not db.autoSave)
    Say("gear auto-save " .. (db.autoSave and "on: replacing a piece of gear while wearing a set updates that set." or "off"))
  elseif cmd == "bars" then
    local sub = rest:lower()
    if sub == "on" or sub == "off" then
      db.barRestore = (sub == "on")
      Say("action bar restore " .. (db.barRestore and "on" or "off"))
    elseif sub == "restore" then
      local r, f = RestoreBars()
      if r == 0 and f == 0 and not InCombatLockdown() then Say("no empty slots to fill from the backup.") end
    elseif sub == "save" then
      SnapshotAll(ActiveGroup(), false)
      Say(SpecLabel(ActiveGroup()) .. ": action bars backed up as they are now.")
    else
      for g = 1, NumGroups() do
        local n = 0
        for _, e in pairs(Bars(g)) do if e then n = n + 1 end end
        DEFAULT_CHAT_FRAME:AddMessage(string.format("  %s%s: %d action%s backed up", SpecLabel(g),
          g == ActiveGroup() and " *" or "", n, n == 1 and "" or "s"))
      end
      Say("action bar restore " .. (db.barRestore and "on" or "off") ..
        ". /specgear bars on|off | restore (fill empty slots now) | save (back up the bars as they are)")
    end
  elseif cmd == "why" then
    if not wornSet or not SetInfo(wornSet) then Say("not wearing a set.") return end
    local changes, reason = GearChanges(wornSet)
    Say(SetInfo(wornSet) .. ": " .. (changes and (reason .. " slot(s) differ, it would be saved") or ("no save: " .. reason)))
  elseif cmd == "save" then
    if not wornSet or not SetInfo(wornSet) then Say("not wearing a set (put one on first).") return end
    if InCombatLockdown() then Say("can't save a set in combat.") return end
    SaveWorn(true)
  else
    Say("/specgear [status] | on | off | sets | link [spec] | set <spec> <set name> | clear <spec> | equip | learn on|off | byname on|off | autosave on|off | save | why | bars [on|off|restore|save]")
  end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:SetScript("OnEvent", function(_, event, arg1, arg2)
  if event == "ADDON_LOADED" then
    if arg1 ~= addonName then return end
    SpecGearSwapDB = SpecGearSwapDB or {}
    db = SpecGearSwapDB
    for k, v in pairs(defaults) do
      if db[k] == nil then db[k] = (type(v) == "table") and {} or v end
    end
    SLASH_SPECGEARSWAP1, SLASH_SPECGEARSWAP2 = "/specgear", "/sgs"
    SlashCmdList.SPECGEARSWAP = Slash
    if not (C_EquipmentSet and C_EquipmentSet.GetEquipmentSetIDs) then
      Say("this client has no equipment manager API; the addon does nothing.")
      return
    end
    ev:RegisterEvent("PLAYER_ENTERING_WORLD")
    ev:RegisterEvent("ACTIVE_TALENT_GROUP_CHANGED")
    ev:RegisterEvent("PLAYER_TALENT_UPDATE")
    ev:RegisterEvent("PLAYER_REGEN_ENABLED")
    ev:RegisterEvent("EQUIPMENT_SWAP_FINISHED")
    ev:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
    ev:RegisterEvent("ACTIONBAR_SLOT_CHANGED")
    pcall(ev.RegisterEvent, ev, "EQUIPMENT_SWAP_PENDING")
  elseif event == "PLAYER_ENTERING_WORLD" then
    if not lastGroup then
      lastGroup = ActiveGroup()
      BarsAtLogin()
    end
    if not wornSet then wornSet = EquippedSet() end
  elseif event == "ACTIONBAR_SLOT_CHANGED" then
    OnSlotChanged(arg1)
  elseif event == "PLAYER_EQUIPMENT_CHANGED" then
    if arg1 and arg1 >= 1 and arg1 <= 18 and not SKIP_SLOTS[arg1] then QueueGearSave() end
  elseif event == "EQUIPMENT_SWAP_PENDING" then
    swapPending = true
  elseif event == "ACTIVE_TALENT_GROUP_CHANGED" or event == "PLAYER_TALENT_UPDATE" then
    if lastGroup then OnSpecChanged() end
  elseif event == "PLAYER_REGEN_ENABLED" then
    if restorePending then
      restorePending = false
      RestoreBars()
    end
    if pendingSave then
      pendingSave = false
      QueueGearSave()
    end
    if pendingEquip then
      local g = pendingEquip
      pendingEquip = nil
      if g == ActiveGroup() then EquipForGroup(g, true) end
    end
  elseif event == "EQUIPMENT_SWAP_FINISHED" then
    -- arg1 = success, arg2 = setID. Learn: a set equipped by hand while the
    -- active spec has no link (and no tree-name set) becomes its set.
    local ok, setID = arg1, arg2
    swapPending = false
    if ok and setID then wornSet = setID end
    if not (ok and setID and db.learn) then return end
    if GetTime() - selfSwap < 3 then return end
    local g = ActiveGroup()
    if db.links[g] or SetForGroup(g) then return end
    Link(g, setID)
  end
end)
