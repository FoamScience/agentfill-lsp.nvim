-- Agent Client Protocol (JSON-RPC over stdio) session with any ACP agent.
-- ACP has no system prompt, so the instructions lead the session's first prompt.
local M = {}

function M.start(agent, instructions, on_exit)
    local session = { partial = "", next_id = 0, replies = {}, queued = nil, first = true }
    local cwd = vim.fs.joinpath(vim.fn.stdpath("cache"), "agentfill")
    vim.fn.mkdir(cwd, "p")

    local function write(msg)
        msg.jsonrpc = "2.0"
        session.job:write(vim.json.encode(msg) .. "\n")
    end

    local function request(method, params, cb)
        session.next_id = session.next_id + 1
        session.replies[session.next_id] = cb
        write({ id = session.next_id, method = method, params = params })
    end

    local function fail(err)
        local cb = session.cb or (session.queued and session.queued[2])
        session.cb, session.queued = nil, nil
        if cb then
            cb(err)
        end
    end

    -- a session that never got set up is useless: drop it so the next turn starts over
    local function broken(err)
        fail(err)
        session.closed = true
        session.job:kill(15)
        on_exit(1, err)
    end

    -- agent-to-client requests: completions never grant tools or files
    local function answer(msg)
        if msg.method == "session/request_permission" then
            write({ id = msg.id, result = { outcome = { outcome = "cancelled" } } })
        else
            write({ id = msg.id, error = { code = -32601, message = "unsupported: " .. msg.method } })
        end
    end

    local function on_message(msg)
        if msg.method and msg.id then
            return answer(msg)
        end
        if msg.method == "session/update" then
            local u = msg.params.update
            if u.sessionUpdate == "agent_message_chunk" and u.content and u.content.type == "text" and session.text then
                session.text[#session.text + 1] = u.content.text
            elseif u.sessionUpdate == "usage_update" then
                session.window = u
            elseif
                u.sessionUpdate == "tool_call"
                and agent.tool_guard ~= false
                and session.text
                and not session.tool
            then
                -- completions never need tools; stop the turn before it touches anything
                session.tool = u.title or u.kind or "tool"
                write({ method = "session/cancel", params = { sessionId = session.id } })
            end
            return
        end
        local cb = msg.id and session.replies[msg.id]
        if cb then
            session.replies[msg.id] = nil
            cb(msg.error, msg.result)
        end
    end

    session.job = vim.system(
        agent.cmd,
        {
            cwd = cwd,
            env = agent.env,
            stdin = true,
            stdout = vim.schedule_wrap(function(_, data)
                if not data then
                    return
                end
                local lines = vim.split(session.partial .. data, "\n", { plain = true })
                session.partial = table.remove(lines)
                for _, line in ipairs(lines) do
                    local ok, msg = pcall(vim.json.decode, line)
                    if ok and type(msg) == "table" then
                        on_message(msg)
                    end
                end
            end),
        },
        vim.schedule_wrap(function(obj)
            fail(agent.cmd[1] .. " exited")
            if not session.closed then
                on_exit(obj.code, obj.stderr)
            end
        end)
    )

    local function prompt(text, cb)
        session.cb, session.text, session.tool = cb, {}, nil
        if session.first then
            session.first = false
            text = instructions .. "\n\n" .. text
        end
        request(
            "session/prompt",
            { sessionId = session.id, prompt = { { type = "text", text = text } } },
            function(err, res)
                local reply = table.concat(session.text or {})
                session.text = nil
                if err then
                    return fail(err.message or vim.inspect(err))
                end
                if session.tool then
                    return fail("agent tried to use a tool (" .. session.tool .. "), turn cancelled")
                end
                session.cb = nil
                cb(nil, reply, session.usage(res and res.usage))
            end
        )
    end

    local function ready()
        session.ready = true
        if session.queued then
            local q = session.queued
            session.queued = nil
            prompt(q[1], q[2])
        end
    end

    local caps = { fs = { readTextFile = false, writeTextFile = false }, terminal = false }
    request("initialize", { protocolVersion = 1, clientCapabilities = caps }, function(err)
        if err then
            return broken("initialize: " .. (err.message or ""))
        end
        request("session/new", { cwd = cwd, mcpServers = {} }, function(err2, res)
            if err2 then
                return broken("session/new: " .. (err2.message or ""))
            end
            session.id = res.sessionId
            -- mode is required: it is what keeps the agent away from its tools
            local wanted = {
                { category = "mode", value = agent.mode, required = true },
                { category = "model", value = agent.model },
            }
            local function apply(i)
                local w = wanted[i]
                if not w then
                    return ready()
                end
                if not w.value then
                    return apply(i + 1)
                end
                local option = vim.iter(res.configOptions or {}):find(function(o)
                    return o.category == w.category
                end)
                local function problem(msg)
                    if w.required then
                        return broken(msg)
                    end
                    vim.notify("agentfill: " .. msg, vim.log.levels.WARN)
                    apply(i + 1)
                end
                if not option then
                    return problem(("agent has no %s option"):format(w.category))
                end
                local params = { sessionId = session.id, configId = option.id, value = w.value }
                request("session/set_config_option", params, function(err3)
                    if err3 then
                        return problem(("cannot set %s %s: %s"):format(w.category, w.value, err3.message or ""))
                    end
                    apply(i + 1)
                end)
            end
            apply(1)
        end)
    end)

    -- usage_update carries the session's cumulative cost; a turn costs the difference
    function session.usage(u)
        u = u or {}
        local w = session.window or {}
        local total = w.cost and w.cost.amount
        local usage = {
            input = u.inputTokens,
            cached = u.cachedReadTokens,
            output = u.outputTokens,
            thought = u.thoughtTokens,
            context_used = w.used,
            context_size = w.size,
            cost = total and total - (session.spent or 0),
            model = agent.model,
        }
        session.spent = total or session.spent
        return usage
    end

    -- one turn at a time; a turn sent before the session exists waits for it
    function session.send(text, cb)
        if session.ready then
            prompt(text, cb)
        else
            session.queued = { text, cb }
        end
    end

    function session.close()
        session.closed = true
        session.job:kill(15)
    end

    return session
end

return M
