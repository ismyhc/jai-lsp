-- jai-lsp.nvim — Neovim plugin for the Jai language server.
--
-- Layered on top of:
--   * vim.lsp (built-in, Neovim 0.8+)
--   * nvim-treesitter (optional, for syntax highlighting via the
--     constantitus/tree-sitter-jai grammar)
--
-- Usage (lazy.nvim / LazyVim):
--
--     {
--       "ismyhc/jai-lsp",
--       ft = "jai",
--       opts = {
--         server_path   = "jai-lsp",  -- or absolute path
--         compiler_path = "/abs/path/to/jai/bin/jai-macos",
--         entry_file    = "/abs/path/to/project/main.jai",
--         inlay_hints   = true,
--       },
--     }
--
-- `opts` (or call `require('jai-lsp').setup({...})`) is everything — no
-- other glue needed. Filetype detection, tree-sitter parser registration,
-- and LSP attach all happen here.

local M = {}

-- GitHub release the plugin auto-downloads from when no binary is
-- otherwise resolvable. Bump on each jai-lsp release.
local GITHUB_REPO    = "ismyhc/jai-lsp"
local BINARY_VERSION = "v0.1.0"

M.config = {
    server_path   = "jai-lsp",
    compiler_path = nil,
    entry_file    = nil,
    inlay_hints   = true,
    -- Optional. When set, used as the LSP root_dir verbatim. When unset
    -- we walk upward from the open file looking for `.git`, `build.jai`,
    -- `first.jai`, `main.jai`, or `.jai-root` and use the dir containing
    -- the first match.
    root_dir      = nil,
    -- When true (default), if `server_path` doesn't resolve to an existing
    -- executable AND `jai-lsp` isn't on PATH, the plugin downloads the
    -- matching binary from the GitHub release and caches it under
    -- vim.fn.stdpath('data').."/jai-lsp/". Set false to disable.
    auto_install  = true,
}

local function apply_env(cfg)
    -- Forward to the spawned LSP process. vim.lsp.start inherits the parent
    -- process env, so setting via vim.env propagates to the child.
    if cfg.compiler_path and cfg.compiler_path ~= "" then
        vim.env.JAI_COMPILER = cfg.compiler_path
    end
    if cfg.entry_file and cfg.entry_file ~= "" then
        vim.env.JAI_LSP_ENTRY_FILE = cfg.entry_file
    end
    vim.env.JAI_LSP_INLAY_HINTS = cfg.inlay_hints and "1" or "0"
end

-- Register .jai files as the `jai` filetype. The ftdetect/jai.lua file does
-- this lazily too; doing it here means it works even if the user disables
-- the ftdetect dir.
local function register_filetype()
    vim.filetype.add({
        extension = { jai = "jai" },
    })
end

-- If the legacy nvim-treesitter API is available, plug our parser config
-- in so `:TSInstall jai` works. Wrapped in pcall because the newer
-- nvim-treesitter rewrite (the "main" branch LazyVim has been moving to)
-- removed `get_parser_configs` — on that version this function silently
-- no-ops and the user installs the parser through the newer mechanism.
local function register_treesitter_parser(cfg)
    local ok, parsers = pcall(require, "nvim-treesitter.parsers")
    if not ok then return end
    if type(parsers.get_parser_configs) ~= "function" then
        -- New nvim-treesitter (main branch) — no custom parser config here.
        -- Users on that version typically install grammars via
        -- `require('nvim-treesitter').install({'jai'})` after registering
        -- the parser source in their own config.
        return
    end
    local ok2, pc = pcall(parsers.get_parser_configs)
    if not ok2 or not pc then return end
    if pc.jai then return end   -- another plugin already registered it
    pc.jai = cfg.parser_config or {
        install_info = {
            url      = "https://github.com/constantitus/tree-sitter-jai",
            files    = { "src/parser.c", "src/scanner.c" },
            branch   = "master",
        },
        filetype = "jai",
    }
end

