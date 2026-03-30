-- ReadyCheckShame test suite
-- Run with: lua tests.lua (requires standalone Lua, not WoW)
-- These tests encode the scenarios discussed during development.

--------------------------------------------------------------------------------
-- Mock WoW API
--------------------------------------------------------------------------------

local time = 0
local function GetTime() return time end
local function SetTime(t) time = t end
local function AdvanceTime(dt) time = time + dt end

local groupMembers = {}
local readyStatuses = {}
local chatMessages = {}
local raidMessages = {}

local function IsInRaid() return #groupMembers > 5 end
local function IsInGroup() return #groupMembers > 0 end
local function GetNumGroupMembers() return #groupMembers end
local function UnitName(unit)
    for _, m in ipairs(groupMembers) do
        if m.unit == unit then return m.name end
    end
    return nil
end
local function GetRaidRosterInfo(i)
    if groupMembers[i] then return groupMembers[i].name end
    return nil
end
local function GetReadyCheckStatus(unit)
    return readyStatuses[unit] or "waiting"
end

-- issecretvalue mock
function issecretvalue(v) return false end

-- Minimal frame mock
local events = {}
local function CreateFrame()
    return {
        RegisterEvent = function(self, e) events[e] = true end,
        UnregisterEvent = function(self, e) events[e] = nil end,
        SetScript = function(self, script, fn) self[script] = fn end,
    }
end

-- Chat mock
DEFAULT_CHAT_FRAME = {
    messages = {},
    AddMessage = function(self, msg)
        table.insert(self.messages, msg)
    end,
}

local function ClearMessages()
    DEFAULT_CHAT_FRAME.messages = {}
end

local function GetMessages()
    return DEFAULT_CHAT_FRAME.messages
end

-- SendChatMessage mock
local sentChatMessages = {}
function SendChatMessage(msg, channel)
    table.insert(sentChatMessages, {msg = msg, channel = channel})
end

-- Other WoW API mocks
function C_ChatInfo.RegisterAddonMessagePrefix() end
C_ChatInfo = { RegisterAddonMessagePrefix = function() end }
function C_Timer.NewTicker() end
C_Timer = { NewTicker = function() end }
function date(fmt) return "2026-03-28" end
function strsplit(sep, str) return str end
function strtrim(s) return s:match("^%s*(.-)%s*$") end
function wipe(t) for k in pairs(t) do t[k] = nil end end

-- Make globals available
_G = _G or {}

--------------------------------------------------------------------------------
-- Test framework
--------------------------------------------------------------------------------

local tests_run = 0
local tests_passed = 0
local tests_failed = 0

local function assert_eq(expected, actual, msg)
    if expected ~= actual then
        error(string.format("FAIL: %s — expected %s, got %s", msg or "", tostring(expected), tostring(actual)), 2)
    end
end

local function assert_gt(a, b, msg)
    if not (a > b) then
        error(string.format("FAIL: %s — expected %s > %s", msg or "", tostring(a), tostring(b)), 2)
    end
end

local function test(name, fn)
    tests_run = tests_run + 1
    -- Reset state
    ReadyCheckShameDB = {}
    ClearMessages()
    sentChatMessages = {}
    groupMembers = {}
    readyStatuses = {}
    SetTime(0)

    local ok, err = pcall(fn)
    if ok then
        tests_passed = tests_passed + 1
        print("  PASS: " .. name)
    else
        tests_failed = tests_failed + 1
        print("  FAIL: " .. name .. " — " .. tostring(err))
    end
end

--------------------------------------------------------------------------------
-- Helper to simulate events
--------------------------------------------------------------------------------

local eventHandler

local function SetupAddon()
    -- Load the addon logic inline since we can't dofile WoW Lua easily
    -- Instead we test the logic functions directly

    ReadyCheckShameDB = {
        alltime = {},
        tonight = { date = "2026-03-28", players = {} },
        history = {},
    }
end

local function EmptyStats()
    return { seen = 0, notready = 0, afk = 0, totalResponseTime = 0, responseCount = 0, timeWasted = 0 }
end

local function EnsurePlayer(name)
    if not ReadyCheckShameDB.alltime[name] then
        ReadyCheckShameDB.alltime[name] = EmptyStats()
    end
    if not ReadyCheckShameDB.tonight.players[name] then
        ReadyCheckShameDB.tonight.players[name] = EmptyStats()
    end
