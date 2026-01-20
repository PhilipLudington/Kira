# Kira Editor Support

This directory contains syntax highlighting definitions for various editors.

## VS Code

The `vscode/` directory contains a TextMate grammar for VS Code.

### Installation

1. Copy the `vscode/` directory to your VS Code extensions folder:
   - **macOS**: `~/.vscode/extensions/kira-language`
   - **Linux**: `~/.vscode/extensions/kira-language`
   - **Windows**: `%USERPROFILE%\.vscode\extensions\kira-language`

2. Restart VS Code

3. Open a `.ki` file to see syntax highlighting

### Development Installation

For development, you can create a symlink:

```bash
ln -s /path/to/kira/editors/vscode ~/.vscode/extensions/kira-language
```

## Vim / Neovim

The `vim/` directory contains Vim syntax files.

### Installation (Vim)

Copy files to your Vim configuration:

```bash
mkdir -p ~/.vim/syntax ~/.vim/ftdetect ~/.vim/indent

cp vim/kira.vim ~/.vim/syntax/
cp vim/ftdetect/kira.vim ~/.vim/ftdetect/
cp vim/indent/kira.vim ~/.vim/indent/
```

### Installation (Neovim)

Copy files to your Neovim configuration:

```bash
mkdir -p ~/.config/nvim/syntax ~/.config/nvim/ftdetect ~/.config/nvim/indent

cp vim/kira.vim ~/.config/nvim/syntax/
cp vim/ftdetect/kira.vim ~/.config/nvim/ftdetect/
cp vim/indent/kira.vim ~/.config/nvim/indent/
```

### Using with a Plugin Manager

If you use a plugin manager like `vim-plug` or `lazy.nvim`, you can point it directly to this repository (once published):

**vim-plug:**
```vim
Plug 'kira-lang/kira', { 'rtp': 'editors/vim' }
```

**lazy.nvim:**
```lua
{ 'kira-lang/kira', config = function()
    vim.opt.rtp:append('editors/vim')
  end
}
```

## Supported Features

Both editor configurations support:

- Keyword highlighting (`fn`, `let`, `type`, `effect`, etc.)
- Control flow (`if`, `else`, `match`, `for`, `return`, `break`)
- Type highlighting (primitives and user-defined types)
- String literals with escape sequences
- String interpolation (`{expr}`)
- Number literals (decimal, hex, binary, with type suffixes)
- Comments (line, block, documentation)
- Operators and punctuation
- Built-in type constructors (`Some`, `None`, `Ok`, `Err`, `Cons`, `Nil`)

## Other Editors

### Sublime Text

The VS Code TextMate grammar (`kira.tmLanguage.json`) can be used with Sublime Text:

1. Copy `vscode/kira.tmLanguage.json` to your Sublime Text Packages folder
2. Rename it to `Kira.tmLanguage` (some versions need `.tmLanguage` extension)

### Emacs

A tree-sitter grammar would be needed for full Emacs support. Alternatively, you can create a simple mode based on the keyword lists in this documentation.

### Zed

Zed uses Tree-sitter grammars. A `tree-sitter-kira` grammar would need to be created for full support.

## Contributing

If you create syntax support for another editor, please contribute it back to this project!
