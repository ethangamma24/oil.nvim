local M = {}

---@alias oil.InternalEntry string[]

---@class oil.Entry
---@field name string
---@field type oil.EntryType
---@field id nil|string Will be nil if it hasn't been persisted to disk yet

---@alias oil.EntryType "file"|"directory"|"socket"|"link"
---@alias oil.TextChunk string|string[]

---@class oil.Adapter
---@field name string
---@field list fun(path: string, cb: fun(err: nil|string, entries: nil|oil.InternalEntry[]))
---@field is_modifiable fun(bufnr: integer): boolean
---@field get_column fun(name: string): nil|oil.ColumnDefinition
---@field normalize_url fun(url: string, callback: fun(url: string))
---@field get_parent nil|fun(bufname: string): string
---@field supports_xfer nil|table<string, boolean>
---@field render_action nil|fun(action: oil.Action): string
---@field perform_action nil|fun(action: oil.Action, cb: fun(err: nil|string))
---@field read_file fun(bufnr: integer)
---@field write_file fun(bufnr: integer)

---Get the entry on a specific line (1-indexed)
---@param bufnr integer
---@param lnum integer
---@return nil|oil.Entry
M.get_entry_on_line = function(bufnr, lnum)
  local columns = require("oil.columns")
  local config = require("oil.config")
  local parser = require("oil.mutator.parser")
  local util = require("oil.util")
  if vim.bo[bufnr].filetype ~= "oil" then
    return nil
  end
  local bufname = vim.api.nvim_buf_get_name(0)
  local scheme = util.parse_url(bufname)
  local adapter = config.get_adapter_by_scheme(scheme)
  if not adapter then
    return nil
  end

  local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, true)[1]
  if not line then
    return nil
  end
  local column_defs = columns.get_supported_columns(scheme)
  local parsed_entry, entry = parser.parse_line(adapter, line, column_defs)
  if parsed_entry then
    if entry then
      return util.export_entry(entry)
    else
      return {
        name = parsed_entry.name,
        type = parsed_entry._type,
      }
    end
  end
  -- This is a NEW entry that hasn't been saved yet
  local name = vim.trim(line)
  local entry_type
  if vim.endswith(name, "/") then
    name = name:sub(1, name:len() - 1)
    entry_type = "directory"
  else
    entry_type = "file"
  end
  if name == "" then
    return nil
  else
    return {
      name = name,
      type = entry_type,
    }
  end
end

---Get the entry currently under the cursor
---@return nil|oil.Entry
M.get_cursor_entry = function()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  return M.get_entry_on_line(0, lnum)
end

---Discard all changes made to oil buffers
M.discard_all_changes = function()
  local view = require("oil.view")
  for _, bufnr in ipairs(view.get_all_buffers()) do
    if vim.bo[bufnr].modified then
      view.render_buffer_async(bufnr, {}, function(err)
        if err then
          vim.notify(
            string.format(
              "Error rendering oil buffer %s: %s",
              vim.api.nvim_buf_get_name(bufnr),
              err
            ),
            vim.log.levels.ERROR
          )
        end
      end)
    end
  end
end

---Delete all files in the trash directory
---@private
---@note
--- Trash functionality is incomplete and experimental.
M.empty_trash = function()
  local config = require("oil.config")
  local fs = require("oil.fs")
  local util = require("oil.util")
  local trash_url = config.get_trash_url()
  if not trash_url then
    vim.notify("No trash directory configured", vim.log.levels.WARN)
    return
  end
  local _, path = util.parse_url(trash_url)
  local dir = fs.posix_to_os_path(path)
  if vim.fn.isdirectory(dir) == 1 then
    fs.recursive_delete("directory", dir, function(err)
      if err then
        vim.notify(string.format("Error emptying trash: %s", err), vim.log.levels.ERROR)
      else
        vim.notify("Trash emptied")
        fs.mkdirp(dir)
      end
    end)
  end
end

---Change the display columns for oil
---@param cols oil.ColumnSpec[]
M.set_columns = function(cols)
  require("oil.view").set_columns(cols)
end

---Get the current directory
---@return nil|string
M.get_current_dir = function()
  local config = require("oil.config")
  local fs = require("oil.fs")
  local util = require("oil.util")
  local scheme, path = util.parse_url(vim.api.nvim_buf_get_name(0))
  if config.adapters[scheme] == "files" then
    return fs.posix_to_os_path(path)
  end
