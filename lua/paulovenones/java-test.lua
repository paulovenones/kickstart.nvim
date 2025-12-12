-- Simple Java/Gradle test runner with dynamic profile selection with visual indicators
local M = {}

-- Store the last used test type (test or integrationTests)
M.last_test_type = 'test'

-- Store the last test command
M.last_test_command = nil

-- Namespace for signs
local ns_id = vim.api.nvim_create_namespace('java_test_results')

-- Test results cache: stores results per buffer and line
-- Structure: { [bufnr] = { [line] = { status = "passed"|"failed", name = "testName" } } }
M.test_results = {}

-- Define signs for test results
local function setup_signs()
  vim.fn.sign_define('TestPassed', { text = '✓', texthl = 'DiagnosticOk', linehl = '' })
  vim.fn.sign_define('TestFailed', { text = '✗', texthl = 'DiagnosticError', linehl = '' })
  vim.fn.sign_define('TestRunning', { text = '⟳', texthl = 'DiagnosticWarn', linehl = '' })
end

-- Call setup when module loads
setup_signs()

-- Clear all test signs and virtual text in a buffer
local function clear_test_indicators(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  -- Clear virtual text
  vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)

  -- Clear signs
  vim.fn.sign_unplace('java_tests', { buffer = bufnr })

  -- Clear cached results
  M.test_results[bufnr] = nil
end

-- Place a sign at a specific line
local function place_sign(bufnr, line, sign_name)
  vim.fn.sign_place(0, 'java_tests', sign_name, bufnr, { lnum = line, priority = 10 })
end

-- Add virtual text to show test result
local function add_virtual_text(bufnr, line, text, hl_group)
  vim.api.nvim_buf_set_extmark(bufnr, ns_id, line - 1, 0, {
    virt_text = { { text, hl_group } },
    virt_text_pos = 'eol',
  })
end

-- Parse Gradle test output and extract test results
local function parse_test_output(output)
  local results = {
    passed = {},
    failed = {},
    total_passed = 0,
    total_failed = 0,
    total_skipped = 0,
  }

  -- Save output to file for inspection
  local debug_file = vim.fn.stdpath('cache') .. '/java-test-output.log'
  local f = io.open(debug_file, 'w')
  if f then
    f:write(output)
    f:close()
  end

  -- Parse test-logger summary: "Executed X tests in Ys (Y failed)"
  -- Examples: "SUCCESS: Executed 5 tests in 2.3s"
  --           "FAILURE: Executed 1 tests in 40.3s (1 failed)"
  local total_tests = output:match('Executed (%d+) tests? in')
  local failed_tests = output:match('%((%d+) failed%)')

  if total_tests then
    local total = tonumber(total_tests)
    local failed = tonumber(failed_tests) or 0
    results.total_passed = total - failed
    results.total_failed = failed
  end

  -- Parse individual test results from test-logger output
  -- Format: "  Test methodName() PASSED" or "  Test methodName() FAILED"
  -- Class name appears on the line before (without indentation)
  local lines = {}
  for line in output:gmatch('[^\r\n]+') do
    table.insert(lines, line)
  end

  local current_class = nil
  local found_test_section = false

  for i, line in ipairs(lines) do
    -- Check if this is a class name line (starts with package path, no leading whitespace)
    local class_name = line:match('^([%w%.]+Test)%s*$')
    if class_name then
      current_class = class_name
      found_test_section = true
    end

    -- If we found a test class, check subsequent lines for test results
    if found_test_section and line:match('^%s+Test%s+') then
      -- Try to parse the line - it could be either:
      -- "  Test methodName() PASSED/FAILED" (normal)
      -- "  Test Display Name PASSED/FAILED" (@DisplayName annotation)

      -- First try to extract method name pattern: methodName()
      local method = line:match('^%s+Test%s+([%w_]+)%(%)')
      local display_name = nil
      local status = line:match('(PASSED)%s*$') or line:match('(FAILED)%s*$')

      -- If no method name with parentheses, it might be a display name
      if not method and status then
        -- Extract everything between "Test " and " PASSED/FAILED"
        display_name = line:match('^%s+Test%s+(.+)%s+' .. status)
        if display_name then
          -- Trim whitespace
          display_name = display_name:match("^%s*(.-)%s*$")
        end
      end

      if (method or display_name) and status and current_class then
        local test_info = {
          class = current_class,
          method = method,
          display_name = display_name,
          full_name = current_class .. '.' .. (method or display_name)
        }

        if status == 'PASSED' then
          table.insert(results.passed, test_info)
        elseif status == 'FAILED' then
          table.insert(results.failed, test_info)
        end
      end
    end
  end

  return results
