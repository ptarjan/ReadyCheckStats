--------------------------------------------------------------------------------
-- ReadyCheckStatsUI.lua — Visual leaderboard window for ReadyCheckStats
-- Standalone file: only touches ReadyCheckShameDB (global) and Print() from core
--------------------------------------------------------------------------------

local addonName, ns = ...

-- Forward-declare the main frame
local RCSFrame

-- Saved position key inside ReadyCheckShameDB
local POS_KEY = "uiPosition"

--------------------------------------------------------------------------------
-- Utilities
--------------------------------------------------------------------------------

local function SafeValue(val)
    if issecretvalue and issecretvalue(val) then return nil end
    return val
end

local function Today()
    return date("%Y-%m-%d")
end

local function FormatTime(seconds)
    if not seconds or seconds <= 0 then return "-" end
    if seconds >= 3600 then
        return string.format("%.1fh", seconds / 3600)
    elseif seconds >= 60 then
        return string.format("%.1fm", seconds / 60)
    end
    return string.format("%.0fs", seconds)
end

local function FormatAvgTime(seconds)
    if not seconds or seconds <= 0 then return "-" end
    return string.format("%.1fs", seconds)
end

local function FailColor(rate)
    if rate <= 0 then
        return 0, 1, 0 -- green
    elseif rate < 25 then
        return 1, 1, 0 -- yellow
    elseif rate <= 50 then
        return 1, 0.53, 0 -- orange
    else
        return 1, 0, 0 -- red
    end
end

local function PerfectColor(rate)
    if rate >= 90 then
        return 0, 1, 0
    elseif rate >= 70 then
        return 1, 1, 0
    else
        return 1, 0, 0
    end
end

local GOLD   = { r = 1,    g = 0.84, b = 0 }
local SILVER = { r = 0.75, g = 0.75, b = 0.75 }
local BRONZE = { r = 0.80, g = 0.50, b = 0.20 }
local MEDAL_COLORS = { GOLD, SILVER, BRONZE }
local MEDAL_LABELS = { "#1", "#2", "#3" }

