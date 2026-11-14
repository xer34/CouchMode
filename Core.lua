-- CouchMode: keep a "Desk" and a "Handheld" UI setup and flip between them.
--
-- What gets swapped per mode:
--   * CVars: UI scale, controller mode + controller cursor/targeting settings
--   * Display: monitor, display mode and window size (saved once, see /cm savedisplay)
--   * Blizzard Edit Mode layout (per character)
--   * Which addons are enabled (per character)
--   * The saved settings of "tracked" addons (bag/chat/frame positions etc.)
--   * Position of the CouchMode button itself
--
-- How tracked addon settings are swapped:
-- For every tracked addon we remember which setup the settings currently on disk
-- belong to (the "owner"). When WoW loads that addon's settings and the owner isn't
-- the setup you're in now, we file the on-disk copy under its owner and put the
-- current setup's copy in its place, before the addon reads it. An addon that was
-- disabled in one setup just keeps its owner, so nothing is ever filed under the
-- wrong setup.
--
-- The folder name starts with "!" so this loads (and registers for ADDON_LOADED)
-- before other addons.

local ADDON = ...
local MODES = { desk = "Desk", handheld = "Handheld" }
local DB_VERSION = 2

local DEFAULT_CVARS = {
	"uiScale", "useUiScale",
	"GamePadEnable", "GamePadCursorAutoEnable", "GamePadCursorCenteredEmulation",
	"GamePadCursorForTargeting", "GamePadEmulateShift", "GamePadEmulateCtrl",
	"GamePadEmulateAlt", "GamePadCameraYawSpeed", "GamePadCameraPitchSpeed",
	"SoftTargetEnemy", "SoftTargetFriend", "SoftTargetInteract",
}

-- Addon name -> SavedVariables to swap per setup. "account" ones are shared by all
-- characters, "char" ones are per character. Only settings, never big data tables.
local DEFAULT_TRACKED = {
	Baganator           = { account = { "BAGANATOR_CONFIG" },   char = { "BAGANATOR_CURRENT_PROFILE" } },
	Chattynator         = { account = { "CHATTYNATOR_CONFIG" }, char = { "CHATTYNATOR_CURRENT_PROFILE" } },
	Leatrix_Plus        = { account = { "LeaPlusDB" },          char = {} },
	MinimapButtonButton = { account = { "MinimapButtonButtonOptions" }, char = {} },
	TomTom              = { account = { "TomTomDB" },           char = {} },
}

-- Keys an addon reads while its files are still loading (before ADDON_LOADED),
-- so swapping them would only half-apply. They're left as-is.
local KEEP_LIVE = {
	LeaPlusDB = { AddonLanguage = true },
}

BINDING_HEADER_COUCHMODE = "CouchMode"
BINDING_NAME_COUCHMODE_TOGGLE = "Switch Desk / Handheld setup"

local db, char
local handledThisSession = {}
local button

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------
local function Print(...)
	print("|cff33ff99CouchMode|r:", ...)
end

local function Other(mode)
	return mode == "desk" and "handheld" or "desk"
end

local function DeepCopy(v)
	if type(v) ~= "table" then return v end
	local t = {}
	for k, val in pairs(v) do t[k] = DeepCopy(val) end
	return t
end

local function PlayerName()
	return (UnitName("player"))
end

-------------------------------------------------------------------------------
-- CVars
-------------------------------------------------------------------------------
local function CaptureCVars()
	local out = {}
	for _, name in ipairs(db.cvars) do
		local value = C_CVar.GetCVar(name)
		if value ~= nil then out[name] = value end
	end
	return out
end

local function ApplyCVars(saved)
	for name, value in pairs(saved or {}) do
		local current = C_CVar.GetCVar(name)
		if current ~= nil and current ~= value then
			C_CVar.SetCVar(name, value)
		end
	end
end

-------------------------------------------------------------------------------
-- /cm findsetting: snapshot every CVar, let the player flip a setting in the
-- game menu, then diff and start tracking whatever changed.
-------------------------------------------------------------------------------
-- Things that change on their own and should never be tracked.
local FIND_IGNORE = {
	"^camera", "^Camera", "^Gamepad?CameraSaved", "^gx", "^Gx", "^lastCharacterIndex$", "^gameTip$",
	"^hardTrackedQuests", "^trackedQuests", "^lastAddonVersion", "^EJ", "^playerStat", "^closedInfoFrames",
	"^lastTransmog", "^lastVoidStorage", "^minimapTracking", "^Sound_", "^showTutorials$",
}
local findSnapshot