end

-- Find the line number of a test method in the buffer
-- Can search by either method name or @DisplayName annotation value
local function find_test_method_line(bufnr, method_name, display_name)
  local parser = vim.treesitter.get_parser(bufnr, 'java')
  if not parser then
    return nil
  end

  local tree = parser:parse()[1]
  local root = tree:root()

  -- Get all buffer lines for annotation checking
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  local query = vim.treesitter.query.parse('java', [[
    (method_declaration
      name: (identifier) @method_name) @method
  ]])

  for id, node in query:iter_captures(root, bufnr) do
    local capture_name = query.captures[id]
    if capture_name == 'method_name' then
      local name = vim.treesitter.get_node_text(node, bufnr)

      -- Get the method start line
      local method_start_row, _, _, _ = node:range()
      local parent = node:parent()
      while parent and parent:type() ~= 'method_declaration' do
        parent = parent:parent()
      end
      if parent then
        method_start_row, _, _, _ = parent:range()
      end

      -- First try exact method name match (if method_name is provided)
      if method_name and name == method_name then
        return method_start_row + 1
      end

      -- If display_name is provided, check for @DisplayName annotation near this method
      if display_name then
        -- Treesitter's method_declaration node includes annotations like @Test
        -- The @DisplayName annotation is typically between @Test and the method signature
        -- So we search from method_start_row forward a few lines to find the actual method signature
        local search_start = method_start_row
        local search_end = math.min(#lines - 1, method_start_row + 5)

        for i = search_start, search_end do
          local line = lines[i + 1] -- Lua arrays are 1-indexed
          if line then
            -- Match @DisplayName("...")
            local annotation_value = line:match('@DisplayName%s*%(%s*"([^"]+)"')
            if annotation_value and annotation_value == display_name then
              return method_start_row + 1
            end
          end
        end
      end
    end
  end

  return nil
end

-- Update visual indicators based on test results
local function update_test_indicators(bufnr, test_results)
  clear_test_indicators(bufnr)

  -- Store results in cache
  M.test_results[bufnr] = {}

  -- Mark passed tests
  for _, test in ipairs(test_results.passed) do
    local search_name = test.method or test.display_name
    local line = find_test_method_line(bufnr, test.method, test.display_name)
    if line then
      place_sign(bufnr, line, 'TestPassed')
      add_virtual_text(bufnr, line, '  ✓ passed', 'DiagnosticOk')
      M.test_results[bufnr][line] = { status = 'passed', name = search_name }
    end
  end

  -- Mark failed tests
  for _, test in ipairs(test_results.failed) do
    local search_name = test.method or test.display_name
    local line = find_test_method_line(bufnr, test.method, test.display_name)
    if line then
      place_sign(bufnr, line, 'TestFailed')
      add_virtual_text(bufnr, line, '  ✗ failed', 'DiagnosticError')
      M.test_results[bufnr][line] = { status = 'failed', name = search_name }
    end
  end

  -- Show summary notification
  local total = test_results.total_passed + test_results.total_failed

  if total > 0 then
    local msg = string.format(
      'Tests: %d/%d passed',
      test_results.total_passed,
      total
    )

    if test_results.total_skipped > 0 then
      msg = msg .. string.format(' (%d skipped)', test_results.total_skipped)
    end

    local level = test_results.total_failed == 0 and vim.log.levels.INFO or vim.log.levels.ERROR
    vim.notify(msg, level)
  else
    -- No test results found - might be a build error or test not found
    vim.notify('No test results found. Check the output window for errors.', vim.log.levels.WARN)
  end
end

-- Run tests and capture output for parsing
local function run_test_with_output(cmd, callback, cwd)
  local output = {}

  -- Parse the command if it's a string
  local cmd_parts = type(cmd) == "string" and vim.split(cmd, " ") or cmd

  local job_id = vim.fn.jobstart(cmd_parts, {
    cwd = cwd,
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line ~= "" then
            table.insert(output, line)
          end
        end
      end
    end,
    on_stderr = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line ~= "" then
            table.insert(output, line)
          end
        end
      end
    end,
    on_exit = function(_, exit_code)
      local full_output = table.concat(output, '\n')
      -- Debug: print output length
      print(string.format("[java-test] Captured %d lines of output", #output))
      callback(full_output, exit_code)
    end,
  })
  return job_id
end

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
  local bufnr = vim.api.nvim_get_current_buf()

  -- Get project root directory
  local jdtls = require('jdtls')
  local root_dir = jdtls.setup.find_root({'.git', 'mvnw', 'gradlew', 'pom.xml', 'build.gradle'})

  M.last_test_type = test_type

  -- Store the last command for replay
  M.last_test_command = function()
    M.run_nearest_test(test_type)
  end

  -- Show terminal with normal gradle output (without --console=plain for better UX)
  local display_cmd = string.format('./gradlew %s --tests "%s"', test_type, test_filter)
  vim.cmd('botright split')
  vim.cmd('resize 15')
  vim.cmd('terminal cd "' .. root_dir .. '" && ' .. display_cmd)
  vim.cmd('startinsert')

  -- Run a background job with --console=plain to capture parseable output
  local parse_cmd = string.format('./gradlew %s --tests "%s" --console=plain', test_type, test_filter)
  local output_lines = {}
  local shell_cmd = string.format('cd "%s" && %s', root_dir or '.', parse_cmd)

  local job_id = vim.fn.jobstart(shell_cmd, {
    on_stdout = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line ~= "" then
            table.insert(output_lines, line)
          end
        end
      end
    end,
    on_stderr = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line ~= "" then
            table.insert(output_lines, line)
          end
        end
      end
    end,
    on_exit = function(_, exit_code)
      local full_output = table.concat(output_lines, '\n')
      vim.schedule(function()
        local test_results = parse_test_output(full_output)
        if vim.api.nvim_buf_is_valid(bufnr) then
          update_test_indicators(bufnr, test_results)
        end
      end)
    end,
  })
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
  local bufnr = vim.api.nvim_get_current_buf()

  -- Get project root directory
  local jdtls = require('jdtls')
  local root_dir = jdtls.setup.find_root({'.git', 'mvnw', 'gradlew', 'pom.xml', 'build.gradle'})

  M.last_test_type = test_type

  -- Store the last command for replay
  M.last_test_command = function()
    M.run_class_tests(test_type)
  end

  -- Show terminal with normal gradle output (without --console=plain for better UX)
  local display_cmd = string.format('./gradlew %s --tests "%s"', test_type, full_class)
  vim.cmd('botright split')
  vim.cmd('resize 15')
  vim.cmd('terminal cd "' .. root_dir .. '" && ' .. display_cmd)
  vim.cmd('startinsert')

  -- Run a background job with --console=plain to capture parseable output
  local parse_cmd = string.format('./gradlew %s --tests "%s" --console=plain', test_type, full_class)
  local output_lines = {}
  local shell_cmd = string.format('cd "%s" && %s', root_dir or '.', parse_cmd)

  local job_id = vim.fn.jobstart(shell_cmd, {
    on_stdout = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line ~= "" then
            table.insert(output_lines, line)
          end
        end
      end
    end,
    on_stderr = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line ~= "" then
            table.insert(output_lines, line)
          end
        end
      end
    end,
    on_exit = function(_, exit_code)
      local full_output = table.concat(output_lines, '\n')
      vim.schedule(function()
        local test_results = parse_test_output(full_output)
        if vim.api.nvim_buf_is_valid(bufnr) then
          update_test_indicators(bufnr, test_results)
        end
      end)
    end,
  })
end

-- Clear test indicators for current buffer
function M.clear_indicators()
  clear_test_indicators(vim.api.nvim_get_current_buf())
  vim.notify('Test indicators cleared', vim.log.levels.INFO)
end

-- Toggle test indicators visibility
function M.toggle_indicators()
  local bufnr = vim.api.nvim_get_current_buf()
  if M.test_results[bufnr] and next(M.test_results[bufnr]) then
    clear_test_indicators(bufnr)
    vim.notify('Test indicators hidden', vim.log.levels.INFO)
  else
    vim.notify('No test results to show. Run tests first.', vim.log.levels.WARN)
  end
end

return M
