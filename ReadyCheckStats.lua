local addonName, ns = ...

-- Saved variable (initialized in ADDON_LOADED)
-- Structure: { tonight = { date = "2026-03-28", players = { [name] = stats } },
--              alltime = { [name] = stats } }
ReadyCheckShameDB = ReadyCheckShameDB or {}

-- Local state for the current ready check in progress
local activeCheck = false
local pendingMembers = {} -- [name] = unit
local checkStartTime = 0
local responseTimes = {}  -- [name] = seconds it took to respond

-- Session: tracks the window from first ready check to pull
local sessionStart = 0         -- GetTime() of the first ready check in this session
local sessionActive = false    -- are we in a ready check session?
local sessionProblems = {}     -- [name] = { checks = N, worst = "slow"|"notready"|"afk"|"chat" }
local sessionGroupSize = 0

-- State for "r"/"ready" chat tracking between ready check end and pull
local waitingForPull = false
local chatReadyMembers = {}
local readyCheckEndTime = 0
local groupSize = 0
local lastCheckDuration = 0
local lastGroupSize = 0
local waitingOnPlayers = {} -- people who were AFK/notready, cleared when they say "r"
local notReadyThisCheck = {} -- people who clicked "Not Ready" this check (removed from pendingMembers)
local preReadied = {} -- people who typed "r" while the check was still running

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function SafeValue(val)
    if issecretvalue and issecretvalue(val) then
        return nil
    end
    return val
end

local function GetGroupType()
    if IsInRaid() then
        return "raid"
    elseif IsInGroup() then
        return "party"
    end
    return nil
end

local function DetectGroupLabel()
    local guilds = {}
    local groupType = GetGroupType()
    if not groupType then return nil end

    if groupType == "raid" then
        for i = 1, GetNumGroupMembers() do
            local unit = "raid" .. i
            local guild = GetGuildInfo(unit)
            guild = SafeValue(guild)
            if guild then
                guilds[guild] = (guilds[guild] or 0) + 1
            end
        end
    else
        for i = 1, GetNumGroupMembers() - 1 do
            local unit = "party" .. i
            local guild = GetGuildInfo(unit)
            guild = SafeValue(guild)
            if guild then
                guilds[guild] = (guilds[guild] or 0) + 1
            end
        end
        local guild = GetGuildInfo("player")
        guild = SafeValue(guild)
        if guild then
            guilds[guild] = (guilds[guild] or 0) + 1
        end
    end

    -- Return the most common guild, raid leader's guild as tiebreaker
    local leaderGuild
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            local _, rank = GetRaidRosterInfo(i)
            if issecretvalue and issecretvalue(rank) then rank = nil end
            if rank and rank == 2 then
                local lg = GetGuildInfo("raid" .. i)
                lg = SafeValue(lg)
                leaderGuild = lg
                break
            end
        end
    end

    local best, bestCount = nil, 0
    for guild, count in pairs(guilds) do
        if count > bestCount or (count == bestCount and guild == leaderGuild) then
            best = guild
            bestCount = count
        end
    end
    return best
end

local function GetGroupMembers()
    local members = {}
    local groupType = GetGroupType()
    if not groupType then return members end

    if groupType == "raid" then
        for i = 1, GetNumGroupMembers() do
            local unit = "raid" .. i
            local name = UnitName(unit)
            name = SafeValue(name)
            if name then
                members[name] = unit
            end
        end
    else
        local playerName = UnitName("player")
        if playerName then
            members[playerName] = "player"
        end
        for i = 1, GetNumGroupMembers() - 1 do
            local unit = "party" .. i
            local name = UnitName(unit)
            name = SafeValue(name)
            if name then
                members[name] = unit
            end
        end
    end

    return members
end

local function Today()
    return date("%Y-%m-%d")
end

local function EmptyStats()
    return {
        seen = 0,
        notready = 0,
        afk = 0,
        totalResponseTime = 0,
        responseCount = 0,
        timeWasted = 0,
    }
end

-- forward declarations: defined later, called from InitDB/slash handler
local ArchiveTonight, RunTests

local function InitDB()
    if not ReadyCheckShameDB.alltime then
        -- Migrate old flat format to new structure
        local old = {}
        for k, v in pairs(ReadyCheckShameDB) do
            if type(v) == "table" and v.seen then
                old[k] = v
            end
        end
        wipe(ReadyCheckShameDB)
        ReadyCheckShameDB.alltime = old
        ReadyCheckShameDB.tonight = { date = Today(), players = {} }
    end
    if not ReadyCheckShameDB.history then
        ReadyCheckShameDB.history = {}
    end
    -- Start a new night if the date changed — archive the old one first
    if ReadyCheckShameDB.tonight.date ~= Today() then
        ArchiveTonight()
        ReadyCheckShameDB.tonight = { date = Today(), players = {} }
    end

    -- Remove bogus alltime entries (blank names, single-seen with huge wasted time)
    if ReadyCheckShameDB.alltime[""] then
        ReadyCheckShameDB.alltime[""] = nil
    end
    for name, d in pairs(ReadyCheckShameDB.alltime) do
        if d.seen and d.seen <= 1 and d.timeWasted and d.timeWasted > 10000 then
            ReadyCheckShameDB.alltime[name] = nil
        end
    end

    -- Clean up duplicate lowercase group keys (e.g. "cowfee" when "Cowfee" exists)
    for _, d in pairs(ReadyCheckShameDB.alltime) do
        if d.groups then
            local toRemove = {}
            for g in pairs(d.groups) do
                if g ~= g:sub(1,1):upper() .. g:sub(2) then
                    -- Lowercase first letter — check if proper-cased version exists
                    local proper = g:sub(1,1):upper() .. g:sub(2)
                    if d.groups[proper] then
                        tinsert(toRemove, g)
                    end
                end
            end
            for _, g in ipairs(toRemove) do
                d.groups[g] = nil
            end
        end
    end

    -- Backfill group tags from history and tonight
    for _, h in ipairs(ReadyCheckShameDB.history) do
        if h.group and h.playerNames then
            for _, name in ipairs(h.playerNames) do
                local d = ReadyCheckShameDB.alltime[name]
                if d then
                    if not d.groups then d.groups = {} end
                    d.groups[h.group] = true
                end
            end
        end
    end

    -- One-time split of pre-existing totals into per-group buckets.
    -- Exact per-group attribution isn't recoverable from old data, so
    -- distribute each player's numbers proportionally to how many recorded
    -- nights they had with each group (even split across tags as fallback).
    -- New stats accrue exactly per group from here on.
    if not ReadyCheckShameDB.byGroupSplitDone then
        ReadyCheckShameDB.byGroupSplitDone = true
        local FIELDS = { "seen", "notready", "afk", "totalResponseTime", "responseCount", "timeWasted" }
        local nights = {} -- name -> { total = n, [group] = n }
        for _, h in ipairs(ReadyCheckShameDB.history) do
            if h.group and h.playerNames then
                for _, name in ipairs(h.playerNames) do
                    local n = nights[name]
                    if not n then
                        n = { total = 0 }
                        nights[name] = n
                    end
                    n[h.group] = (n[h.group] or 0) + 1
                    n.total = n.total + 1
                end
            end
        end
        for name, d in pairs(ReadyCheckShameDB.alltime) do
            local shares = {} -- group -> fraction
            local n = nights[name]
            if n and n.total > 0 then
                for g, c in pairs(n) do
                    if g ~= "total" then
                        shares[g] = c / n.total
                    end
                end
            elseif d.groups and next(d.groups) then
                local count = 0
                for _ in pairs(d.groups) do count = count + 1 end
                for g in pairs(d.groups) do
                    shares[g] = 1 / count
                end
            end
            if next(shares) then
                d.byGroup = d.byGroup or {}
                for g, frac in pairs(shares) do
                    local b = d.byGroup[g] or {}
                    d.byGroup[g] = b
                    for _, f in ipairs(FIELDS) do
                        b[f] = (b[f] or 0) + (d[f] or 0) * frac
                    end
                end
            end
        end
    end
    local group = ReadyCheckShameDB.tonight.group
    if group then
        for name in pairs(ReadyCheckShameDB.tonight.players) do
            local d = ReadyCheckShameDB.alltime[name]
            if d then
                if not d.groups then d.groups = {} end
                d.groups[group] = true
            end
        end
    end