local function SnapshotAllCVars()
	if not (C_Console and C_Console.GetAllCommands) then return nil end
	local cvarType = Enum.ConsoleCommandType and Enum.ConsoleCommandType.Cvar or 0
	local out = {}
	for _, info in ipairs(C_Console.GetAllCommands()) do
		if info.commandType == cvarType and info.command then
			local value = C_CVar.GetCVar(info.command)
			if value ~= nil then out[info.command] = value end
		end
	end
	return out
end

local function IsIgnored(name)
	for _, pattern in ipairs(FIND_IGNORE) do
		if name:find(pattern) then return true end
	end
	return false
end

local function FindSetting()
	if not findSnapshot then
		findSnapshot = SnapshotAllCVars()
		if not findSnapshot then
			Print("This game client can't list its settings, sorry. Use /cm cvar add <name> instead.")
			return
		end
		Print("Step 1 done. Now flip the setting you want remembered per setup (e.g. the controller UI checkbox),")
		Print("click Okay/Apply and close the settings window, then type |cffffffff/cm findsetting|r again.")
		return
	end

	local after = SnapshotAllCVars()
	local found = 0
	for name, value in pairs(after) do
		local before = findSnapshot[name]
		if before ~= nil and before ~= value and not IsIgnored(name) then
			found = found + 1
			local new = not tContains(db.cvars, name)
			if new then tinsert(db.cvars, name) end
			Print(("%s %s (%s -> %s)"):format(new and "Now remembering" or "Already remembering", name, before, value))
		end
	end
	findSnapshot = nil
	if found == 0 then
		Print("No setting changed. It may not have been applied yet (click Okay/Apply), or it's stored by an addon.")
	else
		Print("Done. Each setup will remember its own value from the next time you switch away from it.")
	end
end

-------------------------------------------------------------------------------
-- Display (monitor, display mode, window size)
-- Saved once per setup and only updated with /cm savedisplay, so a resolution
-- Parsec changed on connect never gets recorded as your Desk display.
-------------------------------------------------------------------------------
local function CaptureDisplay()
	local d = {
		maximize = C_CVar.GetCVar("gxMaximize"),
		monitor = C_CVar.GetCVar("gxMonitor"),
	}
	if C_VideoOptions and C_VideoOptions.GetCurrentGameWindowSize then
		local ok, size = pcall(C_VideoOptions.GetCurrentGameWindowSize, tonumber(d.monitor) or 0, d.maximize == "1")
		if ok and size and size.x then
			d.width, d.height = math.floor(size.x), math.floor(size.y)
		end
	end
	return d
end

local function DisplayToString(d)
	local mode = d.maximize == "1" and "windowed fullscreen" or "windowed"
	local size = d.width and (d.width .. "x" .. d.height) or "?"
	return ("%s, %s, monitor %s"):format(mode, size, d.monitor or "?")
end

local function DisplayMatches(d)
	local c = CaptureDisplay()
	if c.maximize ~= d.maximize or c.monitor ~= d.monitor then return false end
	-- In windowed fullscreen the window always fills the monitor; size isn't ours to set.
	if d.maximize == "1" or not d.width then return true end
	return c.width == d.width and c.height == d.height
end

local function ApplyDisplay(d)
	if not d or DisplayMatches(d) then return end
	if d.monitor then C_CVar.SetCVar("gxMonitor", d.monitor) end
	if d.maximize then C_CVar.SetCVar("gxMaximize", d.maximize) end
	if d.maximize ~= "1" and d.width and C_VideoOptions and C_VideoOptions.SetGameWindowSize then
		pcall(C_VideoOptions.SetGameWindowSize, d.width, d.height)
	end
	if type(UpdateWindow) == "function" then pcall(UpdateWindow) end
	db.verifyDisplay = true
end

local function VerifyDisplay()
	local d = db.profiles[db.mode].display
	db.verifyDisplay = nil
	if d and not DisplayMatches(d) then
		Print("|cffff6060Couldn't fully restore your display.|r Wanted: " .. DisplayToString(d) ..
			". Got: " .. DisplayToString(CaptureDisplay()) .. ".")
		Print("Fix it in System > Graphics, then type /cm savedisplay if this is how it should be.")
	end
end

