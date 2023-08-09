---@mod haskell-tools.dap haskell-tools nvim-dap setup

local log = require('haskell-tools.log')
local ht_util = require('haskell-tools.util')
local deps = require('haskell-tools.deps')
local project_util = require('haskell-tools.project.util')
local Path = deps.require_plenary('plenary.path')
local async = deps.require_plenary('plenary.async')

---@param root_dir string
local function get_ghci_dap_cmd(root_dir)
  if project_util.is_cabal_project(root_dir) then
    return 'cabal exec -- ghci-dap --interactive -i ${workspaceFolder}'
  else
    return 'stack ghci --test --no-load --no-build --main-is TARGET --ghci-options -fprint-evld-with-show'
  end
end

---@param root_dir string
---@param opts AddDapConfigOpts
---@return HsDapLaunchConfiguration[]
local function find_json_configurations(root_dir, opts)
  ---@type HsDapLaunchConfiguration[]
  local configurations = {}
  local results = vim.fn.glob(Path:new(root_dir, opts.settings_file_pattern).filename, true, true)
  if #results == 0 then
    log.info(opts.settings_file_pattern .. ' not found in project root ' .. root_dir)
  else
    for _, launch_json in pairs(results) do
      local content = ht_util.read_file(launch_json)
      local success, settings = pcall(vim.json.decode, content)
      if not success then
        local msg = 'Could not decode ' .. launch_json .. '.'
        log.warn { msg, error }
      elseif settings and settings.configurations and type(settings.configurations) == 'table' then
        configurations = vim.list_extend(configurations, settings.configurations)
      end
    end
  end
  return configurations
end

---@param root_dir string
---@return table
local function detect_launch_configurations(root_dir)
  local launch_configurations = {}
  local HTConfig = require('haskell-tools.config.internal')
  local dap_opts = HTConfig.dap
  ---@param entry_point HsEntryPoint
  ---@return HsDapLaunchConfiguration
  local function mk_launch_configuration(entry_point)
    ---@class HsDapLaunchConfiguration
    local HsDapLaunchConfiguration = {
      type = 'ghc',
      request = 'launch',
      name = entry_point.package_name .. ':' .. entry_point.exe_name,
      workspace = '${workspaceFolder}',
      startup = Path:new(entry_point.package_dir, entry_point.source_dir, entry_point.main).filename,
      startupFunc = '', -- defaults to 'main' if not set
      startupArgs = '',
      stopOnEntry = false,
      mainArgs = '',
      logFile = dap_opts.logFile,
      logLevel = dap_opts.logLevel,
      ghciEnv = vim.empty_dict(),
      ghciPrompt = 'λ: ',
      ghciInitialPrompt = 'ghci> ',
      ghciCmd = get_ghci_dap_cmd(root_dir),
      forceInspect = false,
    }
    return HsDapLaunchConfiguration
  end
  for _, entry_point in pairs(project_util.parse_project_entrypoints(root_dir)) do
    table.insert(launch_configurations, mk_launch_configuration(entry_point))
  end
  return launch_configurations
end

---@type table<string, table>
local _configuration_cache = {}

---@class HsDapTools
local HsDapTools = nil

if not deps.has('dap') then
  return HsDapTools
end

local nvim_dap = require('dap')

HsDapTools = {}

---@type table A copy of the nvim-dap `dap` module
HsDapTools.nvim_dap = nvim_dap
local HTConfig = require('haskell-tools.config.internal')
local dap_opts = HTConfig.dap
nvim_dap.adapters.ghc = {
  type = 'executable',
  command = table.concat(dap_opts.cmd, ' '),
}

---@class AddDapConfigOpts
---@field autodetect boolean Whether to automatically detect launch configurations for the project
---@field settings_file_pattern string File name or pattern to search for. Defaults to 'launch.json'

---Discover nvim-dap launch configurations for haskell-debug-adapter.
---@param bufnr number|nil The buffer number
---@param opts AddDapConfigOpts|nil
---@return nil
HsDapTools.discover_configurations = function(bufnr, opts)
  async.run(function()
    bufnr = bufnr or 0 -- Default to current buffer
    local default_opts = {
      autodetect = true,
      settings_file_pattern = 'launch.json',
    }
    opts = vim.tbl_deep_extend('force', {}, default_opts, opts or {})
    local filename = vim.api.nvim_buf_get_name(bufnr)
    local project_root = project_util.match_project_root(filename)
    if not project_root then
      log.warn('haskell-tools.dap: Unable to detect project root for file ' .. filename)
      return
    end
    if _configuration_cache[project_root] then
      return
    end
    local discovered_configurations = {}
    local json_configurations = find_json_configurations(project_root, opts)
    vim.list_extend(discovered_configurations, json_configurations)
    if opts.autodetect then
      local detected_configurations = detect_launch_configurations(project_root)
      vim.list_extend(discovered_configurations, detected_configurations)
    end
    _configuration_cache[project_root] = discovered_configurations
    ---@type HsDapLaunchConfiguration[]
    local dap_configurations = nvim_dap.configurations.haskell or {}
    for _, cfg in ipairs(discovered_configurations) do
      for i, existing_config in pairs(dap_configurations) do
        if cfg.name == existing_config.name and cfg.startup == existing_config.startup then
          table.remove(dap_configurations, i)
        end
      end
      table.insert(dap_configurations, cfg)
    end
    nvim_dap.configurations.haskell = dap_configurations
  end)
end

return HsDapTools
