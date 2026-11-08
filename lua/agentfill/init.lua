local api = vim.api
local config = require("agentfill.config")
local context = require("agentfill.context")
local item = require("agentfill.item")
local stats = require("agentfill.stats")

local M = {}

-- vim.g.agentfill is merged by the first setup(), so a bad value cannot break require()
---@type agentfill.Config
M.config = vim.deepcopy(config.defaults)

local INSTRUCTIONS =
    [[You are a code completion and editing engine inside an editor. The user message ends with an excerpt of a file in which the editable part sits between a <REGION> line and a </REGION> line. The region contains <CURSOR>, where the user is typing: write the code that belongs at <CURSOR> (continue the statement, finish the block, implement what a nearby comment describes) and adjust later lines of the region when they must change to stay consistent. Everything outside the region is read-only and stays in the file: code after </REGION> directly follows your rewrite, so never repeat it; <context> and <outline> blocks show related code from this and other files. Match the indentation and style of the surrounding code and keep lines that need no change exactly as they are, blank lines included. Never call tools or functions, and never explain, ask, or refuse. Reply with exactly <region>, a newline, the full rewritten region without <CURSOR>, a newline, </region>, and nothing else. Return the region unchanged when nothing needs doing.]]

local session, inflight, pending
local client_id
-- :AFToggle; off: no triggers, no suggestions served
local enabled = true
-- last finished suggestion; served while buffer and cursor are unchanged
local ready
-- suggestion on screen, waiting to learn whether it gets accepted
local shown

local function progress(req, message)
    if req.handle then
        req.handle:report({ message = message })
        return
    end
    local ok, fidget = pcall(require, "fidget.progress")
    if ok then
        req.handle =
            fidget.handle.create({ title = "Infill", message = message, lsp_client = { name = M.config.agent } })
    end
end

local function done(req, message)
    if req.handle then
        req.handle:finish(message)
        req.handle = nil
    end
end

local function ms_since(t)
    return (vim.uv.hrtime() - t) / 1e6
end

local function record(req)
    stats.record({
        time = req.time,
        agent = req.agent,
        model = req.model,
        file = req.file,
        filetype = req.filetype,
        outcome = req.outcome,
        accepted = req.accepted,
        gather_ms = req.gather_ms,
        turn_ms = req.turn_ms,
        total_ms = req.total_ms,
        prompt_chars = req.prompt and #req.prompt or nil,
        parts = req.parts,
        counts = req.counts,
        usage = req.usage,
        session_turn = req.session_turn,
        debug = M.config.debug and {
            cursor = { req.row, req.col },
            region = { req.first, req.last },
            reply = req.reply,
            item = req.item,
            drawn = req.drawn,
        } or nil,
    })
end

-- outcome: shown, no_suggestion, discarded, superseded or error; shown waits for accept/reject
local function finish(req, outcome, message)
    done(req, message)
    req.outcome = outcome
    req.total_ms = ms_since(req.started)
    if outcome ~= "shown" then
        record(req)
    end
end

local function settle_shown(accepted)
    if shown then
        shown.accepted = accepted
        record(shown)
        shown = nil
    end
end

local function fresh(req)
    if api.nvim_get_current_buf() ~= req.buf or api.nvim_buf_get_changedtick(req.buf) ~= req.tick then
        return false
    end
    local pos = api.nvim_win_get_cursor(0)
    return pos[1] - 1 == req.row and pos[2] == req.col and api.nvim_get_mode().mode:sub(1, 1) == "i"
end

local dispatch

local function agent()
    local a = M.config.agents[M.config.agent]
    return a or error("agentfill: unknown agent " .. tostring(M.config.agent))
end

local function start()
    local a = agent()
    local s
    local ok, err = pcall(function()
        s = require("agentfill.backends." .. a.backend).start(a, INSTRUCTIONS, function(code, stderr)
            if session == s then
                session = nil
            end
            vim.notify(("agentfill: %s exited %d\n%s"):format(M.config.agent, code, stderr or ""), vim.log.levels.ERROR)
        end)
    end)
    if not ok then
        vim.notify(("agentfill: cannot start %s: %s"):format(M.config.agent, err), vim.log.levels.ERROR)
        return
    end
    s.turns = 0
    return s
end

