local api = vim.api
local context = require("agentfill.context")
local stats = require("agentfill.stats")

local M = {}

M.config = {
    agent = "claude",
    -- backend "claude": native `claude -p` stream-json; backend "acp": any Agent Client Protocol agent.
    -- acp agents: env for the process, mode and model set through the session's config options;
    -- mode must select a tool-less agent, the session refuses to start when it cannot be set;
    -- tool_guard (default on) cancels any turn in which the agent starts a tool call
    agents = {
        claude = { backend = "claude", cmd = "claude", model = "haiku", effort = "low" },
        opencode = {
            backend = "acp",
            cmd = { "opencode", "acp" },
            -- a primary agent with every tool denied; also drops ~8k tokens of tool definitions per turn
            env = {
                OPENCODE_CONFIG_CONTENT = vim.json.encode({
                    agent = {
                        agentfill = {
                            mode = "primary",
                            description = "inline completion, no tools",
                            permission = { ["*"] = "deny" },
                            tools = { ["*"] = false },
                        },
                    },
                }),
            },
            mode = "agentfill",
            -- opencode keeps a `skill` tool no config removes; the deny-all agent refuses it
            tool_guard = false,
        },
    },
    -- every completion stays in the session context; restart before it grows slow
    max_turns = 8,
    lines_before = 80,
    lines_after = 30,
    -- rows around the cursor the model may rewrite in insert mode
    region = { before = 2, after = 8 },
    header_lines = 20,
    max_file_bytes = 512 * 1024,
    -- LSP definitions of identifiers in the region; false disables
    defs = { timeout_ms = 300, max_idents = 30, max = 8, max_lines = 40 },
    -- outlines of imported files, used when no definition was found; false disables
    imports = { max = 6, max_lines = 40 },
    -- semantic search hits via m2v; false disables
    search = {
        n = 8,
        max = 4,
        max_lines = 40,
        max_query = 500,
        timeout_ms = 400,
    },
    -- insert-mode keys; false skips a mapping. accept falls back to its own key when nothing is shown
    keys = { trigger = "<M-c>", accept = false, next = false, prev = false },
    -- enable vim.lsp.inline_completion in buffers the client attaches to
    enable_inline = true,
    -- filetypes to attach to (nil: all) and to never attach to
    filetypes = nil,
    exclude_filetypes = {},
    -- log the reply, the item and what nvim drew for it with each request
    debug = false,
    -- marks the lines a suggestion replaces next to nvim's ghost text; false disables
    hl_delete = "DiffDelete",
}

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