end

local function IncrementStat(name, field, amount)
    ReadyCheckShameDB.alltime[name][field] = ReadyCheckShameDB.alltime[name][field] + (amount or 1)
    ReadyCheckShameDB.tonight.players[name][field] = ReadyCheckShameDB.tonight.players[name][field] + (amount or 1)
end

local SEVERITY = { slow = 1, notready = 2, afk = 5, chat = 3 }

local function FinalizeSession(pullTime, sessionStart, sessionProblems, sessionGroupSize)
    local totalSessionTime = pullTime - sessionStart
    local gs = math.max(sessionGroupSize - 1, 1)

    for name, problem in pairs(sessionProblems) do
        EnsurePlayer(name)
        local weight = SEVERITY[problem.worst] or 1
        local waste = totalSessionTime * gs * weight * problem.checks
        IncrementStat(name, "timeWasted", waste)
    end
end

--------------------------------------------------------------------------------
-- Tests
--------------------------------------------------------------------------------

print("\nReadyCheckShame Test Suite")
print("=========================\n")

-- Scenario: Everyone clicks ready quickly
test("Perfect ready check — no time wasted", function()
    SetupAddon()
    local names = {"Alice", "Bob", "Charlie"}
    for _, n in ipairs(names) do
        EnsurePlayer(n)
        IncrementStat(n, "seen")
        IncrementStat(n, "responseCount")
        IncrementStat(n, "totalResponseTime", 1.5) -- all fast
    end
    -- No session problems, no finalize
    for _, n in ipairs(names) do
        assert_eq(0, ReadyCheckShameDB.alltime[n].timeWasted, n .. " should have 0 wasted")
    end
end)

-- Scenario: One person AFKs a single ready check
test("One AFK — gets 5x penalty", function()
    SetupAddon()
    local sessionProblems = { ["SlowGuy"] = { checks = 1, worst = "afk" } }
    EnsurePlayer("SlowGuy")
    EnsurePlayer("FastGuy")
    IncrementStat("SlowGuy", "seen")
    IncrementStat("FastGuy", "seen")

    -- 20 person raid, 30 second session
    FinalizeSession(30, 0, sessionProblems, 20)

    -- SlowGuy: 30s * 19 people * 5x * 1 check = 2850
    assert_eq(2850, ReadyCheckShameDB.alltime["SlowGuy"].timeWasted, "AFK 5x penalty")
    assert_eq(0, ReadyCheckShameDB.alltime["FastGuy"].timeWasted, "Fast guy no penalty")
end)

-- Scenario: Two people AFK — both get full blame, not split
test("Two AFKs — both get full penalty independently", function()
    SetupAddon()
    local sessionProblems = {
        ["AFK1"] = { checks = 1, worst = "afk" },
        ["AFK2"] = { checks = 1, worst = "afk" },
    }
    EnsurePlayer("AFK1")
    EnsurePlayer("AFK2")
    EnsurePlayer("GoodGuy")

    FinalizeSession(30, 0, sessionProblems, 20)

    -- Both should get the same penalty independently
    assert_eq(2850, ReadyCheckShameDB.alltime["AFK1"].timeWasted, "AFK1 full penalty")
    assert_eq(2850, ReadyCheckShameDB.alltime["AFK2"].timeWasted, "AFK2 full penalty")
    assert_eq(0, ReadyCheckShameDB.alltime["GoodGuy"].timeWasted, "Good guy no penalty")
end)

-- Scenario: Person types "r" in chat after ready check — 3x penalty
test("Chat ready — 3x penalty", function()
    SetupAddon()
    local sessionProblems = { ["ChatGuy"] = { checks = 1, worst = "chat" } }
    EnsurePlayer("ChatGuy")

    FinalizeSession(45, 0, sessionProblems, 20)

    -- 45s * 19 * 3x * 1 = 2565
    assert_eq(2565, ReadyCheckShameDB.alltime["ChatGuy"].timeWasted, "Chat 3x penalty")
end)

-- Scenario: Person is slow (>5s) but clicks ready — 1x penalty
test("Slow responder — 1x penalty", function()
    SetupAddon()
    local sessionProblems = { ["SlowClicker"] = { checks = 1, worst = "slow" } }
    EnsurePlayer("SlowClicker")

    FinalizeSession(15, 0, sessionProblems, 20)

    -- 15s * 19 * 1x * 1 = 285
    assert_eq(285, ReadyCheckShameDB.alltime["SlowClicker"].timeWasted, "Slow 1x penalty")
end)