local function on_result(s, req, err, text, usage)
    inflight = nil
    s.turns = s.turns + 1
    s.usage = usage or s.usage
    req.turn_ms, req.usage, req.session_turn = ms_since(req.sent), usage, s.turns
    req.reply = text
    if err and s.closed then
        finish(req, "superseded", "session restarted")
    elseif err then
        vim.notify("agentfill: " .. tostring(err), vim.log.levels.WARN)
        finish(req, "error", "error")
    elseif not fresh(req) then
        finish(req, "discarded", "discarded (buffer or cursor changed)")
    else
        req.item = item.from_reply(req, text)
        if req.item then
            ready = req
            settle_shown(false)
            shown = req
            req.expect = item.expectation(req)
            finish(req, "shown", ("%.1fs"):format(ms_since(req.started) / 1000))
            -- nvim requests inline completions on cursor events; ask it to come and get this one
            api.nvim_exec_autocmds("CursorMovedI", { buffer = req.buf })
        else
            finish(req, "no_suggestion", "no suggestion")
        end
    end
    if s.turns >= M.config.max_turns and session == s then
        s.close()
        session = start()
    end
    dispatch()
end

dispatch = function()
    if not pending or inflight then
        return
    end
    session = session or start()
    local s = session
    if not s then
        local req = pending
        pending = nil
        return finish(req, "error", "agent failed to start")
    end
    inflight, pending = pending, nil
    local req = inflight
    progress(req, s.turns == 0 and "starting session…" or "thinking…")
    req.sent = vim.uv.hrtime()
    s.send(req.prompt, function(err, text, usage)
        on_result(s, req, err, text, usage)
    end)
end

local seq = 0

