-- AStone
-- Created by: RedFrog
-- Original creation date: 02/24/2025
-- Version: 1.8.0
-- Changelog:
-- 1.8.0: EMU path: PoK/Guild Hall/Lobby -> Rathemtn -> Nemeen -> Lobby -> Nedaria -> South Ro -> Selephra (no Crescent, no Eweberwyn).
-- 1.7.19: GUI: Recessed header background (dark fill + top/bottom edges) from top to separator.
-- 1.7.18: GUI: "Elevator Debug" text left of toggle; Server name + dropdown same line.
-- 1.7.17: GUI: Server on same line as AStone (SameLine); Debug = toggle icon only (MageGear look, no button).
-- 1.7.16: GUI: Icon 64px; Debug right-aligned, MageGear-style green/red toggle button.
-- 1.7.14: Elevator: /keypress RUN_WALK to toggle walk; /run to force run on (not toggle).
-- 1.7.13: GUI: Icon+text left; Server+dropdown left same line. Elevator: retry face 3x, longer walk delay; step 280ms (less overshoot).
-- 1.7.12: GUI: Adventurer's Stone icon (1437) top right + AStone font; Debug button on bottom.
-- 1.7.11: At elevator: face platform center (/doortarget + /face switch), turn on walk (AUTORUN) to prevent overshoot from speed buffs.
-- 1.7.10: Gate AA first, spell secondary; user message 'We will now use your Gate AA' or 'Gate spell'.
-- 1.7.9: Quest complete: popup first (popcustom 10s) + TTS, both visual and spoken.
-- 1.7.8: Gate/travel moved to right after Vladnelg—casters Gate from 2nd floor, skip elevator down; non-Gate classes still take elevator + run.
-- 1.7.7: Replaced all mq.delay(ms, condition) with waitFor() polling loop—fixes "Quest error: function" (MQ callback causes error in coroutine).
-- 1.7.6: Bind check: only Gate if bound in PoK or Guild Lobby; else run back.
-- 1.7.5: Replaced condition-based settle delays with fixed delays (fixes "Quest error: function"); skip mem if Gate already in gem 7 (retry path).
-- 1.7.4: Settling delays after elevator down before Gate mem—avoids EQ client crash when /memspell runs too soon after step-off.
-- 1.7.3: Code cleanup: VERSION constant, removed unused params/stale comments, added timeouts to meditate/travel/buff loops, popup escaping.
-- 1.7.2: Gate made simple/reliable (no "attempt" logic): clear+mem Gate in gem 7, wait, then cast (retry if cast doesn't start / fizzle-like);
--        Added GUI checkbox for Elevator Debug + saved to AStoneSettings.ini; Elevator stays platform-only (Door ID 1) with no spam.

local VERSION = "1.8.0"

local mq = require('mq')
local ImGui = require('ImGui')
local Icons = require('mq.icons')

-- Print Function
local function AStone(msg)
    print(string.format("\ao[\agAStone\ao]\at %s", msg))
end

-- Configuration
local config = {
    running = false,
    serverName = mq.TLO.EverQuest.Server() or "Unknown",
    serverMode = "Live",
    elevDebug = false,
}

local settingsFile = mq.configDir .. "/AStoneSettings.ini"

local function LoadSettings()
    local savedMode = mq.TLO.Ini(settingsFile, "Settings", "ServerMode")() or "Live"
    if savedMode == "Live" or savedMode == "EMU" then
        config.serverMode = savedMode
    end

    local savedDbg = mq.TLO.Ini(settingsFile, "Settings", "ElevDebug")() or "0"
    config.elevDebug = (tostring(savedDbg) == "1" or tostring(savedDbg):lower() == "true")
end

local function SaveSettings()
    mq.cmdf('/ini "%s" "Settings" "ServerMode" "%s"', settingsFile, config.serverMode)
    mq.cmdf('/ini "%s" "Settings" "ElevDebug" "%s"', settingsFile, config.elevDebug and "1" or "0")
end

LoadSettings()

-- Allowed start zones by server mode (EMU has no Crescent Reach, only to DoN)
local function allowedStartZones(mode)
    if mode == "EMU" then
        return { poknowledge=true, guildhall=true, guildlobby=true }
    end
    return { poknowledge=true, guildlobby=true, guildhall=true, crescent=true }
end

local function questCompleteNotify(text)
    local escaped = text:gsub('%%', '%%%%')
    -- Popup (10 sec) + TTS = both visual and spoken
    mq.cmdf('/popcustom 10 %s', escaped)

    local pluginName = "MQTextToSpeech"
    local wasLoaded = mq.TLO.Plugin(pluginName).IsLoaded()

    if not wasLoaded then
        mq.cmdf('/plugin %s', pluginName)
        mq.delay(500)
    end

    if mq.TLO.Plugin(pluginName).IsLoaded() then
        mq.cmdf('/tts say "%s"', escaped)
        mq.delay(6000)
    else
        mq.cmd('/beep')
        mq.cmd('/beep')
    end

    if not wasLoaded and mq.TLO.Plugin(pluginName).IsLoaded() then
        mq.cmdf('/plugin %s unload', pluginName)
    end
end

-- Starting checks (allowed zones depend on Live vs EMU)
local startZones = allowedStartZones(config.serverMode)
if not startZones[mq.TLO.Zone.ShortName():lower()] then
    if config.serverMode == "EMU" then
        AStone("EMU: Must start in PoK, Guild Hall, or Guild Lobby.")
    else
        AStone("Must start in PoK, Guild Lobby/Hall, or Crescent Reach.")
    end
    return
end
if mq.TLO.FindItem("Adventurer's Stone").ID() then
    AStone("You already have an Adventurer's Stone!")
    return
end
if mq.TLO.Me.Level() < 15 then
    AStone("Level too low (need 15+)")
    return
end

AStone(string.format("Server: \ag%s\ax | AStone v%s loaded.", config.serverName, VERSION))

-- Movement buffs
local movementBuffs = {
    BRD = {"Selo's Accelerando", "Selo's Song of Travel"},
    BST = {"Spirit of Wolf", "Spirit of the Shrew"},
    DRU = {"Spirit of Wolf", "Spirit of Cheetah"},
    RNG = {"Spirit of Wolf"},
    SHM = {"Spirit of Wolf", "Spirit of Cheetah"}
}

-- Travel spells (gate)
local travelSpells = { CLR=true, ENC=true, MAG=true, NEC=true, WIZ=true, DRU=true }

-- Polling wait: avoids mq.delay(ms, condition) which causes "Quest error: function" in coroutines
local function waitFor(ms, check)
    local start = mq.gettime()
    while mq.gettime() - start < ms do
        if check() then return true end
        mq.delay(100)
    end
    return false
end

-- Bind check: Gate only if bound in PoK or Guild Lobby
local function isBoundInPoKOrGuildLobby()
    local loc = mq.TLO.Me.BoundLocation(0)
    if not loc or not loc.Zone then return false end
    local z = (loc.Zone.ShortName() or ""):lower()
    return z == "poknowledge" or z == "guildlobby"
end

-- Find free gem slot
local function findFreeGemSlot()
    local maxGems = mq.TLO.Me.NumGems() or 8
    for i = 1, maxGems do
        if not mq.TLO.Me.Gem(i).ID() then return i end
    end
    local lastSlot = maxGems
    AStone(string.format("All gems full, clearing slot %d", lastSlot))
    mq.cmdf("/memspell %d clear", lastSlot)
    mq.delay(2000)
    return lastSlot
end

-- Meditate (with 5 min timeout to avoid infinite loop)
local function meditateToMana(requiredMana)
    if mq.TLO.Me.CurrentMana() < requiredMana then
        AStone(string.format("Meditating for mana (%d needed)", requiredMana))
        mq.cmd("/sit on")
        local timeout = mq.gettime() + 300000 -- 5 min
        while mq.TLO.Me.CurrentMana() < requiredMana do
            if mq.gettime() >= timeout then
                AStone("\arMeditate timeout (5 min).\ax")
                mq.cmd("/stand")
                return
            end
            mq.delay(1000)
        end
        mq.cmd("/stand")
    end
end

-- useMovementBuff - FULL and VERIFIED (kept)
local function useMovementBuff()
    local class = mq.TLO.Me.Class.ShortName()
    if not movementBuffs[class] then
        if mq.TLO.FindItem("Worn Totem").ID() then
            AStone("Using Worn Totem for speed")
            mq.cmdf("/useitem \"Worn Totem\"")
            mq.delay(2000)
            return true
        end
        AStone("No movement buff available for class")
        return false
    end

    for _, spell in ipairs(movementBuffs[class]) do
        local spellData = mq.TLO.Spell(spell)
        if spellData.ID() then
            local gemSlot
            local maxGems = mq.TLO.Me.NumGems() or 8
            for i = 1, maxGems do
                if mq.TLO.Me.Gem(i).Name() and mq.TLO.Me.Gem(i).Name():lower() == spell:lower() then
                    gemSlot = i
                    break
                end
            end

            if not gemSlot then
                gemSlot = findFreeGemSlot()
                AStone(string.format("Memorizing %s in slot %d", spell, gemSlot))
                mq.cmdf('/memspell %d "%s"', gemSlot, spell)
                mq.delay(8000)
            end

            local success = false
            local maxRetries = 10
            local retries = 0
            while not success and retries < maxRetries do
                retries = retries + 1
                meditateToMana(40)
                if mq.TLO.Me.SpellReady(spell)() then
                    mq.cmd("/target myself")
                    mq.delay(500)
                    mq.cmdf('/cast "%s"', spell)
                    local castTime = spellData.CastTime() or 5000
                    waitFor(castTime + 3000, function() return not mq.TLO.Me.Casting() end)
                    mq.delay(2000)
                    if mq.TLO.Me.Buff(spell).ID() then
                        AStone(spell .. " applied!")
                        success = true
                    else
                        AStone("Buff failed, retrying...")
                    end
                else
                    mq.delay(5000)
                end
            end
            if not success then
                AStone(string.format("\arMovement buff failed after %d attempts.\ax", maxRetries))
                return false
            end
            return true
        end
    end
    return false
end

local function checkMovementBuff()
    local class = mq.TLO.Me.Class.ShortName()
    if movementBuffs[class] then
        for _, spell in ipairs(movementBuffs[class]) do
            if mq.TLO.Me.Buff(spell).ID() then return true end
        end
        return useMovementBuff()
    elseif mq.TLO.FindItem("Worn Totem").ID() then
        if mq.TLO.Me.Buff("Spiritual Vigor").ID() then return true end
        mq.cmdf("/useitem \"Worn Totem\"")
        mq.delay(2000)
        return true
    end
    return false
end

local function travelToZone(targetZone)
    if mq.TLO.Zone.ShortName():lower() == targetZone then return true end
    AStone("Traveling to " .. targetZone .. "...")
    mq.cmdf("/travelto %s", targetZone)
    local timeout = mq.gettime() + 300000 -- 5 min
    while mq.TLO.Zone.ShortName():lower() ~= targetZone do
        if mq.gettime() >= timeout then
            AStone(string.format("\arTravel to %s timeout (5 min).\ax", targetZone))
            return false
        end
        mq.delay(1000)
    end
    AStone("Arrived in " .. targetZone)
    return true
end

-- Nav to NPC by name, wait in range, target (for EMU path)
local function findNpcByName(name)
    if not name or name == "" then return nil end
    local s = mq.TLO.Spawn(("npc =%s"):format(name))
    if s and s() and s.ID() and s.ID() > 0 then return s end
    s = mq.TLO.Spawn(("npc %s"):format(name))
    if s and s() and s.ID() and s.ID() > 0 then return s end
    return nil
end

local function navToName(name, stopDist)
    local sp = findNpcByName(name)
    if not sp then
        AStone(name .. " not found!")
        return false
    end
    local id = sp.ID()
    AStone("Navigating to " .. name .. "...")
    mq.cmdf("/squelch /nav id %d", id)
    while mq.TLO.Navigation.Active() do mq.delay(200) end
    local ok = waitFor(10000, function()
        local s = mq.TLO.Spawn(id)
        return s and s.Distance3D and s.Distance3D() <= (stopDist or 25)
    end)
    if not ok then AStone("Did not reach " .. name .. " within range.") end
    mq.cmdf("/target id %d", id)
    mq.delay(500)
    return ok
end

local function sayLines(lines)
    for _, line in ipairs(lines) do
        mq.cmdf("/say %s", line)
        mq.delay(600)
    end
end

local function waitForZone(short, timeoutMs)
    return waitFor(timeoutMs or 60000, function()
        return (mq.TLO.Zone.ShortName() or ""):lower() == (short or ""):lower()
    end)
end

local function waitForCursorItem(name, timeoutMs)
    return waitFor(timeoutMs or 8000, function()
        local cur = mq.TLO.Cursor.Name() or ""
        if cur == name then return true end
        return mq.TLO.FindItem("=" .. name).ID() ~= nil
    end)
end

-- Dialog phrases (EMU path, from astone01)
local NEMEEN_PHRASES = {"information", "deal with", "work", "more", "interesting ore"}
local LDON_PHRASES = {"Adventures", "Favor Journal", "Morden Rasp", "Farstone"}

local function navToVladnelg()
    AStone("Navigating to Vladnelg Galvern on second floor")
    local vladLoc = "-1354 -1575 30"
    AStone("Navigating to close location: " .. vladLoc)
    mq.cmdf("/squelch /nav loc %s", vladLoc)
    while mq.TLO.Navigation.Active() do mq.delay(200) end
    mq.delay(2000)

    local spawn = mq.TLO.Spawn("Vladnelg Galvern")
    if not spawn() then
        AStone("Vladnelg Galvern not found!")
        return false
    end

    if spawn.Distance() < 15 then
        AStone(string.format("Reached Vladnelg Galvern (distance: %.1f)", spawn.Distance()))
        mq.cmdf("/target id %d", spawn.ID())
        mq.delay(1000)
        return true
    else
        AStone(string.format("Too far from Vladnelg after nav (distance: %.1f)", spawn.Distance()))
        return false
    end
end

local function navToNPC(target)
    AStone("Navigating to " .. target .. "...")
    local isLoc = target:match("^[%-%d%.]+ [%-%d%.]+ [%-%d%.]+$")
    if isLoc then
        mq.cmdf("/squelch /nav loc %s", target)
    else
        local spawn = mq.TLO.Spawn("npc " .. target)
        if not spawn() then
            AStone(target .. " not found!")
            return false
        end
        mq.cmdf("/squelch /nav id %d", spawn.ID())
    end
    while mq.TLO.Navigation.Active() do mq.delay(200) end
    mq.delay(2000)
    return true
end

local function interactWithNPC(npc)
    AStone("Hailing " .. npc .. "...")
    mq.cmdf("/target %s", npc)
    mq.delay(1000)
    mq.cmd("/hail")
    mq.delay(2000)
    if npc == "Vladnelg Galvern" then
        mq.cmd("/say information") mq.delay(2000)
        mq.cmd("/say deal with") mq.delay(2000)
        mq.cmd("/say work") mq.delay(2000)
        mq.cmd("/say more") mq.delay(2000)
        mq.cmd("/say interesting ore") mq.delay(2000)
    elseif npc == "Magus Alaria" then mq.cmd("/say nedaria") mq.delay(2000)
    elseif npc == "Magus Wenla" then mq.cmd("/say south ro") mq.delay(2000)
    elseif npc == "Selephra Giztral" then
        mq.cmd("/say Adventures") mq.delay(2000)
        mq.cmd("/say Favor Journal") mq.delay(2000)
        mq.cmd("/say Morden Rasp") mq.delay(2000)
        mq.cmd("/say Farstones") mq.delay(2000)
    end
end

-- ============================================================
-- Gate: AA first, spell secondary
-- ============================================================

local function useGateAA()
    if not mq.TLO.Me.AltAbilityReady("Gate") then return false end
    AStone("We will now use your Gate AA.")
    mq.cmd("/aa act Gate")
    local ok = waitFor(15000, function() return mq.TLO.Me.Zoning() end)
    if ok then
        waitFor(60000, function()
            local z = (mq.TLO.Zone.ShortName() or ""):lower()
            return z == "guildlobby" or z == "poknowledge"
        end)
    end
    return ok
end

local function memGateGem7()
    -- Skip if Gate already in gem 7 (e.g. retry after script error)
    local gem7Name = mq.TLO.Me.Gem(7).Name()
    if gem7Name and gem7Name:lower() == "gate" then
        AStone("Gate already in gem 7.")
        return true
    end

    AStone("Memorizing Gate in gem 7...")
    mq.cmd("/stand")
    mq.delay(3000) -- settle before /memspell (avoids EQ crash after elevator)

    mq.cmd('/memspell 7 clear')
    mq.delay(1200)

    mq.cmd('/memspell 7 "Gate"')

    local ok = waitFor(60000, function()
        local n = mq.TLO.Me.Gem(7).Name()
        return n and n:lower() == "gate"
    end)

    if ok then
        AStone("Gate memorized.")
        return true
    end

    AStone("\arGate did not appear in gem 7 in time.\ax")
    return false
end

local function castGateGem7()
    meditateToMana(70)
    mq.cmd("/target myself")
    mq.delay(300)

    for castTry = 1, 2 do
        mq.delay(13000)
        mq.cmd('/cast 7')

        -- did casting actually begin?
        local started = waitFor(8000, function()
            return mq.TLO.Me.Casting() or mq.TLO.Me.Zoning()
        end)

        if started then
            -- Wait for cast to finish OR zoning starts
            waitFor(25000, function()
                return (not mq.TLO.Me.Casting()) or mq.TLO.Me.Zoning()
            end)

            -- If zoning, we're good
            if mq.TLO.Me.Zoning() then return true end

            -- If we ended casting but didn't zone, treat as "fizzle-like" and retry once
            if castTry == 1 then
                AStone("\ayGate did not zone (possible fizzle). Recasting...\ax")
                mq.delay(600)
            else
                AStone("\arGate cast finished but no zone occurred.\ax")
            end
        else
            -- Cast never even started (lag/blocked) -> retry once
            if castTry == 1 then
                AStone("\ayGate cast didn't start. Retrying...\ax")
                mq.delay(600)
            else
                AStone("\arGate failed to begin casting.\ax")
            end
        end
    end

    return false
end

local function useTravelSpell()
    local class = mq.TLO.Me.Class.ShortName()
    if not travelSpells[class] then return false end

    -- AA first, spell secondary
    if useGateAA() then return true end

    AStone("We will now use your Gate spell.")
    if not memGateGem7() then return false end
    return castGateGem7()
end

-- ============================================================
-- Crescent Elevator (PLATFORM-ONLY CLICK, FIXED ID, NO SPAM)
-- Uses Switch[ID] to READ state/Z without targeting.
-- Only /doortarget right before click, and /squelch it.
--
-- Platform ID from MQ2Nav Doors window: ID 1
-- ============================================================

local ELEV_PLATFORM_ID = 1

-- States (your mapping):
--   0 = down & stopped
--   2 = moving up
--   1 = up & stopped
--   3 = moving down

local function elevPlatform()
    local sw = mq.TLO.Switch(ELEV_PLATFORM_ID)
    if sw() and sw.ID() and sw.ID() > 0 then return sw end
    return nil
end

local function elevState()
    local p = elevPlatform()
    return p and p.State() or nil
end

local function elevZ()
    local p = elevPlatform()
    return p and p.Z() or nil
end

local function dbgElev(tag)
    if not config.elevDebug then return end
    local st = elevState()
    local pz = elevZ() or 0
    local meZ = mq.TLO.Me.Z() or 0
    AStone(string.format("%s | State=%s PlatZ=%.2f MeZ=%.2f", tag, tostring(st), pz, meZ))
end

local function stopAndSettle(ms)
    ms = ms or 250
    mq.cmd("/squelch /nav stop")
    mq.cmd("/keypress forward release")
    mq.delay(ms)
    waitFor(1500, function() return not mq.TLO.Me.Moving() end)
end

local function clickPlatformOnce()
    local p = elevPlatform()
    if not p then
        AStone("\arCould not find elevator platform by Switch[ID].\ax")
        return false
    end

    -- IMPORTANT: squelch to prevent "Switch X targeted" spam
    mq.cmdf("/squelch /doortarget id %d", ELEV_PLATFORM_ID)
    mq.delay(150)

    dbgElev("CLICK platform")
    mq.cmd("/click left door")
    mq.delay(600)
    dbgElev("AFTER click")
    return true
end

local function waitForStopState(timeoutMs)
    timeoutMs = timeoutMs or 35000
    local start = mq.gettime()
    while mq.gettime() - start < timeoutMs do
        local st = elevState()
        if st == 0 or st == 1 then return true end
        mq.delay(200)
    end
    return false
end

local function waitState(wanted, timeoutMs)
    timeoutMs = timeoutMs or 45000
    local start = mq.gettime()
    while mq.gettime() - start < timeoutMs do
        if elevState() == wanted then return true end
        mq.delay(200)
    end
    return false
end

-- Step forward (280ms; reduced from 400ms—speed buffs overshoot with longer step)
local function stepForward280()
    mq.cmd("/keypress forward hold")
    mq.delay(280)
    mq.cmd("/keypress forward release")
end

-- "platform is really here" wait:
-- Require:
--   - correct stopped state (readyState)
--   - platform Z close to meZ
--   - stable for 3 ticks (~600ms)
local function waitPlatformPresentStable(readyState, timeoutMs)
    timeoutMs = timeoutMs or 15000
    local start = mq.gettime()
    local stable = 0

    while mq.gettime() - start < timeoutMs do
        local p = elevPlatform()
        local st = elevState()
        if p and st == readyState then
            local dz = math.abs((mq.TLO.Me.Z() or 0) - (p.Z() or 0))
            if dz <= 10 then
                stable = stable + 1
                if stable >= 3 then return true end
            else
                stable = 0
            end
        else
            stable = 0
        end
        mq.delay(200)
    end
    return false
end

local function handleCrescentElevator(upOrDown)
    if upOrDown ~= "up" and upOrDown ~= "down" then
        AStone("\arhandleCrescentElevator(): use 'up' or 'down'\ax")
        return false
    end

    -- Simple user-facing messaging (no debug spam)
    if upOrDown == "up" then
        AStone("Crescent Reach: heading to elevator to reach Vladnelg...")
        mq.cmdf("/squelch /nav loc %s", "-1308 -1560 -90")
    else
        AStone("Crescent Reach: returning to ground floor...")
        mq.cmdf("/squelch /nav loc %s", "-1308 -1523 10")
    end

    while mq.TLO.Navigation.Active() do mq.delay(200) end
    mq.delay(600)
    stopAndSettle(300)

    -- Face elevator center (retry 3x; speed buffs cause overshoot if not facing platform)
    mq.cmdf("/squelch /doortarget id %d", ELEV_PLATFORM_ID)
    mq.delay(150)
    for faceTry = 1, 3 do
        mq.cmd("/face switch")
        mq.delay(400)
    end

    -- Turn on walk (speed buffs overshoot platform when running)
    mq.delay(300) -- settle before toggle
    mq.cmd("/keypress RUN_WALK")
    mq.delay(500) -- ensure EQ registers walk

    -- Confirm platform exists
    if not elevPlatform() then
        AStone("\arCould not see elevator platform from staging loc.\ax")
        mq.cmd("/run") -- force run on (not toggle)
        return false
    end

    dbgElev("At staging")

    local readyState  = (upOrDown == "up") and 0 or 1
    local finishState = (upOrDown == "up") and 1 or 0

    -- If moving, never click; wait to stop
    local st = elevState()
    if st == 2 or st == 3 then
        AStone("Elevator moving; waiting...")
        if not waitForStopState(35000) then
            dbgElev("Stop wait FAILED")
            mq.cmd("/run") -- force run on (not toggle)
            return false
        end
        dbgElev("Stopped after moving")
        st = elevState()
    end

    -- If not at ready state, click once to call
    if st ~= readyState then
        if not clickPlatformOnce() then
            mq.cmd("/run") -- force run on (not toggle)
            return false
        end

        if not waitState(readyState, 45000) then
            dbgElev("Ready wait FAILED")
            mq.cmd("/run") -- force run on (not toggle)
            return false
        end
        dbgElev("Ready reached")
    else
        dbgElev("Ready without click")
    end

    -- Platform-present/stable wait (prevents walking into hole)
    if not waitPlatformPresentStable(readyState, 15000) then
        dbgElev("Platform-present/stable FAILED")
        mq.cmd("/run") -- force run on (not toggle)
        return false
    end
    dbgElev("Platform-present/stable OK")

    -- Step on (280ms; walk mode + shorter step to avoid overshoot)
    stopAndSettle(150)
    stepForward280()
    mq.delay(300)

    -- Safety: if it started moving, freeze and abort
    local now = elevState()
    if now == 2 or now == 3 then
        AStone("\arElevator moved while stepping on; freezing.\ax")
        stopAndSettle(600)
        mq.cmd("/run") -- force run on (not toggle)
        return false
    end

    -- Start ride (one click)
    if not clickPlatformOnce() then
        mq.cmd("/run") -- force run on (not toggle)
        return false
    end

    if not waitState(finishState, 45000) then
        dbgElev("Finish wait FAILED")
        mq.cmd("/run") -- force run on (not toggle)
        return false
    end
    dbgElev("Finish reached")

    -- Step off only if still stopped
    stopAndSettle(200)
    local st2 = elevState()
    if st2 == 2 or st2 == 3 then
        AStone("\arElevator started moving at stop; freezing (no step-off).\ax")
        stopAndSettle(800)
        mq.cmd("/run") -- force run on (not toggle)
        return false
    end

    stepForward280()
    mq.cmd("/run") -- force run on (not toggle)
    return true
end

-- ============================================================
-- EMU path: PoK/Guild Hall -> Guild Lobby -> Rathemtn -> Nemeen
-- -> Guild Lobby -> Nedaria -> South Ro -> Selephra (no Crescent, no Eweberwyn)
-- ============================================================
local SOUTH_RO_SHORT = "sro"

local function runPathEMU()
    local z = (mq.TLO.Zone.ShortName() or ""):lower()
    if z == "poknowledge" or z == "guildhall" then
        if not travelToZone("guildlobby") then return false end
    end
    if not travelToZone("rathemtn") then return false end
    checkMovementBuff()

    if not navToName("Nemeen Pekasr", 25) then return false end
    sayLines(NEMEEN_PHRASES)

    if not travelToZone("guildlobby") then return false end
    if not navToName("Magus Alaria", 20) then return false end
    mq.cmd("/say Nedaria")
    mq.delay(600)
    if not waitForZone("nedaria", 60000) then
        AStone("\arTo Nedaria failed.\ax")
        return false
    end

    if not navToName("Magus Wenla", 20) then return false end
    mq.cmd("/say South Ro")
    mq.delay(600)
    if not waitForZone(SOUTH_RO_SHORT, 60000) then
        AStone("\arTo South Ro failed.\ax")
        return false
    end

    if not navToName("Selephra Giztral", 20) then return false end
    sayLines(LDON_PHRASES)

    if waitForCursorItem("Adventurer's Stone", 6000) then
        mq.cmd("/autoinventory")
        mq.delay(180)
    end
    if mq.TLO.FindItem("Adventurer's Stone").ID() then
        AStone("\ayQuest complete! Adventurer's Stone acquired.\ax")
        questCompleteNotify("Congratulations Adventurer! Your quest has been completed! You now have an Adventurer's Stone.")
        return true
    end
    AStone("\arNo stone received after Selephra.\ax")
    return false
end

-- Quest coroutine
local questCo = nil

local function RunQuest()
    questCo = coroutine.create(function()
        -- EMU path: no Crescent Reach; uses Rathemtn -> Nemeen -> Guild Lobby -> Nedaria -> South Ro
        if config.serverMode == "EMU" then
            runPathEMU()
            return
        end

        -- Live path: Crescent Reach -> Vladnelg -> Guild Lobby -> Nedaria -> South Ro
        useMovementBuff()

        if mq.TLO.Zone.ShortName():lower() ~= "crescent" then
            if not travelToZone("crescent") then return end
        end

        checkMovementBuff()

        if not handleCrescentElevator("up") then
            AStone("\arElevator UP failed; stopping.\ax")
            return
        end

        if not navToVladnelg() then
            AStone("Failed to reach Vladnelg Galvern!")
            return
        end
        interactWithNPC("Vladnelg Galvern")

        -- Gate/travel: right after Vladnelg—no elevator needed if we can Gate
        local class = mq.TLO.Me.Class.ShortName()
        local canGate = travelSpells[class] and isBoundInPoKOrGuildLobby()

        if canGate then
            AStone("Leaving Crescent Reach: preparing Gate to go back...")
            mq.cmd("/squelch /nav stop")
            mq.cmd("/keypress forward release")
            mq.delay(2000) -- brief settle before /memspell
            if useTravelSpell() then
                waitFor(60000, function()
                    local z = (mq.TLO.Zone.ShortName() or ""):lower()
                    return z == "guildlobby" or z == "poknowledge"
                end)
            end
        else
            if not travelSpells[class] then
                AStone("Not a Gate class; taking elevator down and running back.")
            else
                AStone("Not bound in PoK/Guild Lobby; taking elevator down and running back.")
            end
            if not handleCrescentElevator("down") then
                AStone("\arElevator DOWN failed; stopping.\ax")
                return
            end
            if mq.TLO.Zone.ShortName():lower() ~= "guildlobby" then
                if not travelToZone("guildlobby") then return end
            end
        end

        if mq.TLO.Zone.ShortName():lower() ~= "guildlobby" then
            if not travelToZone("guildlobby") then return end
        end

        checkMovementBuff()
        if not navToNPC("Magus Alaria") then return end
        interactWithNPC("Magus Alaria")
        waitFor(60000, function() return (mq.TLO.Zone.ShortName() or ""):lower() == "nedaria" end)

        checkMovementBuff()
        if not navToNPC("Magus Wenla") then return end
        interactWithNPC("Magus Wenla")
        waitFor(10000, function() return (mq.TLO.Zone.ShortName() or ""):lower() == "southro" end)

        if not navToNPC("Selephra Giztral") then return end
        interactWithNPC("Selephra Giztral")

        waitFor(30000, function() return mq.TLO.Cursor.Name() == "Adventurer's Stone" end)
        if mq.TLO.Cursor.Name() == "Adventurer's Stone" then
            AStone("\amAdventurer's Stone\ax on cursor, autoinventorying...")
            mq.cmd("/autoinventory")
            mq.delay(2000)

            AStone("\ayQuest complete! Adventurer's Stone acquired.\ax")
            questCompleteNotify("Congratulations Adventurer! Your quest has been completed! You now have an Adventurer's Stone.")
            return
        else
            AStone("\arNo stone received.\ax")
        end
    end)
end

-- GUI
local openGUI = true
local ADVENTURER_STONE_ICON_ID = 1437
local EQ_ICON_OFFSET = 500  -- A_DragItem offset for EQ item icons
local astoneIconTex = nil

local function DrawGUI()
    if not openGUI then return end

    ImGui.SetNextWindowSize(420, 210, ImGuiCond.FirstUseEver)
    openGUI = ImGui.Begin("AStone v" .. VERSION, true)

    -- Recessed header background (dark fill + subtle edges) from top to separator
    local iconSize = 64
    local padY = 8
    local style = ImGui.GetStyle and ImGui.GetStyle()
    if style and style.WindowPadding then
        local wp = style.WindowPadding
        if type(wp) == "number" then padY = wp
        elseif type(wp) == "table" then padY = wp.y or wp[2] or 8
        elseif wp and wp.y then padY = wp.y
        end
    end
    local headerH = iconSize + math.max(12, padY * 2)
    local sx, sy = ImGui.GetCursorScreenPos()
    local cw, _ = ImGui.GetContentRegionAvail()
    local cwNum = (type(cw) == "number" and cw) or (cw and (cw.x or cw[1])) or 400
    if sx and sy then
        local dl = ImGui.GetWindowDrawList()
        if dl then
            -- Very light green tinge (G slightly above R/B)
            local colRecess = ImGui.GetColorU32 and ImGui.GetColorU32(0.11, 0.15, 0.12, 0.92) or 0xEA1F261E
            local colTop = ImGui.GetColorU32 and ImGui.GetColorU32(0.19, 0.24, 0.21, 1) or 0xFF36382B
            local colBottom = ImGui.GetColorU32 and ImGui.GetColorU32(0.05, 0.09, 0.06, 1) or 0xFF0F1612
            dl:AddRectFilled(ImVec2(sx, sy), ImVec2(sx + cwNum, sy + headerH), colRecess)
            -- Night-sky sparkle: sparse bright dots (1–3px), green-tinted
            local step = 8
            for i = 0, cwNum, step do
                for j = 0, headerH, step do
                    local h = (i * 7 + j * 13) % 23
                    if h > 18 then  -- ~22% of cells = sparse sparkles
                        local sz = (h == 19 and 1) or (h == 20 and 2) or 2  -- mostly 1–2px, occasional 2
                        if h == 22 then sz = 3 end  -- rare brighter "star"
                        local dx = (i + (h % 5)) % math.max(1, cwNum - 6)
                        local dy = (j + ((h * 3) % 5)) % math.max(1, headerH - 6)
                        -- Brighter = sparkle: pale green-white dots
                        local bright = (h == 22) and 0.65 or ((h % 2 == 0) and 0.45 or 0.35)
                        local r, g, b = 0.2 + bright * 0.5, 0.4 + bright * 0.5, 0.25 + bright * 0.4
                        local colSparkle = ImGui.GetColorU32 and ImGui.GetColorU32(r, g, b, 0.9) or colRecess
                        dl:AddRectFilled(
                            ImVec2(sx + dx, sy + dy),
                            ImVec2(sx + dx + sz, sy + dy + sz),
                            colSparkle
                        )
                    end
                end
            end
            dl:AddLine(ImVec2(sx, sy), ImVec2(sx + cwNum, sy), colTop, 1)
            dl:AddLine(ImVec2(sx, sy + headerH), ImVec2(sx + cwNum, sy + headerH), colBottom, 1)
        end
    end

    -- Left: Adventurer's Stone icon + AStone title (icon size, text centered to icon)
    if astoneIconTex == nil and mq.FindTextureAnimation then
        local ok, tex = pcall(mq.FindTextureAnimation, "A_DragItem")
        if ok and tex then astoneIconTex = tex end
    end
    if astoneIconTex and ImGui.DrawTextureAnimation then
        astoneIconTex:SetTextureCell(ADVENTURER_STONE_ICON_ID - EQ_ICON_OFFSET)
        ImGui.DrawTextureAnimation(astoneIconTex, iconSize, iconSize)
    end
    ImGui.SameLine()
    ImGui.SetWindowFontScale(1.4)
    -- Vertically center AStone text with the icon
    local textLineH = ImGui.GetTextLineHeight and ImGui.GetTextLineHeight() or (iconSize * 0.5)
    local offsetY = (iconSize - textLineH) * 0.5
    if offsetY > 0 then ImGui.SetCursorPosY(ImGui.GetCursorPosY() + offsetY) end
    ImGui.TextColored(0.4, 1, 0.5, 1, "AStone")
    ImGui.SetWindowFontScale(1.0)

    -- Server + dropdown on same line as AStone, right-aligned; lock Y so name and dropdown align with "Server:"
    ImGui.SameLine()
    local availX, _ = ImGui.GetContentRegionAvail()
    local blockW = 220
    ImGui.SetCursorPosX(ImGui.GetCursorPosX() + math.max(0, (availX or 0) - blockW))
    if offsetY > 0 then ImGui.SetCursorPosY(ImGui.GetCursorPosY() + offsetY) end
    local serverRowY = ImGui.GetCursorPosY()
    ImGui.Text("Server:")
    ImGui.SameLine()
    ImGui.SetCursorPosY(serverRowY)
    ImGui.TextColored(0, 1, 0, 1, config.serverName)
    ImGui.SameLine()
    ImGui.SetCursorPosX(ImGui.GetCursorPosX() + 6)
    ImGui.SetCursorPosY(serverRowY)
    ImGui.SetNextItemWidth(100)
    if ImGui.BeginCombo("##ServerMode", config.serverMode) then
        if ImGui.Selectable("Live") then
            config.serverMode = "Live"
            SaveSettings()
        end
        if ImGui.Selectable("EMU") then
            config.serverMode = "EMU"
            SaveSettings()
        end
        ImGui.EndCombo()
    end

    ImGui.Separator()

    local buttonWidth = 150
    local buttonHeight = 42

    if config.running then
        ImGui.PushStyleVar(ImGuiStyleVar.FrameBorderSize, 4)
        ImGui.PushStyleColor(ImGuiCol.Border, 0.0, 0.0, 0.0, 1.0)
        ImGui.PushStyleColor(ImGuiCol.Button, 0.1, 0.5, 0.1, 1.0)
        ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.12, 0.55, 0.12, 1.0)
        ImGui.PushStyleColor(ImGuiCol.ButtonActive, 0.08, 0.4, 0.08, 1.0)
        ImGui.Button(string.format("%s Running...", Icons.FA_PLAY), buttonWidth, buttonHeight)
        ImGui.PopStyleColor(4)
        ImGui.PopStyleVar()

        ImGui.SameLine()

        ImGui.PushStyleVar(ImGuiStyleVar.FrameBorderSize, 4)
        ImGui.PushStyleColor(ImGuiCol.Border, 1.0, 1.0, 1.0, 1.0)
        ImGui.PushStyleColor(ImGuiCol.Button, 0.7, 0.2, 0.2, 1.0)
        ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.9, 0.3, 0.3, 1.0)
        ImGui.PushStyleColor(ImGuiCol.ButtonActive, 0.6, 0.15, 0.15, 1.0)
        if ImGui.Button(string.format("%s Stop", Icons.FA_STOP), buttonWidth, buttonHeight) then
            config.running = false
            mq.cmd("/squelch /nav stop")
            mq.cmd("/squelch /travelto stop")
            questCo = nil
        end
        ImGui.PopStyleColor(4)
        ImGui.PopStyleVar()
    else
        ImGui.PushStyleVar(ImGuiStyleVar.FrameBorderSize, 4)
        ImGui.PushStyleColor(ImGuiCol.Border, 1.0, 1.0, 1.0, 1.0)
        ImGui.PushStyleColor(ImGuiCol.Button, 0.2, 0.8, 0.2, 1.0)
        ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.3, 1.0, 0.3, 1.0)
        ImGui.PushStyleColor(ImGuiCol.ButtonActive, 0.15, 0.7, 0.15, 1.0)
        if ImGui.Button(string.format("%s Start Quest", Icons.FA_PLAY), buttonWidth, buttonHeight) then
            config.running = true
            RunQuest()
        end
        ImGui.PopStyleColor(4)
        ImGui.PopStyleVar()

        ImGui.SameLine()

        ImGui.PushStyleVar(ImGuiStyleVar.FrameBorderSize, 4)
        ImGui.PushStyleColor(ImGuiCol.Border, 0.0, 0.0, 0.0, 1.0)
        ImGui.PushStyleColor(ImGuiCol.Button, 0.3, 0.3, 0.3, 1.0)
        ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.35, 0.35, 0.35, 1.0)
        ImGui.PushStyleColor(ImGuiCol.ButtonActive, 0.25, 0.25, 0.25, 1.0)
        ImGui.Button(string.format("%s Stop", Icons.FA_STOP), buttonWidth, buttonHeight)
        ImGui.PopStyleColor(4)
        ImGui.PopStyleVar()
    end

    ImGui.Separator()

    -- Elevator Debug: label left of toggle (same line), right-aligned block
    local dbgAvailX, _ = ImGui.GetContentRegionAvail()
    local dbgBlockW = 130  -- "Elevator Debug" text + toggle icon
    ImGui.SetCursorPosX(ImGui.GetCursorPosX() + math.max(0, (dbgAvailX or 0) - dbgBlockW))
    ImGui.PushID("ElevatorDebug")
    ImGui.Text("Elevator Debug")
    ImGui.SameLine()
    if config.elevDebug then
        ImGui.TextColored(0.0, 1.0, 0.0, 1.0, Icons.FA_TOGGLE_ON)
    else
        ImGui.TextColored(1.0, 0.0, 0.0, 1.0, Icons.FA_TOGGLE_OFF)
    end
    if ImGui.IsItemHovered() then
        ImGui.SetTooltip(config.elevDebug and "On (click to turn off)" or "Off (click to turn on)")
        if ImGui.IsMouseClicked(0) then
            config.elevDebug = not config.elevDebug
            SaveSettings()
        end
    end
    ImGui.PopID()

    ImGui.End()
end

mq.imgui.init("AStoneGUI", DrawGUI)

-- Main loop
while openGUI do
    if config.running and questCo then
        if coroutine.status(questCo) == "dead" then
            config.running = false
        else
            local ok, err = coroutine.resume(questCo)
            if not ok then
                AStone("Quest error: " .. tostring(err))
                config.running = false
            end
        end
    end
    mq.delay(100)
end

AStone("AStone terminated.")
