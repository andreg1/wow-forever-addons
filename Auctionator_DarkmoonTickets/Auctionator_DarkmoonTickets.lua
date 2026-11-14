--[[
  Auctionator - Darkmoon Tickets

  Ranks every Darkmoon Faire Prize Ticket turn-in by how much it costs per
  ticket at the auction house, using the prices Auctionator stored on its
  last scan:  cost per ticket = AH unit price * items per turn-in / tickets.

  Public surfaces used:
    - Auctionator.API.v1.GetAuctionPriceByItemLink / ...ByItemID  (price)
    - Auctionator.API.v1.GetAuctionAgeByItemID   (days since last seen)
    - Auctionator.API.v1.RegisterForDBUpdate     (refresh after a scan)
    - Auctionator.API.v1.MultiSearchExact        ("Search AH" button)
    Every call is feature-checked and pcall'd: the v1 API raises errors
    (ComposeError) on bad state, e.g. MultiSearch with the AH closed.

  Ticket data: the built-in table comes from community guides and was not
  verified in-game. When you turn a quest in, the addon reads the real
  counts from the quest window (required item count on QUEST_PROGRESS, the
  Prize Ticket reward count on QUEST_COMPLETE) and stores them account-wide
  in DarkmoonTicketsDB.learned, which overrides the built-in numbers.

  Reputation: tiers 1-4 stop being offered at a Darkmoon Faire reputation
  value (approximate, from the same guides); those rows are greyed and sorted
  after the ones you can still turn in.

  No secure frames are touched; the window is a plain frame.
]]

local addonName = ...
local CALLER = "DarkmoonTickets"
local TICKET_ID = 19182
local FACTION_ID = 909 -- Darkmoon Faire

local defaults = {
  learned = {},        -- [itemID] = { qty = n, tickets = n }
  hideCapped = false,
  includeBank = true,
  tooltip = true,
}

-- tier caps: tier offered while DMF reputation value (absolute, Neutral = 0) is below this
local TIER_CAP = { [1] = 401, [2] = 1100, [3] = 1625, [4] = 2500 }

local TURNINS = {
  { id = 3240,  name = "Coarse Weightstone",      qty = 10, tickets = 1,  tier = 1, src = "Blacksmithing" },
  { id = 4363,  name = "Copper Modulator",        qty = 3,  tickets = 1,  tier = 1, src = "Engineering" },
  { id = 2309,  name = "Embossed Leather Boots",  qty = 3,  tickets = 1,  tier = 1, src = "Leatherworking" },
  { id = 5134,  name = "Small Furry Paw",         qty = 5,  tickets = 1,  tier = 1, src = "Beast drop" },
  { id = 3486,  name = "Heavy Grinding Stone",    qty = 7,  tickets = 4,  tier = 2, src = "Blacksmithing" },
  { id = 4375,  name = "Whirring Bronze Gizmo",   qty = 7,  tickets = 4,  tier = 2, src = "Engineering" },
  { id = 2314,  name = "Toughened Leather Armor", qty = 3,  tickets = 4,  tier = 2, src = "Leatherworking" },
  { id = 11407, name = "Torn Bear Pelt",          qty = 5,  tickets = 4,  tier = 2, src = "Beast drop" },
  { id = 3835,  name = "Green Iron Bracers",      qty = 3,  tickets = 8,  tier = 3, src = "Blacksmithing" },
  { id = 9313,  name = "Green Firework",          qty = 36, tickets = 8,  tier = 3, src = "Engineering" },
  { id = 5739,  name = "Barbaric Harness",        qty = 3,  tickets = 8,  tier = 3, src = "Leatherworking" },
  { id = 4582,  name = "Soft Bushy Tail",         qty = 5,  tickets = 8,  tier = 3, src = "Beast drop" },
  { id = 7945,  name = "Big Black Mace",          qty = 3,  tickets = 12, tier = 4, src = "Blacksmithing" },
  { id = 11590, name = "Mechanical Repair Kit",   qty = 6,  tickets = 12, tier = 4, src = "Engineering" },
  { id = 8185,  name = "Turtle Scale Leggings",   qty = 1,  tickets = 12, tier = 4, src = "Leatherworking" },
  { id = 5117,  name = "Vibrant Plume",           qty = 5,  tickets = 12, tier = 4, src = "Beast drop" },
  { id = 12644, name = "Dense Grinding Stone",    qty = 8,  tickets = 20, tier = 5, src = "Blacksmithing" },
  { id = 15994, name = "Thorium Widget",          qty = 6,  tickets = 20, tier = 5, src = "Engineering" },
  { id = 15564, name = "Rugged Armor Kit",        qty = 8,  tickets = 20, tier = 5, src = "Leatherworking" },
  { id = 11404, name = "Evil Bat Eye",            qty = 10, tickets = 20, tier = 5, src = "Beast drop" },
  { id = 19933, name = "Glowing Scorpid Blood",   qty = 10, tickets = 20, tier = 5, src = "Beast drop" },
}