--------------------------------------------------------------------------------
-- Data helpers (mirror the core logic so we don't require exports)
--------------------------------------------------------------------------------

local function BuildEntries(playerTable, groupFilter)
    if not playerTable then return {} end
    local entries = {}
    for name, data in pairs(playerTable) do
        if data and data.seen and data.seen > 0 then
            -- Apply group filter if set
            if groupFilter and data.groups and not data.groups[groupFilter] then
                -- skip: player not in this group
            else
                local failures = (data.notready or 0) + (data.afk or 0)
                local avgTime = 0
                if data.responseCount and data.responseCount > 0 then
                    avgTime = data.totalResponseTime / data.responseCount
                end
                if failures > data.seen then failures = data.seen end
                local failPct = data.seen > 0 and (failures / data.seen * 100) or 0
                table.insert(entries, {
                    name     = name,
                    seen     = data.seen,
                    notready = data.notready or 0,
                    afk      = data.afk or 0,
                    failures = failures,
                    failPct  = failPct,
                    avgTime  = avgTime,
                    timeWasted = data.timeWasted or 0,
                })
            end
        end
    end
    table.sort(entries, function(a, b)
        if a.failures ~= b.failures then return a.failures > b.failures end
        return a.avgTime > b.avgTime
    end)
    return entries
end

local function GetAllGroups(playerTable)
    local groups = {}
    if not playerTable then return groups end
    for _, data in pairs(playerTable) do
        if data.groups then
            for g in pairs(data.groups) do
                groups[g] = true
            end
        end
    end
    local sorted = {}
    for g in pairs(groups) do
        table.insert(sorted, g)
    end
    table.sort(sorted)
    return sorted
end

local function SummarizeNight(nightData)
    if not nightData or not nightData.players then
        return { date = "?", checks = 0, fails = 0, avgTime = 0, perfectRate = 0, timeWasted = 0 }
    end
    local totalSeen, totalFails, totalTime, totalResponses, totalWasted, playerCount = 0, 0, 0, 0, 0, 0
    for _, data in pairs(nightData.players) do
        playerCount = playerCount + 1
        totalSeen     = totalSeen + (data.seen or 0)
        totalFails    = totalFails + (data.notready or 0) + (data.afk or 0)
        totalTime     = totalTime + (data.totalResponseTime or 0)
        totalResponses = totalResponses + (data.responseCount or 0)
        totalWasted   = totalWasted + (data.timeWasted or 0)
    end
    local numChecks = 0
    if playerCount > 0 then
        numChecks = math.floor(totalSeen / playerCount + 0.5)
    end
    return {
        date        = nightData.date or "?",
        group       = nightData.group,
        players     = playerCount,
        checks      = numChecks,
        fails       = totalFails,
        avgTime     = totalResponses > 0 and (totalTime / totalResponses) or 0,
        perfectRate = totalSeen > 0 and ((totalSeen - totalFails) / totalSeen * 100) or 0,
        timeWasted  = totalWasted,
    }
end

--------------------------------------------------------------------------------
-- Backdrop helper (WoW 12.0 BackdropTemplate)
--------------------------------------------------------------------------------

local BACKDROP_INFO = {
    bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile     = true,
    tileEdge = true,
    tileSize = 16,
    edgeSize = 16,
    insets   = { left = 4, right = 4, top = 4, bottom = 4 },
}

local function ApplyBackdrop(frame, bgR, bgG, bgB, bgA, borderR, borderG, borderB, borderA)
    if frame.SetBackdrop then
        frame:SetBackdrop(BACKDROP_INFO)
        frame:SetBackdropColor(bgR or 0.1, bgG or 0.1, bgB or 0.1, bgA or 0.9)
        frame:SetBackdropBorderColor(borderR or 0.4, borderG or 0.4, borderB or 0.4, borderA or 1)
    end
end

--------------------------------------------------------------------------------
-- Row pool — reuse FontStrings
--------------------------------------------------------------------------------

local ROW_HEIGHT = 18
local HEADER_HEIGHT = 22
local MVP_SECTION_HEIGHT = 80
local FRAME_WIDTH = 520
local FRAME_HEIGHT = 530
local SCROLL_WIDTH = FRAME_WIDTH - 30 -- inside scrollframe

--------------------------------------------------------------------------------
-- Build the main frame
--------------------------------------------------------------------------------

local function CreateMainFrame()
    local f = CreateFrame("Frame", "ReadyCheckStatsFrame", UIParent, "BackdropTemplate")
    f:SetSize(FRAME_WIDTH, FRAME_HEIGHT)
    f:SetPoint("CENTER")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        -- Save position
        local point, _, relPoint, x, y = self:GetPoint()
        if ReadyCheckShameDB then
            ReadyCheckShameDB[POS_KEY] = { point = point, relPoint = relPoint, x = x, y = y }
        end
    end)

    ApplyBackdrop(f, 0.08, 0.08, 0.08, 0.92, 0.3, 0.3, 0.3, 1)

    -- Close on ESC
    f:SetFrameStrata("DIALOG")
    table.insert(UISpecialFrames, "ReadyCheckStatsFrame")

    -- Title bar background
    local titleBar = CreateFrame("Frame", nil, f, "BackdropTemplate")
    titleBar:SetHeight(28)
    titleBar:SetPoint("TOPLEFT", f, "TOPLEFT", 4, -4)
    titleBar:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)
    ApplyBackdrop(titleBar, 0.15, 0.15, 0.15, 1, 0.3, 0.3, 0.3, 1)

    local titleText = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    titleText:SetPoint("LEFT", titleBar, "LEFT", 10, 0)
    titleText:SetText("ReadyCheckStats")
    titleText:SetTextColor(0, 0.8, 1)

    -- Close button
    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)
    closeBtn:SetScript("OnClick", function() f:Hide() end)

    -- Reset buttons — inside MVP section, bottom-right
    f.resetTonightBtn = true -- placeholder, created in CreateScrollArea after MVP

    -- Confirmation dialogs
    StaticPopupDialogs["READYCHECKSHAME_RESET"] = {
        text = "Reset tonight's ReadyCheckStats data?",
        button1 = "Yes",
        button2 = "No",
        OnAccept = function()
            ReadyCheckShameDB.tonight = { date = date("%Y-%m-%d"), players = {} }
            if RCSFrame and RCSFrame:IsShown() and RCSFrame.RefreshContent then
                RCSFrame:RefreshContent()
            end
            Print("Tonight's data has been reset.")
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
    }

    StaticPopupDialogs["READYCHECKSHAME_RESET_ALL"] = {
        text = "Reset ALL ReadyCheckStats data? This cannot be undone.",
        button1 = "Yes",
        button2 = "No",
        OnAccept = function()
            wipe(ReadyCheckShameDB)
            ReadyCheckShameDB.alltime = {}
            ReadyCheckShameDB.tonight = { date = date("%Y-%m-%d"), players = {} }
            ReadyCheckShameDB.history = {}
            if RCSFrame and RCSFrame:IsShown() and RCSFrame.RefreshContent then
                RCSFrame:RefreshContent()
            end
            Print("All data has been reset.")
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
    }

    f.titleBar = titleBar
    f.titleText = titleText
    return f
