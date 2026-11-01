# agentfill-lsp.nvim

Coding agents as an inline completion source for Neovim's built-in `vim.lsp.inline_completion`. An in-process language server answers `textDocument/inlineCompletion`; suggestions come from a long-lived agent session.

- Manual trigger: `<M-c>` in insert mode. Accept and cycle with whatever you map to `vim.lsp.inline_completion.get()` / `.select()`.
- The model rewrites a small region around the cursor, so a suggestion can also change the lines after the cursor: nvim shows the new text as ghost text and the lines it replaces are highlighted with `hl_delete`; accepting applies it as one range.
- Context sent with each request: the surrounding lines, the file header, LSP definitions of identifiers near the cursor (or imported files' outlines when no LSP answers), and m2v.nvim semantic search hits when that plugin is installed.

## Agents

| agent | backend | notes |
|---|---|---|
| `claude` (default) | native `claude -p` stream-json | Claude Code subscription, no API key. Runs with no tools, no settings, no MCP and its own system prompt. |
| `opencode` | ACP (`opencode acp`) | Uses a tool-less `agentfill` agent injected through `OPENCODE_CONFIG_CONTENT`, selected as the session mode. |

Any other [Agent Client Protocol](https://agentclientprotocol.com) agent can be added under `agents` with `backend = "acp"`.

## Install

lazy.nvim:

```lua
{
    "<owner>/agentfill-lsp.nvim",
    main = "agentfill",
    -- start its client before other LSP servers so its suggestion sorts first
    lazy = false,
    opts = {},
}
```

Inline completion must be enabled for buffers where the `agentfill` client attaches, for example:

```lua
vim.api.nvim_create_autocmd("LspAttach", {
    callback = function(ev)
        local client = vim.lsp.get_client_by_id(ev.data.client_id)
        if client and client:supports_method("textDocument/inlineCompletion", ev.buf) then
            vim.lsp.inline_completion.enable(true, { bufnr = ev.buf })
        end
    end,
})
vim.keymap.set("i", "<C-f>", function() return vim.lsp.inline_completion.get() end)
```

## Configuration

```lua
opts = {
    agent = "opencode",
    agents = {
        opencode = { model = "nvidia/openai/gpt-oss-20b" },
        -- any ACP agent:
        -- myagent = { backend = "acp", cmd = { "my-agent", "--acp" }, mode = "...", env = { ... } },
    },
    max_turns = 8, -- restart the session after this many completions
    keys = { trigger = "<M-c>" },
    hl_delete = "DiffDelete", -- lines a suggestion replaces, shown next to the ghost text; false disables
}
```

Context sources can be turned off one by one with `defs = false`, `imports = false` and `search = false`.

ACP agent fields:

- `cmd`: command list
- `env`: extra environment for the agent process
- `mode`: value for the session's `mode` config option; the session refuses to start if it cannot be applied
- `model`: value for the session's `model` config option (warns when it cannot be applied)
- `tool_guard` (default `true`): cancel any turn in which the agent starts a tool call

## Metrics

`:AFStats` opens a float with this nvim's numbers next to all-time totals, plus the last 10 requests:

- outcomes: shown, accepted (the first insert-mode edit after a suggestion matches it), no suggestion, discarded (buffer or cursor moved), superseded, error
- latency p50/p90: context gathering, agent turn, total
- tokens per turn (input, cached, output) and cost, as reported by the agent
- prompt size in characters, split by part (excerpt, header, definitions, import outlines, search hits) with counts
- current session: turns used of `max_turns`, context used / window

Every request is appended as one JSON line to `stdpath("state")/agentfill/requests.jsonl`. Claude input counts cache reads and cache writes; ACP agents report their own `inputTokens`, so the two are not directly comparable.

With `debug = true`, each entry also carries the cursor, the editable region, the agent's raw reply, the inline completion item and the virtual text nvim drew for it (`drawn`; empty when nothing was visible).

## Safety

Completions never need tools. The client advertises no filesystem or terminal capabilities, answers every permission request with `cancelled`, and (with `tool_guard`) cancels a turn as soon as a tool call starts. A guard cannot undo a tool that ran before the cancel arrived: an ACP agent without a tool-less `mode` can still act in its working directory (`stdpath("cache")/agentfill`) or on absolute paths, so give every ACP agent a deny-all mode, as the opencode preset does.