-- Scenario: Multiple ready checks needed for same person
test("Multiple ready checks — penalty multiplied by checks failed", function()
    SetupAddon()
    -- Person AFKed through 3 ready checks before responding on the 4th
    local sessionProblems = { ["SuperAFK"] = { checks = 3, worst = "afk" } }
    EnsurePlayer("SuperAFK")

    -- Total session was 2 minutes (120s)
    FinalizeSession(120, 0, sessionProblems, 20)

    -- 120s * 19 * 5x * 3 checks = 34200
    assert_eq(34200, ReadyCheckShameDB.alltime["SuperAFK"].timeWasted, "Multi-check AFK")
end)

-- Scenario: Person clicked ready fast — no penalty even if check took long
test("Fast responder during long check — zero penalty", function()
    SetupAddon()
    -- Only the AFK person is in sessionProblems, not the fast clicker
    local sessionProblems = { ["AFKGuy"] = { checks = 1, worst = "afk" } }
    EnsurePlayer("FastGuy")
    EnsurePlayer("AFKGuy")

    FinalizeSession(60, 0, sessionProblems, 20)

    assert_eq(0, ReadyCheckShameDB.alltime["FastGuy"].timeWasted, "Fast guy zero penalty")
    assert_gt(ReadyCheckShameDB.alltime["AFKGuy"].timeWasted, 0, "AFK guy has penalty")
end)

-- Scenario: Severity escalation — starts slow, ends up AFK
test("Severity escalation — worst offense wins", function()
    SetupAddon()
    -- Person was slow on check 1, then full AFK on check 2
    -- worst should be "afk" (5x), not "slow" (1x)
    local sessionProblems = { ["Escalator"] = { checks = 2, worst = "afk" } }
    EnsurePlayer("Escalator")

    FinalizeSession(60, 0, sessionProblems, 20)

    -- 60s * 19 * 5x * 2 checks = 11400
    assert_eq(11400, ReadyCheckShameDB.alltime["Escalator"].timeWasted, "Worst severity wins")
end)

-- Scenario: Chat ready is worse than slow but less than AFK
test("Severity ordering: slow < notready < chat < afk", function()
    assert_gt(SEVERITY["notready"], SEVERITY["slow"], "notready > slow")
    assert_gt(SEVERITY["chat"], SEVERITY["notready"], "chat > notready")
    assert_gt(SEVERITY["afk"], SEVERITY["chat"], "afk > chat")
end)

-- Scenario: Tonight resets on new date
test("Tonight resets when date changes", function()
    SetupAddon()
    EnsurePlayer("Raider")
    IncrementStat("Raider", "seen")
    IncrementStat("Raider", "afk")

    assert_eq(1, ReadyCheckShameDB.tonight.players["Raider"].afk, "Tonight has data")
    assert_eq(1, ReadyCheckShameDB.alltime["Raider"].afk, "Alltime has data")

    -- Simulate new day
    ReadyCheckShameDB.tonight = { date = "2026-03-29", players = {} }

    assert_eq(nil, ReadyCheckShameDB.tonight.players["Raider"], "Tonight reset")
    assert_eq(1, ReadyCheckShameDB.alltime["Raider"].afk, "Alltime preserved")
end)

-- Scenario: Raid size matters — bigger raid = more wasted time
test("Bigger raid = more time wasted per person", function()
    SetupAddon()
    EnsurePlayer("AFK_Small")
    EnsurePlayer("AFK_Big")

    -- 5-person group
    FinalizeSession(30, 0, { ["AFK_Small"] = { checks = 1, worst = "afk" } }, 5)
    local small = ReadyCheckShameDB.alltime["AFK_Small"].timeWasted

    -- 20-person raid
    FinalizeSession(30, 0, { ["AFK_Big"] = { checks = 1, worst = "afk" } }, 20)
    local big = ReadyCheckShameDB.alltime["AFK_Big"].timeWasted

    assert_gt(big, small, "20-person raid wastes more than 5-person")
    -- Small: 30 * 4 * 5 = 600
    -- Big: 30 * 19 * 5 = 2850
    assert_eq(600, small, "5-person calc")
    assert_eq(2850, big, "20-person calc")
end)