local byID = {}
for _, t in ipairs(TURNINS) do byID[t.id] = t end

local db
local frame, rows = nil, {}

local function Say(msg)
  DEFAULT_CHAT_FRAME:AddMessage("|cffd16bffDarkmoon Tickets|r: " .. tostring(msg))
end

---------------------------------------------------------------------------
-- Data helpers
---------------------------------------------------------------------------

local function TurnIn(t)
  local l = db and db.learned[t.id]
  if l and l.qty and l.tickets and l.tickets > 0 then
    return l.qty, l.tickets, true
  end
  return t.qty, t.tickets, false
end

local function ItemInfo(id)
  local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
  local name, link, _, _, _, _, _, _, _, icon = getInfo(id)
  if not name and C_Item and C_Item.RequestLoadItemDataByID then
    pcall(C_Item.RequestLoadItemDataByID, id)
  end
  if not icon then
    local getInstant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    if getInstant then icon = select(5, getInstant(id)) end
  end
  return name, link, icon
end

local function HaveAPI()
  return Auctionator and Auctionator.API and Auctionator.API.v1
end

local function Price(id, link)
  local api = HaveAPI()
  if not api then return nil end
  local price
  if link and api.GetAuctionPriceByItemLink then
    local ok, p = pcall(api.GetAuctionPriceByItemLink, CALLER, link)
    if ok then price = p end
  end
  if not price and api.GetAuctionPriceByItemID then
    local ok, p = pcall(api.GetAuctionPriceByItemID, CALLER, id)
    if ok then price = p end
  end
  return price
end

local function Age(id)
  local api = HaveAPI()
  if not (api and api.GetAuctionAgeByItemID) then return nil end
  local ok, a = pcall(api.GetAuctionAgeByItemID, CALLER, id)
  if ok then return a end
end

local function Count(id)
  local inc = db and db.includeBank
  if C_Item and C_Item.GetItemCount then
    local ok, n = pcall(C_Item.GetItemCount, id, inc)
    if ok and n then return n end
  end
  if GetItemCount then return GetItemCount(id, inc) or 0 end
  return 0
end

local function Reputation()
  if C_Reputation and C_Reputation.GetFactionDataByID then
    local ok, d = pcall(C_Reputation.GetFactionDataByID, FACTION_ID)
    if ok and d and d.currentStanding then
      return d.currentStanding, d.reaction
    end
  end
  if GetFactionInfoByID then
    local ok, _, _, standingID, _, _, value = pcall(GetFactionInfoByID, FACTION_ID)
    if ok and value then return value, standingID end
  end
  return nil
end

local function IsCapped(tier, rep)
  local cap = TIER_CAP[tier]
  return cap ~= nil and rep ~= nil and rep >= cap
end

local function Money(copper)
  if not copper then return "|cff808080--|r" end
  copper = math.floor(copper + 0.5)
  if GetCoinTextureString then
    local ok, s = pcall(GetCoinTextureString, copper)
    if ok and s then return s end
  end
  local g, s, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
  if g > 0 then return string.format("%dg %02ds %02dc", g, s, c) end
  if s > 0 then return string.format("%ds %02dc", s, c) end
  return c .. "c"
end

