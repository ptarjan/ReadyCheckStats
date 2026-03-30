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

    -- Return the most common guild
    local best, bestCount = nil, 0
    for guild, count in pairs(guilds) do
        if count > bestCount then
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
    local hasData = false
    for _ in pairs(tonight.players) do hasData = true; break end
    if not hasData then return end

    local summary = SummarizeNight(tonight)
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
    -- Tonight
    if not ReadyCheckShameDB.tonight.players[name] then
        ReadyCheckShameDB.tonight.players[name] = EmptyStats()
    end
end

local function IncrementStat(name, field, amount)
    amount = amount or 1
    ReadyCheckShameDB.alltime[name][field] = ReadyCheckShameDB.alltime[name][field] + amount
    ReadyCheckShameDB.tonight.players[name][field] = ReadyCheckShameDB.tonight.players[name][field] + amount
end

local function RecordResponseTime(name, elapsed)
    EnsurePlayer(name)
    IncrementStat(name, "totalResponseTime", elapsed)
    IncrementStat(name, "responseCount", 1)
    -- timeWasted is now calculated at end of ready check, not here
end

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ccff[ReadyCheckStats]|r " .. msg)
end

-- Severity weights for time wasted
local SEVERITY = { slow = 1, notready = 2, afk = 5, chat = 3 }

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
            -- Use chat ready time if available, otherwise full session
            local readyAt = chatReadyMembers[name]
            local personTime
            if readyAt then
                -- They typed "r" readyAt seconds after check ended
                -- Total time from session start = lastCheckDuration + readyAt (approx)
                personTime = totalSessionTime  -- simplify: charge for full session
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

    elseif event == "ENCOUNTER_START" or event == "PLAYER_REGEN_LOST" then
        -- Pull happened (with or without a timer) — finalize session
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
        checkStartTime = now
        waitingForPull = false
        chatReadyMembers = {}

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

        -- arg1 = initiator name
        local initiator = SafeValue((...))

        -- Detect group label (retry if nil — guild info loads late)
        if not ReadyCheckShameDB.tonight.group then
            ReadyCheckShameDB.tonight.group = DetectGroupLabel()
        end

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

        local unit, isReady = ...
        unit = SafeValue(unit)
        isReady = SafeValue(isReady)
        if not unit then return end

        local name = UnitName(unit)
        name = SafeValue(name)
        if not name then return end

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
            elseif status == "ready" then
                -- They were still pending but now show "ready" —
                -- likely a last-second click we missed. Record it
                -- but don't add to slow list since we can't trust the timing.
                RecordResponseTime(name, checkDuration)
            else
                -- "waiting" = never responded
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
        -- Not ready clickers
        for name, unit in pairs(pendingMembers) do
            local status = GetReadyCheckStatus(unit)
            status = SafeValue(status)
            if status == "notready" then
                if not sessionProblems[name] then
                    sessionProblems[name] = { checks = 0, worst = "notready" }
                end
                sessionProblems[name].checks = sessionProblems[name].checks + 1
                if SEVERITY["notready"] > SEVERITY[sessionProblems[name].worst] then
                    sessionProblems[name].worst = "notready"
                end
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
                table.insert(slow, string.format("%s (%.1fs)", name, t))
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
                "100%% ready. This is the dream.",
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
            table.sort(slow, function(a, b) return a > b end) -- slowest first
            local top = {}
            for i = 1, math.min(3, #slow) do top[i] = slow[i] end
            Print("Slowest: " .. table.concat(top, ", "))
        end

        activeCheck = false
        readyCheckEndTime = GetTime()
        lastCheckDuration = checkDuration
        lastGroupSize = groupSize
        waitingForPull = true

        -- Remember who we're still waiting on (AFK/notready from this check)
        waitingOnPlayers = {}
        for name in pairs(afkNames) do
            waitingOnPlayers[name] = true
        end
        for name, unit in pairs(pendingMembers) do
            local status = GetReadyCheckStatus(unit)
            status = SafeValue(status)
            if status == "notready" then
                waitingOnPlayers[name] = true
            end
        end

        pendingMembers = {}

        -- Auto-refresh UI if open
        if RCSFrame and RCSFrame:IsShown() and RCSFrame.RefreshContent then
            RCSFrame:RefreshContent()
        end

    elseif event == "CHAT_MSG_RAID" or event == "CHAT_MSG_RAID_LEADER"
        or event == "CHAT_MSG_PARTY" or event == "CHAT_MSG_PARTY_LEADER"
        or event == "CHAT_MSG_SAY" then

        if not waitingForPull then return end

        local msg, sender = ...
        msg = SafeValue(msg)
        sender = SafeValue(sender)
        if not msg or not sender then return end

        local shortMsg = strtrim(msg):lower()
        if shortMsg == "r" or shortMsg == "rdy"
            or string.find(shortMsg, "ready")
            or string.find(shortMsg, "redy")
            or string.find(shortMsg, "i'm r")
            or string.find(shortMsg, "im r")
            or string.find(shortMsg, "now r")
            or string.find(shortMsg, "here")
            or string.find(shortMsg, "back") then
            local name = StripRealm(sender)
            if name and not chatReadyMembers[name] and waitingOnPlayers[name] then
                local elapsed = GetTime() - readyCheckEndTime
                chatReadyMembers[name] = elapsed
                -- Track as chat-ready in the session (3x severity)
                if not sessionProblems[name] then
                    sessionProblems[name] = { checks = 0, worst = "chat" }
                end
                sessionProblems[name].checks = sessionProblems[name].checks + 1
                if SEVERITY["chat"] > SEVERITY[sessionProblems[name].worst] then
                    sessionProblems[name].worst = "chat"
                end
                Print(string.format("%s said ready in chat (%.1fs after check ended)", name, elapsed))

                -- Remove from waiting list and check if everyone's ready
                waitingOnPlayers[name] = nil
                if next(waitingOnPlayers) == nil then
                    Print("Everyone's ready — pull!")
                    PlaySound(8959) -- raid warning sound
                end
            end
        end

        if string.find(shortMsg, "pull in") or string.find(shortMsg, "pull timer") then
            FinalizeSession(GetTime())
            waitingForPull = false
        end
    end
end)

