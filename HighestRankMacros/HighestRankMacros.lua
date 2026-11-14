-------------------------------------------------------------------------------
--  Highest Rank Macros
--
--  For every spell in your spellbook that has ranks, keeps a character macro
--      #showtooltip
--      /cast <spell name>
--  with no rank in it: /cast without a rank casts the highest rank you know,
--  so the macro never needs rewriting when you learn a new rank. Drag the
--  macros to your bars instead of the spells.
--
--  Ranks named with a Roman numeral ("Frostbolt II", subtext "Rank 2", the
--  same thing WhatsTraining's stripRankNumeral handles) are grouped under the
--  base name ("Frostbolt"), and the macro casts the base name.
--
--  Which spells: player spellbook entries that are known (not future) and not
--  passive, whose subtext holds a number ("Rank 3"). Professions ("Artisan"),
--  racials and the like have no number and are skipped. Pet spells aren't in
--  the player spellbook.
--
--  The macros are character macros (spells differ per class) named after the
--  spell (with a "+" if one of your macros already has that name), icon =
--  question mark so #showtooltip shows the spell. Which macros are ours is
--  saved per character (spell -> macro name), and only a macro by that name
--  whose text is still "#showtooltip\n/cast ..." is ever edited or deleted,
--  so your own macros are never touched; a macro of ours you delete by hand is recreated by
--  /hrm make, and stays gone otherwise (/hrm ignore keeps it from coming back
--  with new spells too).
--
--  APIs: C_SpellBook skill lines / item info (modern), with the old
--  GetSpellTabInfo / GetSpellBookItemName fallback; CreateMacro / EditMacro /
--  GetMacroIndexByName. Macros can't be created or edited in combat: changes
--  wait for PLAYER_REGEN_ENABLED.
-------------------------------------------------------------------------------
local addonName = ...

local PREFIX = "|cff9f7fffHighest Rank Macros:|r "
local MACRO_ICON = 134400 -- question mark: #showtooltip shows the spell's icon
local NAME_LIMIT = 16     -- characters a macro name may hold

local defaults = {
    auto = true,     -- create macros for newly learned ranked spells by themselves
    macros = {},     -- [base spell name] = macro name (ours)
    ignored = {},    -- [base spell name] = true
}

local db
local pending = false   -- a sync is waiting (combat or throttle)
local syncQueued = false

local function Say(message)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. message)
    end
end

-------------------------------------------------------------------------------
--  Spellbook
-------------------------------------------------------------------------------
local ROMAN = { I = 1, V = 5, X = 10 }
local function RomanToNumber(s)
    local total, prev = 0, 0
    for i = #s, 1, -1 do
        local v = ROMAN[s:sub(i, i)] or 0
        if v < prev then total = total - v else total = total + v; prev = v end
    end
    return total
end

-- "Frostbolt II" + "Rank 2" -> "Frostbolt"; otherwise the name unchanged
local function BaseName(name, rank)
    local base, numeral = name:match("^(.-)%s+([IVX]+)$")
    if base and rank and RomanToNumber(numeral) == rank then return base end
    return name
end

-- Calls fn(name, subText, spellID, isPassive) for each known player spellbook spell.
local function EachSpell(fn)
    local SB = C_SpellBook
    if SB and SB.GetNumSpellBookSkillLines and SB.GetSpellBookItemInfo then
        local bank = Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player or 0
        local SPELL = Enum and Enum.SpellBookItemType and Enum.SpellBookItemType.Spell or 1
        for line = 1, SB.GetNumSpellBookSkillLines() do
            local info = SB.GetSpellBookSkillLineInfo(line)
            if info and not info.offSpecID then
                local offset = info.itemIndexOffset or 0
                for i = offset + 1, offset + (info.numSpellBookItems or 0) do
                    local item = SB.GetSpellBookItemInfo(i, bank)
                    if item and item.itemType == SPELL and item.name then
                        local sub = item.subName
                        if (not sub or sub == "") and C_Spell and C_Spell.GetSpellSubtext and item.spellID then
                            sub = C_Spell.GetSpellSubtext(item.spellID)
                        end
                        fn(item.name, sub, item.spellID, item.isPassive)
                    end
                end
            end
        end
        return
    end
    -- Older client API
    local BOOK = BOOKTYPE_SPELL or "spell"
    for tab = 1, (GetNumSpellTabs and GetNumSpellTabs() or 0) do
        local _, _, offset, numSlots = GetSpellTabInfo(tab)
        for i = offset + 1, offset + numSlots do
            local kind, id = GetSpellBookItemInfo(i, BOOK)
            if kind == "SPELL" then
                local name, sub = GetSpellBookItemName(i, BOOK)
                fn(name, sub, id, IsPassiveSpell and IsPassiveSpell(i, BOOK))
            end
        end
    end