end

local function SummarizeNight(nightData)
    local totalSeen, totalFails, totalTime, totalResponses, totalWasted, playerCount = 0, 0, 0, 0, 0, 0
    for _, data in pairs(nightData.players) do
        playerCount = playerCount + 1
        totalSeen = totalSeen + data.seen
        totalFails = totalFails + data.notready + data.afk
        totalTime = totalTime + data.totalResponseTime
        totalResponses = totalResponses + data.responseCount
        totalWasted = totalWasted + data.timeWasted
    end
    local numChecks = 0
    if playerCount > 0 then
        numChecks = math.floor(totalSeen / playerCount + 0.5)
    end
    return {
        date = nightData.date,
        group = nightData.group,
        players = playerCount,
        checks = numChecks,
        fails = totalFails,
        avgTime = totalResponses > 0 and (totalTime / totalResponses) or 0,
        perfectRate = totalSeen > 0 and ((totalSeen - totalFails) / totalSeen * 100) or 0,
        timeWasted = totalWasted,
    }
end

function ArchiveTonight()
    local tonight = ReadyCheckShameDB.tonight
    -- Only archive if there was actual data
    if next(tonight.players) == nil then return end

    local summary = SummarizeNight(tonight)
    -- Store player names for group tagging backfill
    local names = {}
    for name in pairs(tonight.players) do
        table.insert(names, name)
    end
    summary.playerNames = names
    table.insert(ReadyCheckShameDB.history, summary)
    -- Keep last 50 nights max
    while #ReadyCheckShameDB.history > 50 do
        table.remove(ReadyCheckShameDB.history, 1)
    end
end

local function EnsurePlayer(name)
    -- Alltime
    if not ReadyCheckShameDB.alltime[name] then
        ReadyCheckShameDB.alltime[name] = EmptyStats()
    end
    local d = ReadyCheckShameDB.alltime[name]
    if not d.totalResponseTime then d.totalResponseTime = 0 end
    if not d.timeWasted then d.timeWasted = 0 end
    if not d.responseCount then d.responseCount = 0 end
    -- Tag player with current group and ensure its stat bucket
    local group = ReadyCheckShameDB.tonight.group
    if group then
        if not d.groups then d.groups = {} end
        d.groups[group] = true
        if not d.byGroup then d.byGroup = {} end
        if not d.byGroup[group] then d.byGroup[group] = EmptyStats() end
    end
    -- Tonight
    if not ReadyCheckShameDB.tonight.players[name] then
        ReadyCheckShameDB.tonight.players[name] = EmptyStats()
    end
end

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ccff[ReadyCheckStats]|r " .. msg)
end
ns.Print = Print

-- Every stat mutation is appended to a raw event log (always on, like the
-- CauldronTracker debug log). /rcs audit independently re-sums the log and
-- diffs it against the stored totals, so the displayed numbers are
-- verifiable rather than trusted.
local AUDIT_CAP = 3000

local function AuditLog(name, field, amount, group)
    local log = ReadyCheckShameDB.auditLog
    if not log then
        log = {}
        ReadyCheckShameDB.auditLog = log
    end
    log[#log + 1] = {
        d = ReadyCheckShameDB.tonight.date,
        n = name,
        f = field,
        a = math.floor(amount * 100 + 0.5) / 100,
        g = group,
    }
    if #log > AUDIT_CAP then
        -- trim in chunks; remember the date we trimmed into so the audit
        -- can warn instead of reporting false mismatches
        ReadyCheckShameDB.auditTrimmedDate = log[500] and log[500].d
        for _ = 1, 500 do
            table.remove(log, 1)
        end
    end
end

local function IncrementStat(name, field, amount)
    amount = amount or 1
    local d = ReadyCheckShameDB.alltime[name]
    d[field] = d[field] + amount
    ReadyCheckShameDB.tonight.players[name][field] = ReadyCheckShameDB.tonight.players[name][field] + amount
    -- Mirror into tonight's group bucket so per-group views show numbers
    -- earned WITH that group, not the player's all-group totals
    local group = ReadyCheckShameDB.tonight.group
    if group and d.byGroup and d.byGroup[group] then
        d.byGroup[group][field] = (d.byGroup[group][field] or 0) + amount
    end
    AuditLog(name, field, amount, group)
end

local AUDIT_FIELDS = { "seen", "notready", "afk", "totalResponseTime", "responseCount", "timeWasted" }

local function RunAudit()
    local log = ReadyCheckShameDB.auditLog or {}
    local today = ReadyCheckShameDB.tonight.date
    if ReadyCheckShameDB.auditTrimmedDate == today then
        Print("Audit log rotated mid-night (very long session) — audit would be incomplete, skipping.")
        return
    end
    local sums = {}
    local eventCount = 0
    for _, entry in ipairs(log) do
        if entry.d == today then
            eventCount = eventCount + 1
            local p = sums[entry.n]
            if not p then
                p = {}
                sums[entry.n] = p
            end
            p[entry.f] = (p[entry.f] or 0) + entry.a
        end
    end
    local players = ReadyCheckShameDB.tonight.players or {}
    local names = {}
    for n in pairs(players) do names[n] = true end
    for n in pairs(sums) do names[n] = true end
    local mismatches = 0
    for n in pairs(names) do
        local stored = players[n] or {}
        local summed = sums[n] or {}
        for _, f in ipairs(AUDIT_FIELDS) do
            local a, b = stored[f] or 0, summed[f] or 0
            if math.abs(a - b) > 0.5 then
                mismatches = mismatches + 1
                Print(string.format("MISMATCH %s.%s: stored %.1f vs %.1f recomputed from the event log", n, f, a, b))
            end
        end
    end
    if mismatches == 0 then
        Print(string.format("Audit OK — %d logged events independently reproduce tonight's numbers.", eventCount))
    else
        Print(string.format("Audit FAILED — %d mismatch(es) across %d logged events. The mismatched numbers cannot be trusted; please report.", mismatches, eventCount))
    end
