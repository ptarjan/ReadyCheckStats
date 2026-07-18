-- Unit tests for ReadyCheckStats accounting math.
-- Run from the repo root:  lua tests/run.lua
local spec = dofile("tests/spec.lua")
local describe, it, eq, near, ok = spec.describe, spec.it, spec.eq, spec.near, spec.ok

local ns = {}
assert(loadfile("ReadyCheckStats_Math.lua"))("ReadyCheckStats", ns)
local M = ns.Math

describe("FairSplitShares", function()
    it("splits intervals among everyone still waiting", function()
        -- Two slow players (10s, 20s), baseline 5s, 19 people waiting.
        -- 5s..10s: both outstanding, 5s*19 split two ways = 47.5 each.
        -- 10s..20s: only the slowest, 10s*19 = 190.
        local shares = M.FairSplitShares(
            { { name = "A", time = 10 }, { name = "B", time = 20 } }, 5, 19)
        near(shares.A, 47.5, 0.01, "A")
        near(shares.B, 237.5, 0.01, "B")
    end)

    it("total equals total-delay-beyond-baseline times people waiting", function()
        local shares = M.FairSplitShares(
            { { name = "A", time = 10 }, { name = "B", time = 20 } }, 5, 19)
        near(shares.A + shares.B, (20 - 5) * 19, 0.01)
    end)

    it("returns empty for empty list", function()
        local shares = M.FairSplitShares({}, 0, 19)
        eq(next(shares), nil)
    end)
end)

describe("Median", function()
    it("takes the upper median for even counts", function()
        eq(M.Median({ 3, 4, 10, 20 }), 4)
    end)
    it("takes the middle for odd counts", function()
        eq(M.Median({ 1, 7, 9 }), 7)
    end)
    it("is 0 for empty", function()
        eq(M.Median({}), 0)
    end)
end)

describe("SlowShares", function()
    it("charges only above-median responders slower than 5s", function()
        local shares, median = M.SlowShares(
            { Fast1 = 3, Fast2 = 4, Slow = 10, Slower = 20 }, 20)
        eq(median, 4, "median")
        eq(shares.Fast1, nil, "fast player uncharged")
        near(shares.Slow, (10 - 4) / 2 * 19, 0.01, "Slow")
        near(shares.Slower, (10 - 4) / 2 * 19 + (20 - 10) * 19, 0.01, "Slower")
    end)

    it("never charges anyone at 5s or under", function()
        local shares = M.SlowShares({ A = 2, B = 3, C = 4, D = 5 }, 20)
        eq(next(shares), nil)
    end)

    it("charges nothing when everyone is equally slow (all at median)", function()
        local shares = M.SlowShares({ A = 30, B = 30, C = 30 }, 20)
        eq(next(shares), nil)
    end)
end)

describe("SessionShares", function()
    it("caps chat-ready players at check duration plus their r-time", function()
        -- The 3.4h-class bug: AFK-until-pull used to be charged to everyone.
        -- Session ran 240s (leader dawdled); Chatty typed r 10s after a 35s
        -- check; Afk never responded.
        local shares = M.SessionShares(
            { Chatty = 1, Afk = 1 }, { Chatty = 10 }, 35, 240, 19)
        -- Chatty outstanding 45s: 45*19 split 2 ways = 427.5.
        near(shares.Chatty, 427.5, 0.01, "Chatty")
        -- Afk carries the remaining 195s alone: 427.5 + 195*19.
        near(shares.Afk, 427.5 + 195 * 19, 0.01, "Afk")
    end)

    it("never charges beyond the session length", function()
        local shares = M.SessionShares(
            { Late = 1 }, { Late = 9999 }, 35, 240, 19)
        near(shares.Late, 240 * 19, 0.01)
    end)

    it("charges the full session to never-ready players", function()
        local shares = M.SessionShares({ Afk = 1 }, {}, 35, 120, 9)
        near(shares.Afk, 120 * 9, 0.01)
    end)
end)

describe("migration split", function()
    it("attributes proportionally to recorded nights", function()
        local nights = M.NightsPerGroup({
            { group = "Cowfee", playerNames = { "Bob" } },
            { group = "Cowfee", playerNames = { "Bob" } },
            { group = "Cowfee", playerNames = { "Bob" } },
            { group = "Game Theory", playerNames = { "Bob" } },
        })
        local shares = M.GroupFractions(nights.Bob, nil)
        near(shares["Cowfee"], 0.75, 0.001, "Cowfee")
        near(shares["Game Theory"], 0.25, 0.001, "Game Theory")
    end)

    it("splits evenly across tags when no history", function()
        local shares = M.GroupFractions(nil, { Cowfee = true, ["Game Theory"] = true })
        near(shares["Cowfee"], 0.5, 0.001)
        near(shares["Game Theory"], 0.5, 0.001)
    end)

    it("returns nothing with neither history nor tags", function()
        local shares = M.GroupFractions(nil, nil)
        eq(next(shares), nil)
    end)

    it("fractions always sum to 1 when any attribution exists", function()
        local nights = M.NightsPerGroup({
            { group = "A", playerNames = { "P" } },
            { group = "B", playerNames = { "P" } },
            { group = "B", playerNames = { "P" } },
        })
        local shares = M.GroupFractions(nights.P, nil)
        local sum = 0
        for _, f in pairs(shares) do sum = sum + f end
        near(sum, 1, 0.001)
    end)
end)

ok(true, "suite loaded")
os.exit(spec.finish())
