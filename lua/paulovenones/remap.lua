vim.g.mapleader = ' '
vim.keymap.set('n', '<leader>pv', vim.cmd.Ex)

-- Diagnostics
vim.keymap.set('n', '<leader>Q', vim.diagnostic.setqflist, { desc = 'Open diagnostic [Q]uickfix list (all buffers)' })