-- Builds the ranked list. Each entry: t, name, link, icon, qty, tickets,
-- learned, unit, perTicket, perTurnIn, age, have, capped.
local function BuildList()
  local rep = Reputation()
  local list = {}
  for _, t in ipairs(TURNINS) do
    local name, link, icon = ItemInfo(t.id)
    local qty, tickets, learned = TurnIn(t)
    local unit = Price(t.id, link)
    local e = {
      t = t, name = name or t.name, link = link, icon = icon,
      qty = qty, tickets = tickets, learned = learned,
      unit = unit, age = Age(t.id), have = Count(t.id),
      capped = IsCapped(t.tier, rep),
    }
    if unit then
      e.perTurnIn = unit * qty
      e.perTicket = e.perTurnIn / tickets
    end
    if not (e.capped and db.hideCapped) then
      table.insert(list, e)
    end
  end
  table.sort(list, function(a, b)
    if a.capped ~= b.capped then return not a.capped end
    if (a.perTicket ~= nil) ~= (b.perTicket ~= nil) then return a.perTicket ~= nil end
    if a.perTicket and b.perTicket and a.perTicket ~= b.perTicket then
      return a.perTicket < b.perTicket
    end
    return a.t.id < b.t.id
  end)
  return list, rep
end

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------

local ROW_H, NUM_ROWS, WIDTH = 20, #TURNINS, 700
local COLS = { -- x offset, width, justify
  rank   = { 8,   20,  "RIGHT" },
  item   = { 34,  200, "LEFT" },
  turnin = { 238, 70,  "CENTER" },
  unit   = { 310, 100, "RIGHT" },
  ticket = { 414, 110, "RIGHT" },
  seen   = { 528, 50,  "CENTER" },
  have   = { 580, 50,  "CENTER" },
  tier   = { 632, 56,  "CENTER" },
}

local function MakeText(parent, col, font)
  local c = COLS[col]
  local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
  fs:SetPoint("LEFT", parent, "LEFT", c[1], 0)
  fs:SetWidth(c[2])
  fs:SetJustifyH(c[3])
  fs:SetWordWrap(false)
  return fs
end

local Refresh

