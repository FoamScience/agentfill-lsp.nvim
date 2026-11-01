-- `claude -p` stream-json session: no tools, no settings, our own system prompt
local M = {}

-- normalized usage of one stream-json result; input counts cached and cache-write tokens too
function M.usage(msg)
    local u = msg.usage or {}
    local usage = {
        input = (u.input_tokens or 0) + (u.cache_creation_input_tokens or 0) + (u.cache_read_input_tokens or 0),
        cached = u.cache_read_input_tokens,
        output = u.output_tokens,
        ttft_ms = msg.ttft_ms,
    }
    for model, m in pairs(msg.model_usage_since_last_result or {}) do
        usage.model = model
        usage.cost = (usage.cost or 0) + (m.costUSD or 0)
        usage.context_size = m.contextWindow
    end
    usage.context_used = usage.input
    return usage
end

-- calls on_exit(code, stderr) when the process dies without close()
function M.start(agent, instructions, on_exit)
    local session = { partial = "" }
    session.job = vim.system(
        {
            agent.cmd or "claude",
            "-p",
            "--input-format",
            "stream-json",
            "--output-format",
            "stream-json",
            "--verbose",
            "--model",
            agent.model or "haiku",
            "--effort",
            agent.effort or "low",
            "--system-prompt",
            instructions,
            "--tools",
            "",
            "--strict-mcp-config",
            "--setting-sources",
            "",
            "--disable-slash-commands",
            "--no-session-persistence",
        },
        {
            -- neutral cwd so no project CLAUDE.md gets pulled into the prompt
            cwd = vim.fn.stdpath("cache"),
            env = { CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = "1" },
            stdin = true,
            stdout = vim.schedule_wrap(function(_, data)
                if not data then
                    return
                end
                local lines = vim.split(session.partial .. data, "\n", { plain = true })
                session.partial = table.remove(lines)
                for _, line in ipairs(lines) do
                    local ok, msg = pcall(vim.json.decode, line)
                    if ok and type(msg) == "table" and msg.type == "result" and session.cb then
                        local cb = session.cb
                        session.cb = nil
                        if msg.is_error then
                            cb(tostring(msg.result))
                        else
                            cb(nil, type(msg.result) == "string" and msg.result or "", M.usage(msg))
                        end
                    end
                end
            end),
        },
        vim.schedule_wrap(function(obj)
            if session.cb then
                session.cb("claude exited")
                session.cb = nil
            end
            if not session.closed then
                on_exit(obj.code, obj.stderr)
            end
        end)
    )

    -- one turn at a time: stream-json merges messages queued mid-turn
    function session.send(text, cb)
        session.cb = cb
        local msg = { type = "user", message = { role = "user", content = text } }
        session.job:write(vim.json.encode(msg) .. "\n")
    end

    function session.close()
        session.closed = true
        session.job:write(nil)
    end

    return session
end

return M
