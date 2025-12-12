-- Only runs when opening a Java file
local jdtls = require('jdtls')

-- Set indentation to 4 spaces for Java files
vim.opt_local.expandtab = true      -- Use spaces instead of tabs
vim.opt_local.tabstop = 4           -- Number of spaces a tab counts for
vim.opt_local.softtabstop = 4       -- Number of spaces a tab counts for when editing
vim.opt_local.shiftwidth = 4        -- Number of spaces for each step of indent

-- Paths
local mason_path = vim.fn.stdpath('data') .. '/mason/packages/jdtls'
local lombok_path = mason_path .. '/lombok.jar'

-- Download Lombok if needed
if vim.fn.filereadable(lombok_path) == 0 then
  vim.notify('Downloading Lombok...', vim.log.levels.INFO)
  vim.fn.system(string.format('curl -L -o "%s" "https://projectlombok.org/downloads/lombok.jar"', lombok_path))
  if vim.fn.filereadable(lombok_path) == 1 then
    vim.notify('Lombok downloaded successfully', vim.log.levels.INFO)
  end
end

-- Find project root
local root_dir = jdtls.setup.find_root({'.git', 'mvnw', 'gradlew', 'pom.xml', 'build.gradle'})
if not root_dir then
  return
end

-- Workspace directory
local project_name = vim.fn.fnamemodify(root_dir, ':p:h:t')
local workspace_dir = vim.fn.stdpath('data') .. '/jdtls-workspace/' .. project_name

-- Config
local config = {
  cmd = {
    'jdtls',
    '--jvm-arg=-javaagent:' .. lombok_path,
    '-data', workspace_dir,
  },
  root_dir = root_dir,
}

-- Start JDTLS
jdtls.start_or_attach(config)

-- Test runner keybindings
local test = require('paulovenones.java-test')

-- <leader>t prefix for test commands
vim.keymap.set('n', '<leader>tn', test.run_nearest_test, { buffer = true, desc = '[T]est: Run [N]earest test' })
vim.keymap.set('n', '<leader>tc', test.run_class_tests, { buffer = true, desc = '[T]est: Run current [C]lass tests' })
vim.keymap.set('n', '<leader>tl', test.run_last, { buffer = true, desc = '[T]est: Run [L]ast test' })
vim.keymap.set('n', '<leader>tu', test.run_unit_tests, { buffer = true, desc = '[T]est: Run all [U]nit tests' })
vim.keymap.set('n', '<leader>ti', test.run_integration_tests, { buffer = true, desc = '[T]est: Run all [I]ntegration tests' })
vim.keymap.set('n', '<leader>tx', test.clear_indicators, { buffer = true, desc = '[T]est: Clear indicators' })

-- Helper to view test output debug log
vim.keymap.set('n', '<leader>td', function()
  local log_file = vim.fn.stdpath('cache') .. '/java-test-output.log'
  vim.cmd('vsplit ' .. log_file)
end, { buffer = true, desc = '[T]est: View [D]ebug log' })