end

---Get the oil url for a given directory
---@private
---@param dir nil|string When nil, use the cwd
---@return nil|string The parent url
---@return nil|string The basename (if present) of the file/dir we were just in
M.get_url_for_path = function(dir)
  local config = require("oil.config")
  local fs = require("oil.fs")
  if dir then
    local abspath = vim.fn.fnamemodify(dir, ":p")
    local path = fs.os_to_posix_path(abspath)
    return config.adapter_to_scheme.files .. path
  else
    local bufname = vim.api.nvim_buf_get_name(0)
    return M.get_buffer_parent_url(bufname)
  end
end

---@private
---@param bufname string
---@return string
---@return nil|string
M.get_buffer_parent_url = function(bufname)
  local config = require("oil.config")
  local fs = require("oil.fs")
  local pathutil = require("oil.pathutil")
  local util = require("oil.util")
  local scheme, path = util.parse_url(bufname)
  if not scheme then
    local parent, basename
    scheme = config.adapter_to_scheme.files
    if bufname == "" then
      parent = fs.os_to_posix_path(vim.fn.getcwd())
    else
      parent = fs.os_to_posix_path(vim.fn.fnamemodify(bufname, ":p:h"))
      basename = vim.fn.fnamemodify(bufname, ":t")
    end
    local parent_url = util.addslash(scheme .. parent)
    return parent_url, basename
  else
    -- TODO maybe we should remove this special case and turn it into a config
    if scheme == "term://" then
      path = path:match("^(.*)//")
      return config.adapter_to_scheme.files .. util.addslash(path)
    end

    local adapter = config.get_adapter_by_scheme(scheme)
    local parent_url
    if adapter and adapter.get_parent then
      local adapter_scheme = config.adapter_to_scheme[adapter.name]
      parent_url = adapter.get_parent(adapter_scheme .. path)
    else
      local parent = pathutil.parent(path)
      parent_url = scheme .. util.addslash(parent)
    end
    if parent_url == bufname then
      return parent_url
    else
      return util.addslash(parent_url), pathutil.basename(path)
    end
  end
end

---Open oil browser in a floating window
---@param dir nil|string When nil, open the parent of the current buffer, or the cwd if current buffer is not a file
M.open_float = function(dir)
  local config = require("oil.config")
  local util = require("oil.util")
  local view = require("oil.view")
  local parent_url, basename = M.get_url_for_path(dir)
  if not parent_url then
    return
  end
  if basename then
    view.set_last_cursor(parent_url, basename)
  end

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].bufhidden = "wipe"
  local total_width = vim.o.columns
  local total_height = util.get_editor_height()
  local width = total_width - 2 * config.float.padding
  if config.float.border ~= "none" then
    width = width - 2 -- The border consumes 1 col on each side
  end
  if config.float.max_width > 0 then
    width = math.min(width, config.float.max_width)
  end
  local height = total_height - 2 * config.float.padding
  if config.float.max_height > 0 then
    height = math.min(height, config.float.max_height)
  end
  local row = math.floor((total_height - height) / 2)
  local col = math.floor((total_width - width) / 2) - 1 -- adjust for border width
  local winid = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = config.float.border,
    zindex = 45,
  })
  local winleave_autocmd
  winleave_autocmd = vim.api.nvim_create_autocmd("WinLeave", {
    desc = "Close floating oil window",
    group = "Oil",
    callback = vim.schedule_wrap(function()
      if util.is_floating_win() then
        return
      end
      if vim.api.nvim_win_is_valid(winid) then
        vim.api.nvim_win_close(winid, true)
      end
      vim.api.nvim_del_autocmd(winleave_autocmd)
    end),
    nested = true,
  })
  for k, v in pairs(config.float.win_options) do
    vim.api.nvim_win_set_option(winid, k, v)
  end
  vim.cmd.edit({ args = { parent_url }, mods = { keepalt = true } })
  util.add_title_to_win(winid)
end

---Open oil browser for a directory
---@param dir nil|string When nil, open the parent of the current buffer, or the cwd if current buffer is not a file
M.open = function(dir)
  local view = require("oil.view")
  local parent_url, basename = M.get_url_for_path(dir)
  if not parent_url then
    return
  end
  if basename then
    view.set_last_cursor(parent_url, basename)
  end
  vim.cmd.edit({ args = { parent_url }, mods = { keepalt = true } })
end