-- buffer rows the item leaves behind once accepted, to recognize the accept
local function expectation(req)
    local r = req.item.range
    local lines = api.nvim_buf_get_lines(req.buf, r.start.line, r["end"].line + 1, false)
    local text = lines[1]:sub(1, r.start.character) .. req.item.insertText .. lines[#lines]:sub(r["end"].character + 1)
    return { row = r.start.line, lines = vim.split(text, "\n", { plain = true }) }
end

local function fresh(req)
    if api.nvim_get_current_buf() ~= req.buf or api.nvim_buf_get_changedtick(req.buf) ~= req.tick then
        return false
    end
    local pos = api.nvim_win_get_cursor(0)
    return pos[1] - 1 == req.row and pos[2] == req.col and api.nvim_get_mode().mode:sub(1, 1) == "i"
end

local function position(row, col)
    return { line = row, character = col }
end

-- lsp.InlineCompletionItem for the rewritten region, positions in utf-8 bytes
local function to_item(req, text)
    -- anything outside <region> is the model talking, not code
    text = text:match("<region>\n?(.-)\n?</region>")
    if not text then
        return
    end
    text = text:gsub("^```[%w_+-]*\n", ""):gsub("\n?```%s*$", ""):gsub("<CURSOR>", "")
    -- text around the cursor survived untouched: plain insertion at the cursor
    local old, before = table.concat(req.old, "\n"), req.before
    local after = old:sub(#before + 1)
    if #text > #old and text:sub(1, #before) == before and text:sub(#text - #after + 1) == after then
        local at = position(req.row, req.col)
        return { insertText = text:sub(#before + 1, #text - #after), range = { start = at, ["end"] = at } }
    end

    local new = vim.split(text, "\n", { plain = true })
    -- the model dropping the blank line the cursor sits on is not a suggestion
    local at = req.row - req.first + 1
    if req.old[at]:match("^%s*$") then
        local rest = vim.deepcopy(req.old)
        table.remove(rest, at)
        if vim.deep_equal(rest, new) then
            return
        end
    end
    local hunks = vim.text.diff(old .. "\n", table.concat(new, "\n") .. "\n", { result_type = "indices" })
    if #hunks == 0 then
        return
    end
    req.deleted = {}
    for _, h in ipairs(hunks) do
        if h[2] > 0 then
            req.deleted[#req.deleted + 1] = { req.first + h[1] - 1, req.first + h[1] + h[2] - 1 }
        end
    end
    -- one item has one range: span every hunk, carrying unchanged lines in between
    local a_lo, a_hi, b_lo, b_hi = math.huge, -1, math.huge, -1
    for _, h in ipairs(hunks) do
        local sa, ca, sb, cb = unpack(h)
        a_lo, a_hi = math.min(a_lo, ca > 0 and sa or sa + 1), math.max(a_hi, ca > 0 and sa + ca - 1 or sa)
        b_lo, b_hi = math.min(b_lo, cb > 0 and sb or sb + 1), math.max(b_hi, cb > 0 and sb + cb - 1 or sb)
    end
    local added = table.concat(vim.list_slice(new, b_lo, b_hi), "\n")
    if a_lo > a_hi then
        -- pure addition after old line a_hi (0 = before the region)
        if a_hi == 0 then
            local at = position(req.first, 0)
            return { insertText = added .. "\n", range = { start = at, ["end"] = at } }
        end
        local at = position(req.first + a_hi - 1, #req.old[a_hi])
        return { insertText = "\n" .. added, range = { start = at, ["end"] = at } }
    end
    local row = req.first + a_lo - 1
    local stop = position(req.first + a_hi - 1, #req.old[a_hi])
    if row == 0 then
        return { insertText = added, range = { start = position(0, 0), ["end"] = stop } }
    end
    -- anchored at the end of the row above, nvim shows the new lines as virtual lines above the
    -- replaced ones instead of overlaying the first replaced row
    local above = api.nvim_buf_get_lines(req.buf, row - 1, row, false)[1]
    return { insertText = "\n" .. added, range = { start = position(row - 1, #above), ["end"] = stop } }
end

local dispatch

local function agent()
    local a = M.config.agents[M.config.agent]
    return a or error("agentfill: unknown agent " .. tostring(M.config.agent))
end

local function start()
    local a = agent()
    local s
    s = require("agentfill.backends." .. a.backend).start(a, INSTRUCTIONS, function(code, stderr)
        if session == s then
            session = nil
        end
        vim.notify(("agentfill: %s exited %d\n%s"):format(M.config.agent, code, stderr or ""), vim.log.levels.ERROR)
    end)
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
        req.item = to_item(req, text)
        if req.item then
            ready = req
            settle_shown(false)
            shown = req
            req.expect = expectation(req)
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

local function attach(buf)
    local cfg, name, ft = M.config, api.nvim_buf_get_name(buf), vim.bo[buf].filetype
    if
        vim.bo[buf].buftype ~= ""
        or name == ""
        or (cfg.filetypes and not vim.list_contains(cfg.filetypes, ft))
        or vim.list_contains(cfg.exclude_filetypes, ft)
        or vim.fn.getfsize(name) > cfg.max_file_bytes
    then
        return
    end
    vim.lsp.buf_attach_client(buf, client_id)
end

local function restart()
    if session then
        session.close()
        session = nil
    end
end

local function set_keys()
    local keys, map = M.config.keys, vim.keymap.set
    map("i", "<Plug>(agentfill-trigger)", M.trigger, { desc = "Agent: request infill" })
    if keys.trigger then
        map("i", keys.trigger, M.trigger, { desc = "Agent: request infill" })
    end
    if keys.accept then
        map("i", keys.accept, function()
            if not vim.lsp.inline_completion.get() then
                return keys.accept
            end
        end, { expr = true, desc = "Agent: accept inline completion" })
    end
    if keys.next then
        map("i", keys.next, function()
            vim.lsp.inline_completion.select({ count = 1 })
        end, { desc = "Agent: next inline completion" })
    end
    if keys.prev then
        map("i", keys.prev, function()
            vim.lsp.inline_completion.select({ count = -1 })
        end, { desc = "Agent: previous inline completion" })
    end
end

local function set_commands()
    local command = api.nvim_create_user_command
    command("AFRestart", function()
        restart()
        vim.notify("agentfill: session restarted")
    end, { desc = "agentfill: start a new agent session" })
    command("AFToggle", function()
        enabled = not enabled
        if not enabled then
            ready = nil
            settle_shown(false)
            clear_marks()
        end
        vim.notify("agentfill: " .. (enabled and "enabled" or "disabled"))
    end, { desc = "agentfill: enable or disable suggestions" })
    command("AFAgent", function(args)
        if args.args == "" then
            return vim.notify("agentfill: agent " .. M.config.agent)
        end
        if not M.config.agents[args.args] then
            return vim.notify("agentfill: unknown agent " .. args.args, vim.log.levels.ERROR)
        end
        M.config.agent = args.args
        restart()
        vim.notify("agentfill: agent " .. args.args)
    end, {
        nargs = "?",
        complete = function()
            local names = vim.tbl_keys(M.config.agents)
            table.sort(names)
            return names
        end,
        desc = "agentfill: show or switch the agent",
    })
end

function M.setup(opts)
    M.config = vim.tbl_deep_extend("force", M.config, opts or {})
    set_keys()
    set_commands()
    -- started before other servers so its item sorts first among inline completions
    client_id = vim.lsp.start({ name = "agentfill", cmd = require("agentfill.server") }, { attach = false })
    local attach_group = api.nvim_create_augroup("agentfill", { clear = true })
    api.nvim_create_autocmd({ "BufEnter", "FileType" }, {
        group = attach_group,
        callback = function(ev)
            attach(ev.buf)
        end,
    })
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
            attach(buf)
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
    api.nvim_create_user_command("AFStats", function()
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
    end, { desc = "agentfill: request metrics" })
    api.nvim_create_autocmd("VimLeavePre", {
        callback = function()
            settle_shown(false)
            if session then
                session.close()
            end
        end,
    })
    -- warm the session before the first trigger, not for every nvim started
    api.nvim_create_autocmd("InsertEnter", {
        once = true,
        callback = function()
            session = session or start()
        end,
    })
end

return M
