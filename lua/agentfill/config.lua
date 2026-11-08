-- Every option agentfill reads, with its default. Read the defaults with
-- `require("agentfill.config").defaults`, the active config with `require("agentfill").config`.
local M = {}

---@class agentfill.Agent
---@field backend "claude"|"acp" "claude": native `claude -p` stream-json; "acp": any Agent Client Protocol agent
---@field cmd string|string[] executable ("claude") or command list ("acp")
---@field model? string
---@field effort? string claude only: `--effort`
---@field env? table<string, string> acp only: extra environment for the agent process
---@field mode? string acp only: must select a tool-less agent; the session refuses to start when it cannot be set
---@field tool_guard? boolean acp only: cancel any turn in which the agent starts a tool call (default true)

---@class agentfill.Keys insert-mode keys; false skips a mapping
---@field trigger string|false
---@field accept string|false falls back to its own key when no suggestion is shown
---@field next string|false
---@field prev string|false

---@class agentfill.Config
---@field agent string key of agents
---@field agents table<string, agentfill.Agent>
---@field max_turns integer completions per session before it restarts
---@field lines_before integer excerpt rows above the region
---@field lines_after integer excerpt rows below the region
---@field region { before: integer, after: integer } rows around the cursor the model may rewrite
---@field header_lines integer
---@field max_file_bytes integer larger files are not attached to
---@field defs { timeout_ms: integer, max_idents: integer, max: integer, max_lines: integer }|false
---@field imports { max: integer, max_lines: integer }|false
---@field search { n: integer, max: integer, max_lines: integer, max_query: integer, timeout_ms: integer }|false
---@field keys agentfill.Keys
---@field enable_inline boolean
---@field filetypes? string[] attach only to these; nil attaches to all
---@field exclude_filetypes string[]
---@field debug boolean
---@field hl_delete string|false

---@type agentfill.Config
M.defaults = {
    agent = "claude",
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
    keys = { trigger = "<M-c>", accept = false, next = false, prev = false },
    -- enable vim.lsp.inline_completion in buffers the client attaches to
    enable_inline = true,
    filetypes = nil,
    exclude_filetypes = {},
    -- log the reply, the item and what nvim drew for it with each request
    debug = false,
    -- marks the lines a suggestion replaces next to nvim's ghost text; false disables
    hl_delete = "AgentfillDelete",
}

local function validate(opts)
    for key, kind in pairs({
        agent = "string",
        agents = "table",
        max_turns = "number",
        lines_before = "number",
        lines_after = "number",
        region = "table",
        header_lines = "number",
        max_file_bytes = "number",
        defs = { "table", "boolean" },
        imports = { "table", "boolean" },
        search = { "table", "boolean" },
        keys = "table",
        enable_inline = "boolean",
        filetypes = "table",
        exclude_filetypes = "table",
        debug = "boolean",
        hl_delete = { "string", "boolean" },
    }) do
        vim.validate("agentfill." .. key, opts[key], kind, true)
    end
    for _, section in ipairs({ "region", "defs", "imports", "search" }) do
        if type(opts[section]) == "table" then
            for key, value in pairs(opts[section]) do
                vim.validate(("agentfill.%s.%s"):format(section, key), value, "number")
            end
        end
    end
    for key, value in pairs(opts.keys or {}) do
        vim.validate("agentfill.keys." .. key, value, { "string", "boolean" })
    end
end

--- opts merged over base, validated; errors without touching base
---@param base agentfill.Config
---@param opts table any subset of agentfill.Config
---@return agentfill.Config
function M.merge(base, opts)
    validate(opts)
    local cfg = vim.tbl_deep_extend("force", vim.deepcopy(base), vim.deepcopy(opts))
    for name, a in pairs(cfg.agents) do
        vim.validate(("agentfill.agents.%s.backend"):format(name), a.backend, function(v)
            return v == "claude" or v == "acp"
        end, '"claude" or "acp"')
    end
    vim.validate("agentfill.agent", cfg.agent, function(v)
        return cfg.agents[v] ~= nil
    end, "a key of agents")
    return cfg
end

return M