end

local respondedThisCheck = {}

local function RecordResponseTime(name, elapsed)
    if respondedThisCheck[name] then return end
    respondedThisCheck[name] = true
    EnsurePlayer(name)
    IncrementStat(name, "totalResponseTime", elapsed)
    IncrementStat(name, "responseCount", 1)
end

-- Severity weights (all equal — no multipliers)
local SEVERITY = { slow = 1, notready = 1, afk = 1, chat = 1 }

local function FinalizeSession(pullTime)
    if not sessionActive then return end
    local totalSessionTime = pullTime - sessionStart
    local gs = math.max(sessionGroupSize - 1, 1)

    -- Fair split for session-level problems (AFK, notready, chat-ready)
    -- Slow responders already charged per-check with fair split
    local sessionList = {}
    for name, problem in pairs(sessionProblems) do
        if problem.worst ~= "slow" then
            EnsurePlayer(name)
            local weight = SEVERITY[problem.worst] or 1
            -- Charge chat-ready players only until they typed "r"; charging
            -- the full first-check-to-pull span billed the raid leader's
            -- dawdle time to players who were long since ready
            local readyAt = chatReadyMembers[name]
            local personTime
            if readyAt then
                -- readyAt is seconds after the check ended, so their real
                -- delay from session start is roughly check + readyAt
                personTime = math.min(totalSessionTime, lastCheckDuration + readyAt)
            else
                personTime = totalSessionTime
            end
            table.insert(sessionList, { name = name, time = personTime * weight, rawTime = personTime })
        end
    end

    -- Sort by weighted time and do fair split
    table.sort(sessionList, function(a, b) return a.time < b.time end)
    if #sessionList > 0 then
        local prevTime = 0
        for i, entry in ipairs(sessionList) do
            local interval = entry.time - prevTime
            local numStillWaiting = #sessionList - i + 1
            local share = (interval / numStillWaiting) * gs
            for j = i, #sessionList do
                EnsurePlayer(sessionList[j].name)
                IncrementStat(sessionList[j].name, "timeWasted", share)
            end
            prevTime = entry.time
        end
    end

    if next(sessionProblems) then
        local totalWaste = totalSessionTime * gs
        Print(string.format("Session: %.0fs from first ready check to pull (%d people-minutes wasted)",
            totalSessionTime, math.floor(totalWaste / 60 + 0.5)))
    end

    sessionActive = false
    sessionProblems = {}
end

local function StripRealm(name)
    if not name then return name end
    return strsplit("-", name, 2)
end

-- Mark anyone we're still waiting on as chat-ready right now (e.g. pull timer / combat start)
local function MarkWaitersReady()
    if readyCheckEndTime == 0 then return end
    local elapsed = GetTime() - readyCheckEndTime
    for name in pairs(waitingOnPlayers) do
        if not chatReadyMembers[name] then
            chatReadyMembers[name] = elapsed
            if not sessionProblems[name] then
                sessionProblems[name] = { checks = 0, worst = "chat" }
            end
            sessionProblems[name].checks = sessionProblems[name].checks + 1
            if SEVERITY["chat"] > SEVERITY[sessionProblems[name].worst] then
                sessionProblems[name].worst = "chat"
            end
        end
    end
    wipe(waitingOnPlayers)
end

--------------------------------------------------------------------------------
-- Event handling
--------------------------------------------------------------------------------

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("READY_CHECK")
frame:RegisterEvent("READY_CHECK_CONFIRM")
frame:RegisterEvent("READY_CHECK_FINISHED")
frame:RegisterEvent("ENCOUNTER_START")
pcall(frame.RegisterEvent, frame, "PLAYER_REGEN_LOST")
frame:RegisterEvent("CHAT_MSG_RAID")
frame:RegisterEvent("CHAT_MSG_RAID_LEADER")
frame:RegisterEvent("CHAT_MSG_PARTY")
frame:RegisterEvent("CHAT_MSG_PARTY_LEADER")
frame:RegisterEvent("CHAT_MSG_SAY")

