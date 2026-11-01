-- Per-request metrics: kept for this nvim, appended to a JSONL log, shown by :AFStats
local M = {}

M.entries = {}
M.path = vim.fs.joinpath(vim.fn.stdpath("state"), "agentfill", "requests.jsonl")

local PARTS = { "excerpt", "header", "definition", "outline", "search" }

function M.record(entry)
    M.entries[#M.entries + 1] = entry
    vim.fn.mkdir(vim.fs.dirname(M.path), "p")
    local f = io.open(M.path, "a")
    if f then
        f:write(vim.json.encode(entry), "\n")
        f:close()
    end
end

local function load_all()
    local all = {}
    local f = io.open(M.path, "r")
    if not f then
        return all
    end
    for line in f:lines() do
        local ok, e = pcall(vim.json.decode, line)
        if ok and type(e) == "table" then
            all[#all + 1] = e
        end
    end
    f:close()
    return all
end

local function percentile(values, p)
    if #values == 0 then
        return nil
    end
    table.sort(values)
    return values[math.max(1, math.ceil(#values * p))]
end

local function summarize(entries)
    local s = { n = #entries, outcomes = {}, accepted = 0, shown = 0, lat = { gather = {}, turn = {}, total = {} } }
    s.tokens = { input = 0, cached = 0, output = 0, turns = 0 }
    s.cost, s.chars, s.prompted, s.parts, s.counts = 0, 0, 0, {}, {}
    for _, e in ipairs(entries) do
        s.outcomes[e.outcome] = (s.outcomes[e.outcome] or 0) + 1
        if e.outcome == "shown" then
            s.shown = s.shown + 1
            s.accepted = s.accepted + (e.accepted and 1 or 0)
        end
        for k, list in pairs(s.lat) do
            if e[k .. "_ms"] then
                list[#list + 1] = e[k .. "_ms"]
            end
        end
        local u = e.usage
        if u then
            s.tokens.turns = s.tokens.turns + 1
            s.tokens.input = s.tokens.input + (u.input or 0)
            s.tokens.cached = s.tokens.cached + (u.cached or 0)
            s.tokens.output = s.tokens.output + (u.output or 0)
            s.cost = s.cost + (u.cost or 0)
        end
        if e.prompt_chars then
            s.prompted = s.prompted + 1
            s.chars = s.chars + e.prompt_chars
            for _, part in ipairs(PARTS) do
                s.parts[part] = (s.parts[part] or 0) + ((e.parts or {})[part] or 0)
                s.counts[part] = (s.counts[part] or 0) + ((e.counts or {})[part] or 0)
            end
        end
    end
    return s
end

local function k(n)
    if not n then
        return "-"
    end
    return n >= 1000 and ("%.1fk"):format(n / 1000) or tostring(math.floor(n + 0.5))
end

local function pct(a, b)
    return b > 0 and ("%d%%"):format(math.floor(100 * a / b + 0.5)) or "-"
end

local function duration(v)
    if not v then
        return "-"
    end
    return v < 1000 and ("%dms"):format(v) or ("%.1fs"):format(v / 1000)
end

local function ms(list, p)
    return duration(percentile(vim.deepcopy(list), p))
end

local function rows(a, b)
    local function avg(total, n)
        return n > 0 and k(total / n) or "-"
    end
    local out = {
        { "requests", tostring(a.n), tostring(b.n) },
        { "shown", ("%d (%s)"):format(a.shown, pct(a.shown, a.n)), ("%d (%s)"):format(b.shown, pct(b.shown, b.n)) },
        {
            "accepted",
            ("%d (%s of shown)"):format(a.accepted, pct(a.accepted, a.shown)),
            ("%d (%s of shown)"):format(b.accepted, pct(b.accepted, b.shown)),
        },
    }
    for _, o in ipairs({ "no_suggestion", "discarded", "superseded", "error" }) do
        out[#out + 1] = { "  " .. o, tostring(a.outcomes[o] or 0), tostring(b.outcomes[o] or 0) }
    end
    for _, l in ipairs({ "gather", "turn", "total" }) do
        out[#out + 1] = {
            l .. " p50 / p90",
            ms(a.lat[l], 0.5) .. " / " .. ms(a.lat[l], 0.9),
            ms(b.lat[l], 0.5) .. " / " .. ms(b.lat[l], 0.9),
        }
    end
    out[#out + 1] = {
        "input tokens / turn",
        avg(a.tokens.input, a.tokens.turns),
        avg(b.tokens.input, b.tokens.turns),
    }
    out[#out + 1] = {
        "  cached / turn",
        avg(a.tokens.cached, a.tokens.turns),
        avg(b.tokens.cached, b.tokens.turns),
    }
    out[#out + 1] = {
        "output tokens / turn",
        avg(a.tokens.output, a.tokens.turns),
        avg(b.tokens.output, b.tokens.turns),
    }
    out[#out + 1] = { "tokens in total", k(a.tokens.input), k(b.tokens.input) }
    out[#out + 1] = { "cost (USD)", ("%.4f"):format(a.cost), ("%.4f"):format(b.cost) }
    out[#out + 1] = { "prompt chars / request", avg(a.chars, a.prompted), avg(b.chars, b.prompted) }
    for _, part in ipairs(PARTS) do
        out[#out + 1] = {
            ("  %s (chars, count)"):format(part),
            ("%s, %s"):format(avg(a.parts[part] or 0, a.prompted), avg(a.counts[part] or 0, a.prompted)),
            ("%s, %s"):format(avg(b.parts[part] or 0, b.prompted), avg(b.counts[part] or 0, b.prompted)),
        }
    end
    return out
end

local function table_lines(header, body)
    local all = { header }
    vim.list_extend(all, body)
    local widths = {}
    for _, r in ipairs(all) do
        for i, c in ipairs(r) do
            widths[i] = math.max(widths[i] or 0, vim.fn.strdisplaywidth(c))
        end
    end
    return vim.tbl_map(function(r)
        local cells = {}
        for i, c in ipairs(r) do
            cells[i] = c .. (" "):rep(widths[i] - vim.fn.strdisplaywidth(c))
        end
        return ("  " .. table.concat(cells, "   ")):gsub("%s+$", "")
    end, all)
end

-- live: { agent, model, turns, max_turns, context_used, context_size }
function M.open(live)
    local lines = {
        ("  agent %s%s   session turns %s/%d   context %s / %s"):format(
            live.agent,
            live.model and (" (" .. live.model .. ")") or "",
            live.turns or "-",
            live.max_turns,
            k(live.context_used),
            k(live.context_size)
        ),
        "",
    }
    vim.list_extend(
        lines,
        table_lines({ "", "this nvim", "all time" }, rows(summarize(M.entries), summarize(load_all())))
    )
    lines[#lines + 1] = ""
    lines[#lines + 1] = "  last requests"
    local recent = {}
    for i = #M.entries, math.max(1, #M.entries - 9), -1 do
        local e = M.entries[i]
        local u = e.usage or {}
        recent[#recent + 1] = {
            os.date("%H:%M:%S", e.time),
            vim.fn.fnamemodify(e.file or "", ":t"),
            e.outcome .. (e.outcome == "shown" and (e.accepted and " +acc" or " -acc") or ""),
            duration(e.total_ms),
            k(u.input),
            k(u.output),
            e.prompt_chars and k(e.prompt_chars) or "-",
        }
    end
    vim.list_extend(lines, table_lines({ "time", "file", "outcome", "total", "in", "out", "chars" }, recent))
    lines[#lines + 1] = ""
    lines[#lines + 1] = "  log: " .. vim.fn.fnamemodify(M.path, ":~")

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.bo[buf].bufhidden = "wipe"
    local width = 0
    for _, l in ipairs(lines) do
        width = math.max(width, vim.fn.strdisplaywidth(l))
    end
    width = math.min(width + 2, vim.o.columns - 4)
    local height = math.min(#lines, vim.o.lines - 4)
    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        width = width,
        height = height,
        row = math.floor((vim.o.lines - height) / 2),
        col = math.floor((vim.o.columns - width) / 2),
        style = "minimal",
        border = "rounded",
        title = " agentfill ",
    })
    for _, key in ipairs({ "q", "<Esc>" }) do
        vim.keymap.set("n", key, function()
            vim.api.nvim_win_close(win, true)
        end, { buffer = buf, nowait = true })
    end
end

return M
