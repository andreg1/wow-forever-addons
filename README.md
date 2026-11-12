# WoW Forever addons

Small addons for World of Warcraft: Forever. Each one is its own folder, kept apart from the addons it builds on, so updating those never removes them.

| Addon | What it does | Needs |
|---|---|---|
| [ForeverSleepingBag](ForeverSleepingBag) | Reminds you to use your Cozy Sleeping Bag when Well-Rested is missing, under 3 stacks, or about to end | Nothing |
| [EllesmereUIBags_ItemLock](EllesmereUIBags_ItemLock) | Alt+Right-click a bag item to lock it, so it can't be sold or destroyed | EllesmereUI Bags |

## Install

1. Download this repository (**Code > Download ZIP**) and unzip it.
2. Copy the addon folders you want (for example `ForeverSleepingBag`) into
   `World of Warcraft\_forever_\Interface\AddOns\`.
   Copy the folder itself, not the files inside it.
3. Restart the game or type `/reload`, and make sure the addon is ticked in the AddOns list.

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

**Note:** EllesmereUI's optional *Quick Actions* feature also uses Alt-click, to disenchant. With it turned on, Alt+Right-click on an item you can disenchant will disenchant it instead of locking it.

## License

[MIT](LICENSE)