end

--------------------------------------------------------------------------------
-- Tab system
--------------------------------------------------------------------------------

local TAB_NAMES = { "Tonight", "All-Time", "Trends" }
local activeTab = 1
local alltimeGroupFilter = nil -- nil = all groups

local function CreateTabs(parent)
    local tabs = {}
    local tabWidth = (FRAME_WIDTH - 20) / #TAB_NAMES

    for i, name in ipairs(TAB_NAMES) do
        local tab = CreateFrame("Button", nil, parent, "BackdropTemplate")
        tab:SetSize(tabWidth - 4, 24)
        tab:SetPoint("TOPLEFT", parent, "TOPLEFT", 8 + (i - 1) * tabWidth, -36)

        ApplyBackdrop(tab, 0.2, 0.2, 0.2, 1, 0.4, 0.4, 0.4, 1)

        local text = tab:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        text:SetPoint("CENTER")
        text:SetText(name)
        tab.text = text
        tab.index = i

        tab:SetScript("OnClick", function()
            activeTab = i
            parent:UpdateTabs()
            parent:Refresh()
        end)

        tab:SetScript("OnEnter", function(self)
            if activeTab ~= self.index then
                ApplyBackdrop(self, 0.3, 0.3, 0.3, 1, 0.5, 0.5, 0.5, 1)
            end
        end)
        tab:SetScript("OnLeave", function(self)
            parent:UpdateTabs()
        end)

        tabs[i] = tab
    end

    parent.tabs = tabs

    function parent:UpdateTabs()
        for i, tab in ipairs(self.tabs) do
            if i == activeTab then
                ApplyBackdrop(tab, 0.1, 0.3, 0.5, 1, 0, 0.6, 1, 1)
                tab.text:SetTextColor(1, 1, 1)
            else
                ApplyBackdrop(tab, 0.2, 0.2, 0.2, 1, 0.4, 0.4, 0.4, 1)
                tab.text:SetTextColor(0.6, 0.6, 0.6)
            end
        end
    end
end

--------------------------------------------------------------------------------
-- Scroll content area
--------------------------------------------------------------------------------

