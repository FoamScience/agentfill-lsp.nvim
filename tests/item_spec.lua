-- nvim --headless -l tests/item_spec.lua
vim.opt.rtp:prepend(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h"))
local item = require("agentfill.item")

local failures = 0

local function test(name, fn)
    local ok, err = pcall(fn)
    print(("%s %s"):format(ok and "ok  " or "FAIL", name))
    if not ok then
        failures = failures + 1
        print("     " .. tostring(err))
    end
end

local function eq(expected, actual)
    if not vim.deep_equal(expected, actual) then
        error(("expected %s, got %s"):format(vim.inspect(expected), vim.inspect(actual)), 2)
    end
end

-- request over the whole buffer, cursor at 0-based row/col
local function req_for(lines, row, col)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    local before = vim.list_slice(lines, 1, row + 1)
    before[#before] = before[#before]:sub(1, col)
    return {
        buf = buf,
        row = row,
        col = col,
        first = 0,
        last = #lines,
        old = vim.deepcopy(lines),
        before = table.concat(before, "\n"),
    }
end

local function reply(lines)
    return "<region>\n" .. table.concat(lines, "\n") .. "\n</region>"
end

-- accepting the item turns the buffer into the reply, and expectation predicts it
local function accept(req, new)
    req.item = item.from_reply(req, reply(new))
    assert(req.item, "no item")
    local expect = item.expectation(req)
    local r = req.item.range
    vim.api.nvim_buf_set_text(
        req.buf,
        r.start.line,
        r.start.character,
        r["end"].line,
        r["end"].character,
        vim.split(req.item.insertText, "\n", { plain = true })
    )
    local lines = vim.api.nvim_buf_get_lines(req.buf, 0, -1, false)
    eq(new, lines)
    eq(expect.lines, vim.list_slice(lines, expect.row + 1, expect.row + #expect.lines))
end

test("insertion at the cursor", function()
    local req = req_for({ "local x = ", "return x" }, 0, 10)
    local it = item.from_reply(req, reply({ "local x = 1", "return x" }))
    eq(
        { insertText = "1", range = { start = { line = 0, character = 10 }, ["end"] = { line = 0, character = 10 } } },
        it
    )
    accept(req_for({ "local x = ", "return x" }, 0, 10), { "local x = 1", "return x" })
end)

test("reply without region tags", function()
    eq(nil, item.from_reply(req_for({ "a" }, 0, 1), "a\nb"))
end)

test("code fences and the cursor marker are stripped", function()
    local req = req_for({ "f(", ")" }, 0, 2)
    local it = item.from_reply(req, "<region>\n```lua\nf(x<CURSOR>\n)\n```\n</region>")
    eq({ insertText = "x", range = { start = { line = 0, character = 2 }, ["end"] = { line = 0, character = 2 } } }, it)
end)

test("unchanged region is no suggestion", function()
    eq(nil, item.from_reply(req_for({ "a", "b" }, 0, 1), reply({ "a", "b" })))
end)

test("dropping the blank cursor line is no suggestion", function()
    eq(nil, item.from_reply(req_for({ "a", "", "b" }, 1, 0), reply({ "a", "b" })))
end)

test("rewrite of a later line", function()
    local req = req_for({ "a", "b", "c" }, 0, 1)
    local it = item.from_reply(req, reply({ "a", "B", "c" }))
    eq({ { 1, 2 } }, req.deleted)
    eq("\nB", it.insertText)
    eq({ start = { line = 0, character = 1 }, ["end"] = { line = 1, character = 1 } }, it.range)
    accept(req_for({ "a", "b", "c" }, 0, 1), { "a", "B", "c" })
end)

test("rewrite of the first line", function()
    accept(req_for({ "a", "b" }, 1, 1), { "A", "b" })
end)

test("pure addition after a line", function()
    local req = req_for({ "ab", "c" }, 0, 1)
    local it = item.from_reply(req, reply({ "ab", "X", "c" }))
    eq(
        { insertText = "\nX", range = { start = { line = 0, character = 2 }, ["end"] = { line = 0, character = 2 } } },
        it
    )
    accept(req_for({ "ab", "c" }, 0, 1), { "ab", "X", "c" })
end)

test("pure addition above the first region row", function()
    accept(req_for({ "b", "c" }, 1, 0), { "a", "b", "c" })
end)

test("hunks spanning unchanged lines", function()
    accept(req_for({ "a", "b", "c", "d" }, 0, 0), { "A", "b", "c", "D" })
end)

if failures > 0 then
    print(failures .. " failed")
    os.exit(1)
end