local function CreateWindow()
  local ok, f = pcall(CreateFrame, "Frame", "DarkmoonTicketsFrame", UIParent, "BasicFrameTemplateWithInset")
  if not ok or not f then
    f = CreateFrame("Frame", "DarkmoonTicketsFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    if f.SetBackdrop then
      f:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background", edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32, insets = { left = 8, right = 8, top = 8, bottom = 8 } })
    end
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -4, -4)
  end
  f:SetSize(WIDTH, 92 + ROW_H * NUM_ROWS + 34)
  f:SetPoint("CENTER")
  f:SetFrameStrata("HIGH")
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", f.StopMovingOrSizing)
  f:SetClampedToScreen(true)
  f:Hide()
  tinsert(UISpecialFrames, "DarkmoonTicketsFrame")

  local title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  title:SetPoint("TOP", 0, -5)
  title:SetText("Darkmoon Faire - cost per Prize Ticket (Auctionator last scan)")

  f.summary = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  f.summary:SetPoint("TOPLEFT", 14, -32)
  f.summary:SetPoint("RIGHT", -14, 0)
  f.summary:SetJustifyH("LEFT")

  local header = CreateFrame("Frame", nil, f)
  header:SetPoint("TOPLEFT", 6, -58)
  header:SetSize(WIDTH - 12, ROW_H)
  local labels = { rank = "#", item = "Item", turnin = "Items > Tix", unit = "AH unit", ticket = "Per ticket", seen = "Seen", have = "Have", tier = "Tier" }
  for col, text in pairs(labels) do
    local fs = MakeText(header, col, "GameFontNormalSmall")
    fs:SetText(text)
  end

  for i = 1, NUM_ROWS do
    local r = CreateFrame("Button", nil, f)
    r:SetSize(WIDTH - 12, ROW_H)
    r:SetPoint("TOPLEFT", 6, -58 - ROW_H * i)
    r.bg = r:CreateTexture(nil, "BACKGROUND")
    r.bg:SetAllPoints()
    r.bg:SetColorTexture(1, 1, 1, (i % 2 == 0) and 0.04 or 0)
    r.hl = r:CreateTexture(nil, "HIGHLIGHT")
    r.hl:SetAllPoints()
    r.hl:SetColorTexture(1, 1, 1, 0.08)
    r.icon = r:CreateTexture(nil, "ARTWORK")
    r.icon:SetSize(ROW_H - 4, ROW_H - 4)
    r.icon:SetPoint("LEFT", COLS.item[1], 0)
    r.rank, r.turnin, r.unit = MakeText(r, "rank"), MakeText(r, "turnin"), MakeText(r, "unit")
    r.ticket, r.seen, r.have, r.tier = MakeText(r, "ticket"), MakeText(r, "seen"), MakeText(r, "have"), MakeText(r, "tier")
    r.item = MakeText(r, "item")
    r.item:ClearAllPoints()
    r.item:SetPoint("LEFT", r.icon, "RIGHT", 4, 0)
    r.item:SetWidth(COLS.item[2] - ROW_H)
    r:SetScript("OnEnter", function(self)
      if not self.entry then return end
      local e = self.entry
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetItemByID(e.t.id)
      GameTooltip:AddLine(" ")
      GameTooltip:AddLine(string.format("Turn-in: %d for %d ticket%s%s", e.qty, e.tickets, e.tickets == 1 and "" or "s",
        e.learned and " |cff00ff00(seen in quest window)|r" or " |cffaaaaaa(guide data)|r"), 1, 1, 1)
      GameTooltip:AddLine("Source: " .. e.t.src, 0.8, 0.8, 0.8)
      if e.perTurnIn then GameTooltip:AddLine("Cost per turn-in: " .. Money(e.perTurnIn), 1, 1, 1) end
      if e.have and e.have > 0 then
        GameTooltip:AddLine(string.format("You have %d (%d turn-in%s)", e.have, math.floor(e.have / e.qty),
          math.floor(e.have / e.qty) == 1 and "" or "s"), 0.6, 1, 0.6)
      end
      if e.capped then GameTooltip:AddLine("Your Darkmoon reputation is past this tier (approximate cap).", 1, 0.4, 0.4, true) end
      GameTooltip:AddLine("Shift-click: link in chat", 0.5, 0.5, 0.5)
      GameTooltip:Show()
    end)
    r:SetScript("OnLeave", function() GameTooltip:Hide() end)
    r:SetScript("OnClick", function(self)
      if self.entry and IsModifiedClick("CHATLINK") then
        local _, link = ItemInfo(self.entry.t.id)
        if link and ChatEdit_InsertLink then ChatEdit_InsertLink(link) end
      end
    end)
    rows[i] = r
  end

  local search = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  search:SetSize(150, 22)
  search:SetPoint("BOTTOMLEFT", 12, 10)
  search:SetText("Search all on AH")
  search:SetScript("OnClick", function()
    local api = HaveAPI()
    if not (api and api.MultiSearchExact) then Say("Auctionator's MultiSearchExact API is missing.") return end
    local names = {}
    for _, t in ipairs(TURNINS) do
      local name = ItemInfo(t.id)
      table.insert(names, name or t.name)
    end
    local ok, err = pcall(api.MultiSearchExact, CALLER, names)
    if not ok then Say("Open the auction house first. (" .. tostring(err):gsub("^.-: ", "") .. ")") end
  end)
  f.search = search

  local capped = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
  capped:SetSize(24, 24)
  capped:SetPoint("LEFT", search, "RIGHT", 12, 0)
  local cl = capped:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  cl:SetPoint("LEFT", capped, "RIGHT", 2, 0)
  cl:SetText("Hide tiers past my reputation")
  capped:SetScript("OnClick", function(self) db.hideCapped = self:GetChecked() and true or false; Refresh() end)
  f.cappedCheck = capped

  local bank = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
  bank:SetSize(24, 24)
  bank:SetPoint("LEFT", cl, "RIGHT", 14, 0)
  local bl = bank:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  bl:SetPoint("LEFT", bank, "RIGHT", 2, 0)
  bl:SetText("Count bank items")
  bank:SetScript("OnClick", function(self) db.includeBank = self:GetChecked() and true or false; Refresh() end)
  f.bankCheck = bank

  f:SetScript("OnShow", function() Refresh() end)
  frame = f
end