end

-- [base name] = { rank = n, cast = "/cast text target", spellID }
local function HighestRanks()
    local best = {}
    EachSpell(function(name, sub, spellID, isPassive)
        if isPassive then return end
        local rank = type(sub) == "string" and tonumber(sub:match("%d+"))
        if not rank then return end
        local base = BaseName(name, rank)
        local cur = best[base]
        if not cur or rank > cur.rank then
            -- No rank in the cast text: /cast without one picks the highest known
            best[base] = { rank = rank, cast = base, spellID = spellID }
        end
    end)
    return best
end

-------------------------------------------------------------------------------
--  Macros
-------------------------------------------------------------------------------
local function Body(entry)
    return "#showtooltip\n/cast " .. entry.cast
end

local function IsRankBody(body)
    return type(body) == "string" and body:find("^#showtooltip\n/cast ") ~= nil
end

-- The spell's name, cut to fit; if one of your macros already has that name,
-- a "+" marks ours apart.
local function MacroName(base)
    local name = base:sub(1, NAME_LIMIT)
    if GetMacroIndexByName(name) > 0 then
        name = base:sub(1, NAME_LIMIT - 1) .. "+"
        if GetMacroIndexByName(name) > 0 then return nil end
    end
    return name
end

local function CharacterSlotsFree()
    local _, perChar = GetNumMacros()
    return (MAX_CHARACTER_MACROS or 18) - (perChar or 0)
end

-- Ours, if it still exists: index. A macro by that name whose text isn't a
-- rank macro is yours (you renamed or rewrote it): never touched.
local function OurMacro(base)
    local name = db.macros[base]
    if not name then return end
    local index = GetMacroIndexByName(name)
    if index and index > 0 and IsRankBody(select(3, GetMacroInfo(index))) then return index end
end

