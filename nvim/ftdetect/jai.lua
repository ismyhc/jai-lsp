-- Filetype detection for .jai files. Doing it here makes the filetype
-- recognized even before the user calls require('jai-lsp').setup({...}).
vim.filetype.add({
    extension = { jai = "jai" },
})
