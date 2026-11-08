if vim.g.loaded_agentfill then
    return
end
vim.g.loaded_agentfill = 1

local function agentfill()
    return require("agentfill")
end

local subcommands = {
    agent = function(args)
        agentfill().agent(args)
    end,
    restart = function()
        agentfill().restart()
        vim.notify("agentfill: session restarted")
    end,
    toggle = function()
        agentfill().toggle()
    end,
    stats = function()
        agentfill().stats()
    end,
}

vim.api.nvim_create_user_command("Agentfill", function(cmd)
    local name, rest = cmd.args:match("^(%S+)%s*(.*)$")
    local run = subcommands[name]
    if not run then
        return vim.notify("agentfill: unknown subcommand " .. (name or ""), vim.log.levels.ERROR)
    end
    run(rest)
end, {
    nargs = "+",
    desc = "Agent inline completion",
    complete = function(lead, line)
        if line:match("^%S*Agentfill!?%s+%S*$") then
            local names = vim.tbl_filter(function(name)
                return vim.startswith(name, lead)
            end, vim.tbl_keys(subcommands))
            table.sort(names)
            return names
        end
        if line:match("^%S*Agentfill!?%s+agent%s+%S*$") then
            local names = vim.tbl_filter(function(name)
                return vim.startswith(name, lead)
            end, vim.tbl_keys(agentfill().config.agents))
            table.sort(names)
            return names
        end
        return {}
    end,
})

vim.keymap.set("i", "<Plug>(agentfill-trigger)", function()
    agentfill().trigger()
end, { desc = "Agent: request infill" })

local function start()
    if not agentfill().started then
        agentfill().setup()
    end
end

if vim.v.vim_did_enter == 1 then
    start()
else
    vim.api.nvim_create_autocmd("VimEnter", { once = true, callback = start })
end
