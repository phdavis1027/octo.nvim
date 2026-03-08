local config = require "octo.config"
local vim = vim

local M = {}

M._threads = {}
M._repo = nil
M._pr = nil

local function graphql_query(pr_number)
  local owner, name = M._repo:match("^(.+)/(.+)$")
  return string.format(
    [[
query {
  repository(owner: "%s", name: "%s") {
    pullRequest(number: %s) {
      reviewThreads(first: 100) {
        nodes {
          id
          isResolved
          line
          originalLine
          path
          diffSide
          comments(first: 1) {
            nodes {
              body
              diffHunk
            }
          }
        }
      }
    }
  }
}]],
    owner,
    name,
    pr_number
  )
end

function M.load(pr_number)
  local gh_cmd = config.values and config.values.gh_cmd or "gh"
  M._repo = vim.trim(vim.fn.system(gh_cmd .. " repo view --json nameWithOwner -q .nameWithOwner"))
  if vim.v.shell_error ~= 0 then
    vim.notify("Failed to detect repo", vim.log.levels.ERROR)
    return
  end
  M._pr = pr_number

  local query = graphql_query(pr_number)
  local cmd = { gh_cmd, "api", "graphql", "-f", "query=" .. query }

  vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      local raw = table.concat(data, "\n")
      local ok, parsed = pcall(vim.json.decode, raw)
      if not ok or not parsed.data then
        vim.schedule(function()
          vim.notify("Failed to parse GraphQL response", vim.log.levels.ERROR)
        end)
        return
      end

      local threads = parsed.data.repository.pullRequest.reviewThreads.nodes
      M._threads = {}
      local items = {}

      for _, thread in ipairs(threads) do
        if not thread.isResolved then
          local comment = thread.comments.nodes[1]
          if comment then
            local lnum = tonumber(thread.line or thread.originalLine) or 1
            local entry = {
              thread_id = thread.id,
              diff_hunk = comment.diffHunk or "",
              body = comment.body or "",
              path = thread.path,
              lnum = lnum,
              resolved = false,
            }
            table.insert(M._threads, entry)
            table.insert(items, {
              filename = thread.path,
              lnum = lnum,
              text = comment.body:gsub("\n", " "):sub(1, 120),
            })
          end
        end
      end

      vim.schedule(function()
        if #items == 0 then
          vim.notify("No unresolved comments on PR #" .. pr_number, vim.log.levels.INFO)
          return
        end

        vim.fn.setqflist({}, " ", {
          title = "PR #" .. pr_number .. " comments",
          items = items,
        })
        vim.cmd "copen"

        local qf_buf = vim.api.nvim_get_current_buf()
        vim.keymap.set("n", "p", function()
          M.preview()
        end, { buffer = qf_buf, desc = "Preview diff hunk" })
        vim.keymap.set("n", "R", function()
          M.resolve()
        end, { buffer = qf_buf, desc = "Resolve thread" })

        vim.notify(
          string.format("Loaded %d unresolved comments from PR #%s  |  p=preview  R=resolve", #items, pr_number),
          vim.log.levels.INFO
        )
      end)
    end,
    on_stderr = function(_, data)
      local err = vim.trim(table.concat(data, "\n"))
      if err ~= "" then
        vim.schedule(function()
          vim.notify("gh error: " .. err, vim.log.levels.ERROR)
        end)
      end
    end,
  })
end

function M.preview()
  local idx = vim.fn.line "."
  local thread = M._threads[idx]
  if not thread then
    return
  end

  local lines = {}
  table.insert(lines, "--- " .. thread.path .. " ---")
  table.insert(lines, "")
  for hunk_line in thread.diff_hunk:gmatch "[^\n]+" do
    table.insert(lines, hunk_line)
  end
  table.insert(lines, "")
  table.insert(lines, string.rep("\xe2\x94\x80", 60))
  table.insert(lines, "")
  for body_line in thread.body:gmatch "[^\n]+" do
    table.insert(lines, body_line)
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "diff"
  vim.bo[buf].bufhidden = "wipe"

  local width = math.min(90, vim.o.columns - 10)
  local height = math.min(#lines + 2, vim.o.lines - 10)
  vim.api.nvim_open_win(buf, true, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " Comment " .. idx .. "/" .. #M._threads .. " ",
    title_pos = "center",
  })

  vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = buf })
  vim.keymap.set("n", "<Esc>", "<cmd>close<cr>", { buffer = buf })
end

function M.resolve()
  local gh_cmd = config.values and config.values.gh_cmd or "gh"
  local idx = vim.fn.line "."
  local thread = M._threads[idx]
  if not thread then
    return
  end
  if thread.resolved then
    vim.notify("Already resolved", vim.log.levels.INFO)
    return
  end

  local mutation = string.format(
    'mutation { resolveReviewThread(input: {threadId: "%s"}) { thread { isResolved } } }',
    thread.thread_id
  )

  vim.fn.jobstart({ gh_cmd, "api", "graphql", "-f", "query=" .. mutation }, {
    stdout_buffered = true,
    on_stdout = function()
      thread.resolved = true
      vim.schedule(function()
        vim.notify(
          string.format("Resolved: %s:%d", thread.path, tonumber(thread.lnum) or 0),
          vim.log.levels.INFO
        )
      end)
    end,
    on_stderr = function(_, data)
      local err = vim.trim(table.concat(data, "\n"))
      if err ~= "" then
        vim.schedule(function()
          vim.notify("Resolve failed: " .. err, vim.log.levels.ERROR)
        end)
      end
    end,
  })
end

return M