-------------------------------------------------------------------------------
-- Edit Mode layouts
-------------------------------------------------------------------------------
local function GetAllLayouts()
	if not (C_EditMode and C_EditMode.GetLayouts) then return {}, nil end
	local info = C_EditMode.GetLayouts()
	local list = {}
	if EditModePresetLayoutManager and EditModePresetLayoutManager.GetCopyOfPresetLayouts then
		for _, layout in ipairs(EditModePresetLayoutManager:GetCopyOfPresetLayouts()) do
			list[#list + 1] = layout
		end
	end
	for _, layout in ipairs(info and info.layouts or {}) do
		list[#list + 1] = layout
	end
	return list, info and info.activeLayout
end

local function CurrentLayoutName()
	local list, active = GetAllLayouts()
	return active and list[active] and list[active].layoutName
end

local function ApplyLayout(name)
	if not name then return end
	local list, active = GetAllLayouts()
	for i, layout in ipairs(list) do
		if layout.layoutName == name then
			if i ~= active then C_EditMode.SetActiveLayout(i) end
			return
		end
	end
	Print(("Edit Mode layout '%s' no longer exists, keeping the current one."):format(name))
end

-------------------------------------------------------------------------------
-- Addon enable/disable state (per character)
-------------------------------------------------------------------------------
-- GetAddOnEnableState's argument order differs between game clients (name-first
-- on Retail, character-first on older ones), and the wrong order silently reports
-- everything as enabled. GetAddOnInfo's "reason" is the same everywhere: it's
-- "DISABLED" when the addon is switched off for this character, and it updates
-- as soon as you untick it, before any reload.
local function CaptureAddons()
	local out = {}
	for i = 1, C_AddOns.GetNumAddOns() do
		local name, _, _, _, reason = C_AddOns.GetAddOnInfo(i)
		if name and name ~= ADDON then
			out[name] = reason ~= "DISABLED"
		end
	end
	return out
end

-- Returns true if anything actually changed.
local function ApplyAddons(saved)
	if not saved then return false end
	local me, changed = PlayerName(), false
	local current = CaptureAddons()
	for name, enabled in pairs(saved) do
		if name ~= ADDON and current[name] ~= nil and current[name] ~= enabled then
			if enabled then C_AddOns.EnableAddOn(name, me) else C_AddOns.DisableAddOn(name, me) end
			changed = true
		end
	end
	if changed then
		-- Check it took, so a failure is visible instead of silent.
		local after, failed = CaptureAddons(), {}
		for name, enabled in pairs(saved) do
			if after[name] ~= nil and after[name] ~= enabled then failed[#failed + 1] = name end
		end
		if #failed > 0 then
			Print("|cffff6060Couldn't switch these addons on/off:|r " .. table.concat(failed, ", "))
		end
	end
	return changed
end

-------------------------------------------------------------------------------
-- Tracked addon SavedVariables
-------------------------------------------------------------------------------
local function RestoreVar(var, snapshot)
	local live, new, keep = _G[var], DeepCopy(snapshot), KEEP_LIVE[var]
	if type(live) == "table" and type(new) == "table" then
		local kept = {}
		if keep then for k in pairs(keep) do kept[k] = live[k] end end
		-- Replace contents in place so any reference the addon already holds stays valid.
		wipe(live)
		for k, v in pairs(new) do live[k] = v end
		if keep then for k, v in pairs(kept) do live[k] = v end end
	else
		_G[var] = new
	end
end

-- owners:    table addonName -> mode whose settings are on disk right now
-- mode:      the setup we're in now
-- snapshots: function(mode) -> table holding that setup's copies
local function SwapVars(addonName, vars, owners, mode, snapshots)
	if not vars or #vars == 0 then return end
	local owner = owners[addonName]
	if owner and owner ~= mode then
		for _, var in ipairs(vars) do
			-- What's on disk is the latest state of the owner setup.
			snapshots(owner)[var] = DeepCopy(_G[var])
			local target = snapshots(mode)[var]
			if target ~= nil then RestoreVar(var, target) end
		end
	end
	owners[addonName] = mode
end

-- Runs from ADDON_LOADED: WoW has just loaded the addon's SavedVariables and,
-- because we registered first, the addon's own ADDON_LOADED code hasn't run yet.
local function SyncTrackedAddon(addonName)
	local entry = db.tracked[addonName]
	SwapVars(addonName, entry.account, db.svOwner, db.mode, function(m) return db.profiles[m].sv end)
	-- Per-character settings follow the setup this character is actually on.
	SwapVars(addonName, entry.char, char.svOwner, char.appliedMode, function(m) return char.sv[m] end)
	handledThisSession[addonName] = true
end

-------------------------------------------------------------------------------
-- The button
-------------------------------------------------------------------------------
local function SaveButtonPosition()
	local point, _, relPoint, x, y = button:GetPoint(1)
	if point then db.profiles[db.mode].button = { point, relPoint, x, y } end
end

local function PlaceButton()
	local pos = db.profiles[db.mode].button or { "TOP", "TOP", 0, -4 }
	button:ClearAllPoints()
	button:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
end

local function UpdateButton()
	if not button then return end
	button:SetText(MODES[db.mode])
	button:SetShown(not db.hideButton)
end

local function CreateButton()
	button = CreateFrame("Button", "CouchModeButton", UIParent, "UIPanelButtonTemplate")
	button:SetSize(96, 22)
	button:SetFrameStrata("MEDIUM")
	button:SetMovable(true)
	button:SetClampedToScreen(true)
	button:RegisterForDrag("LeftButton")
	button:SetScript("OnDragStart", function(self)
		if IsShiftKeyDown() then self:StartMoving() end
	end)
	button:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		self:SetUserPlaced(false)
		SaveButtonPosition()
	end)
	button:SetScript("OnClick", function() CouchMode_Toggle() end)
	button:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
		GameTooltip:AddLine("CouchMode")
		GameTooltip:AddLine("Current setup: |cffffffff" .. MODES[db.mode] .. "|r")
		GameTooltip:AddLine("Click to switch to " .. MODES[Other(db.mode)] .. ".", 1, 1, 1)
		GameTooltip:AddLine("Shift-drag to move.", 0.7, 0.7, 0.7)
		GameTooltip:Show()
	end)
	button:SetScript("OnLeave", GameTooltip_Hide)
	PlaceButton()
	UpdateButton()
