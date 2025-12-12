-- Simple Java/Gradle test runner with dynamic profile selection
local M = {}

-- Store the last used test type (test or integrationTests)
M.last_test_type = 'test'

-- Store the last test command
M.last_test_command = nil

-- Detect test type based on file path
local function detect_test_type()
  local filepath = vim.fn.expand('%:p')

  -- Check if it's an integration test
  if filepath:match('/src/integration/') then
    return 'integrationTests'
  end

  -- Default to unit tests
  return 'test'
end

-- Get the package name from the current buffer
local function get_package_name()
  local lines = vim.api.nvim_buf_get_lines(0, 0, 50, false)
  for _, line in ipairs(lines) do
    local package = line:match('^package%s+([%w%.]+);')
    if package then
      return package
    end
  end
  return nil
end

-- Get the class name from the current buffer using treesitter
local function get_class_name()
  local bufnr = vim.api.nvim_get_current_buf()
  local parser = vim.treesitter.get_parser(bufnr, 'java')
  if not parser then
    return nil
  end

  local tree = parser:parse()[1]
  local root = tree:root()

  local query = vim.treesitter.query.parse('java', [[
    (class_declaration
      name: (identifier) @class_name)
  ]])

  for id, node in query:iter_captures(root, bufnr) do
    local capture_name = query.captures[id]
    if capture_name == 'class_name' then
      return vim.treesitter.get_node_text(node, bufnr)
    end
  end

  return nil
end

-- Get the test method name under cursor using treesitter
local function get_test_method_name()
  local bufnr = vim.api.nvim_get_current_buf()
  local parser = vim.treesitter.get_parser(bufnr, 'java')
  if not parser then
    return nil
  end

  -- Get cursor position
  local cursor = vim.api.nvim_win_get_cursor(0)
  local cursor_row = cursor[1] - 1 -- treesitter uses 0-indexed rows

  local tree = parser:parse()[1]
  local root = tree:root()

  -- First, find all method declarations and check if cursor is inside one
  local query_methods = vim.treesitter.query.parse('java', [[
    (method_declaration) @method
  ]])

  local current_method = nil
  for id, node in query_methods:iter_captures(root, bufnr) do
    local start_row, _, end_row, _ = node:range()
    if cursor_row >= start_row and cursor_row <= end_row then
      current_method = node
      break
    end
  end

  if not current_method then
    return nil
  end

  -- Now get the name of the method
  local query_name = vim.treesitter.query.parse('java', [[
    (method_declaration
      name: (identifier) @method_name)
  ]])

  for id, node in query_name:iter_captures(current_method, bufnr) do
    local capture_name = query_name.captures[id]
    if capture_name == 'method_name' then
      return vim.treesitter.get_node_text(node, bufnr)
    end
  end

  return nil
end

-- Run all tests with a specific Gradle task
function M.run_all_tests(test_type)
  test_type = test_type or M.last_test_type
  M.last_test_type = test_type

  local cmd = string.format('./gradlew %s', test_type)

  -- Store the last command for replay
  M.last_test_command = function()
    M.run_all_tests(test_type)
  end

  vim.cmd('botright split')
  vim.cmd('resize 15')
  vim.cmd('terminal ' .. cmd)
  vim.cmd('startinsert')
end


-- Run last test command again
function M.run_last()
  if M.last_test_command then
    M.last_test_command()
  else
    vim.notify('No previous test command to run', vim.log.levels.WARN)
  end
end

-- Quick run unit tests
function M.run_unit_tests()
  M.run_all_tests('test')
end

-- Quick run integration tests
function M.run_integration_tests()
  M.run_all_tests('integrationTests')
end

-- Run the nearest test method (under cursor)
function M.run_nearest_test(test_type)
  -- Auto-detect test type if not provided
  test_type = test_type or detect_test_type()

  local package = get_package_name()
  local class_name = get_class_name()
  local method_name = get_test_method_name()

  if not package or not class_name or not method_name then
    vim.notify('Could not find test method under cursor', vim.log.levels.WARN)
    return
  end

  local full_class = package .. '.' .. class_name
  local test_filter = full_class .. '.' .. method_name

  M.last_test_type = test_type

  -- Store the last command for replay (capture current values BEFORE running)
  local captured_test_type = test_type
  local captured_test_filter = test_filter
  M.last_test_command = function()
    local replay_cmd = string.format('./gradlew %s --tests "%s"', captured_test_type, captured_test_filter)
    vim.cmd('botright split')
    vim.cmd('resize 15')
    vim.cmd('terminal ' .. replay_cmd)
    vim.cmd('startinsert')
  end

  local cmd = string.format('./gradlew %s --tests "%s"', test_type, test_filter)

  vim.cmd('botright split')
  vim.cmd('resize 15')
  vim.cmd('terminal ' .. cmd)
  vim.cmd('startinsert')
end


-- Run nearest test class (all tests in current class)
function M.run_class_tests(test_type)
  -- Auto-detect test type if not provided
  test_type = test_type or detect_test_type()

  local package = get_package_name()
  local class_name = get_class_name()

  if not package or not class_name then
    vim.notify('Could not find test class', vim.log.levels.WARN)
    return
  end

  local full_class = package .. '.' .. class_name

  M.last_test_type = test_type

  local cmd = string.format('./gradlew %s --tests "%s"', test_type, full_class)

  -- Store the last command for replay (capture current values)
  local captured_test_type = test_type
  local captured_full_class = full_class
  M.last_test_command = function()
    local replay_cmd = string.format('./gradlew %s --tests "%s"', captured_test_type, captured_full_class)
    vim.cmd('botright split')
    vim.cmd('resize 15')
    vim.cmd('terminal ' .. replay_cmd)
    vim.cmd('startinsert')
  end

  vim.cmd('botright split')
  vim.cmd('resize 15')
  vim.cmd('terminal ' .. cmd)
  vim.cmd('startinsert')
end

return M
