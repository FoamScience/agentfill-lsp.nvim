-- The agent's rewritten region as an lsp.InlineCompletionItem, positions in utf-8 bytes
local api = vim.api

local M = {}

local function position(row, col)
    return { line = row, character = col }
end

-- req: buf, row, col, first (0-based first region row), old (region lines), before (region text up to the cursor).
-- Sets req.deleted to the 0-based end-exclusive row ranges the item replaces.
function M.from_reply(req, text)
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

-- buffer rows req.item leaves behind once accepted, to recognize the accept
function M.expectation(req)
    local r = req.item.range
    local lines = api.nvim_buf_get_lines(req.buf, r.start.line, r["end"].line + 1, false)
    local text = lines[1]:sub(1, r.start.character) .. req.item.insertText .. lines[#lines]:sub(r["end"].character + 1)
    return { row = r.start.line, lines = vim.split(text, "\n", { plain = true }) }
end

return M