local function prompt(req, snippets, win)
    local name = vim.fn.fnamemodify(api.nvim_buf_get_name(req.buf), ":~:.")
    local lines = api.nvim_buf_get_lines(req.buf, win[1], win[2], false)
    local rel = req.first - win[1]
    local cur = lines[req.row - win[1] + 1]
    lines[req.row - win[1] + 1] = cur:sub(1, req.col) .. "<CURSOR>" .. cur:sub(req.col + 1)
    table.insert(lines, rel + 1 + (req.last - req.first), "</REGION>")
    table.insert(lines, rel + 1, "<REGION>")
    local parts = {}
    req.parts, req.counts = {}, {}
    local function count(kind, text)
        req.parts[kind] = (req.parts[kind] or 0) + #text
        req.counts[kind] = (req.counts[kind] or 0) + 1
    end
    for _, sn in ipairs(snippets) do
        local path = vim.fn.fnamemodify(sn.path, ":~:.")
        local body = table.concat(sn.lines, "\n")
        count(sn.kind, body)
        if sn.first then
            parts[#parts + 1] = ('<context path="%s" lines="%d-%d">\n%s\n</context>'):format(
                path,
                sn.first + 1,
                sn.last + 1,
                body
            )
        else
            parts[#parts + 1] = ('<outline path="%s">\n%s\n</outline>'):format(path, body)
        end
    end
    count("excerpt", table.concat(lines, "\n"))
    parts[#parts + 1] = ("File: %s (filetype: %s)\n\n%s"):format(
        name,
        vim.bo[req.buf].filetype,
        table.concat(lines, "\n")
    )
    return table.concat(parts, "\n\n")
end

-- first/last: 0-based end-exclusive rows the model may rewrite
local function request(buf, first, last, row, col)
    seq = seq + 1
    ready = nil
    settle_shown(false)
    local a = agent()
    local before = api.nvim_buf_get_lines(buf, first, row + 1, false)
    before[#before] = before[#before]:sub(1, col)
    local req = {
        seq = seq,
        started = vim.uv.hrtime(),
        time = os.time(),
        agent = M.config.agent,
        model = a.model,
        file = vim.fn.fnamemodify(api.nvim_buf_get_name(buf), ":~:."),
        filetype = vim.bo[buf].filetype,
        buf = buf,
        first = first,
        last = last,
        row = row,
        col = col,
        tick = api.nvim_buf_get_changedtick(buf),
        old = api.nvim_buf_get_lines(buf, first, last, false),
        before = table.concat(before, "\n"),
    }
    local win = {
        math.max(0, first - M.config.lines_before),
        math.min(api.nvim_buf_line_count(buf), last + M.config.lines_after),
    }
    progress(req, "gathering context…")
    context.gather(buf, win, { first, last }, M.config, function(snippets)
        req.gather_ms = ms_since(req.started)
        if req.seq ~= seq then
            return finish(req, "superseded", "superseded")
        end
        if not fresh(req) then
            return finish(req, "discarded", "discarded (buffer or cursor changed)")
        end
        req.prompt = prompt(req, snippets, win)
        if pending then
            finish(pending, "superseded", "superseded")
        end
        pending = req
        dispatch()
        if pending then
            progress(pending, "queued…")
        end
    end)
end

function M.trigger()
    local buf = api.nvim_get_current_buf()
    if not enabled or not (client_id and vim.lsp.buf_is_attached(buf, client_id)) then
        return
    end
    local row, col = unpack(api.nvim_win_get_cursor(0))
    local first = math.max(0, row - 1 - M.config.region.before)
    local last = math.min(api.nvim_buf_line_count(buf), row + M.config.region.after)
    -- models tend to drop blank lines at the region edges
    local function blank(r)
        return api.nvim_buf_get_lines(buf, r, r + 1, false)[1]:match("^%s*$")
    end
    while first < row - 1 and blank(first) do
        first = first + 1
    end
    while last > row and blank(last - 1) do
        last = last - 1
    end
    request(buf, first, last, row - 1, col)
end

local drawn_ns = api.nvim_create_namespace("nvim.lsp.inline_completion")
local ns = api.nvim_create_namespace("agentfill")

local function clear_marks()
    for _, buf in ipairs(api.nvim_list_bufs()) do
        api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    end
end

-- once nvim's handler ran: mark the replaced lines while its ghost text is up, and log what it drew
local function after_draw(req)
    vim.defer_fn(function()
        if not api.nvim_buf_is_valid(req.buf) or not fresh(req) then
            return
        end
        local marks = api.nvim_buf_get_extmarks(req.buf, drawn_ns, 0, -1, { details = true })
        clear_marks()
        if M.config.hl_delete and #marks > 0 then
            for _, d in ipairs(req.deleted or {}) do
                api.nvim_buf_set_extmark(req.buf, ns, d[1], 0, {
                    end_row = d[2],
                    hl_group = M.config.hl_delete,
                    hl_eol = true,
                    priority = 10,
                })
            end
        end
        if not M.config.debug then
            return
        end
        req.drawn = vim.tbl_map(function(m)
            local function join(chunks)
                return table.concat(vim.tbl_map(function(c)
                    return c[1]
                end, chunks or {}))
            end
            return {
                row = m[2],
                col = m[3],
                pos = m[4].virt_text_pos,
                text = join(m[4].virt_text),
                lines = vim.tbl_map(join, m[4].virt_lines or {}),
            }
        end, marks)
    end, 100)
end

-- answers textDocument/inlineCompletion with the ready suggestion, if it still fits
function M.complete(params)
    local req = ready
    if
        not enabled
        or not req
        or vim.uri_to_bufnr(params.textDocument.uri) ~= req.buf
        or params.position.line ~= req.row
        or params.position.character ~= req.col
        or not fresh(req)
    then
        return { items = {} }
    end
    after_draw(req)
    return { items = { req.item } }
end

local function wanted(buf)
    local cfg, name, ft = M.config, api.nvim_buf_get_name(buf), vim.bo[buf].filetype
    return vim.bo[buf].buftype == ""
        and name ~= ""
        and (not cfg.filetypes or vim.list_contains(cfg.filetypes, ft))
        and not vim.list_contains(cfg.exclude_filetypes, ft)
        and vim.fn.getfsize(name) <= cfg.max_file_bytes
end

-- attaches the client to buf, or detaches it when buf no longer passes the filters
local function sync(buf)
    if wanted(buf) then
        vim.lsp.buf_attach_client(buf, client_id)
    elseif vim.lsp.buf_is_attached(buf, client_id) then
        vim.lsp.buf_detach_client(buf, client_id)
    end
end

function M.restart()
    if session then
        session.close()
        session = nil
    end
end

function M.toggle()
    enabled = not enabled
    if not enabled then
        ready = nil
        settle_shown(false)
        clear_marks()
    end
    vim.notify("agentfill: " .. (enabled and "enabled" or "disabled"))
end

-- shows the agent, or switches to name and starts a new session
function M.agent(name)
    if not name or name == "" then
        return vim.notify("agentfill: agent " .. M.config.agent)
    end
    if not M.config.agents[name] then
        return vim.notify("agentfill: unknown agent " .. name, vim.log.levels.ERROR)
    end
    M.config.agent = name
    M.restart()
    vim.notify("agentfill: agent " .. name)
end

function M.stats()
    local a = agent()
    local u = session and session.usage or {}
    stats.open({
        agent = M.config.agent,
        model = a.model or u.model,
        turns = session and session.turns,
        max_turns = M.config.max_turns,
        context_used = u.context_used,
        context_size = u.context_size,
    })
end

local mapped = {}

local function set_keys()
    for _, lhs in ipairs(mapped) do
        pcall(vim.keymap.del, "i", lhs)
    end
    mapped = {}
    local keys = M.config.keys
    local function map(lhs, rhs, opts)
        vim.keymap.set("i", lhs, rhs, opts)
        mapped[#mapped + 1] = lhs
    end
    if keys.trigger then
        map(keys.trigger, M.trigger, { desc = "Agent: request infill" })
    end
    if keys.accept then
        map(keys.accept, function()
            if not vim.lsp.inline_completion.get() then
                return keys.accept
            end
        end, { expr = true, desc = "Agent: accept inline completion" })
    end
    if keys.next then
        map(keys.next, function()
            vim.lsp.inline_completion.select({ count = 1 })
        end, { desc = "Agent: next inline completion" })
    end
    if keys.prev then
        map(keys.prev, function()
            vim.lsp.inline_completion.select({ count = -1 })
        end, { desc = "Agent: previous inline completion" })
    end
end

local function set_hl()
    api.nvim_set_hl(0, "AgentfillDelete", { link = "DiffDelete", default = true })
end

--- Merges opts over the active config (over the defaults and vim.g.agentfill on the first call), then
--- starts the client. Safe to call again. Optional: plugin/agentfill.lua calls it on VimEnter.
---@param opts? table
function M.setup(opts)
    local old = M.config
    local base = M.started and old or config.merge(old, vim.g.agentfill or {})
    M.config = config.merge(base, opts or {})
    M.started = true
    if old.agent ~= M.config.agent or not vim.deep_equal(old.agents[old.agent], M.config.agents[M.config.agent]) then
        M.restart()
    end
    set_hl()
    set_keys()
    -- started before other servers so its item sorts first among inline completions
    if not (client_id and vim.lsp.get_client_by_id(client_id)) then
        client_id = vim.lsp.start({ name = "agentfill", cmd = require("agentfill.server") }, { attach = false })
    end
    local attach_group = api.nvim_create_augroup("agentfill", { clear = true })
    api.nvim_create_autocmd({ "BufEnter", "FileType" }, {
        group = attach_group,
        callback = function(ev)
            sync(ev.buf)
        end,
    })
    api.nvim_create_autocmd("ColorScheme", { group = attach_group, callback = set_hl })
    if M.config.enable_inline then
        api.nvim_create_autocmd("LspAttach", {
            group = attach_group,
            callback = function(ev)
                if ev.data.client_id == client_id then
                    vim.lsp.inline_completion.enable(true, { bufnr = ev.buf })
                end
            end,
        })
    end
    for _, buf in ipairs(api.nvim_list_bufs()) do
        if api.nvim_buf_is_loaded(buf) then
            sync(buf)
            if old.enable_inline ~= M.config.enable_inline and vim.lsp.buf_is_attached(buf, client_id) then
                vim.lsp.inline_completion.enable(M.config.enable_inline, { bufnr = buf })
            end
        end
    end
    local group = api.nvim_create_augroup("agentfill.stats", { clear = true })
    -- the first edit after a suggestion shows tells whether it was accepted
    api.nvim_create_autocmd("TextChangedI", {
        group = group,
        callback = function(ev)
            if not shown or shown.buf ~= ev.buf then
                return
            end
            local e = shown.expect
            settle_shown(vim.deep_equal(api.nvim_buf_get_lines(ev.buf, e.row, e.row + #e.lines, false), e.lines))
        end,
    })
    api.nvim_create_autocmd({ "InsertLeave", "BufLeave" }, {
        group = group,
        callback = function()
            settle_shown(false)
        end,
    })
    api.nvim_create_autocmd({ "CursorMovedI", "TextChangedI", "InsertLeave", "BufLeave" }, {
        group = group,
        callback = function()
            if not (ready and fresh(ready)) then
                clear_marks()
            end
        end,
    })
    api.nvim_create_autocmd("VimLeavePre", {
        group = group,
        callback = function()
            settle_shown(false)
            if session then
                session.close()
            end
        end,
    })
    -- warm the session before the first trigger, not for every nvim started
    api.nvim_create_autocmd("InsertEnter", {
        group = group,
        once = true,
        callback = function()
            session = session or start()
        end,
    })
end

return M
