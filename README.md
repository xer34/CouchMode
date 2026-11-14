# CouchMode

A World of Warcraft addon for people who play at a desk with mouse and keyboard, and sometimes from the couch on a handheld or phone (for example, streaming with Parsec and a controller).

CouchMode keeps two complete UI setups, **Desk** and **Handheld**. One button or keybind switches between them. Each switch remembers how you left the old setup.

Works on Retail (Midnight) and WoW Forever.

## What it swaps

| What | Scope |
| --- | --- |
| UI scale, controller mode, controller cursor and soft-targeting CVars | Account |
| Display mode, monitor and window size | Account, saved once per setup |
| Blizzard Edit Mode layout | Per character |
| Which addons are enabled | Per character |
| Settings of tracked addons (bag, chat, minimap and arrow positions) | Account or per character |
| Position of the CouchMode button | Per setup |

Tracked by default: Baganator, Chattynator, Leatrix Plus, MinimapButtonButton and TomTom. Only settings tables are tracked, never data such as price scans, inventories or chat logs.

## Install

Download or clone this repository into your AddOns folder, in a folder named **`!CouchMode`**. Keep the `!` in the name, because it makes CouchMode load before the addons whose settings it swaps.

```
World of Warcraft/_retail_/Interface/AddOns/!CouchMode/
World of Warcraft/_forever_/Interface/AddOns/!CouchMode/
```

## Use

1. Log in at your desk with everything set up the way you like. A small **Desk** button appears at the top of the screen. Shift-drag it to move it.
2. When you move to the couch, click the button (or type `/cm`) and confirm. Your UI reloads.
3. The first time you switch to Handheld, nothing changes yet. Set it up the way you want it there: controller mode, UI scale, display, and a **new** Edit Mode layout so you don't edit your Desk one. CouchMode saves the Handheld setup when you switch back.

You can also bind a key or controller button under **Key Bindings → AddOns → Switch Desk / Handheld setup**.

## Commands

| Command | What it does |
| --- | --- |
| `/cm` | Switch setups (same as the button) |
| `/cm desk`, `/cm handheld` | Switch to that setup |
| `/cm status` | Show the current setup |
| `/cm savedisplay` | Save the current display mode and resolution for this setup |
| `/cm relabel desk\|handheld` | Name your current setup without changing anything |
| `/cm track <Addon> <SavedVar ...>` | Also swap an addon's account-wide settings |
| `/cm trackchar <Addon> <SavedVar ...>` | Same, for per-character settings |
| `/cm untrack <Addon>` | Stop swapping an addon's settings |
| `/cm cvar add\|remove <CVar>` | Change which CVars are swapped |
| `/cm list` | Show what's tracked |
| `/cm button` | Show or hide the on-screen button |

## How addon settings are swapped

For each tracked addon, CouchMode records which setup the settings file on disk belongs to. When WoW loads that addon's saved variables and they belong to the other setup, CouchMode files that copy under its own setup. It then puts the current setup's copy in its place, before the addon reads it. An addon disabled in one setup keeps its owner, so a copy is never filed under the wrong setup.

## Notes

- **Display:** each setup's display is saved once. Desk's is saved at your first login after install, before you've connected through Parsec. Handheld's is saved the first time you switch away from it, after you've set it up. After that, a display only changes when you run `/cm savedisplay`, so a resolution Parsec sets when you connect is never saved as your Desk display. If a display restore doesn't take, CouchMode says so in chat.
- **Windowed fullscreen:** in this mode the window always fills the monitor, so CouchMode restores the display mode and monitor but not the window size. If Parsec changes your PC's screen resolution, that change belongs to Parsec, not to CouchMode.
- **Before you start:** back up your `WTF` folder before first use, as you would before trying any addon that touches saved variables.
- **Alts:** if you switch setups on one character and then log in to an alt, CouchMode offers to bring that alt's layout and addons in line.