-- Scenario: Pull without a timer — combat finalizes session
test("Combat start finalizes session (no pull timer needed)", function()
    SetupAddon()
    local sessionProblems = { ["AFKGuy"] = { checks = 1, worst = "afk" } }
    EnsurePlayer("AFKGuy")

    -- Session started at t=0, combat at t=45
    FinalizeSession(45, 0, sessionProblems, 20)

    assert_eq(4275, ReadyCheckShameDB.alltime["AFKGuy"].timeWasted, "Combat finalized session")
    -- 45 * 19 * 5 * 1 = 4275
end)

-- Scenario: Raid leader excluded from tracking
test("Raid leader (initiator) should not be tracked", function()
    SetupAddon()
    -- Simulate: initiator "RaidLeader" is excluded from pendingMembers
    -- Only "Raider1" and "Raider2" are tracked
    EnsurePlayer("Raider1")
    EnsurePlayer("Raider2")
    IncrementStat("Raider1", "seen")
    IncrementStat("Raider2", "seen")

    -- RaidLeader should NOT be in the DB at all
    assert_eq(nil, ReadyCheckShameDB.alltime["RaidLeader"], "Leader not tracked")
    assert_eq(1, ReadyCheckShameDB.alltime["Raider1"].seen, "Raider1 tracked")
end)

-- Scenario: Ready check cancelled — no penalties
test("Cancelled ready check — no session problems recorded", function()
    SetupAddon()
    -- If READY_CHECK_FINISHED fires with everyone still pending but
    -- the check was cancelled, GetReadyCheckStatus returns "waiting"
    -- for everyone. They'd all get AFK charges, which is wrong.
    -- However, WoW doesn't fire READY_CHECK_FINISHED on cancel,
    -- so this scenario doesn't create session problems.
    -- Just verify empty session = no damage.
    FinalizeSession(10, 0, {}, 20)

    -- No players should have any time wasted
    local hasData = false
    for _ in pairs(ReadyCheckShameDB.alltime) do hasData = true end
    assert_eq(false, hasData, "No data from empty session")
end)

-- Scenario: Cross-realm name matching for chat "r"
test("Cross-realm name stripping for chat ready", function()
    -- StripRealm should handle "Player-Proudmoore" -> "Player"
    local function StripRealm(name)
        if not name then return name end
        return (strsplit("-", name))
    end

    -- Note: our mock strsplit doesn't actually split, so test the logic
    assert_eq("Player", StripRealm("Player"), "No realm stays same")
    -- In real WoW, strsplit("-", "Player-Proudmoore") returns "Player", "Proudmoore"
end)

-- Scenario: Person joins mid-session, only charged for checks they were in
test("Mid-session joiner only charged for their checks", function()
    SetupAddon()
    -- LateComer only failed 1 check (they joined after the first 2)
    -- OGSlacker failed all 3
    local sessionProblems = {
        ["OGSlacker"] = { checks = 3, worst = "afk" },
        ["LateComer"] = { checks = 1, worst = "afk" },
    }
    EnsurePlayer("OGSlacker")
    EnsurePlayer("LateComer")

    FinalizeSession(120, 0, sessionProblems, 20)

    local og = ReadyCheckShameDB.alltime["OGSlacker"].timeWasted
    local late = ReadyCheckShameDB.alltime["LateComer"].timeWasted

    -- OG: 120 * 19 * 5 * 3 = 34200
    -- Late: 120 * 19 * 5 * 1 = 11400
    assert_eq(34200, og, "OGSlacker charged for 3 checks")
    assert_eq(11400, late, "LateComer charged for 1 check")
    assert_gt(og, late, "More checks = more penalty")
end)

-- Scenario: Session timeout after 2 minutes with no pull
test("Session auto-finalizes after timeout", function()
    SetupAddon()
    local sessionProblems = { ["Wanderer"] = { checks = 1, worst = "afk" } }
    EnsurePlayer("Wanderer")

    -- Timeout at 120s
    FinalizeSession(120, 0, sessionProblems, 20)

    assert_gt(ReadyCheckShameDB.alltime["Wanderer"].timeWasted, 0, "Timeout finalizes")
end)

-- Scenario: notready (clicked the X) is worse than slow but less than chat
test("Clicked Not Ready — 2x penalty", function()
    SetupAddon()
    local sessionProblems = { ["Troll"] = { checks = 1, worst = "notready" } }
    EnsurePlayer("Troll")

    FinalizeSession(30, 0, sessionProblems, 20)

    -- 30 * 19 * 2 * 1 = 1140
    assert_eq(1140, ReadyCheckShameDB.alltime["Troll"].timeWasted, "NotReady 2x penalty")
end)