local function CreateScrollArea(parent)
    -- Outer container for scrollframe + MVP
    local container = CreateFrame("Frame", nil, parent)
    container:SetPoint("TOPLEFT", parent, "TOPLEFT", 8, -66)
    container:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -8, 8)

    -- Scroll frame area (leaves room at bottom for MVP)
    local scrollFrame = CreateFrame("ScrollFrame", "RCSScrollFrame", container, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", container, "TOPLEFT", 0, 0)
    scrollFrame:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", -26, MVP_SECTION_HEIGHT + 4)

    local scrollChild = CreateFrame("Frame", nil, scrollFrame)
    scrollChild:SetWidth(SCROLL_WIDTH)
    scrollChild:SetHeight(1) -- will be resized
    scrollFrame:SetScrollChild(scrollChild)

    parent.scrollFrame = scrollFrame
    parent.scrollChild = scrollChild
    parent.container = container

    -- MVP section at the bottom
    local mvp = CreateFrame("Frame", nil, container, "BackdropTemplate")
    mvp:SetHeight(MVP_SECTION_HEIGHT)
    mvp:SetPoint("BOTTOMLEFT", container, "BOTTOMLEFT", 0, 0)
    mvp:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", 0, 0)
    ApplyBackdrop(mvp, 0.12, 0.12, 0.12, 0.95, 0.3, 0.3, 0.3, 1)

    local mvpTitle = mvp:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    mvpTitle:SetPoint("TOPLEFT", mvp, "TOPLEFT", 10, -8)
    mvpTitle:SetText("Fastest Fingers")
    mvpTitle:SetTextColor(1, 0.84, 0)

    parent.mvpFrame = mvp
    parent.mvpTitle = mvpTitle
    parent.mvpLines = {}

    for i = 1, 3 do
        local line = mvp:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        line:SetPoint("TOPLEFT", mvp, "TOPLEFT", 14, -8 - i * 18)
        line:SetJustifyH("LEFT")
        line:SetWidth(SCROLL_WIDTH - 28)
        parent.mvpLines[i] = line
    end

    -- Reset buttons inside MVP section
    local resetTonightBtn = CreateFrame("Button", nil, mvp, "UIPanelButtonTemplate")
    resetTonightBtn:SetSize(100, 18)
    resetTonightBtn:SetPoint("BOTTOMRIGHT", mvp, "BOTTOMRIGHT", -8, 6)
    resetTonightBtn:SetText("Reset Tonight")
    resetTonightBtn:SetScript("OnClick", function()
        StaticPopup_Show("READYCHECKSHAME_RESET")
    end)

    local resetAllBtn = CreateFrame("Button", nil, mvp, "UIPanelButtonTemplate")
    resetAllBtn:SetSize(70, 18)
    resetAllBtn:SetPoint("RIGHT", resetTonightBtn, "LEFT", -4, 0)
    resetAllBtn:SetText("Reset All")
    resetAllBtn:SetScript("OnClick", function()
        StaticPopup_Show("READYCHECKSHAME_RESET_ALL")
    end)
end

--------------------------------------------------------------------------------
-- Clear and populate content
--------------------------------------------------------------------------------

local function ClearScrollContent(parent)
    for _, child in ipairs({ parent.scrollChild:GetRegions() }) do
        child:Hide()
        child:SetParent(nil)
    end
    -- Also clear child frames
    for _, child in ipairs({ parent.scrollChild:GetChildren() }) do
        child:Hide()
        child:SetParent(nil)
    end
end

-- Sort state
local currentSortKey = "failPct"
local currentSortAsc = false -- descending by default

local function SortEntries(entries, key, ascending)
    table.sort(entries, function(a, b)
        local va, vb = a[key], b[key]
        if va == vb then return a.name < b.name end
        if ascending then
            return va < vb
        else
            return va > vb
        end
    end)
end

local function MakeHeaderRow(scrollChild, y, columns, refreshFn)
    local row = CreateFrame("Frame", nil, scrollChild)
    row:SetSize(SCROLL_WIDTH, HEADER_HEIGHT)
    row:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 0, -y)

    -- Subtle header background
    local bg = row:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.2, 0.2, 0.2, 0.5)

    for _, col in ipairs(columns) do
        if col.sortKey then
            -- Clickable header button
            local btn = CreateFrame("Button", nil, row)
            btn:SetPoint("LEFT", row, "LEFT", col.x, 0)
            btn:SetSize(col.width, HEADER_HEIGHT)

            local fs = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            fs:SetAllPoints()
            if col.justify then fs:SetJustifyH(col.justify) end

            local function UpdateLabel()
                local arrow = ""
                if currentSortKey == col.sortKey then
                    arrow = currentSortAsc and " ^" or " v"
                end
                fs:SetText(col.label .. arrow)
                if currentSortKey == col.sortKey then
                    fs:SetTextColor(1, 0.84, 0)
                else
                    fs:SetTextColor(0.7, 0.7, 0.7)
                end
            end

            btn:SetScript("OnClick", function()
                if currentSortKey == col.sortKey then
                    currentSortAsc = not currentSortAsc
                else
                    currentSortKey = col.sortKey
                    currentSortAsc = false
                end
                if refreshFn then refreshFn() end
            end)

            btn:SetScript("OnEnter", function()
                fs:SetTextColor(1, 1, 1)
            end)
            btn:SetScript("OnLeave", function()
                UpdateLabel()
            end)

            UpdateLabel()
        else
            local fs = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            fs:SetPoint("LEFT", row, "LEFT", col.x, 0)
            fs:SetText(col.label)
            fs:SetTextColor(0.7, 0.7, 0.7)
            if col.width then fs:SetWidth(col.width) end
            if col.justify then fs:SetJustifyH(col.justify) end
        end
    end

    return HEADER_HEIGHT
end