---Restore the buffer that was present when oil was opened
M.close = function()
  local util = require("oil.util")
  if util.is_floating_win(0) then
    vim.api.nvim_win_close(0, true)
    return
  end
  local ok, bufnr = pcall(vim.api.nvim_win_get_var, 0, "oil_original_buffer")
  if ok then
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_win_set_buf(0, bufnr)
      return
    end
  end
  vim.api.nvim_buf_delete(0, { force = true })
end

---Select the entry under the cursor
---@param opts table
---    vertical boolean Open the buffer in a vertical split
---    horizontal boolean Open the buffer in a horizontal split
---    split "aboveleft"|"belowright"|"topleft"|"botright" Split modifier
---    preview boolean Open the buffer in a preview window
M.select = function(opts)
  local cache = require("oil.cache")
  opts = vim.tbl_extend("keep", opts or {}, {})
  if opts.horizontal or opts.vertical or opts.preview then
    opts.split = opts.split or "belowright"
  end
  if opts.preview and not opts.horizontal and opts.vertical == nil then
    opts.vertical = true
  end
  local util = require("oil.util")
  if util.is_floating_win() and opts.preview then
    vim.notify("oil preview doesn't work in a floating window", vim.log.levels.ERROR)
    return
  end
  local adapter = util.get_adapter(0)
  if not adapter then
    return
  end

  local mode = vim.api.nvim_get_mode().mode
  local is_visual = mode:match("^[vV]")

  local entries = {}
  if is_visual then
    -- This is the best way to get the visual selection at the moment
    -- https://github.com/neovim/neovim/pull/13896
    local _, start_lnum, _, _ = unpack(vim.fn.getpos("v"))
    local _, end_lnum, _, _, _ = unpack(vim.fn.getcurpos())
    if start_lnum > end_lnum then
      start_lnum, end_lnum = end_lnum, start_lnum
    end
    for i = start_lnum, end_lnum do
      local entry = M.get_entry_on_line(0, i)
      if entry then
        table.insert(entries, entry)
      end
    end
  else
    local entry = M.get_cursor_entry()
    if entry then
      table.insert(entries, entry)
    end
  end
  if vim.tbl_isempty(entries) then
    vim.notify("Could not find entry under cursor", vim.log.levels.ERROR)
    return
  end
  if #entries > 1 and opts.preview then
    vim.notify("Cannot preview multiple entries", vim.log.levels.WARN)
    entries = { entries[1] }
  end
  -- Close the preview window
  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_option(winid, "previewwindow") then
      vim.api.nvim_win_close(winid, true)
    end
  end
  local bufname = vim.api.nvim_buf_get_name(0)
  local prev_win = vim.api.nvim_get_current_win()
  for _, entry in ipairs(entries) do
    local scheme, dir = util.parse_url(bufname)
    local child = dir .. entry.name
    local url = scheme .. child
    if
      entry.type == "directory"
      or (
        entry.type == "link"
        and entry.meta
        and entry.meta.link_stat
        and entry.meta.link_stat.type == "directory"
      )
    then
      -- If this is a new directory BUT we think we already have an entry with this name, disallow
      -- entry. This prevents the case of MOVE /foo -> /bar + CREATE /foo.
      -- If you enter the new /foo, it will show the contents of the old /foo.
      if not entry.id and cache.list_url(bufname)[entry.name] then
        vim.notify("Please save changes before entering new directory", vim.log.levels.ERROR)
        return
      end
    else
      if util.is_floating_win() then
        vim.api.nvim_win_close(0, false)
      end
    end
    local mods = {
      vertical = opts.vertical,
      horizontal = opts.horizontal,
      split = opts.split,
    }
    if vim.tbl_isempty(mods) then
      mods = nil
    end
    local cmd = opts.split and "split" or "edit"
    vim.cmd({
      cmd = cmd,
      args = { url },
      mods = mods,
    })
    if opts.preview then
      vim.api.nvim_win_set_option(0, "previewwindow", true)
      vim.api.nvim_win_set_var(0, "oil_entry_id", entry.id)
      vim.api.nvim_set_current_win(prev_win)
    end
    -- Set opts.split so that for every entry after the first, we do a split
    opts.split = opts.split or "belowright"
    if not opts.horizontal and opts.vertical == nil then
      opts.vertical = true
    end
  end
end