-- Map vim.uv.os_uname() to our binary naming scheme.
local function platform_arch()
    local uname = vim.uv.os_uname()
    local os_str
    if uname.sysname == "Darwin"  then os_str = "darwin"
    elseif uname.sysname == "Linux" then os_str = "linux"
    elseif uname.sysname:find("Windows") then os_str = "windows"
    else os_str = uname.sysname:lower() end

    local arch_str
    local m = uname.machine
    if m == "arm64" or m == "aarch64" then arch_str = "arm64"
    elseif m == "x86_64" or m == "amd64" then arch_str = "x64"
    else arch_str = m end

    local ext = (os_str == "windows") and ".exe" or ""
    return os_str, arch_str, ext
end

local function executable_exists(path)
    if not path or path == "" then return false end
    if path:find("/") then
        local st = vim.uv.fs_stat(path)
        return st ~= nil
    end
    return vim.fn.executable(path) == 1
end

-- If `server_path` doesn't point at an existing binary and `jai-lsp` isn't
-- on PATH, fetch the matching release asset into a cache dir under
-- stdpath('data') and return its path. Returns the original server_path
-- on failure so the user gets the standard "not found" error.
local function ensure_binary(cfg)
    if executable_exists(cfg.server_path) then return cfg.server_path end
    if vim.fn.executable("jai-lsp") == 1     then return "jai-lsp" end
    if not cfg.auto_install                  then return cfg.server_path end

    local os_str, arch_str, ext = platform_arch()
    local name      = string.format("jai-lsp-%s-%s%s", os_str, arch_str, ext)
    local cache_dir = string.format("%s/jai-lsp/%s", vim.fn.stdpath("data"), BINARY_VERSION)
    local dest      = string.format("%s/%s", cache_dir, name)

    if executable_exists(dest) then return dest end

    vim.fn.mkdir(cache_dir, "p")

    local url = string.format(
        "https://github.com/%s/releases/download/%s/%s",
        GITHUB_REPO, BINARY_VERSION, name
    )

    vim.notify(string.format("jai-lsp: downloading %s ...", name), vim.log.levels.INFO)
    local result = vim.fn.system({ "curl", "-fL", "--silent", "--show-error", "-o", dest, url })
    if vim.v.shell_error ~= 0 then
        vim.notify(string.format("jai-lsp: download failed (%s): %s", url, result),
                   vim.log.levels.ERROR)
        return cfg.server_path
    end
    if os_str ~= "windows" then
        vim.uv.fs_chmod(dest, 493)   -- 0755
    end
    vim.notify("jai-lsp: download complete", vim.log.levels.INFO)
    return dest
end

-- Wire the LSP. Uses the built-in vim.lsp.start so we don't require
-- nvim-lspconfig. Two attach paths:
--   1. Autocmd on FileType=jai, for files opened after plugin load.
--   2. Immediate start for any *already-open* jai buffers, in case the
--      plugin is loaded lazily AFTER the FileType event has already fired
--      (LazyVim + ft=jai is the common case).
local function attach_lsp(cfg)
    local function start_for_buf(bufnr)
        local fname = vim.api.nvim_buf_get_name(bufnr)
        if fname == "" then return end
        local path = vim.fn.fnamemodify(fname, ":p:h")
        local root
        if cfg.root_dir and cfg.root_dir ~= "" then
            root = cfg.root_dir
        else
            local hits = vim.fs.find(
                { ".jai-root", ".git", "build.jai", "first.jai", "main.jai" },
                { upward = true, path = path }
            )
            root = (hits and hits[1] and vim.fs.dirname(hits[1])) or path
        end
        local binary = ensure_binary(cfg)
        vim.lsp.start({
            name     = "jai-lsp",
            cmd      = { binary },
            root_dir = root,
        }, { bufnr = bufnr })
    end

    -- Future jai buffers.
    vim.api.nvim_create_autocmd("FileType", {
        pattern  = "jai",
        callback = function(args) start_for_buf(args.buf) end,
        desc     = "jai-lsp: start language server",
    })

    -- Currently-open jai buffers (lazy-loaded after FileType fired).
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(buf)
            and vim.bo[buf].filetype == "jai"
        then
            start_for_buf(buf)
        end
    end
end

function M.setup(opts)
    M.config = vim.tbl_deep_extend("force", M.config, opts or {})
    apply_env(M.config)
    register_filetype()
    register_treesitter_parser(M.config)
    attach_lsp(M.config)
end

return M
