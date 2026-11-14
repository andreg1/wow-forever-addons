# WoW Forever addons

Small addons for World of Warcraft: Forever. Each one is its own folder, kept apart from the addons it builds on, so updating those never removes them.

| Addon | What it does | Needs |
|---|---|---|
| [ForeverSleepingBag](ForeverSleepingBag) | Reminds you to use your Cozy Sleeping Bag when Well-Rested is missing, under 3 stacks, or about to end | Nothing |
| [EllesmereUIBags_ItemLock](EllesmereUIBags_ItemLock) | Alt+Right-click a bag item to lock it, so it can't be sold or destroyed; locked items get their own bag category | EllesmereUI Bags |
| [EllesmereUIQuestTracker_QuestItems](EllesmereUIQuestTracker_QuestItems) | Small item icon next to tracked quests whose objective needs you to use an item | EllesmereUI Quest Tracker (Custom Quest Tracker) |
| [Questie_NewInForever](Questie_NewInForever) | Star on Questie's map icons for quests that are new in WoW Forever | Questie |
| [Questie_SubQuestFilter](Questie_SubQuestFilter) | Hides Questie sub-quests until you can actually pick them up | Questie |
| [Questie_RareObjectives](Questie_RareObjectives) | Watches for rare and named quest mobs you still need in your zone, and alerts and marks them | QuestieDB (Questie recommended) |
| [QuestieDB_Search](QuestieDB_Search) | Quest search window: keywords, quests that lead into a zone, Alliance/Horde filter | QuestieDB |
| [Auctionator_DarkmoonTickets](Auctionator_DarkmoonTickets) | Ranks Darkmoon Faire ticket turn-ins by cost per Prize Ticket, from Auctionator's last scan | Auctionator |
| [SpecGearSwap](SpecGearSwap) | Equips the gear set that goes with your talent spec when you switch specs, and updates the set when you change a weapon | Nothing |
| [FishingPoleAlert](FishingPoleAlert) | Warns you when you're in combat with a fishing pole equipped, with a key to put your weapons back on | Nothing |
| [HighestRankMacros](HighestRankMacros) | One macro per ranked spell that always casts your highest rank, so your bars never need updating | Nothing |

## Install