end

-------------------------------------------------------------------------------
-- Switching
-------------------------------------------------------------------------------
local function SwitchTo(to)
	if InCombatLockdown() then
		Print("Can't switch setups in combat.")
		return
	end
	local from = db.mode
	if to == from then
		Print("Already using the " .. MODES[to] .. " setup.")
		return
	end
	local fromProfile, toProfile = db.profiles[from], db.profiles[to]
	-- Usually the same as `from`; differs only on a character that declined to sync.
	local charFrom = char.appliedMode

	-- 1. Remember the setup we're leaving. (Tracked addon settings take care of
	--    themselves: they're written to disk on reload and filed by owner on load.)
	fromProfile.cvars = CaptureCVars()
	if not fromProfile.display then fromProfile.display = CaptureDisplay() end
	fromProfile.saved = true
	if charFrom ~= to then
		char.layouts[charFrom] = CurrentLayoutName()
		char.addons[charFrom] = CaptureAddons()
	end
	if button then SaveButtonPosition() end

	-- 2. Apply the target setup (if we've ever been there).
	if toProfile.saved then
		ApplyCVars(toProfile.cvars)
		ApplyDisplay(toProfile.display)
	else
		db.firstTimeIn = to
	end
	if charFrom ~= to then
		ApplyLayout(char.layouts[to])
		ApplyAddons(char.addons[to])
	end

	db.mode = to
	char.appliedMode = to
	ReloadUI()
end

-- This character last played in the other setup (e.g. you switched on an alt).
local function SyncCharacter()
	if InCombatLockdown() then
		Print("Can't do that in combat. You'll be asked again next login.")
		return
	end
	local from, to = char.appliedMode, db.mode
	char.layouts[from] = CurrentLayoutName()
	char.addons[from] = CaptureAddons()
	ApplyLayout(char.layouts[to])
	ApplyAddons(char.addons[to])
	char.appliedMode = to
	ReloadUI() -- so per-character addon settings (e.g. Baganator profile) swap too
end

StaticPopupDialogs["COUCHMODE_CONFIRM"] = {
	text = "Switch to your %s setup?\nYour UI will reload.",
	button1 = YES,
	button2 = NO,
	OnAccept = function(_, data) SwitchTo(data) end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

StaticPopupDialogs["COUCHMODE_SYNC_CHAR"] = {
	-- StaticPopup only formats two text arguments.
	text = "This character is still on its %s setup.\nApply your %s setup to it? (UI reloads)",
	button1 = YES,
	button2 = NO,
	OnAccept = function() SyncCharacter() end,
	-- On No we change nothing: the character stays on its old setup and its
	-- layout/addons stay filed under that setup.
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

function CouchMode_Toggle()
	if InCombatLockdown() then
		Print("Can't switch setups in combat.")
		return
	end
	local to = Other(db.mode)
	StaticPopup_Show("COUCHMODE_CONFIRM", MODES[to], nil, to)
end

-------------------------------------------------------------------------------
-- Init / events
-------------------------------------------------------------------------------
local function InitDB()
	CouchModeDB = CouchModeDB or {}
	db = CouchModeDB
	-- Future format changes must migrate data here, never discard it: the other
	-- setup's addon settings may exist only in these snapshots.
	db.version = db.version or DB_VERSION
	db.mode = db.mode or "desk"
	db.profiles = db.profiles or {}
	for mode in pairs(MODES) do
		db.profiles[mode] = db.profiles[mode] or {}
		db.profiles[mode].sv = db.profiles[mode].sv or {}
	end
	db.cvars = db.cvars or CopyTable(DEFAULT_CVARS)
	db.tracked = db.tracked or CopyTable(DEFAULT_TRACKED)
	db.svOwner = db.svOwner or {}

	CouchModeCharDB = CouchModeCharDB or {}
	char = CouchModeCharDB
	char.layouts = char.layouts or {}
	char.addons = char.addons or {}
	if char.addonsFormat ~= 2 then
		-- Lists saved by 1.0.x on WoW Forever wrongly recorded every addon as
		-- enabled; applying them would switch on addons you'd turned off. Drop them
		-- and they'll be recorded correctly on the next switch.
		wipe(char.addons)
		char.addonsFormat = 2
	end
	char.sv = char.sv or {}
	for mode in pairs(MODES) do char.sv[mode] = char.sv[mode] or {} end
	char.svOwner = char.svOwner or {}
	char.appliedMode = char.appliedMode or db.mode
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:SetScript("OnEvent", function(_, event, arg1, arg2)
	if event == "ADDON_LOADED" then
		if arg1 == ADDON then
			InitDB()
		elseif db and db.tracked[arg1] then
			SyncTrackedAddon(arg1)
		end

	elseif event == "PLAYER_LOGIN" then
		for addonName in pairs(db.tracked) do
			if not handledThisSession[addonName] and C_AddOns.IsAddOnLoaded(addonName) then
				Print(("Couldn't swap settings for %s (it loaded before CouchMode)."):format(addonName))
			end
		end
		CreateButton()

	elseif event == "PLAYER_ENTERING_WORLD" and (arg1 or arg2) then -- login or reload
		if db.verifyDisplay then C_Timer.After(3, VerifyDisplay) end
		-- Desk: take the display baseline at login, before you've had a chance to
		-- connect through Parsec and switch, rather than at the moment you switch away.
		-- Handheld is different: on your first visit you haven't set it up yet, so its
		-- display is saved when you first switch away from it (see SwitchTo).
		local profile = db.profiles[db.mode]
		if db.mode == "desk" and not profile.display then
			profile.display = CaptureDisplay()
			Print(("Saved your %s display: %s."):format(MODES[db.mode], DisplayToString(profile.display)))
			Print("If you're streaming right now, type /cm savedisplay next time you're at your desk.")
		end
		if db.firstTimeIn then
			Print(("First time in your |cffffffff%s|r setup. Set things up however you like:"):format(MODES[db.firstTimeIn]))
			Print("UI scale, controller mode, display, a NEW Edit Mode layout (so you don't edit your other one), bag/chat position, etc.")
			Print("It's all remembered the next time you press the CouchMode button.")
			db.firstTimeIn = nil
		elseif char.appliedMode ~= db.mode then
			StaticPopup_Show("COUCHMODE_SYNC_CHAR", MODES[char.appliedMode], MODES[db.mode])
		end
	end
end)

-------------------------------------------------------------------------------
-- Slash commands
-------------------------------------------------------------------------------
local function ListTracked()
	Print("Tracked addon settings:")
	for addonName, entry in pairs(db.tracked) do
		local vars = {}
		for _, v in ipairs(entry.account or {}) do vars[#vars + 1] = v end
		for _, v in ipairs(entry.char or {}) do vars[#vars + 1] = v .. " (per character)" end
		print(("   %s: %s"):format(addonName, table.concat(vars, ", ")))
	end
	Print("CVars: " .. table.concat(db.cvars, ", "))
	for mode, label in pairs(MODES) do
		local d = db.profiles[mode].display
		Print(label .. " display: " .. (d and DisplayToString(d) or "not saved yet"))
	end
end

local HELP = {
	"/cm  - switch between Desk and Handheld (same as the button)",
	"/cm desk | handheld  - switch to that setup",
	"/cm status  - show the current setup",
	"/cm addons  - list which addons this setup has turned off",
	"/cm findsetting  - run, flip a game setting, run again: that setting is then remembered per setup",
	"/cm savedisplay  - save the current display mode/resolution for this setup",
	"/cm relabel desk | handheld  - say what your CURRENT setup is, without changing anything",
	"/cm track <Addon> <SavedVar ...>  - also swap that addon's account-wide settings",
	"/cm trackchar <Addon> <SavedVar ...>  - same, for per-character settings",
	"/cm untrack <Addon>",
	"/cm cvar add | remove <CVar>",
	"/cm list  - show what's tracked",
	"/cm button  - show/hide the on-screen button",
}

SLASH_COUCHMODE1 = "/couchmode"
SLASH_COUCHMODE2 = "/cm"
SlashCmdList.COUCHMODE = function(msg)
	local args = {}
	for word in (msg or ""):gmatch("%S+") do args[#args + 1] = word end
	local cmd = (args[1] or ""):lower()

	if cmd == "" or cmd == "toggle" then
		CouchMode_Toggle()
	elseif MODES[cmd] then
		SwitchTo(cmd)
	elseif cmd == "status" then
		Print("Current setup: " .. MODES[db.mode] .. ". " .. MODES[Other(db.mode)] ..
			(db.profiles[Other(db.mode)].saved and " is saved." or " hasn't been set up yet."))
	elseif cmd == "addons" then
		local off = {}
		for name, enabled in pairs(CaptureAddons()) do
			if not enabled then off[#off + 1] = name end
		end
		table.sort(off)
		Print(("Addons off in your %s setup on this character: %s"):format(MODES[db.mode],
			#off > 0 and table.concat(off, ", ") or "none"))
	elseif cmd == "findsetting" then
		FindSetting()
	elseif cmd == "savedisplay" then
		local d = CaptureDisplay()
		db.profiles[db.mode].display = d
		Print(MODES[db.mode] .. " display saved: " .. DisplayToString(d))
	elseif cmd == "relabel" and MODES[(args[2] or ""):lower()] then
		local mode = args[2]:lower()
		db.mode, char.appliedMode = mode, mode
		-- Only loaded addons' settings are live under the new label. A disabled
		-- addon's file still belongs to whichever setup last ran it, so leave it alone.
		for addonName in pairs(db.tracked) do
			if C_AddOns.IsAddOnLoaded(addonName) then
				db.svOwner[addonName] = mode
				char.svOwner[addonName] = mode
			end
		end
		PlaceButton()
		UpdateButton()
		Print("Your current setup is now called " .. MODES[mode] .. ".")
	elseif (cmd == "track" or cmd == "trackchar") and args[3] then
		local addonName = args[2]
		local entry = db.tracked[addonName] or { account = {}, char = {} }
		local list = cmd == "track" and entry.account or entry.char
		for i = 3, #args do
			if not tContains(list, args[i]) then tinsert(list, args[i]) end
		end
		db.tracked[addonName] = entry
		Print(("Now tracking %s. Only add settings tables, never big data ones (prices, inventories, logs)."):format(addonName))
	elseif cmd == "untrack" and args[2] then
		db.tracked[args[2]] = nil
		db.svOwner[args[2]] = nil
		char.svOwner[args[2]] = nil
		Print("No longer tracking " .. args[2] .. ".")
	elseif cmd == "cvar" and args[3] then
		local action, name = args[2]:lower(), args[3]
		tDeleteItem(db.cvars, name)
		if action == "add" then
			if C_CVar.GetCVar(name) == nil then Print("Unknown CVar: " .. name) return end
			tinsert(db.cvars, name)
		end
		Print(("CVar %s %s."):format(name, action == "add" and "added" or "removed"))
	elseif cmd == "list" then
		ListTracked()
	elseif cmd == "button" then
		db.hideButton = not db.hideButton
		UpdateButton()
		Print(db.hideButton and "Button hidden. Use /cm or a keybind to switch." or "Button shown.")
	else
		for _, line in ipairs(HELP) do print(line) end
	end
end