frame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local name = ...
        if name == addonName then
            InitDB()
            Print("Loaded. Type /rcs for tonight, /rcs all for all-time.")
            self:UnregisterEvent("ADDON_LOADED")
        end

    elseif event == "PLAYER_REGEN_LOST" or event == "ENCOUNTER_START" then
        -- Any combat — everyone's implicitly ready, finalize session
        MarkWaitersReady()
        if sessionActive then
            FinalizeSession(GetTime())
        end
        waitingForPull = false

    elseif event == "READY_CHECK" then
        -- Debounce: ignore ready checks within 10 seconds of the last one
        local now = GetTime()
        if checkStartTime > 0 and (now - checkStartTime) < 10 then
            return
        end

        -- Ignore ready checks outside of a group (BG queue pops etc)
        if not GetGroupType() then return end

        activeCheck = true
        pendingMembers = {}
        responseTimes = {}
        respondedThisCheck = {}
        checkStartTime = now
        waitingForPull = false
        chatReadyMembers = {}
        notReadyThisCheck = {}
        preReadied = {}

        local members = GetGroupMembers()
        groupSize = 0
        for _ in pairs(members) do groupSize = groupSize + 1 end

        -- Start a new session if we're not already in one
        if not sessionActive then
            sessionStart = checkStartTime
            sessionActive = true
            sessionProblems = {}
            sessionGroupSize = groupSize
        end

        -- arg1 = initiator name (may be "Name-Realm" format)
        local initiator = SafeValue((...))
        initiator = StripRealm(initiator)

        -- Re-detect group label each ready check (guild info loads late)
        ReadyCheckShameDB.tonight.group = DetectGroupLabel() or ReadyCheckShameDB.tonight.group

        for name, unit in pairs(members) do
            EnsurePlayer(name)
            IncrementStat(name, "seen", 1)
            -- Don't track the initiator for ready/not-ready — WoW doesn't
            -- always fire READY_CHECK_CONFIRM for them, so they'd falsely
            -- show as AFK. They still get counted in "seen".
            if name ~= initiator then
                pendingMembers[name] = unit
            end
        end

    elseif event == "READY_CHECK_CONFIRM" then
        if not activeCheck then return end
        -- Auto-refresh UI if open
        if ns.RCSFrame and ns.RCSFrame:IsShown() and ns.RCSFrame.RefreshContent then
            C_Timer.After(0, function() ns.RCSFrame:RefreshContent() end)
        end

        local unit, isReady = ...
        unit = SafeValue(unit)
        isReady = SafeValue(isReady)
        if not unit then return end

        local name = UnitName(unit)
        name = SafeValue(name)
        if not name then return end
        if not pendingMembers[name] then return end

        -- A secret isReady is indistinguishable from a Not Ready click. Leave
        -- the player in pendingMembers and let READY_CHECK_FINISHED resolve
        -- them via GetReadyCheckStatus. (A real Not Ready click is false,
        -- which survives SafeValue; only secrets become nil.)
        if isReady == nil then return end

        local elapsed = GetTime() - checkStartTime

        if isReady then
            responseTimes[name] = elapsed
            RecordResponseTime(name, elapsed)
            pendingMembers[name] = nil
        else
            responseTimes[name] = elapsed
            RecordResponseTime(name, elapsed)
            EnsurePlayer(name)
            IncrementStat(name, "notready", 1)
            pendingMembers[name] = nil
            -- Remember them so we still wait for their "r" — they were removed
            -- from pendingMembers so the finish handler can't see them.
            notReadyThisCheck[name] = true
        end

    elseif event == "READY_CHECK_FINISHED" then
        if not activeCheck then return end

        local checkDuration = GetTime() - checkStartTime
        local afkNames = {}

        for name, unit in pairs(pendingMembers) do
            local status = GetReadyCheckStatus(unit)
            status = SafeValue(status)

            if status == "notready" then
                EnsurePlayer(name)
                IncrementStat(name, "notready", 1)
                -- We never saw their CONFIRM, but their live status says not
                -- ready — treat them like a Not Ready clicker so their "r"
                -- still counts toward the all-clear.
                notReadyThisCheck[name] = true
            elseif status == "ready" then
                -- They were still pending but now show "ready" —
                -- likely a last-second click we missed. Record it
                -- but don't add to slow list since we can't trust the timing.
                RecordResponseTime(name, checkDuration)
            else
                -- "waiting" = never responded — count as full check duration
                RecordResponseTime(name, checkDuration)
                EnsurePlayer(name)
                IncrementStat(name, "afk", 1)
                afkNames[name] = true
            end
        end

        -- Calculate fair time wasted for slow responders this check
        -- Sort all response times, find median, then split delay fairly
        local sortedTimes = {}
        for _, t in pairs(responseTimes) do
            table.insert(sortedTimes, t)
        end
        table.sort(sortedTimes)
        local medianTime = 0
        if #sortedTimes > 0 then
            local mid = math.ceil(#sortedTimes / 2)
            medianTime = sortedTimes[mid]
        end

        -- Get slow responders (above median) sorted by time
        local slowList = {}
        for name, t in pairs(responseTimes) do
            if t > medianTime and t > 5 then
                table.insert(slowList, { name = name, time = t })
            end
        end
        table.sort(slowList, function(a, b) return a.time < b.time end)

        -- Fair split: for each interval, divide among people still slow
        if #slowList > 0 then
            local gs = math.max(groupSize - 1, 1)
            local prevTime = medianTime
            for i, entry in ipairs(slowList) do
                -- From prevTime to entry.time, there are (#slowList - i + 1) people still slow
                -- Each gets (interval / numStillSlow) * raidSize
                local interval = entry.time - prevTime
                local numStillSlow = #slowList - i + 1
                local share = (interval / numStillSlow) * gs
                -- Charge this share to everyone from index i onward
                for j = i, #slowList do
                    EnsurePlayer(slowList[j].name)
                    IncrementStat(slowList[j].name, "timeWasted", share)
                end
                prevTime = entry.time
            end
        end

        -- Track session problems for AFK/notready (wasted calculated at pull time)
        for name, t in pairs(responseTimes) do
            if t > 5 and t > medianTime then
                if not sessionProblems[name] then
                    sessionProblems[name] = { checks = 0, worst = "slow" }
                end
                sessionProblems[name].checks = sessionProblems[name].checks + 1
            end
        end
        -- Not ready clickers (removed from pendingMembers at confirm time)
        for name in pairs(notReadyThisCheck) do
            if not sessionProblems[name] then
                sessionProblems[name] = { checks = 0, worst = "notready" }
            end
            sessionProblems[name].checks = sessionProblems[name].checks + 1
            if SEVERITY["notready"] > SEVERITY[sessionProblems[name].worst] then
                sessionProblems[name].worst = "notready"
            end
        end
        -- AFK
        for name in pairs(afkNames) do
            if not sessionProblems[name] then
                sessionProblems[name] = { checks = 0, worst = "afk" }
            end
            sessionProblems[name].checks = sessionProblems[name].checks + 1
            if SEVERITY["afk"] > SEVERITY[sessionProblems[name].worst] then
                sessionProblems[name].worst = "afk"
            end
        end

        -- Summarize
        local shamed = {}
        for name, unit in pairs(pendingMembers) do
            local status = GetReadyCheckStatus(unit)
            status = SafeValue(status)
            if status ~= "ready" then
                table.insert(shamed, name)
            end
        end

        local slow = {}
        for name, t in pairs(responseTimes) do
            if t > 5 then
                table.insert(slow, { name = name, time = t })
            end
        end

        local fastestName, fastestTime
        for name, t in pairs(responseTimes) do
            if not fastestTime or t < fastestTime then
                fastestName = name
                fastestTime = t
            end
        end

        if #shamed > 0 then
            local actualShamed = {}
            for _, name in ipairs(shamed) do
                EnsurePlayer(name)
                local total = ReadyCheckShameDB.tonight.players[name].notready + ReadyCheckShameDB.tonight.players[name].afk
                if total <= 1 or total % 3 == 0 then
                    table.insert(actualShamed, name)
                end
            end
            if #actualShamed > 0 then
                Print("Shame on: " .. table.concat(actualShamed, ", "))
            end
        elseif #slow == 0 then
            local cheers = {
                "Everyone ready! Let's go!",
                "Full ready check! You beautiful people!",
                "100% ready. This is the dream.",
                "All ready, no drama. Chef's kiss.",
                "Perfect ready check! Is this real life?",
                "Flawless. Every single one of you.",
            }
            Print(cheers[math.random(#cheers)])
            if fastestName then
                Print(string.format("Fastest: %s (%.1fs)", fastestName, fastestTime))
            end
        end
        if #slow > 0 and #shamed == 0 then
            table.sort(slow, function(a, b) return a.time > b.time end) -- slowest first
            local top = {}
            for i = 1, math.min(3, #slow) do
                top[i] = string.format("%s (%.1fs)", slow[i].name, slow[i].time)
            end
            Print("Slowest: " .. table.concat(top, ", "))
        end

        activeCheck = false
        readyCheckEndTime = GetTime()
        lastCheckDuration = checkDuration
        lastGroupSize = groupSize
        waitingForPull = true

        -- Remember who we're still waiting on (AFK/notready from this check).
        -- Anyone who already typed "r" while the check was running counts as
        -- chat-ready the moment it ends instead of being waited on again.
        waitingOnPlayers = {}
        local anyPreReadied = false
        local function addWaiter(name)
            if preReadied[name] then
                anyPreReadied = true
                chatReadyMembers[name] = 0
                if not sessionProblems[name] then
                    sessionProblems[name] = { checks = 0, worst = "chat" }
                end
                sessionProblems[name].checks = sessionProblems[name].checks + 1
            else
                waitingOnPlayers[name] = true
            end
        end
        for name in pairs(afkNames) do
            addWaiter(name)
        end
        -- Not-ready clickers were removed from pendingMembers at confirm time,
        -- so pull them from the set we tracked there.
        for name in pairs(notReadyThisCheck) do
            addWaiter(name)
        end
        -- If the only holdouts already said "r" mid-check, fire the all-clear now.
        if anyPreReadied and next(waitingOnPlayers) == nil then
            C_Timer.After(0, function()
                Print("|cff00ff00Everyone's ready — pull!|r")
                PlaySound(8959) -- raid warning sound
            end)
        end

        pendingMembers = {}

        -- Auto-refresh UI if open
        if ns.RCSFrame and ns.RCSFrame:IsShown() and ns.RCSFrame.RefreshContent then
            ns.RCSFrame:RefreshContent()
        end

    elseif event == "CHAT_MSG_RAID" or event == "CHAT_MSG_RAID_LEADER"
        or event == "CHAT_MSG_PARTY" or event == "CHAT_MSG_PARTY_LEADER"
        or event == "CHAT_MSG_SAY" then

        -- Chat matters while we're waiting for the pull AND while a check is
        -- still running (an early "r" counts once the check ends).
        if not waitingForPull and not activeCheck then return end

        local msg, sender = ...
        msg = SafeValue(msg)
        sender = SafeValue(sender)
        if not msg or not sender then return end

        local shortMsg = strtrim(msg):lower()
        local padded = " "..shortMsg.." "
        if string.find(padded, "%Wr%W")
            or string.find(padded, "%Wb%W")
            or string.find(padded, "%Wrdy%W")
            or string.find(padded, "%Wready%W")
            or string.find(padded, "%Wredy%W")
            or string.find(padded, "%Where%W")
            or string.find(padded, "%Wback%W") then
            local name = StripRealm(sender)
            if activeCheck and not waitingForPull then
                -- "r" during the check itself: remember it so the finish
                -- handler doesn't wait on them — they've already announced
                -- they're ready. (Only matters for people who clicked Not
                -- Ready or haven't responded; anyone else is harmless here.)
                if name and (pendingMembers[name] or notReadyThisCheck[name]) then
                    preReadied[name] = true
                end
            elseif name and not chatReadyMembers[name] and waitingOnPlayers[name] then
                local elapsed = GetTime() - readyCheckEndTime
                chatReadyMembers[name] = elapsed
                if not sessionProblems[name] then
                    sessionProblems[name] = { checks = 0, worst = "chat" }
                end
                sessionProblems[name].checks = sessionProblems[name].checks + 1
                if SEVERITY["chat"] > SEVERITY[sessionProblems[name].worst] then
                    sessionProblems[name].worst = "chat"
                end
                -- Remove from waiting list and check if everyone's ready
                waitingOnPlayers[name] = nil
                if ns.RCSFrame and ns.RCSFrame:IsShown() and ns.RCSFrame.RefreshContent then
                    ns.RCSFrame:RefreshContent()
                end
                if next(waitingOnPlayers) == nil then
                    C_Timer.After(0, function()
                        Print("|cff00ff00Everyone's ready — pull!|r")
                        PlaySound(8959) -- raid warning sound
                    end)
                end
            end
        end

        if waitingForPull then
            if string.find(shortMsg, "pull in") or string.find(shortMsg, "pull timer") then
                MarkWaitersReady()
                FinalizeSession(GetTime())
                waitingForPull = false
            end
            if string.find(shortMsg, "break") then
                FinalizeSession(GetTime())
                waitingForPull = false
            end
        end
    end
end)

-- DBM pull timer detection
if DBM and DBM.RegisterCallback then
    DBM:RegisterCallback("DBM_TimerStart", function(_, id, msg)
        local lower = msg:lower()
        if string.find(lower, "pull") then
            MarkWaitersReady()
            FinalizeSession(GetTime())
            waitingForPull = false
        elseif string.find(lower, "break") then
            FinalizeSession(GetTime())
            waitingForPull = false
        end
    end)
end

-- BigWigs pull bar detection
local bwFrame = CreateFrame("Frame")
bwFrame:RegisterEvent("CHAT_MSG_ADDON")
bwFrame:SetScript("OnEvent", function(self, event, prefix, msg)
    if prefix == "BigWigs" or prefix == "D4" then
        if msg then
            local lower = msg:lower()
            if string.find(lower, "pull") then
                MarkWaitersReady()
                FinalizeSession(GetTime())
                waitingForPull = false
            elseif string.find(lower, "break") then
                FinalizeSession(GetTime())
                waitingForPull = false
            end
        end
    end
end)
C_ChatInfo.RegisterAddonMessagePrefix("BigWigs")
C_ChatInfo.RegisterAddonMessagePrefix("D4")

-- Poll combat state: if we enter combat while waiting, treat it as a pull
C_Timer.NewTicker(1, function()
    if waitingForPull and InCombatLockdown() then
        MarkWaitersReady()
        if sessionActive then
            FinalizeSession(GetTime())
        end
        waitingForPull = false
    end
end)

-- Stop tracking chat readies after 5 minutes with no pull
C_Timer.NewTicker(10, function()
    if waitingForPull and not InCombatLockdown() and (GetTime() - readyCheckEndTime > 300) then
        Print("No pull detected after 5 minutes — ending session.")
        FinalizeSession(GetTime())
        waitingForPull = false
    end
end)

--------------------------------------------------------------------------------
-- Slash commands
--------------------------------------------------------------------------------

local function GetChatChannel()
    if IsInRaid() then
        return "RAID"
    elseif IsInGroup() then
        return "PARTY"
    end
    return nil
end

local chatQueue = {}
local chatQueueRunning = false

local function ProcessChatQueue()
    if #chatQueue == 0 then
        chatQueueRunning = false
        return
    end
    local item = table.remove(chatQueue, 1)
    SendChatMessage(item.msg, item.channel)
    C_Timer.After(0.5, ProcessChatQueue)
end

local function SendChat(msg)
    local channel = GetChatChannel()
    if channel then
        table.insert(chatQueue, { msg = msg, channel = channel })
        if not chatQueueRunning then
            chatQueueRunning = true
            ProcessChatQueue()
        end
    else
        Print(msg)
    end
end

local function BuildEntries(playerTable)
    local entries = {}
    for name, data in pairs(playerTable) do
        local failures = data.notready + data.afk
        if data.seen > 0 then
            local avgTime = 0
            if data.responseCount and data.responseCount > 0 then
                avgTime = data.totalResponseTime / data.responseCount
            end
            table.insert(entries, {
                name = name,
                seen = data.seen,
                notready = data.notready,
                afk = data.afk,
                failures = failures,
                avgTime = avgTime,
                timeWasted = data.timeWasted or 0,
            })
        end
    end

    table.sort(entries, function(a, b)
        if a.failures ~= b.failures then
            return a.failures > b.failures
        end
        return a.avgTime > b.avgTime
    end)

    return entries
end

local function ShowLeaderboard(toChat, which)
    local playerTable, label
    if which == "alltime" then
        playerTable = ReadyCheckShameDB.alltime
        label = "All-Time"
    else
        playerTable = ReadyCheckShameDB.tonight.players
        local groupStr = ReadyCheckShameDB.tonight.group and (" — " .. ReadyCheckShameDB.tonight.group) or ""
        label = "Tonight (" .. ReadyCheckShameDB.tonight.date .. groupStr .. ")"
    end

    local entries = BuildEntries(playerTable)

    if #entries == 0 then
        Print("No ready check data for " .. label .. ".")
        return
    end

    local out = toChat and SendChat or Print

    out("--- Ready Check Shame: " .. label .. " ---")
    local maxShow = toChat and 5 or #entries -- Cap at 5 for raid chat
    for i, e in ipairs(entries) do
        if toChat and i > maxShow then break end
        local rate = 0
        if e.seen > 0 then
            rate = (e.failures / e.seen) * 100
        end
        local avgStr = e.avgTime > 0 and string.format("%.1fs", e.avgTime) or "-"
        local wastedStr
        if e.timeWasted >= 60 then
            wastedStr = string.format("%.1fm", e.timeWasted / 60)
        else
            wastedStr = string.format("%.0fs", e.timeWasted)
        end
        if toChat then
            out(string.format("%s: %d seen, %d not ready, %d AFK, avg %s, %s raid-time, %.0f%% fail",
                e.name, e.seen, e.notready, e.afk, avgStr, wastedStr, rate))
        else
            local color
            if e.failures == 0 then
                color = "|cff00ff00"
            elseif rate > 50 then
                color = "|cffff0000"
            elseif rate > 25 then
                color = "|cffff8800"
            else
                color = "|cffffff00"
            end
            Print(string.format("  %s%s|r: %d seen, %d NR, %d AFK, avg %s, %s raid-time, %.0f%% fail",
                color, e.name, e.seen, e.notready, e.afk, avgStr, wastedStr, rate))
        end
    end

    -- Celebrate the fastest responders
    local fastest = {}
    for _, e in ipairs(entries) do
        if e.avgTime > 0 then
            table.insert(fastest, e)
        end
    end
    table.sort(fastest, function(a, b) return a.avgTime < b.avgTime end)
    local top = math.min(3, #fastest)
    if top > 0 then
        local medals = {"\124cffffd700#1\124r", "\124cffc0c0c0#2\124r", "\124cffcd7f32#3\124r"}
        local chatMedals = {"#1", "#2", "#3"}
        local lines = {}
        for i = 1, top do
            local m = toChat and chatMedals[i] or medals[i]
            table.insert(lines, string.format("%s %s (%.1fs avg)", m, fastest[i].name, fastest[i].avgTime))
        end
        out("Fastest: " .. table.concat(lines, ", "))
    end
end

local function ShowTrend(toChat)
    local history = ReadyCheckShameDB.history or {}
    -- Include tonight as the latest entry
    local tonightSummary = SummarizeNight(ReadyCheckShameDB.tonight)

    local all = {}
    for _, h in ipairs(history) do
        table.insert(all, h)
    end
    if tonightSummary.checks > 0 then
        table.insert(all, tonightSummary)
    end

    if #all == 0 then
        Print("No raid night history yet.")
        return
    end

    local out = toChat and SendChat or Print

    out("--- Ready Check Trends ---")
    for _, h in ipairs(all) do
        local wastedStr
        if h.timeWasted >= 60 then
            wastedStr = string.format("%.1fm", h.timeWasted / 60)
        else
            wastedStr = string.format("%.0fs", h.timeWasted)
        end
        local label = h.date
        if h.group then
            label = label .. " (" .. h.group .. ")"
        end
        if toChat then
            out(string.format("%s: %d checks, %.0f%% perfect, %.1fs avg, %s raid-time",
                label, h.checks, h.perfectRate, h.avgTime, wastedStr))
        else
            local color
            if h.perfectRate >= 90 then color = "|cff00ff00"
            elseif h.perfectRate >= 70 then color = "|cffffff00"
            else color = "|cffff0000" end
            Print(string.format("  %s%s: %d checks, %.0f%% perfect, %.1fs avg, %s raid-time|r",
                color, label, h.checks, h.perfectRate, h.avgTime, wastedStr))
        end
    end

    -- Show improvement/decline
    if #all >= 2 then
        local prev = all[#all - 1]
        local curr = all[#all]
        local diff = curr.perfectRate - prev.perfectRate
        if diff >= 0.5 then
            out(string.format("Trending up! +%.0f%% perfect rate vs last time", diff))
        elseif diff <= -0.5 then
            out(string.format("Trending down... %.0f%% perfect rate vs last time", diff))
        end
        local wastedDiff = curr.timeWasted - prev.timeWasted
        if wastedDiff < -60 then
            out(string.format("Less time wasted! %.1fm saved vs last time", -wastedDiff / 60))
        elseif wastedDiff > 60 then
            out(string.format("More time wasted... %.1fm more vs last time", wastedDiff / 60))
        end
    end
end

local function ShowMVP(toChat)
    local playerTable = ReadyCheckShameDB.tonight.players
    local entries = BuildEntries(playerTable)

    if #entries == 0 then
        Print("No data for tonight yet.")
        return
    end

    local out = toChat and SendChat or Print

    -- Fastest average response
    local fastest = {}
    for _, e in ipairs(entries) do
        if e.avgTime > 0 then
            table.insert(fastest, e)
        end
    end
    table.sort(fastest, function(a, b) return a.avgTime < b.avgTime end)

    -- Most reliable (highest seen with 0 failures)
    local reliable = {}
    for _, e in ipairs(entries) do
        if e.failures == 0 and e.seen >= 1 then
            table.insert(reliable, e)
        end
    end
    table.sort(reliable, function(a, b) return a.seen > b.seen end)

    out("--- Tonight's Ready Check MVPs ---")

    -- Fastest fingers top 3
    local top = math.min(3, #fastest)
    if top > 0 then
        local lines = {}
        local chatMedals = {"#1", "#2", "#3"}
        local colorMedals = {"\124cffffd700#1\124r", "\124cffc0c0c0#2\124r", "\124cffcd7f32#3\124r"}
        for i = 1, top do
            local m = toChat and chatMedals[i] or colorMedals[i]
            table.insert(lines, string.format("%s %s (%.1fs)", m, fastest[i].name, fastest[i].avgTime))
        end
        out("Fastest fingers: " .. table.concat(lines, ", "))
    end

    -- 100% reliable
    if #reliable > 0 then
        local names = {}
        for _, e in ipairs(reliable) do
            table.insert(names, e.name)
        end
        out("100% ready: " .. table.concat(names, ", "))
    end

    -- Overall stats
    local summary = SummarizeNight(ReadyCheckShameDB.tonight)
    if summary.checks > 0 then
        out(string.format("Tonight: %d checks, %.0f%% perfect, %.1fs avg response", summary.checks, summary.perfectRate, summary.avgTime))
    end
end

local function ResetData()
    wipe(ReadyCheckShameDB)
    InitDB()
    Print("All data has been reset.")
end

SLASH_READYCHECKSTATS1 = "/rcs"
SLASH_READYCHECKSTATS2 = "/readycheckstats"

SlashCmdList["READYCHECKSTATS"] = function(rawMsg)
    local msg = strtrim(rawMsg):lower()
    if msg == "reset" then
        ResetData()
    elseif msg == "reset tonight" then
        ReadyCheckShameDB.tonight = { date = Today(), players = {} }
        -- drop tonight's audit events too, or /rcs audit would compare
        -- them against the freshly zeroed totals and report mismatches
        if ReadyCheckShameDB.auditLog then
            local kept = {}
            for _, entry in ipairs(ReadyCheckShameDB.auditLog) do
                if entry.d ~= Today() then
                    kept[#kept + 1] = entry
                end
            end
            ReadyCheckShameDB.auditLog = kept
        end
        Print("Tonight's data has been reset.")
    elseif msg == "share" then
        ShowLeaderboard(true, "tonight")
    elseif msg == "share all" then
        ShowLeaderboard(true, "alltime")
    elseif msg == "all" then
        ShowLeaderboard(false, "alltime")
    elseif msg == "trend" then
        ShowTrend(false)
    elseif msg == "share trend" then
        ShowTrend(true)
    elseif msg == "mvp" then
        ShowMVP(false)
    elseif msg == "share mvp" then
        ShowMVP(true)
    elseif msg == "audit" then
        RunAudit()
    elseif msg == "test" then
        RunTests()
    elseif msg == "help" then
        Print("Commands:")
        Print("  /rcs — open leaderboard window")
        Print("  /rcs text — tonight's leaderboard (chat)")
        Print("  /rcs audit — verify tonight's numbers against the raw event log")
        Print("  /rcs all — all-time leaderboard")
        Print("  /rcs mvp — tonight's MVPs (positive only)")
        Print("  /rcs trend — raid night trends over time")
        Print("  /rcs share [mvp|trend|all] — post to raid chat")
        Print("  /rcs group <name> — set tonight's group name")
        Print("  /rcs reset [tonight] — clear data")
        Print("  /rcs test — run self-tests")
    elseif msg:sub(1, 6) == "group " then
        local groupName = strtrim(strtrim(rawMsg):sub(7))
        if groupName ~= "" then
            ReadyCheckShameDB.tonight.group = groupName
            Print("Group set to: " .. groupName)
        end
    elseif msg == "text" then
        ShowLeaderboard(false, "tonight")
    end
end

--------------------------------------------------------------------------------
-- In-game tests (/rcs test)
--------------------------------------------------------------------------------

function RunTests()
    local passed, failed = 0, 0

    local function assert_eq(expected, actual, msg)
        if expected == actual then
            passed = passed + 1
        else
            failed = failed + 1
            Print(string.format("  FAIL: %s — expected %s, got %s", msg, tostring(expected), tostring(actual)))
        end
    end

    local function assert_gt(a, b, msg)
        if a > b then
            passed = passed + 1
        else
            failed = failed + 1
            Print(string.format("  FAIL: %s — expected %s > %s", msg, tostring(a), tostring(b)))
        end
    end

    -- Save and restore real data
    local savedDB = ReadyCheckShameDB
    local savedSession = sessionActive
    local savedProblems = sessionProblems
    local savedStart = sessionStart
    local savedGroupSize = sessionGroupSize
    local savedActiveCheck = activeCheck
    local savedCheckStart = checkStartTime
    local savedCheckGroupSize = groupSize
    local savedPending = pendingMembers
    local savedResponseTimes = responseTimes
    local savedChatReady = chatReadyMembers
    local savedNotReady = notReadyThisCheck
    local savedPreReadied = preReadied
    local savedWaitingOn = waitingOnPlayers
    local savedWaitingForPull = waitingForPull
    local savedEndTime = readyCheckEndTime
    local savedLastDuration = lastCheckDuration
    local savedLastGroupSize = lastGroupSize

    Print("--- Running Tests ---")

    -- Helper: fresh DB for each test
    local function freshDB()
        ReadyCheckShameDB = { alltime = {}, tonight = { date = Today(), players = {} }, history = {} }
    end

    -- Test 1: FinalizeSession with one AFK in 20-person raid
    -- All weights are equal (no multipliers); a lone offender is charged the
    -- full session time × the number of people kept waiting.
    freshDB()
    sessionProblems = { ["TestAFK"] = { checks = 1, worst = "afk" } }
    sessionActive = true
    sessionStart = GetTime() - 30
    sessionGroupSize = 20
    EnsurePlayer("TestAFK")
    FinalizeSession(GetTime())
    -- 30s * 19 others = 570
    assert_eq(570, ReadyCheckShameDB.alltime["TestAFK"].timeWasted, "Lone AFK charged full session")

    -- Test 2: Two AFKs both get full penalty
    freshDB()
    sessionProblems = {
        ["AFK1"] = { checks = 1, worst = "afk" },
        ["AFK2"] = { checks = 1, worst = "afk" },
    }
    sessionActive = true
    sessionStart = GetTime() - 30
    sessionGroupSize = 20
    EnsurePlayer("AFK1")
    EnsurePlayer("AFK2")
    EnsurePlayer("GoodGuy")
    FinalizeSession(GetTime())
    -- Fair split: two equal offenders share the blame — (30/2)s * 19 = 285 each
    assert_eq(285, ReadyCheckShameDB.alltime["AFK1"].timeWasted, "AFK1 fair-split share")
    assert_eq(285, ReadyCheckShameDB.alltime["AFK2"].timeWasted, "AFK2 fair-split share")
    assert_eq(0, ReadyCheckShameDB.alltime["GoodGuy"].timeWasted, "GoodGuy no penalty")

    -- Test 3: Chat ready — charged full session, same weight as everything else
    freshDB()
    sessionProblems = { ["ChatGuy"] = { checks = 1, worst = "chat" } }
    sessionActive = true
    sessionStart = GetTime() - 45
    sessionGroupSize = 20
    EnsurePlayer("ChatGuy")
    FinalizeSession(GetTime())
    -- 45s * 19 = 855
    assert_eq(855, ReadyCheckShameDB.alltime["ChatGuy"].timeWasted, "Chat-ready charged full session")

    -- Test 4: Slow responders are charged per-check (in READY_CHECK_FINISHED),
    -- not at session finalize — FinalizeSession must skip them entirely.
    freshDB()
    sessionProblems = { ["SlowGuy"] = { checks = 1, worst = "slow" } }
    sessionActive = true
    sessionStart = GetTime() - 15
    sessionGroupSize = 20
    EnsurePlayer("SlowGuy")
    FinalizeSession(GetTime())
    assert_eq(0, ReadyCheckShameDB.alltime["SlowGuy"].timeWasted, "Slow skipped at finalize")

    -- Test 5: NotReady — charged full session, same weight as everything else
    freshDB()
    sessionProblems = { ["Troll"] = { checks = 1, worst = "notready" } }
    sessionActive = true
    sessionStart = GetTime() - 30
    sessionGroupSize = 20
    EnsurePlayer("Troll")
    FinalizeSession(GetTime())
    -- 30s * 19 = 570
    assert_eq(570, ReadyCheckShameDB.alltime["Troll"].timeWasted, "NotReady charged full session")

    -- Test 6: Failing multiple checks does NOT multiply the session charge
    freshDB()
    sessionProblems = { ["SuperAFK"] = { checks = 3, worst = "afk" } }
    sessionActive = true
    sessionStart = GetTime() - 120
    sessionGroupSize = 20
    EnsurePlayer("SuperAFK")
    FinalizeSession(GetTime())
    -- 120s * 19 = 2280 regardless of checks
    assert_eq(2280, ReadyCheckShameDB.alltime["SuperAFK"].timeWasted, "Checks don't multiply charge")

    -- Test 7: All severity weights are equal by design (no multipliers)
    assert_eq(1, SEVERITY["slow"], "slow weight is 1")
    assert_eq(1, SEVERITY["notready"], "notready weight is 1")
    assert_eq(1, SEVERITY["chat"], "chat weight is 1")
    assert_eq(1, SEVERITY["afk"], "afk weight is 1")

    -- Test 8: Bigger raid = more waste
    freshDB()
    sessionProblems = { ["Small"] = { checks = 1, worst = "afk" } }
    sessionActive = true
    sessionStart = GetTime() - 30
    sessionGroupSize = 5
    EnsurePlayer("Small")
    FinalizeSession(GetTime())
    local smallWaste = ReadyCheckShameDB.alltime["Small"].timeWasted

    freshDB()
    sessionProblems = { ["Big"] = { checks = 1, worst = "afk" } }
    sessionActive = true
    sessionStart = GetTime() - 30
    sessionGroupSize = 20
    EnsurePlayer("Big")
    FinalizeSession(GetTime())
    local bigWaste = ReadyCheckShameDB.alltime["Big"].timeWasted

    assert_eq(120, smallWaste, "5-person raid (30s * 4 others)")
    assert_eq(570, bigWaste, "20-person raid (30s * 19 others)")
    assert_gt(bigWaste, smallWaste, "Bigger raid wastes more")

    -- Test 9: Solo group — no crash
    freshDB()
    sessionProblems = { ["Solo"] = { checks = 1, worst = "afk" } }
    sessionActive = true
    sessionStart = GetTime() - 30
    sessionGroupSize = 1
    EnsurePlayer("Solo")
    FinalizeSession(GetTime())
    assert_eq(30, ReadyCheckShameDB.alltime["Solo"].timeWasted, "Solo group (30s * 1 floor)")

    -- Test 10: Empty session — no crash
    freshDB()
    sessionProblems = {}
    sessionActive = true
    sessionStart = GetTime() - 60
    sessionGroupSize = 20
    FinalizeSession(GetTime())
    local count = 0
    for _ in pairs(ReadyCheckShameDB.alltime) do count = count + 1 end
    assert_eq(0, count, "Empty session no data")

    -- Test 11: Check count doesn't change the split — two AFKs with different
    -- check counts still share the session evenly (no multipliers by design)
    freshDB()
    sessionProblems = {
        ["OG"] = { checks = 3, worst = "afk" },
        ["Late"] = { checks = 1, worst = "afk" },
    }
    sessionActive = true
    sessionStart = GetTime() - 120
    sessionGroupSize = 20
    EnsurePlayer("OG")
    EnsurePlayer("Late")
    FinalizeSession(GetTime())
    -- (120/2)s * 19 = 1140 each
    assert_eq(1140, ReadyCheckShameDB.alltime["OG"].timeWasted, "OG fair-split share")
    assert_eq(1140, ReadyCheckShameDB.alltime["Late"].timeWasted, "Late fair-split share")

    -- Test 12: Multiple sessions accumulate
    freshDB()
    sessionProblems = { ["Repeat"] = { checks = 1, worst = "afk" } }
    sessionActive = true
    sessionStart = GetTime() - 30
    sessionGroupSize = 20
    EnsurePlayer("Repeat")
    FinalizeSession(GetTime())
    local after1 = ReadyCheckShameDB.alltime["Repeat"].timeWasted

    sessionProblems = { ["Repeat"] = { checks = 1, worst = "afk" } }
    sessionActive = true
    sessionStart = GetTime() - 30
    sessionGroupSize = 20
    FinalizeSession(GetTime())
    local after2 = ReadyCheckShameDB.alltime["Repeat"].timeWasted

    assert_eq(570, after1, "First session (30s * 19)")
    assert_eq(1140, after2, "Accumulated across sessions")

    -- Test 13: Not Ready clicker must type "r" before the all-clear (1.2.4)
    freshDB()
    sessionProblems = {}
    sessionActive = true
    sessionStart = GetTime() - 5
    sessionGroupSize = 5
    activeCheck = true
    checkStartTime = GetTime() - 10
    groupSize = 5
    pendingMembers = {}
    responseTimes = {}
    chatReadyMembers = {}
    notReadyThisCheck = { ["NotReadyBob"] = true }
    preReadied = {}
    local handler = frame:GetScript("OnEvent")
    handler(frame, "READY_CHECK_FINISHED")
    assert_eq(true, waitingOnPlayers["NotReadyBob"], "NotReady clicker still waited on after check")
    assert_eq("notready", sessionProblems["NotReadyBob"] and sessionProblems["NotReadyBob"].worst, "NotReady session problem recorded")
    -- Their "r" (with realm suffix) clears them and triggers the all-clear
    handler(frame, "CHAT_MSG_RAID", "r", "NotReadyBob-SomeRealm")
    assert_eq(nil, waitingOnPlayers["NotReadyBob"], "Chat 'r' clears NotReady clicker")

    -- Test 14: typing "r" while the check is still running counts (1.2.5)
    freshDB()
    sessionProblems = {}
    sessionActive = true
    sessionStart = GetTime() - 5
    sessionGroupSize = 5
    activeCheck = true
    waitingForPull = false
    checkStartTime = GetTime() - 10
    groupSize = 5
    pendingMembers = {}
    responseTimes = {}
    chatReadyMembers = {}
    notReadyThisCheck = { ["EagerEddie"] = true }
    preReadied = {}
    handler(frame, "CHAT_MSG_RAID", "r", "EagerEddie-SomeRealm")
    assert_eq(true, preReadied["EagerEddie"], "Mid-check 'r' recorded")
    handler(frame, "READY_CHECK_FINISHED")
    assert_eq(nil, waitingOnPlayers["EagerEddie"], "Pre-readied player not waited on")
    assert_eq(0, chatReadyMembers["EagerEddie"], "Pre-readied counted as chat-ready at 0s")

    -- Restore real data
    ReadyCheckShameDB = savedDB
    sessionActive = savedSession
    sessionProblems = savedProblems
    sessionStart = savedStart
    sessionGroupSize = savedGroupSize
    activeCheck = savedActiveCheck
    checkStartTime = savedCheckStart
    groupSize = savedCheckGroupSize
    pendingMembers = savedPending
    responseTimes = savedResponseTimes
    chatReadyMembers = savedChatReady
    notReadyThisCheck = savedNotReady
    preReadied = savedPreReadied
    waitingOnPlayers = savedWaitingOn
    waitingForPull = savedWaitingForPull
    readyCheckEndTime = savedEndTime
    lastCheckDuration = savedLastDuration
    lastGroupSize = savedLastGroupSize

    Print(string.format("--- %d passed, %d failed ---", passed, failed))
end