---@param bufnr integer
local function maybe_hijack_directory_buffer(bufnr)
  local config = require("oil.config")
  local util = require("oil.util")
  local bufname = vim.api.nvim_buf_get_name(bufnr)
  if bufname == "" then
    return
  end
  if util.parse_url(bufname) or vim.fn.isdirectory(bufname) == 0 then
    return
  end
  util.rename_buffer(
    bufnr,
    util.addslash(config.adapter_to_scheme.files .. vim.fn.fnamemodify(bufname, ":p"))
  )
end

---@private
M._get_highlights = function()
  return {
    {
      name = "OilDir",
      link = "Special",
      desc = "Directories in an oil buffer",
    },
    {
      name = "OilSocket",
      link = "Keyword",
      desc = "Socket files in an oil buffer",
    },
    {
      name = "OilLink",
      link = nil,
      desc = "Soft links in an oil buffer",
    },
    {
      name = "OilFile",
      link = nil,
      desc = "Normal files in an oil buffer",
    },
    {
      name = "OilCreate",
      link = "DiagnosticInfo",
      desc = "Create action in the oil preview window",
    },
    {
      name = "OilDelete",
      link = "DiagnosticError",
      desc = "Delete action in the oil preview window",
    },
    {
      name = "OilMove",
      link = "DiagnosticWarn",
      desc = "Move action in the oil preview window",
    },
    {
      name = "OilCopy",
      link = "DiagnosticHint",
      desc = "Copy action in the oil preview window",
    },
    {
      name = "OilChange",
      link = "Special",
      desc = "Change action in the oil preview window",
    },
  }
end

local function set_colors()
  for _, conf in ipairs(M._get_highlights()) do
    if conf.link then
      vim.api.nvim_set_hl(0, conf.name, { default = true, link = conf.link })
    end
  end
  if not pcall(vim.api.nvim_get_hl_by_name, "FloatTitle") then
    local border = vim.api.nvim_get_hl_by_name("FloatBorder", true)
    local normal = vim.api.nvim_get_hl_by_name("Normal", true)
    vim.api.nvim_set_hl(
      0,
      "FloatTitle",
      { fg = normal.foreground, bg = border.background or normal.background }
    )
  end
end

---Save all changes
---@param opts nil|table
---    confirm nil|boolean Show confirmation when true, never when false, respect skip_confirm_for_simple_edits if nil
M.save = function(opts)
  opts = opts or {}
  local mutator = require("oil.mutator")
  mutator.try_write_changes(opts.confirm)
end

local function restore_alt_buf()
  local config = require("oil.config")
  local view = require("oil.view")
  if vim.bo.filetype == "oil" then
    view.set_win_options()
    vim.api.nvim_win_set_var(0, "oil_did_enter", true)
  elseif vim.w.oil_did_enter then
    vim.api.nvim_win_del_var(0, "oil_did_enter")
    -- We are entering a non-oil buffer *after* having been in an oil buffer
    local has_orig, orig_buffer = pcall(vim.api.nvim_win_get_var, 0, "oil_original_buffer")
    if has_orig and vim.api.nvim_buf_is_valid(orig_buffer) then
      if vim.api.nvim_get_current_buf() ~= orig_buffer then
        -- If we are editing a new file after navigating around oil, set the alternate buffer
        -- to be the last buffer we were in before opening oil
        vim.fn.setreg("#", orig_buffer)
      else
        -- If we are editing the same buffer that we started oil from, set the alternate to be
        -- what it was before we opened oil
        local has_orig_alt, alt_buffer =
          pcall(vim.api.nvim_win_get_var, 0, "oil_original_alternate")
        if has_orig_alt and vim.api.nvim_buf_is_valid(alt_buffer) then
          vim.fn.setreg("#", alt_buffer)
        end
      end
    end

    if config.restore_win_options then
      view.restore_win_options()
    end
  end
end