-- create: "all" also makes macros for ranked spells without one (/hrm make);
-- "new" only for spells that never had one (automatic, so a macro you deleted
-- by hand stays deleted); nil only updates.
-- Returns created, updated, skippedForSpace (list of names)
local function Sync(create)
    local best = HighestRanks()
    local created, updated, noRoom = 0, 0, {}
    local names = {}
    for base in pairs(best) do names[#names + 1] = base end
    table.sort(names)
    for _, base in ipairs(names) do
        local entry = best[base]
        local body = Body(entry)
        local index = OurMacro(base)
        if index then
            local name, icon, current = GetMacroInfo(index)
            if current ~= body then
                EditMacro(index, name, icon, body)
                updated = updated + 1
            end
        elseif not db.ignored[base] and (create == "all" or (create == "new" and db.macros[base] == nil)) then
            if CharacterSlotsFree() <= 0 then
                noRoom[#noRoom + 1] = base
            else
                local name = MacroName(base)
                local ok = name and pcall(CreateMacro, name, MACRO_ICON, body, true)
                if ok and GetMacroIndexByName(name) > 0 then
                    db.macros[base] = name
                    created = created + 1
                end
            end
        end
    end
    return created, updated, noRoom
end

local function Report(created, updated, noRoom, quietIfNothing)
    if created > 0 or updated > 0 then
        Say(string.format("%d macro%s created, %d updated.",
            created, created == 1 and "" or "s", updated))
    elseif not quietIfNothing then
        Say("All rank macros are up to date.")
    end
    if #noRoom > 0 then
        Say(string.format("No free character macro slot for %d spell%s: %s. Free some slots, then /hrm make.",
            #noRoom, #noRoom == 1 and "" or "s", table.concat(noRoom, ", ")))
    end
end

-- Spellbook changed: update ours, and (auto) add new ones.
local function AutoSync()
    syncQueued = false
    if InCombatLockdown() then pending = true; return end
    pending = false
    local created, updated, noRoom = Sync(db.auto and "new" or nil)
    Report(created, updated, noRoom, true)
end

local function QueueSync()
    if syncQueued then return end
    syncQueued = true
    -- SPELLS_CHANGED comes in bursts (and at login before the book is complete)
    C_Timer.After(1, AutoSync)
end

-------------------------------------------------------------------------------
--  Slash command
-------------------------------------------------------------------------------
local function FindBase(text)
    local wanted = text:lower()
    for base in pairs(HighestRanks()) do
        if base:lower() == wanted then return base end
    end
    for base in pairs(db.macros) do
        if base:lower() == wanted then return base end
    end
    for base in pairs(db.ignored) do
        if base:lower() == wanted then return base end
    end
end

local function SlashHandler(message)
    local command, rest = (message or ""):match("^%s*(%S*)%s*(.-)%s*$")
    command = (command or ""):lower()
    if InCombatLockdown() and (command == "make" or command == "delete" or command == "ignore") then
        Say("Macros can't be changed in combat.")
        return
    end
    if command == "make" then
        local created, updated, noRoom = Sync("all")
        Report(created, updated, noRoom, false)
        if created > 0 then Say("Find them in /macro, Character tab, and drag them to your bars.") end
    elseif command == "list" then
        local best = HighestRanks()
        local names = {}
        for base in pairs(best) do names[#names + 1] = base end
        table.sort(names)
        for _, base in ipairs(names) do
            local state = db.ignored[base] and "|cffaaaaaaignored|r"
                or (OurMacro(base) and "|cff40ff40macro|r") or "|cffffd100no macro|r"
            Say(string.format("  %s (highest known: rank %d) - %s", base, best[base].rank, state))
        end
        if #names == 0 then Say("No spells with ranks in your spellbook.") end
        Say(string.format("%d character macro slot%s free.", CharacterSlotsFree(), CharacterSlotsFree() == 1 and "" or "s"))
    elseif command == "auto" then
        if rest == "on" or rest == "off" then db.auto = rest == "on" else db.auto = not db.auto end
        Say("Create macros for newly learned ranked spells by themselves: " .. (db.auto and "on" or "off") .. ".")
    elseif command == "ignore" and rest ~= "" then
        local base = FindBase(rest) or rest
        db.ignored[base] = true
        local index = OurMacro(base)
        if index then DeleteMacro(index) end
        db.macros[base] = nil
        Say(base .. " ignored" .. (index and "; its macro was deleted." or "."))
    elseif command == "unignore" and rest ~= "" then
        local base = FindBase(rest) or rest
        db.ignored[base] = nil
        Say(base .. " is no longer ignored (/hrm make creates its macro).")
    elseif command == "delete" then
        local n = 0
        for base in pairs(db.macros) do
            local index = OurMacro(base)
            if index then DeleteMacro(index); n = n + 1 end
            -- Kept (macro name, now deleted) so automatic creation doesn't bring it back
        end
        Say(string.format("Deleted %d rank macro%s (your own macros were left alone). /hrm make brings them back.",
            n, n == 1 and "" or "s"))
    else
        Say("Keeps a #showtooltip macro per ranked spell that always casts your highest rank.")
        Say("/hrm make - create the missing macros (and update the rest)")
        Say("/hrm list - ranked spells, the rank each macro casts, and free slots")
        Say("/hrm auto on | off - make macros for newly learned ranked spells by themselves (now "
            .. (db.auto and "on" or "off") .. ")")
        Say("/hrm ignore <spell> | unignore <spell> - no macro for that spell")
        Say("/hrm delete - delete every macro this addon made")
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
        if type(HighestRankMacrosDB) ~= "table" then HighestRankMacrosDB = {} end
        db = HighestRankMacrosDB
        for k, v in pairs(defaults) do
            if type(db[k]) ~= type(v) then db[k] = type(v) == "table" and {} or v end
        end
        SLASH_HIGHESTRANKMACROS1 = "/hrm"
        SLASH_HIGHESTRANKMACROS2 = "/highestrank"
        SlashCmdList.HIGHESTRANKMACROS = SlashHandler
        events:RegisterEvent("PLAYER_LOGIN")
        events:RegisterEvent("SPELLS_CHANGED")
        events:RegisterEvent("LEARNED_SPELL_IN_TAB")
        events:RegisterEvent("PLAYER_REGEN_ENABLED")
    elseif event == "PLAYER_REGEN_ENABLED" then
        if pending then QueueSync() end
    else
        QueueSync()
    end
end)