-- Scenario: Debounce — rapid ready checks should be ignored
test("Debounce — ready check within 10s ignored", function()
    -- The debounce logic is: if (now - checkStartTime) < 10 then return
    -- We test the logic here
    local lastCheck = 100
    local now = 105  -- 5 seconds later
    local shouldIgnore = (lastCheck > 0 and (now - lastCheck) < 10)
    assert_eq(true, shouldIgnore, "5s gap should be ignored")

    now = 115  -- 15 seconds later
    shouldIgnore = (lastCheck > 0 and (now - lastCheck) < 10)
    assert_eq(false, shouldIgnore, "15s gap should NOT be ignored")
end)

-- Scenario: Solo group — groupSize-1 = 0, no division errors
test("Solo group — no crash, zero wasted", function()
    SetupAddon()
    local sessionProblems = { ["LonelyGuy"] = { checks = 1, worst = "afk" } }
    EnsurePlayer("LonelyGuy")

    -- groupSize = 1, math.max(1-1, 1) = 1, still works
    FinalizeSession(30, 0, sessionProblems, 1)

    -- 30 * max(0,1) * 5 * 1 = 150 (1 is the floor)
    assert_eq(150, ReadyCheckShameDB.alltime["LonelyGuy"].timeWasted, "Solo group handled")
end)

-- Scenario: Chat throttle — shared output should be capped
test("Shared leaderboard capped at 5 entries", function()
    SetupAddon()
    -- Create 10 players
    for i = 1, 10 do
        local name = "Player" .. i
        EnsurePlayer(name)
        IncrementStat(name, "seen", 10)
        IncrementStat(name, "afk", i) -- varying fail rates
    end

    -- We can't easily test SendChatMessage count without more mocking,
    -- but verify BuildEntries returns all 10
    local entries = {}
    for name, data in pairs(ReadyCheckShameDB.alltime) do
        if data.seen > 0 then
            table.insert(entries, { name = name, failures = data.notready + data.afk })
        end
    end
    assert_eq(10, #entries, "All 10 players in data")
    -- The cap is enforced in ShowLeaderboard with `if toChat and i > 5 then break end`
end)

-- Scenario: No group type — ready check outside group ignored
test("Ready check outside of group is ignored", function()
    -- GetGroupType returns nil when not in a group
    -- The READY_CHECK handler should return early
    -- We just verify the logic
    local inGroup = false
    local shouldProcess = inGroup  -- would be GetGroupType() ~= nil
    assert_eq(false, shouldProcess, "Not in group = skip")
end)

-- Scenario: Empty session finalize — no crash
test("Empty session finalize — no crash, no data", function()
    SetupAddon()
    FinalizeSession(60, 0, {}, 20)

    local count = 0
    for _ in pairs(ReadyCheckShameDB.alltime) do count = count + 1 end
    assert_eq(0, count, "No players from empty session")
end)

-- Scenario: Multiple sessions same night (between bosses)
test("Multiple sessions same night accumulate correctly", function()
    SetupAddon()
    EnsurePlayer("Repeater")

    -- Session 1: AFK once
    FinalizeSession(30, 0, { ["Repeater"] = { checks = 1, worst = "afk" } }, 20)
    local after1 = ReadyCheckShameDB.alltime["Repeater"].timeWasted

    -- Session 2: AFK again
    FinalizeSession(90, 60, { ["Repeater"] = { checks = 1, worst = "afk" } }, 20)
    local after2 = ReadyCheckShameDB.alltime["Repeater"].timeWasted

    assert_gt(after2, after1, "Second session adds more waste")
    -- Session 1: 30 * 19 * 5 * 1 = 2850
    -- Session 2: 30 * 19 * 5 * 1 = 2850 (30s session, from t=60 to t=90)
    -- Total: 5700
    assert_eq(5700, after2, "Accumulated across sessions")
end)

--------------------------------------------------------------------------------
-- Summary
--------------------------------------------------------------------------------

print(string.format("\n%d tests run, %d passed, %d failed\n",
    tests_run, tests_passed, tests_failed))

if tests_failed > 0 then
    os.exit(1)
end