---@param bufnr integer
local function load_oil_buffer(bufnr)
  local config = require("oil.config")
  local keymap_util = require("oil.keymap_util")
  local loading = require("oil.loading")
  local util = require("oil.util")
  local view = require("oil.view")
  local bufname = vim.api.nvim_buf_get_name(bufnr)
  local scheme, path = util.parse_url(bufname)
  if config.adapter_aliases[scheme] then
    scheme = config.adapter_aliases[scheme]
    bufname = scheme .. path
    util.rename_buffer(bufnr, bufname)
  end

  local adapter = config.get_adapter_by_scheme(scheme)

  if vim.endswith(bufname, "/") then
    -- This is a small quality-of-life thing. If the buffer name ends with a `/`, we know it's a
    -- directory, and can set the filetype early. This is helpful for adapters with a lot of latency
    -- (e.g. ssh) because it will set up the filetype keybinds at the *beginning* of the loading
    -- process.
    vim.bo[bufnr].filetype = "oil"
    keymap_util.set_keymaps("", config.keymaps, bufnr)
  end
  loading.set_loading(bufnr, true)
  local function finish(new_url)
    if new_url ~= bufname then
      if util.rename_buffer(bufnr, new_url) then
        -- If the buffer was replaced then don't initialize it. It's dead. The replacement will
        -- have BufReadCmd called for it
        return
      end
      bufname = new_url
    end
    if vim.endswith(bufname, "/") then
      vim.cmd.doautocmd({ args = { "BufReadPre", bufname }, mods = { emsg_silent = true } })
      view.initialize(bufnr)
      vim.cmd.doautocmd({ args = { "BufReadPost", bufname }, mods = { emsg_silent = true } })
    else
      vim.bo[bufnr].buftype = "acwrite"
      adapter.read_file(bufnr)
    end
    restore_alt_buf()
  end

  adapter.normalize_url(bufname, finish)
end