Refresh = function()
  if not (frame and frame:IsShown()) then return end
  frame.cappedCheck:SetChecked(db.hideCapped)
  frame.bankCheck:SetChecked(db.includeBank)
  local list, rep = BuildList()

  local best
  for _, e in ipairs(list) do
    if not e.capped and e.perTicket then best = e break end
  end
  local repText = rep and string.format("DMF reputation %d", rep) or "DMF reputation unknown"
  if best then
    frame.summary:SetText(string.format("Best: |cffffffff%s|r at %s per ticket  (%d for %d tickets = %s)   |cffaaaaaa%s|r",
      best.name, Money(best.perTicket), best.qty, best.tickets, Money(best.perTurnIn), repText))
  else
    frame.summary:SetText("No Auctionator prices for these items yet: scan the AH or use \"Search all on AH\".   |cffaaaaaa" .. repText .. "|r")
  end

  for i, r in ipairs(rows) do
    local e = list[i]
    r.entry = e
    if not e then
      r:Hide()
    else
      r:Show()
      local dim = e.capped
      local function c(s) return dim and ("|cff707070" .. s .. "|r") or s end
      r.rank:SetText(c(tostring(i)))
      r.icon:SetTexture(e.icon or 134400)
      r.icon:SetDesaturated(dim)
      r.item:SetText(dim and c(e.name) or (e == best and ("|cff00ff00" .. e.name .. "|r") or e.name))
      r.turnin:SetText(c(string.format("%d > %d%s", e.qty, e.tickets, e.learned and "" or "*")))
      r.unit:SetText(e.unit and c(Money(e.unit)) or "|cff808080no price|r")
      r.ticket:SetText(e.perTicket and c(Money(e.perTicket)) or "|cff808080--|r")
      local seen = e.age == nil and "-" or (e.age == 0 and "today" or (e.age .. "d"))
      r.seen:SetText(c(seen))
      r.have:SetText(c(e.have > 0 and (e.have >= e.qty and ("|cff00ff00" .. e.have .. "|r") or tostring(e.have)) or "-"))
      r.tier:SetText(c(e.capped and ("T" .. e.t.tier .. " cap") or ("T" .. e.t.tier)))
    end
  end
end

---------------------------------------------------------------------------
-- Learning real counts from the quest window
---------------------------------------------------------------------------

local pending -- { id, qty, title }

local function ItemIDFromLink(link)
  return link and tonumber(link:match("item:(%d+)"))
end

local function OnQuestProgress()
  pending = nil
  local n = GetNumQuestItems and GetNumQuestItems() or 0
  for i = 1, n do
    local id = ItemIDFromLink(GetQuestItemLink("required", i))
    local _, _, count = GetQuestItemInfo("required", i)
    if id and byID[id] and count then
      pending = { id = id, qty = count, title = GetTitleText and GetTitleText() }
      return
    end
  end
end

local function OnQuestComplete()
  if not pending then return end
  if GetTitleText and pending.title and GetTitleText() ~= pending.title then pending = nil return end
  local n = GetNumQuestRewards and GetNumQuestRewards() or 0
  for i = 1, n do
    local id = ItemIDFromLink(GetQuestItemLink("reward", i))
    if id == TICKET_ID then
      local _, _, count = GetQuestItemInfo("reward", i)
      if count and count > 0 then
        local t = byID[pending.id]
        local old = db.learned[pending.id]
        db.learned[pending.id] = { qty = pending.qty, tickets = count }
        if (not old and (t.qty ~= pending.qty or t.tickets ~= count)) or (old and (old.qty ~= pending.qty or old.tickets ~= count)) then
          Say(string.format("learned %s: %d for %d tickets (was %d for %d).", t.name, pending.qty, count,
            old and old.qty or t.qty, old and old.tickets or t.tickets))
        end
        Refresh()
      end
      break
    end
  end
  pending = nil
end

---------------------------------------------------------------------------
-- Tooltip line
---------------------------------------------------------------------------

local function AddTooltipLine(tt, id)
  if not (db and db.tooltip and id and byID[id]) then return end
  local t = byID[id]
  local qty, tickets = TurnIn(t)
  local _, link = ItemInfo(id)
  local unit = Price(id, link)
  local text = string.format("Darkmoon: %d for %d ticket%s", qty, tickets, tickets == 1 and "" or "s")
  if unit then text = text .. " (" .. Money(unit * qty / tickets) .. " per ticket)" end
  tt:AddLine(text, 0.82, 0.42, 1)
