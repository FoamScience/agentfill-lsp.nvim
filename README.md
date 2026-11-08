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

- **Manual trigger:** press `<M-c>` in insert mode. Accept and cycle keys are optional (see
  [Keys](#keys)).
- **Region rewrites:** the model rewrites a small region around the cursor, so a suggestion can
  also change the lines after the cursor. Neovim shows the new text as ghost text, the lines it
  replaces are highlighted with `hl_delete`, and accepting applies it as one range.
- **Context:** each request carries:
  - the surrounding lines and the file header
  - LSP definitions of identifiers near the cursor (or imported files' outlines when no LSP answers)
  - [m2v.nvim](https://github.com/FoamScience/m2v.nvim) semantic search hits, when that plugin is installed
- **Runtime control:** switch agents, restart the session or pause suggestions without
  restarting Neovim (see [Commands](#commands)).
- **Filtering:** attach by filetype allow and deny lists, skipping files over `max_file_bytes`.
- **Metrics:** `:Agentfill stats` reports outcomes, latency, tokens and cost.
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
- optional: [m2v.nvim](https://github.com/FoamScience/m2v.nvim), which adds semantic search hits
  to each request's context

### lazy.nvim

```lua
{
    "FoamScience/agentfill-lsp.nvim",
    main = "agentfill",
    -- optional: semantic search context
    dependencies = { "FoamScience/m2v.nvim" },
    -- start its client before other LSP servers so its suggestion sorts first
    lazy = false,
    opts = {},
}
```

No `setup()` call is needed: without one the client starts on `VimEnter` with the defaults
merged with `vim.g.agentfill`. `setup(opts)` can be called again at any time to change options.

Run `:checkhealth agentfill` to check the setup.

## Configuration

Every option and its default lives in
[`lua/agentfill/config.lua`](lua/agentfill/config.lua), also readable at runtime as
`require("agentfill.config").defaults` (the active config is `require("agentfill").config`).
Options go to `setup(opts)` or, before the plugin loads, to `vim.g.agentfill`. Values of the
wrong type raise an error naming the option. For example:

```lua
opts = {
    agent = "opencode",
    agents = {
        opencode = { model = "nvidia/openai/gpt-oss-20b" },
        -- any ACP agent:
        -- myagent = { backend = "acp", cmd = { "my-agent", "--acp" }, mode = "...", env = { ... } },
    },
    max_turns = 8, -- restart the session after this many completions
    keys = { trigger = "<M-c>", accept = "<Tab>", next = "<M-]>", prev = "<M-[>" },
    enable_inline = true, -- enable vim.lsp.inline_completion where the client attaches
    filetypes = nil, -- attach only to these filetypes; nil attaches to all
    exclude_filetypes = { "gitcommit" },
    hl_delete = "AgentfillDelete", -- lines a suggestion replaces, shown next to the ghost text; false disables
}
```

> [!TIP]
> Context sources can be turned off one by one with `defs = false`, `imports = false` and
> `search = false`.

The client attaches to named, normal buffers that pass the filetype filters and are no larger
than `max_file_bytes` (512 KiB by default). The trigger does nothing in other buffers.

### Keys

All keys are insert-mode mappings. Set a key to `false` to skip its mapping.

| Key | Default | Action |
|---|---|---|
| `trigger` | `<M-c>` | Request a suggestion; `<Plug>(agentfill-trigger)` is always mapped too |
| `accept` | `false` | `vim.lsp.inline_completion.get()`; types the key itself when no suggestion is shown |
| `next` / `prev` | `false` | `vim.lsp.inline_completion.select()` forward / backward |

### Commands

| Command | Action |
|---|---|
| `:Agentfill agent [name]` | Show the agent, or switch to `name` and start a new session |
| `:Agentfill restart` | Start a new agent session |
| `:Agentfill toggle` | Turn suggestions off or on |
| `:Agentfill stats` | Show request metrics (see [Metrics](#metrics)) |

The same actions are Lua functions: `require("agentfill").agent(name)`, `.restart()`,
`.toggle()`, `.stats()` and `.trigger()`.

### Highlights

| Group | Default | Used for |
|---|---|---|
| `AgentfillDelete` | links to `DiffDelete` | lines a suggestion replaces |

### ACP agent fields

| Field | Default | Description |
|---|---|---|
| `cmd` | | Command list |
| `env` | | Extra environment for the agent process |
| `mode` | | Value for the session's `mode` config option; the session refuses to start if it cannot be applied |
| `model` | | Value for the session's `model` config option (warns when it cannot be applied) |
| `tool_guard` | `true` | Cancel any turn in which the agent starts a tool call |

## Metrics

`:Agentfill stats` opens a float with this Neovim instance's numbers next to all-time totals, plus the
last 10 requests:

| Metric | Details |
|---|---|
| Outcomes | shown, accepted (the first insert-mode edit after a suggestion matches it), no suggestion, discarded (buffer or cursor moved), superseded (by a newer request or a session restart), error |
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

## Development

```sh
nvim --clean --headless -l tests/item_spec.lua
stylua --check lua plugin tests
```

See `:h agentfill` for the full reference.