1. Download this repository (**Code > Download ZIP**) and unzip it.
2. Copy the addon folders you want (for example `ForeverSleepingBag`) into
   `World of Warcraft\_forever_\Interface\AddOns\`.
   Copy the folder itself, not the files inside it.
3. Restart the game (a new addon folder is only found on a full restart), and make sure the addon is ticked in the AddOns list.

## ForeverSleepingBag

The Cozy Sleeping Bag lays down a bag you can rest in. Resting in it gives **Well-Rested** (more experience, up to 3 stacks, 2 hours). The bag has a 1-hour cooldown.

A small alert appears, with the bag icon (click it to use the bag), when all of these are true:

- you are below level 60
- the bag is in your bags and off cooldown
- you are not already lying in it
- Well-Rested is missing, under 3 stacks, or has 20 minutes or less left

It stays hidden in combat, while dead, flying or on a flight path. Drag the alert to move it.

| Command | Does |
|---|---|
| `/fsb` | Help and current settings |
| `/fsb on` / `/fsb off` | Turn reminders on or off |
| `/fsb chat` | Turn the chat message on or off |
| `/fsb refresh <minutes>` | How long before Well-Rested ends to remind you (default 20) |
| `/fsb test` | Show the alert for 20 seconds so you can move it |
| `/fsb reset` | Put the alert back in its default spot |
| `/fsb status` | Show your stacks, time left and the bag's cooldown |

Settings are saved per character.

## EllesmereUIBags_ItemLock

An add-on for the EllesmereUI Bags window.

- **Lock or unlock:** Alt+Right-click an item in your bags or bank. A padlock appears on it and its tooltip says it is locked. Locking an item locks every copy of it.
- **Gear sets:** items in your equipment sets are protected the same way without a lock (blue padlock). Take an item out of the set to sell or destroy it.
- **Locked category:** padlocked items move to their own "Locked" category instead of their usual one (such as The Armory).
- **Destroying:** dragging a locked item out to destroy it cancels the confirmation and puts the item back.
- **Selling:** while a merchant is open, right-clicking a locked item does nothing. Left-click, drag and Shift-click still work.
- **Sell Junk:** EllesmereUI's Sell Junk skips locked items. A locked grey item also leaves the Junk category.
- **Any other sale**, such as dragging the item onto the merchant: the item is bought back at once.

Locks are saved per character.

| Command | Does |
|---|---|
| `/itemlock` | Help |
| `/itemlock list` | List locked items |
| `/itemlock <Shift-click an item>` | Lock or unlock that item |
| `/itemlock clear` | Remove every lock on this character |
| `/itemlock sets on` / `off` | Protect gear set items (default on) |
| `/itemlock category on` / `off` | Put padlocked items in their own "Locked" category (default on) |
| `/itemlock category sets on` / `off` | Put gear set items in it too (default on) |

**Note:** EllesmereUI's optional *Quick Actions* feature also uses Alt-click, to disenchant. With it turned on, Alt+Right-click on an item you can disenchant will disenchant it instead of locking it.

## EllesmereUIQuestTracker_QuestItems

Adds a small item icon right of a quest's title in EllesmereUI's Custom Quest Tracker when the quest's objective needs you to *use* an item, for example Swineherd's Staff for *Drive Them Back*. Hover the icon for the item's tooltip. The icon is greyed out while the item isn't in your bags, and goes away once the quest is complete.

It uses the game's own quest item when there is one, otherwise Questie's database (the item a quest gives you, or requires), keeping only items with a *Use:* effect. It shows in the Custom Quest Tracker only.

| Command | Does |
|---|---|
| `/eqi` | Help and current settings |
| `/eqi on` / `/eqi off` | Show or hide the icons |
| `/eqi missing` | Also show the (greyed) icon when the item isn't in your bags |
| `/eqi check <questID>` | Which items a quest uses |

## Questie_NewInForever

Puts a small star on Questie's world map icons, and in Questie's map tooltip, for quests that are new in WoW Forever (quest ID 10000 and up; every original Classic quest is below that).

| Command | Does |
|---|---|
| `/qnew` | Help and current settings |
| `/qnew on` / `/qnew off` | Show or hide the stars |
| `/qnew minimap` / `turnins` / `objectives` / `tooltip` | Toggle where stars are shown |
| `/qnew min <id>` | Cutoff ID (90000 = only Forever's own quests); `/qnew min` resets it to 10000 |
| `/qnew check <questID>` | Is this quest new? |

## Questie_SubQuestFilter

While a quest is in your log, Questie shows its follow-on sub-quests as available without checking most of their requirements. This hides them on the map and in NPC tooltips until you meet their level and Questie's other requirements (class, reputation, profession, earlier quests). A quest an NPC actually offers you is always shown. Nothing is hidden permanently: every check runs again whenever Questie refreshes.

| Command | Does |
|---|---|
| `/qsub` | Help |
| `/qsub on` / `/qsub off` | Turn the filter on or off |
| `/qsub list` | Sub-quests hidden right now, and why |
| `/qsub check <questID>` | Why a quest is shown or hidden |
| `/qsub refresh` | Redraw Questie's available quests |

## Questie_RareObjectives

Watches for the rare and named mobs your quests still need while you're in their zone: rare mobs, objectives that need one kill, and items that only one mob drops (for example *WANTED: Trapclaw*). When one shows up you get a raid-warning message, a sound, a flashing taskbar icon, and a map waypoint when its position is known. Finished objectives drop off the list by themselves.

Addons can't search for units on their own, so it sees what the game shows: enemy nameplates, your target and mouseover, and the minimap's rare markers. Turn enemy nameplates on (V) for it to work well.

**Scan:** for a longer reach, either bind *Options > Keybindings > AddOns > "Scan for rare quest mobs"*, or type `/qrare makemacro` to get a **QRareScan** macro (Character tab of `/macro`) for your action bar. The addon keeps that macro up to date, and `/qrare extra /cast <your mount>` makes it mount you too, so one press does both. Each press targets any watched mob in view, puts a raid marker on it (skull by default) and pings it. If none is in view, you keep your old target. (The game only allows markers and pings from a key you press, so the addon can't do this by itself when it spots the mob. And `/click QuestieRareObjectivesScan` inside your own macro does nothing: the game won't run it from another macro.)

| Command | Does |
|---|---|
| `/qrare` | Help and current settings |
| `/qrare list` | Mobs being watched, and whether they're in your zone |
| `/qrare on` / `/qrare off` | Turn watching on or off |
| `/qrare add <name>` / `remove <name>` | Watch any mob by name, in every zone |
| `/qrare mark <0-8>` | Marker the scan key puts on a found mob (0 = none, 8 = skull) |
| `/qrare ping on` / `off` / `<seconds>` | Whether the scan pings a found mob, and how often at most (default once every 15 seconds) |
| `/qrare sound` / `flash` / `waypoint` | Toggle that part of the alert |
| `/qrare nameplates` | Turn enemy nameplates on and raise their range |
| `/qrare makemacro` | Create the QRareScan macro for your action bar |
| `/qrare extra <macro line>` / `clear` | A last line for QRareScan, e.g. `/cast` your mount |
| `/qrare macro` | Show what the scan runs |
| `/qrare test` | Show a test alert |

## QuestieDB_Search

A quest search window over QuestieDB's quest database.

- **Search text:** quests whose name or objective text contains every word.
- **Leads into zone:** quests that start outside a zone and end at someone in it, or whose text names it.
- **All / Alliance / Horde:** faction filter on the results.

| Command | Does |
|---|---|
| `/qs` | Open the window |
| `/qs <words>` | Open it and search |
| `/qs to <zone>` | Quests that lead into that zone |

## Auctionator_DarkmoonTickets

Shows which Darkmoon Faire turn-in gets you Prize Tickets for the least gold. For each of the 21 turn-ins it takes Auctionator's price from your last scan and works out the cost per ticket (unit price × items per turn-in ÷ tickets). The window lists them cheapest first, with the AH unit price, how many days ago Auctionator last saw the item, how many you already have, and the tier. The cheapest one you can still turn in is shown in green.

- **Search all on AH:** with the auction house open, searches all 21 items at once in Auctionator's Shopping tab, so the prices are fresh. The window updates when the search finishes.
- **Ticket counts:** the built-in numbers come from community guides. When you turn a quest in, the addon reads the real counts from the quest window and uses those from then on, for all your characters. A `*` marks a count not yet seen in-game.
- **Reputation:** tiers 1 to 4 stop being offered as your Darkmoon Faire reputation goes up (roughly at 401, 1100, 1625 and 2500). Tiers you're past are greyed and moved to the bottom, or hidden with the checkbox.
- **Tooltips:** the turn-in items get a line with their tickets and cost per ticket.

Prices are what it costs to buy the items, not to craft them.

| Command | Does |
|---|---|
| `/dmft` | Open or close the window |
| `/dmft best [n]` | Print the n cheapest turn-ins to chat (default 5) |
| `/dmft tooltip on` / `off` | Show or hide the tooltip line |
| `/dmft learned` | Ticket counts read from the quest window so far |
| `/dmft forget` | Clear those and go back to the built-in numbers |

## SpecGearSwap

When you switch talent spec (dual spec), this equips the gear set that goes with the new spec. It uses the game's own equipment sets, so make those first.

- **Linking a set to a spec:** put the set on while in that spec and type `/specgear link`. Or name it: `/specgear set 1 Holy`.
- **No link needed** if a set is named after the spec's main talent tree (for example a set called "Feral" for a Feral spec).
- **Learning:** in a spec with no set, the first set you put on by hand is linked to it.
- **In combat:** gear can't change in combat, so the swap happens when combat ends.
- **Missing items:** you're told how many items of the set aren't in your bags.

**Weapon auto-save:** while you're wearing a set, replacing a weapon (main hand, off hand or ranged) saves the new weapon into that set. It only does this when the rest of your gear still matches the set, so nothing else gets written into it by accident. It never saves an empty weapon slot or a fishing pole. If the new weapons make you match another set completely, it treats that as switching sets and saves nothing. `/specgear why` tells you why a change wasn't saved.

| Command | Does |
|---|---|
| `/specgear` (or `/sgs`) | Which set each spec uses, and the set you're wearing |
| `/specgear on` / `off` | Turn the automatic swap on or off |
| `/specgear sets` | List your gear sets |
| `/specgear link [spec]` | Link the set you're wearing to this spec (or spec 1 / 2) |
| `/specgear set <spec> <set name>` | Link a set by name |
| `/specgear clear <spec>` | Remove a spec's link |
| `/specgear equip` | Put on this spec's set now |
| `/specgear learn on` / `off` | Link the first set you put on in a spec without one (default on) |
| `/specgear byname on` / `off` | Use a set named after the main talent tree (default on) |
| `/specgear autosave on` / `off` | Save weapon changes into the set you're wearing (default on) |
| `/specgear why` | Would a weapon change be saved right now, and if not, why |

Settings are saved per character.

## FishingPoleAlert

If combat starts while a fishing pole is in your hand, or you put one on during a fight, you get a pulsing alert at the top of the screen, a raid-warning message, a sound and a flashing taskbar icon. The sound and message repeat every 8 seconds until the pole comes off or combat ends.

**Weapon swap key:** bind *Options > Keybindings > AddOns > Fishing Pole Alert > "Put my weapons back on"*. The addon remembers the last weapons you wore (main hand, plus off hand if you had one), and the key puts them back on, in combat too. Wear your normal weapons once before you fish so it knows them. (Addons can't change your gear by themselves in combat, but a key you press can.)

| Command | Does |
|---|---|
| `/fpa` | Settings, the bound key and the remembered weapons |
| `/fpa on` / `off` | Turn the alert on or off |
| `/fpa sound` / `warning` / `flash` | Toggle that part of the alert |
| `/fpa repeat <seconds>` | How often it repeats (0 = once per fight) |
| `/fpa test` | Show the alert for 5 seconds |

## HighestRankMacros

For every spell in your spellbook that has ranks, this keeps a character macro that casts the spell without a rank (`#showtooltip` + `/cast Frostbolt`). A cast without a rank uses the highest rank you know, so when you train a new rank, the macro on your bar uses it right away. Drag the macros (`/macro`, Character tab) to your bars instead of the spells.

- New ranked spells get a macro by themselves when you learn them (`/hrm auto off` to stop that).
- Macros are named after the spell, with a "+" if you already have a macro by that name. Your own macros are never changed or deleted.
- A macro of this addon's that you delete stays deleted, until `/hrm make`.
- Macros can't be changed in combat, so changes wait for combat to end.

| Command | Does |
|---|---|
| `/hrm make` | Create the missing macros and update the rest |
| `/hrm list` | Ranked spells, whether each has a macro, and free macro slots |
| `/hrm auto on` / `off` | Make macros for newly learned ranked spells (default on) |
| `/hrm ignore <spell>` / `unignore <spell>` | No macro for that spell |
| `/hrm delete` | Delete every macro this addon made |

## License

[MIT](LICENSE)
