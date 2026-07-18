local _, ns = ...

--------------------------------------------------------------------------------
-- Pure accounting math, extracted so it can be unit-tested outside the game
-- (tests/ loads this file standalone with a stub ns). No WoW APIs here.
--
-- "Shares" are person-time: a player's delay multiplied by how many other
-- raiders were kept waiting, split fairly among everyone still waiting for
-- each interval.
--------------------------------------------------------------------------------

local Math = {}
ns.Math = Math

-- Fair split of waiting intervals. list = array of { name, time } sorted
-- ascending by time; baseline = where charging starts; gs = people waiting.
-- For each interval between consecutive times, everyone still outstanding
-- splits (interval * gs) equally. Returns { [name] = share }.
function Math.FairSplitShares(list, baseline, gs)
    local shares = {}
    local prevTime = baseline
    for i, entry in ipairs(list) do
        local interval = entry.time - prevTime
        local numStillWaiting = #list - i + 1
        local share = (interval / numStillWaiting) * gs
        for j = i, #list do
            shares[list[j].name] = (shares[list[j].name] or 0) + share
        end
        prevTime = entry.time
    end
    return shares
end

-- Median of an ascending-sorted array (upper median, matching the addon's
-- historical behavior).
function Math.Median(sortedTimes)
    if #sortedTimes == 0 then return 0 end
    return sortedTimes[math.ceil(#sortedTimes / 2)]
end

-- Per-check charging: players slower than the median (and slower than 5s)
-- split the delay beyond the median. responseTimes = { [name] = seconds },
-- groupSize = raid size including the player.
function Math.SlowShares(responseTimes, groupSize)
    local sortedTimes = {}
    for _, t in pairs(responseTimes) do
        table.insert(sortedTimes, t)
    end
    table.sort(sortedTimes)
    local medianTime = Math.Median(sortedTimes)

    local slowList = {}
    for name, t in pairs(responseTimes) do
        if t > medianTime and t > 5 then
            table.insert(slowList, { name = name, time = t })
        end
    end
    table.sort(slowList, function(a, b) return a.time < b.time end)

    local gs = math.max(groupSize - 1, 1)
    return Math.FairSplitShares(slowList, medianTime, gs), medianTime
end

-- Session-end charging for AFK/notready/chat-ready players. Chat-ready
-- players are charged only until they typed "r" (lastCheckDuration +
-- readyAt), never more than the full session.
-- problems = { [name] = weight }, chatReadyAt = { [name] = seconds after
-- check end }, gs = people waiting.
function Math.SessionShares(problems, chatReadyAt, lastCheckDuration, totalSessionTime, gs)
    local sessionList = {}
    for name, weight in pairs(problems) do
        local readyAt = chatReadyAt[name]
        local personTime
        if readyAt then
            personTime = math.min(totalSessionTime, lastCheckDuration + readyAt)
        else
            personTime = totalSessionTime
        end
        table.insert(sessionList, { name = name, time = personTime * weight })
    end
    table.sort(sessionList, function(a, b) return a.time < b.time end)
    return Math.FairSplitShares(sessionList, 0, gs)
end

-- Migration helper: how many recorded nights each player had with each
-- group. history = array of { group, playerNames }. Returns
-- { [name] = { total = n, [group] = n } }.
function Math.NightsPerGroup(history)
    local nights = {}
    for _, h in ipairs(history or {}) do
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
    return nights
end

-- Migration helper: fraction of a player's totals attributed to each group.
-- Proportional to recorded nights; even split across tag set as fallback.
function Math.GroupFractions(nightsForPlayer, groupTags)
    local shares = {}
    if nightsForPlayer and nightsForPlayer.total > 0 then
        for g, c in pairs(nightsForPlayer) do
            if g ~= "total" then
                shares[g] = c / nightsForPlayer.total
            end
        end
    elseif groupTags and next(groupTags) then
        local count = 0
        for _ in pairs(groupTags) do count = count + 1 end
        for g in pairs(groupTags) do
            shares[g] = 1 / count
        end
    end
    return shares
end

return Math