-- DBM pull timer detection
if DBM and DBM.RegisterCallback then
    DBM:RegisterCallback("DBM_TimerStart", function(_, id, msg)
        if msg and string.find(msg:lower(), "pull") then
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
        if msg and (string.find(msg, "Pull") or string.find(msg, "pull")) then
            FinalizeSession(GetTime())
            waitingForPull = false
        end
    end
end)
C_ChatInfo.RegisterAddonMessagePrefix("BigWigs")
C_ChatInfo.RegisterAddonMessagePrefix("D4")

-- Stop tracking chat readies after 2 minutes, finalize session
C_Timer.NewTicker(10, function()
    if waitingForPull and (GetTime() - readyCheckEndTime > 120) then
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
            out(string.format("%s: %d seen, %d not ready, %d AFK, avg %s, %s wasted, %.0f%% fail",
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
            Print(string.format("  %s%s|r: %d seen, %d NR, %d AFK, avg %s, %s wasted, %.0f%% fail",
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
            out(string.format("%s: %d checks, %.0f%% perfect, %.1fs avg, %s wasted",
                label, h.checks, h.perfectRate, h.avgTime, wastedStr))
        else
            local color
            if h.perfectRate >= 90 then color = "|cff00ff00"
            elseif h.perfectRate >= 70 then color = "|cffffff00"
            else color = "|cffff0000" end
            Print(string.format("  %s%s: %d checks, %.0f%% perfect, %.1fs avg, %s wasted|r",
                color, label, h.checks, h.perfectRate, h.avgTime, wastedStr))
        end
    end

    -- Show improvement/decline
    if #all >= 2 then
        local prev = all[#all - 1]
        local curr = all[#all]
        local diff = curr.perfectRate - prev.perfectRate
        local timeDiff = curr.avgTime - prev.avgTime
        if diff > 0 then
            out(string.format("Trending up! +%.0f%% perfect rate vs last time", diff))
        elseif diff < 0 then
            out(string.format("Trending down... %.0f%% perfect rate vs last time", diff))
        end
        if timeDiff < -0.5 then
            out(string.format("Getting faster! %.1fs quicker on average", -timeDiff))
        elseif timeDiff > 0.5 then
            out(string.format("Getting slower... %.1fs slower on average", timeDiff))
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

SlashCmdList["READYCHECKSTATS"] = function(msg)
    msg = strtrim(msg):lower()
    if msg == "reset" then
        ResetData()
    elseif msg == "reset tonight" then
        ReadyCheckShameDB.tonight = { date = Today(), players = {} }
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
    elseif msg == "test" then
        RunTests()
    elseif msg == "help" then
        Print("Commands:")
        Print("  /rcs — tonight's leaderboard")
        Print("  /rcs all — all-time leaderboard")
        Print("  /rcs ui — open visual leaderboard window")
        Print("  /rcs mvp — tonight's MVPs (positive only)")
        Print("  /rcs trend — raid night trends over time")
        Print("  /rcs share [mvp|trend|all] — post to raid chat")
        Print("  /rcs reset [tonight] — clear data")
        Print("  /rcs test — run self-tests")
    else
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

    Print("--- Running Tests ---")

    -- Helper: fresh DB for each test
    local function freshDB()
        ReadyCheckShameDB = { alltime = {}, tonight = { date = Today(), players = {} }, history = {} }
    end

    -- Test 1: FinalizeSession with one AFK in 20-person raid
    freshDB()
    sessionProblems = { ["TestAFK"] = { checks = 1, worst = "afk" } }
    sessionActive = true
    sessionStart = GetTime() - 30
    sessionGroupSize = 20
    EnsurePlayer("TestAFK")
    FinalizeSession(GetTime())
    -- 30 * 19 * 5 * 1 = 2850
    assert_eq(2850, ReadyCheckShameDB.alltime["TestAFK"].timeWasted, "AFK 5x penalty")

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
    assert_eq(2850, ReadyCheckShameDB.alltime["AFK1"].timeWasted, "AFK1 full penalty")
    assert_eq(2850, ReadyCheckShameDB.alltime["AFK2"].timeWasted, "AFK2 full penalty")
    assert_eq(0, ReadyCheckShameDB.alltime["GoodGuy"].timeWasted, "GoodGuy no penalty")

    -- Test 3: Chat ready — 3x penalty
    freshDB()
    sessionProblems = { ["ChatGuy"] = { checks = 1, worst = "chat" } }
    sessionActive = true
    sessionStart = GetTime() - 45
    sessionGroupSize = 20
    EnsurePlayer("ChatGuy")
    FinalizeSession(GetTime())
    -- 45 * 19 * 3 * 1 = 2565
    assert_eq(2565, ReadyCheckShameDB.alltime["ChatGuy"].timeWasted, "Chat 3x penalty")

    -- Test 4: Slow — 1x penalty
    freshDB()
    sessionProblems = { ["SlowGuy"] = { checks = 1, worst = "slow" } }
    sessionActive = true
    sessionStart = GetTime() - 15
    sessionGroupSize = 20
    EnsurePlayer("SlowGuy")
    FinalizeSession(GetTime())
    -- 15 * 19 * 1 * 1 = 285
    assert_eq(285, ReadyCheckShameDB.alltime["SlowGuy"].timeWasted, "Slow 1x penalty")

    -- Test 5: NotReady — 2x penalty
    freshDB()
    sessionProblems = { ["Troll"] = { checks = 1, worst = "notready" } }
    sessionActive = true
    sessionStart = GetTime() - 30
    sessionGroupSize = 20
    EnsurePlayer("Troll")
    FinalizeSession(GetTime())
    -- 30 * 19 * 2 * 1 = 1140
    assert_eq(1140, ReadyCheckShameDB.alltime["Troll"].timeWasted, "NotReady 2x penalty")

    -- Test 6: Multi-check AFK — multiplied by checks
    freshDB()
    sessionProblems = { ["SuperAFK"] = { checks = 3, worst = "afk" } }
    sessionActive = true
    sessionStart = GetTime() - 120
    sessionGroupSize = 20
    EnsurePlayer("SuperAFK")
    FinalizeSession(GetTime())
    -- 120 * 19 * 5 * 3 = 34200
    assert_eq(34200, ReadyCheckShameDB.alltime["SuperAFK"].timeWasted, "Multi-check AFK")

    -- Test 7: Severity ordering
    assert_gt(SEVERITY["notready"], SEVERITY["slow"], "notready > slow")
    assert_gt(SEVERITY["chat"], SEVERITY["notready"], "chat > notready")
    assert_gt(SEVERITY["afk"], SEVERITY["chat"], "afk > chat")

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

    assert_eq(600, smallWaste, "5-person raid (30*4*5*1)")
    assert_eq(2850, bigWaste, "20-person raid (30*19*5*1)")
    assert_gt(bigWaste, smallWaste, "Bigger raid wastes more")

    -- Test 9: Solo group — no crash
    freshDB()
    sessionProblems = { ["Solo"] = { checks = 1, worst = "afk" } }
    sessionActive = true
    sessionStart = GetTime() - 30
    sessionGroupSize = 1
    EnsurePlayer("Solo")
    FinalizeSession(GetTime())
    assert_eq(150, ReadyCheckShameDB.alltime["Solo"].timeWasted, "Solo group (30*1*5*1)")

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

    -- Test 11: Mid-session joiner charged only for their checks
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
    assert_eq(34200, ReadyCheckShameDB.alltime["OG"].timeWasted, "OG 3 checks")
    assert_eq(11400, ReadyCheckShameDB.alltime["Late"].timeWasted, "Late 1 check")
    assert_gt(ReadyCheckShameDB.alltime["OG"].timeWasted, ReadyCheckShameDB.alltime["Late"].timeWasted, "More checks = more waste")

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

    assert_eq(2850, after1, "First session")
    assert_eq(5700, after2, "Accumulated across sessions")

    -- Restore real data
    ReadyCheckShameDB = savedDB
    sessionActive = savedSession
    sessionProblems = savedProblems
    sessionStart = savedStart
    sessionGroupSize = savedGroupSize

    Print(string.format("--- %d passed, %d failed ---", passed, failed))
end