-- Player-list columns (Tonight / All-Time)
local PLAYER_COLS = {
    { label = "Name",       x = 8,   width = 120, justify = "LEFT",  sortKey = "name" },
    { label = "Seen",       x = 135, width = 35,  justify = "LEFT",  sortKey = "seen" },
    { label = "NR",         x = 180, width = 30,  justify = "LEFT",  sortKey = "notready" },
    { label = "AFK",        x = 220, width = 30,  justify = "LEFT",  sortKey = "afk" },
    { label = "Avg",        x = 260, width = 50,  justify = "LEFT",  sortKey = "avgTime" },
    { label = "Wasted",     x = 320, width = 70,  justify = "LEFT",  sortKey = "timeWasted" },
    { label = "Fail %",     x = 400, width = 55,  justify = "LEFT",  sortKey = "failPct" },
}

local function PopulatePlayerList(parent, entries, yOffset)
    local sc = parent.scrollChild
    local y = yOffset or 0

    -- Sort entries by current sort key
    SortEntries(entries, currentSortKey, currentSortAsc)

    local function refreshFn()
        if parent.Refresh then parent:Refresh(parent) end
    end
    y = y + MakeHeaderRow(sc, y, PLAYER_COLS, refreshFn)

    if #entries == 0 then
        local empty = sc:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        empty:SetPoint("TOPLEFT", sc, "TOPLEFT", 6, -(y + 20))
        empty:SetText("No ready check data yet.")
        empty:SetTextColor(0.5, 0.5, 0.5)
        y = y + 40
        sc:SetHeight(y)
        return entries
    end

    for _, e in ipairs(entries) do
        local row = CreateFrame("Frame", nil, sc)
        row:SetSize(SCROLL_WIDTH, ROW_HEIGHT)
        row:SetPoint("TOPLEFT", sc, "TOPLEFT", 0, -y)

        -- Alternating row background
        if _ % 2 == 0 then
            local bg = row:CreateTexture(nil, "BACKGROUND")
            bg:SetAllPoints()
            bg:SetColorTexture(0.15, 0.15, 0.15, 0.4)
        end

        local rate = e.seen > 0 and (e.failures / e.seen * 100) or 0
        local cr, cg, cb = FailColor(rate)

        -- Build values matching PLAYER_COLS order
        local values = {
            { text = e.name,                         r = cr,  g = cg,  b = cb },
            { text = tostring(e.seen),               r = 0.8, g = 0.8, b = 0.8 },
            { text = tostring(e.notready),           r = e.notready > 0 and 1 or 0.5, g = e.notready > 0 and 0.5 or 0.5, b = 0.5 },
            { text = tostring(e.afk),                r = e.afk > 0 and 1 or 0.5, g = e.afk > 0 and 0.3 or 0.5, b = e.afk > 0 and 0.3 or 0.5 },
            { text = FormatAvgTime(e.avgTime),        r = 0.8, g = 0.8, b = 0.8 },
            { text = FormatTime(e.timeWasted),        r = 0.8, g = 0.6, b = 0.4 },
            { text = string.format("%.0f%%", rate),   r = cr,  g = cg,  b = cb },
        }

        for ci, col in ipairs(PLAYER_COLS) do
            local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            fs:SetPoint("LEFT", row, "LEFT", col.x, 0)
            fs:SetWidth(col.width)
            fs:SetJustifyH(col.justify)
            fs:SetText(values[ci].text)
            fs:SetTextColor(values[ci].r, values[ci].g, values[ci].b)
        end

        y = y + ROW_HEIGHT
    end

    sc:SetHeight(math.max(y, 1))
    return entries
end

-- Trends columns
local TREND_COLS = {
    { label = "Date",      x = 6,   width = 80,  justify = "LEFT"  },
    { label = "Group",     x = 92,  width = 90,  justify = "LEFT"  },
    { label = "Checks",    x = 194, width = 45,  justify = "RIGHT" },
    { label = "Perfect %", x = 250, width = 55,  justify = "RIGHT" },
    { label = "Avg",       x = 312, width = 45,  justify = "RIGHT" },
    { label = "Wasted",    x = 364, width = 70,  justify = "RIGHT" },
}

