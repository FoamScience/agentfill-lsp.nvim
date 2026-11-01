<div align="center">

# agentfill-lsp.nvim

**Coding agents as an inline completion source for Neovim**

![Neovim](https://img.shields.io/badge/Neovim-0.12%2B-57A143?logo=neovim&logoColor=white)
![Lua](https://img.shields.io/badge/Lua-2C2D72?logo=lua&logoColor=white)
![Agents](https://img.shields.io/badge/agents-Claude%20Code%20%7C%20ACP-D97757)

</div>

An in-process language server answers `textDocument/inlineCompletion` for Neovim's built-in
`vim.lsp.inline_completion`. Suggestions come from a long-lived agent session.

## Features

- **Manual trigger:** press `<M-c>` in insert mode. Accept and cycle with whatever you map to
  `vim.lsp.inline_completion.get()` / `.select()`.
- **Region rewrites:** the model rewrites a small region around the cursor, so a suggestion can
  also change the lines after the cursor. Neovim shows the new text as ghost text, the lines it
  replaces are highlighted with `hl_delete`, and accepting applies it as one range.
- **Context:** each request carries:
  - the surrounding lines and the file header
  - LSP definitions of identifiers near the cursor (or imported files' outlines when no LSP answers)
  - [m2v.nvim](https://github.com/FoamScience/m2v.nvim) semantic search hits, when that plugin is installed
- **Metrics:** `:AFStats` reports outcomes, latency, tokens and cost.
- **No tools:** see [Safety](#safety).

## Agents

| Agent | Backend | Notes |
|---|---|---|
| `claude` *(default)* | native `claude -p` stream-json | Claude Code subscription, no API key. Runs with no tools, no settings, no MCP and its own system prompt. |
| `opencode` | ACP (`opencode acp`) | Uses a tool-less `agentfill` agent injected through `OPENCODE_CONFIG_CONTENT`, selected as the session mode. |

Any other [Agent Client Protocol](https://agentclientprotocol.com) agent can be added under
`agents` with `backend = "acp"`.

## Install

### Requirements

- Neovim with `vim.lsp.inline_completion` (0.12+)
- the CLI of the agent you use (`claude` or `opencode`) on `$PATH`

### lazy.nvim

```lua
{
    "FoamScience/agentfill-lsp.nvim",
    main = "agentfill",
    -- start its client before other LSP servers so its suggestion sorts first
    lazy = false,
    opts = {},
}
```

### Enable inline completion

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

> [!TIP]
> Context sources can be turned off one by one with `defs = false`, `imports = false` and
> `search = false`.

### ACP agent fields

| Field | Default | Description |
|---|---|---|
| `cmd` | | Command list |
| `env` | | Extra environment for the agent process |
| `mode` | | Value for the session's `mode` config option; the session refuses to start if it cannot be applied |
| `model` | | Value for the session's `model` config option (warns when it cannot be applied) |
| `tool_guard` | `true` | Cancel any turn in which the agent starts a tool call |

## Metrics

`:AFStats` opens a float with this Neovim instance's numbers next to all-time totals, plus the
last 10 requests:

| Metric | Details |
|---|---|
| Outcomes | shown, accepted (the first insert-mode edit after a suggestion matches it), no suggestion, discarded (buffer or cursor moved), superseded, error |
| Latency p50/p90 | context gathering, agent turn, total |
| Tokens per turn | input, cached, output, and cost, as reported by the agent |
| Prompt size | characters, split by part (excerpt, header, definitions, import outlines, search hits) with counts |
| Current session | turns used of `max_turns`, context used / window |

Every request is appended as one JSON line to `stdpath("state")/agentfill/requests.jsonl`.

> [!NOTE]
> Claude input counts cache reads and cache writes; ACP agents report their own `inputTokens`,
> so the two are not directly comparable.

With `debug = true`, each entry also carries the cursor, the editable region, the agent's raw
reply, the inline completion item and the virtual text Neovim drew for it (`drawn`; empty when
nothing was visible).

## Safety

Completions never need tools. The client:

- advertises no filesystem or terminal capabilities
- answers every permission request with `cancelled`
- cancels a turn as soon as a tool call starts (with `tool_guard`)

> [!WARNING]
> A guard cannot undo a tool that ran before the cancel arrived. An ACP agent without a tool-less
> `mode` can still act in its working directory (`stdpath("cache")/agentfill`) or on absolute
> paths, so give every ACP agent a deny-all mode, as the opencode preset does.