---Initialize oil
---@param opts nil|table
M.setup = function(opts)
  local config = require("oil.config")

  config.setup(opts)
  set_colors()
  vim.api.nvim_create_user_command("Oil", function(args)
    local float = false
    for i, v in ipairs(args.fargs) do
      if v == "--float" then
        float = true
        table.remove(args.fargs, i)
      end
    end
    local method = float and "open_float" or "open"
    M[method](unpack(args.fargs))
  end, { desc = "Open oil file browser on a directory", nargs = "*", complete = "dir" })
  local aug = vim.api.nvim_create_augroup("Oil", {})
  if vim.fn.exists("#FileExplorer") then
    vim.api.nvim_create_augroup("FileExplorer", { clear = true })
  end

  local patterns = {}
  local filetype_patterns = {}
  for scheme in pairs(config.adapters) do
    table.insert(patterns, scheme .. "*")
    filetype_patterns[scheme .. ".*"] = { "oil", { priority = 10 } }
  end
  for scheme in pairs(config.adapter_aliases) do
    table.insert(patterns, scheme .. "*")
    filetype_patterns[scheme .. ".*"] = { "oil", { priority = 10 } }
  end
  local scheme_pattern = table.concat(patterns, ",")
  -- We need to add these patterns to the filetype matcher so the filetype doesn't get overridden
  -- by other patterns. See https://github.com/stevearc/oil.nvim/issues/47
  vim.filetype.add({
    pattern = filetype_patterns,
  })

  vim.api.nvim_create_autocmd("ColorScheme", {
    desc = "Set default oil highlights",
    group = aug,
    pattern = "*",
    callback = set_colors,
  })
  vim.api.nvim_create_autocmd("BufReadCmd", {
    group = aug,
    pattern = scheme_pattern,
    nested = true,
    callback = function(params)
      load_oil_buffer(params.buf)
    end,
  })
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = aug,
    pattern = scheme_pattern,
    nested = true,
    callback = function(params)
      local bufname = vim.api.nvim_buf_get_name(params.buf)
      if vim.endswith(bufname, "/") then
        vim.cmd.doautocmd({ args = { "BufWritePre", params.file }, mods = { silent = true } })
        M.save()
        vim.bo[params.buf].modified = false
        vim.cmd.doautocmd({ args = { "BufWritePost", params.file }, mods = { silent = true } })
      else
        local adapter = config.get_adapter_by_scheme(bufname)
        adapter.write_file(params.buf)
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWinLeave", {
    desc = "Save alternate buffer for later",
    group = aug,
    pattern = "*",
    callback = function()
      local util = require("oil.util")
      if not util.is_oil_bufnr(0) then
        vim.api.nvim_win_set_var(0, "oil_original_buffer", vim.api.nvim_get_current_buf())
        vim.api.nvim_win_set_var(0, "oil_original_alternate", vim.fn.bufnr("#"))
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWinEnter", {
    desc = "Set/unset oil window options and restore alternate buffer",
    group = aug,
    pattern = "*",
    callback = function()
      local util = require("oil.util")
      local view = require("oil.view")
      local bufname = vim.api.nvim_buf_get_name(0)
      local scheme = util.parse_url(bufname)
      if scheme and config.adapters[scheme] then
        view.maybe_set_cursor()
      elseif vim.fn.isdirectory(bufname) == 0 then
        -- Only run this logic if we are *not* in an oil buffer (and it's not a directory, which
        -- will be replaced by an oil:// url)
        -- Oil buffers have to run it in BufReadCmd after confirming they are a directory or a file
        restore_alt_buf()
      end
    end,
  })
  if not config.silence_scp_warning then
    vim.api.nvim_create_autocmd("BufNew", {
      desc = "Warn about scp:// usage",
      group = aug,
      pattern = "scp://*",
      once = true,
      callback = function()
        vim.notify(
          "If you are trying to browse using Oil, use oil-ssh:// instead of scp://\nSet `silence_scp_warning = true` in oil.setup() to disable this message.\nSee https://github.com/stevearc/oil.nvim/issues/27 for more information.",
          vim.log.levels.WARN
        )
      end,
    })
  end
  if vim.g.loaded_netrwPlugin ~= 1 and not config.silence_netrw_warning then
    vim.api.nvim_create_autocmd("FileType", {
      desc = "Inform user how to disable netrw",
      group = aug,
      pattern = "netrw",
      once = true,
      callback = function()
        vim.notify(
          "If you expected an Oil buffer here, you may want to disable netrw (:help netrw-noload)\nSet `silence_netrw_warning = true` in oil.setup() to disable this message.",
          vim.log.levels.WARN
        )
      end,
    })
  end
  vim.api.nvim_create_autocmd("WinNew", {
    desc = "Restore window options when splitting an oil window",
    group = aug,
    pattern = "*",
    nested = true,
    callback = function(params)
      local util = require("oil.util")
      if not util.is_oil_bufnr(params.buf) or vim.w.oil_did_enter then
        return
      end
      -- This new window is a split off of an oil window. We need to transfer the window
      -- variables. First, locate the parent window
      local parent_win
      -- First search windows in this tab, then search all windows
      local winids = vim.list_extend(vim.api.nvim_tabpage_list_wins(0), vim.api.nvim_list_wins())
      for _, winid in ipairs(winids) do
        if vim.api.nvim_win_is_valid(winid) then
          if vim.w[winid].oil_did_enter then
            parent_win = winid
            break
          end
        end
      end
      if not parent_win then
        vim.notify(
          "Oil split could not find parent window. Please try to replicate whatever you just did and report a bug on github",
          vim.log.levels.WARN
        )
        return
      end
      -- Then transfer over the relevant window vars
      vim.w.oil_did_enter = true
      local has_orig, orig_buffer =
        pcall(vim.api.nvim_win_get_var, parent_win, "oil_original_buffer")
      if has_orig and vim.api.nvim_buf_is_valid(orig_buffer) then
        vim.w.oil_original_buffer = orig_buffer
      end
      local has_orig_alt, alt_buffer =
        pcall(vim.api.nvim_win_get_var, parent_win, "oil_original_alternate")
      if has_orig_alt and vim.api.nvim_buf_is_valid(alt_buffer) then
        vim.w.oil_original_alternate = alt_buffer
      end
      for k in pairs(config.win_options) do
        local varname = "_oil_" .. k
        local has_opt, opt = pcall(vim.api.nvim_win_get_var, parent_win, varname)
        if has_opt then
          vim.api.nvim_win_set_option(0, k, opt)
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufAdd", {
    desc = "Detect directory buffer and open oil file browser",
    group = aug,
    pattern = "*",
    nested = true,
    callback = function(params)
      maybe_hijack_directory_buffer(params.buf)
    end,
  })
  -- mksession doesn't save oil buffers in a useful way. We have to manually load them after a
  -- session finishes loading. See https://github.com/stevearc/oil.nvim/issues/29
  vim.api.nvim_create_autocmd("SessionLoadPost", {
    desc = "Load oil buffers after a session is loaded",
    group = aug,
    pattern = "*",
    callback = function(params)
      local util = require("oil.util")
      for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        local bufname = vim.api.nvim_buf_get_name(bufnr)
        local scheme = util.parse_url(bufname)
        if config.adapters[scheme] and vim.api.nvim_buf_line_count(bufnr) == 1 then
          load_oil_buffer(bufnr)
        end
      end
    end,
  })

  maybe_hijack_directory_buffer(0)
end

return M
