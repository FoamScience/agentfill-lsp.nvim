local M = {}

function M.check()
    local health = vim.health
    local cfg = require("agentfill").config

    health.start("agentfill: neovim")
    if vim.lsp.inline_completion then
        health.ok("vim.lsp.inline_completion is available")
    else
        health.error("vim.lsp.inline_completion is missing", "Neovim 0.12 or newer is required")
    end
    if #vim.lsp.get_clients({ name = "agentfill" }) > 0 then
        health.ok("agentfill client is running")
    else
        health.warn("agentfill client is not running", "call require('agentfill').setup()")
    end

    health.start("agentfill: agent")
    local a = cfg.agents[cfg.agent]
    if not a then
        health.error("unknown agent " .. tostring(cfg.agent), "pick one of the keys in opts.agents")
    else
        local cmd = type(a.cmd) == "table" and a.cmd[1] or a.cmd or "claude"
        if vim.fn.executable(cmd) == 1 then
            health.ok(("%s: %s found (backend %s)"):format(cfg.agent, cmd, a.backend))
        else
            health.error(
                ("%s: %s is not executable"):format(cfg.agent, cmd),
                "install it or set agents." .. cfg.agent .. ".cmd"
            )
        end
    end

    health.start("agentfill: optional plugins")
    if cfg.search == false then
        health.info("m2v.nvim: search context disabled")
    elseif pcall(require, "m2v") then
        health.ok("m2v.nvim: semantic search context enabled")
    else
        health.info("m2v.nvim not installed: no semantic search context")
    end
    if pcall(require, "fidget.progress") then
        health.ok("fidget.nvim: request progress shown")
    else
        health.info("fidget.nvim not installed: no request progress")
    end
end

return M