end

local function InstallTooltip()
  if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tt, data)
      if tt ~= GameTooltip and tt ~= ItemRefTooltip then return end
      AddTooltipLine(tt, data and data.id)
    end)
  elseif GameTooltip.HasScript and GameTooltip:HasScript("OnTooltipSetItem") then
    GameTooltip:HookScript("OnTooltipSetItem", function(tt)
      local _, link = tt:GetItem()
      AddTooltipLine(tt, ItemIDFromLink(link))
    end)
  end
end

---------------------------------------------------------------------------
-- Slash + events
---------------------------------------------------------------------------

local function PrintBest(n)
  local list, rep = BuildList()
  local shown = 0
  Say(string.format("cheapest tickets from the last Auctionator scan%s:", rep and (" (DMF rep " .. rep .. ")") or ""))
  for _, e in ipairs(list) do
    if e.perTicket and not e.capped then
      shown = shown + 1
      DEFAULT_CHAT_FRAME:AddMessage(string.format("  %d. %s - %s per ticket (%d for %d, %s per turn-in)",
        shown, e.link or e.name, Money(e.perTicket), e.qty, e.tickets, Money(e.perTurnIn)))
      if shown >= n then break end
    end
  end
  if shown == 0 then Say("no prices yet. Scan the AH with Auctionator first.") end
end

local function Slash(msg)
  msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
  local cmd, arg = msg:match("^(%S*)%s*(.*)$")
  if cmd == "" or cmd == "show" then
    if not frame then CreateWindow() end
    frame:SetShown(not frame:IsShown())
  elseif cmd == "best" then
    PrintBest(tonumber(arg) or 5)
  elseif cmd == "tooltip" then
    db.tooltip = (arg == "on") or (arg ~= "off" and not db.tooltip)
    Say("tooltip line " .. (db.tooltip and "on" or "off"))
  elseif cmd == "learned" then
    local any = false
    for id, l in pairs(db.learned) do
      any = true
      Say(string.format("%s: %d for %d tickets", byID[id] and byID[id].name or id, l.qty, l.tickets))
    end
    if not any then Say("nothing learned yet; counts update when you turn a quest in.") end
  elseif cmd == "forget" then
    wipe(db.learned)
    Say("learned counts cleared; using the built-in table.")
    Refresh()
  else
    Say("/dmft - toggle window | best [n] - top n in chat | tooltip on|off | learned | forget")
  end
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:SetScript("OnEvent", function(_, event, arg1)
  if event == "ADDON_LOADED" then
    if arg1 ~= addonName then return end
    DarkmoonTicketsDB = DarkmoonTicketsDB or {}
    db = DarkmoonTicketsDB
    for k, v in pairs(defaults) do
      if db[k] == nil then db[k] = (type(v) == "table") and {} or v end
    end
    SLASH_DARKMOONTICKETS1, SLASH_DARKMOONTICKETS2 = "/dmft", "/dmtickets"
    SlashCmdList.DARKMOONTICKETS = Slash
    InstallTooltip()
    local api = HaveAPI()
    if api and api.RegisterForDBUpdate then
      pcall(api.RegisterForDBUpdate, CALLER, function() Refresh() end)
    elseif not api then
      Say("Auctionator API v1 not found; prices will be missing.")
    end
    ev:RegisterEvent("QUEST_PROGRESS")
    ev:RegisterEvent("QUEST_COMPLETE")
    ev:RegisterEvent("GET_ITEM_INFO_RECEIVED")
    ev:RegisterEvent("BAG_UPDATE_DELAYED")
    ev:RegisterEvent("UPDATE_FACTION")
    for _, t in ipairs(TURNINS) do ItemInfo(t.id) end -- warm the item cache
  elseif event == "QUEST_PROGRESS" then
    OnQuestProgress()
  elseif event == "QUEST_COMPLETE" then
    OnQuestComplete()
  elseif event == "GET_ITEM_INFO_RECEIVED" then
    if arg1 and byID[arg1] then Refresh() end
  else
    Refresh()
  end
end)