local function PopulateTrends(parent)
    local sc = parent.scrollChild
    local y = 0

    y = y + MakeHeaderRow(sc, y, TREND_COLS)

    local db = ReadyCheckShameDB
    if not db then
        sc:SetHeight(y + 40)
        return
    end

    local history = db.history or {}
    local all = {}
    for _, h in ipairs(history) do
        table.insert(all, h)
    end

    -- Include tonight as the latest entry
    if db.tonight then
        local tonightSummary = SummarizeNight(db.tonight)
        if tonightSummary.checks > 0 then
            table.insert(all, tonightSummary)
        end
    end

    if #all == 0 then
        local empty = sc:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        empty:SetPoint("TOPLEFT", sc, "TOPLEFT", 6, -(y + 20))
        empty:SetText("No raid night history yet.")
        empty:SetTextColor(0.5, 0.5, 0.5)
        sc:SetHeight(y + 40)
        return
    end

    for idx, h in ipairs(all) do
        local row = CreateFrame("Frame", nil, sc)
        row:SetSize(SCROLL_WIDTH, ROW_HEIGHT)
        row:SetPoint("TOPLEFT", sc, "TOPLEFT", 0, -y)

        if idx % 2 == 0 then
            local bg = row:CreateTexture(nil, "BACKGROUND")
            bg:SetAllPoints()
            bg:SetColorTexture(0.15, 0.15, 0.15, 0.4)
        end

        local pr, pg, pb = PerfectColor(h.perfectRate or 0)

        -- Date
        local dateFs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        dateFs:SetPoint("LEFT", row, "LEFT", 6, 0)
        dateFs:SetWidth(80)
        dateFs:SetJustifyH("LEFT")
        dateFs:SetText(h.date or "?")
        dateFs:SetTextColor(pr, pg, pb)

        -- Group
        local groupFs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        groupFs:SetPoint("LEFT", row, "LEFT", 92, 0)
        groupFs:SetWidth(90)
        groupFs:SetJustifyH("LEFT")
        groupFs:SetText(h.group or "-")
        groupFs:SetTextColor(0.7, 0.7, 0.7)

        -- Checks
        local checksFs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        checksFs:SetPoint("RIGHT", row, "LEFT", 239, 0)
        checksFs:SetWidth(45)
        checksFs:SetJustifyH("RIGHT")
        checksFs:SetText(tostring(h.checks or 0))
        checksFs:SetTextColor(0.8, 0.8, 0.8)

        -- Perfect %
        local perfFs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        perfFs:SetPoint("RIGHT", row, "LEFT", 305, 0)
        perfFs:SetWidth(55)
        perfFs:SetJustifyH("RIGHT")
        perfFs:SetText(string.format("%.0f%%", h.perfectRate or 0))
        perfFs:SetTextColor(pr, pg, pb)

        -- Avg time
        local avgFs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        avgFs:SetPoint("RIGHT", row, "LEFT", 357, 0)
        avgFs:SetWidth(45)
        avgFs:SetJustifyH("LEFT")
        avgFs:SetText(FormatAvgTime(h.avgTime))
        avgFs:SetTextColor(0.8, 0.8, 0.8)

        -- Wasted
        local wastedFs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        wastedFs:SetPoint("RIGHT", row, "LEFT", 434, 0)
        wastedFs:SetWidth(70)
        wastedFs:SetJustifyH("RIGHT")
        wastedFs:SetText(FormatTime(h.timeWasted))
        wastedFs:SetTextColor(0.8, 0.6, 0.4)

        y = y + ROW_HEIGHT
    end

    -- Trend summary at the bottom
    if #all >= 2 then
        local prev = all[#all - 1]
        local curr = all[#all]
        local diff = (curr.perfectRate or 0) - (prev.perfectRate or 0)
        local wastedDiff = (curr.timeWasted or 0) - (prev.timeWasted or 0)

        y = y + 6
        if math.abs(diff) >= 0.5 or math.abs(wastedDiff) >= 60 then
            local trendFs = sc:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            trendFs:SetPoint("TOPLEFT", sc, "TOPLEFT", 6, -y)
            trendFs:SetWidth(SCROLL_WIDTH - 12)
            trendFs:SetJustifyH("LEFT")

            local parts = {}
            if diff >= 0.5 then
                table.insert(parts, string.format("|cff00ff00Trending up! +%.0f%% perfect rate|r", diff))
            elseif diff <= -0.5 then
                table.insert(parts, string.format("|cffff0000Trending down... %.0f%% perfect rate|r", diff))
            end
            local wastedDiff = (curr.timeWasted or 0) - (prev.timeWasted or 0)
            if wastedDiff < -60 then
                table.insert(parts, string.format("|cff00ff00Less time wasted! %.1fm saved|r", -wastedDiff / 60))
            elseif wastedDiff > 60 then
                table.insert(parts, string.format("|cffff0000More time wasted... %.1fm more|r", wastedDiff / 60))
            end
            trendFs:SetText(table.concat(parts, "  "))
            y = y + 18
        end
    end

    sc:SetHeight(math.max(y, 1))
end

local function UpdateMVP(parent, entries)
    -- Find fastest responders from the entries
    local fastest = {}
    if entries then
        for _, e in ipairs(entries) do
            if e.avgTime > 0 then
                table.insert(fastest, e)
            end
        end
        table.sort(fastest, function(a, b) return a.avgTime < b.avgTime end)
    end

    local top = math.min(3, #fastest)
    for i = 1, 3 do
        local line = parent.mvpLines[i]
        if i <= top then
            local c = MEDAL_COLORS[i]
            local e = fastest[i]
            line:SetText(string.format(
                "|cff%02x%02x%02x%s|r  %s  —  %s avg",
                math.floor(c.r * 255), math.floor(c.g * 255), math.floor(c.b * 255),
                MEDAL_LABELS[i], e.name, FormatAvgTime(e.avgTime)
            ))
            line:Show()
        else
            line:SetText("")
            line:Hide()
        end
    end

    if top == 0 then
        parent.mvpTitle:SetText("Fastest Fingers — no data yet")
    else
        parent.mvpTitle:SetText("Fastest Fingers")
    end
end

--------------------------------------------------------------------------------
-- Refresh logic
--------------------------------------------------------------------------------

local function Refresh(parent)
    ClearScrollContent(parent)

    local db = ReadyCheckShameDB
    if not db then return end

    local entries

    if activeTab == 1 then
        -- Tonight
        local players = db.tonight and db.tonight.players or {}
        entries = BuildEntries(players)
        PopulatePlayerList(parent, entries)

        -- Update subtitle
        local groupStr = ""
        if db.tonight and db.tonight.group then
            groupStr = " | " .. db.tonight.group
        end
        local dateStr = db.tonight and db.tonight.date or Today()
        parent.titleText:SetText("ReadyCheckStats — Tonight (" .. dateStr .. groupStr .. ")")

    elseif activeTab == 2 then
        -- All-Time with group filter
        local sc = parent.scrollChild
        local groups = GetAllGroups(db.alltime or {})
        if #groups > 0 then
            local y = 0
            local filterRow = CreateFrame("Frame", nil, sc)
            filterRow:SetSize(SCROLL_WIDTH, 22)
            filterRow:SetPoint("TOPLEFT", sc, "TOPLEFT", 0, -y)

            local lbl = filterRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            lbl:SetPoint("LEFT", filterRow, "LEFT", 8, 0)
            lbl:SetText("Group:")
            lbl:SetTextColor(0.7, 0.7, 0.7)

            local xOff = 50
            -- "All" button
            local allBtn = CreateFrame("Button", nil, filterRow, "BackdropTemplate")
            allBtn:SetSize(40, 18)
            allBtn:SetPoint("LEFT", filterRow, "LEFT", xOff, 0)
            if not alltimeGroupFilter then
                ApplyBackdrop(allBtn, 0.1, 0.3, 0.5, 1, 0, 0.6, 1, 1)
            else
                ApplyBackdrop(allBtn, 0.2, 0.2, 0.2, 1, 0.4, 0.4, 0.4, 1)
            end
            local allText = allBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            allText:SetPoint("CENTER")
            allText:SetText("All")
            allText:SetTextColor(alltimeGroupFilter and 0.6 or 1, alltimeGroupFilter and 0.6 or 1, alltimeGroupFilter and 0.6 or 1)
            allBtn:SetScript("OnClick", function()
                alltimeGroupFilter = nil
                parent:Refresh()
            end)
            xOff = xOff + 44

            for _, g in ipairs(groups) do
                local btn = CreateFrame("Button", nil, filterRow, "BackdropTemplate")
                local bw = math.max(40, g:len() * 7 + 10)
                btn:SetSize(bw, 18)
                btn:SetPoint("LEFT", filterRow, "LEFT", xOff, 0)
                local isActive = alltimeGroupFilter == g
                if isActive then
                    ApplyBackdrop(btn, 0.1, 0.3, 0.5, 1, 0, 0.6, 1, 1)
                else
                    ApplyBackdrop(btn, 0.2, 0.2, 0.2, 1, 0.4, 0.4, 0.4, 1)
                end
                local btnText = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                btnText:SetPoint("CENTER")
                btnText:SetText(g)
                btnText:SetTextColor(isActive and 1 or 0.6, isActive and 1 or 0.6, isActive and 1 or 0.6)
                btn:SetScript("OnClick", function()
                    alltimeGroupFilter = g
                    parent:Refresh()
                end)
                xOff = xOff + bw + 4
            end
        end

        entries = BuildEntries(db.alltime or {}, alltimeGroupFilter)
        PopulatePlayerList(parent, entries, #groups > 0 and 24 or 0)
        local titleSuffix = alltimeGroupFilter and (" — " .. alltimeGroupFilter) or ""
        parent.titleText:SetText("ReadyCheckStats — All-Time" .. titleSuffix)

    elseif activeTab == 3 then
        -- Trends
        entries = nil
        PopulateTrends(parent)
        parent.titleText:SetText("ReadyCheckStats — Trends")
    end

    -- MVP: show data from the active player tab, or tonight for trends
    if activeTab == 3 then
        -- For trends tab, show tonight's MVPs
        local players = db.tonight and db.tonight.players or {}
        local tonightEntries = BuildEntries(players)
        UpdateMVP(parent, tonightEntries)
    else
        UpdateMVP(parent, entries)
    end

    -- Reset scroll position
    parent.scrollFrame:SetVerticalScroll(0)
end

--------------------------------------------------------------------------------
-- Build everything
--------------------------------------------------------------------------------

local function InitUI()
    if RCSFrame then return RCSFrame end

    RCSFrame = CreateMainFrame()
    CreateTabs(RCSFrame)
    CreateScrollArea(RCSFrame)

    RCSFrame.Refresh = Refresh
    RCSFrame.RefreshContent = function(self) Refresh(self) end
    RCSFrame:UpdateTabs()

    -- Restore saved position
    if ReadyCheckShameDB and ReadyCheckShameDB[POS_KEY] then
        local pos = ReadyCheckShameDB[POS_KEY]
        RCSFrame:ClearAllPoints()
        RCSFrame:SetPoint(pos.point or "CENTER", UIParent, pos.relPoint or "CENTER", pos.x or 0, pos.y or 0)
    end

    RCSFrame:Hide()
    return RCSFrame
end

--------------------------------------------------------------------------------
-- Public toggle
--------------------------------------------------------------------------------

local function ToggleUI()
    local f = InitUI()
    if f:IsShown() then
        f:Hide()
    else
        f:Refresh(f)
        f:Show()
    end
end

-- Expose for slash command
ns.ToggleUI = ToggleUI

--------------------------------------------------------------------------------
-- Hook into slash command: /rcs ui
--------------------------------------------------------------------------------

local originalHandler = SlashCmdList["READYCHECKSTATS"]

SlashCmdList["READYCHECKSTATS"] = function(msg)
    local trimmed = strtrim(msg):lower()
    if trimmed == "" or trimmed == "ui" then
        ToggleUI()
        return
    end
    if originalHandler then
        originalHandler(msg)
    end
end

--------------------------------------------------------------------------------
-- LibDBIcon minimap button (optional — skipped gracefully if library absent)
--------------------------------------------------------------------------------

local function TryMinimapButton()
    local LDB = LibStub and LibStub("LibDataBroker-1.1", true)
    local LDBIcon = LibStub and LibStub("LibDBIcon-1.0", true)
    if not LDB or not LDBIcon then return end

    local dataObj = LDB:NewDataObject("ReadyCheckStats", {
        type  = "launcher",
        icon  = "Interface\\RaidFrame\\ReadyCheck-Ready",
        label = "ReadyCheckStats",
        OnClick = function(_, button)
            if button == "LeftButton" then
                ToggleUI()
            end
        end,
        OnTooltipShow = function(tt)
            tt:AddLine("ReadyCheckStats")
            tt:AddLine("|cffffffffClick|r to toggle leaderboard", 0.8, 0.8, 0.8)
        end,
    })

    -- Ensure minimap settings exist
    if not ReadyCheckShameDB.minimap then
        ReadyCheckShameDB.minimap = { hide = false }
    end

    LDBIcon:Register("ReadyCheckStats", dataObj, ReadyCheckShameDB.minimap)
end

--------------------------------------------------------------------------------
-- Init on ADDON_LOADED (after core has initialized)
--------------------------------------------------------------------------------

local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:SetScript("OnEvent", function(self, event, name)
    if name ~= addonName then return end
    self:UnregisterEvent("ADDON_LOADED")

    -- Delay slightly so core's ADDON_LOADED fires first
    C_Timer.After(0, function()
        TryMinimapButton()
    end)
end)
