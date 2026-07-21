# Editor support for Rusty

Two pieces, both self-contained (no npm build, no bundled runtime):

- **Syntax highlighting + editor config** — `rusty.tmLanguage.json` (a TextMate
  grammar, understood by VS Code, Sublime Text, and anything else that speaks
  TextMate) and `language-configuration.json` (brackets, comments, auto-close).
- **Language server** — `rusty-lsp`, built from this repo (`cargo build --release`
  → `target/release/rusty-lsp`). Speaks LSP over stdio, no LSP crate. It provides:
  diagnostics (unbalanced parens / unterminated strings with positions),
  completion (every binding of a real interpreter env), hover, a document-symbol
  outline of top-level definitions, and **document formatting** (the same
  canonical formatter as `rusty fmt`).

Everything below points an editor at those two pieces. Nothing here is required
to *run* Rusty — it is opt-in tooling.

## VS Code

Highlighting works with the declarative extension in `vscode/` — no build step:

```bash
# symlink (or copy) the extension into your VS Code extensions dir
ln -s "$(pwd)/editor/vscode" ~/.vscode/extensions/rusty-lisp-0.1.0
```

Reload VS Code; `.lisp` files highlight as Rusty. Wiring the LSP into VS Code
needs a language-client extension (the `vscode-languageclient` npm package) —
that build is intentionally left out of this repo to keep it dependency-free.
Editors with **native** LSP support (below) get diagnostics/completion/hover/
outline/formatting from `rusty-lsp` directly, no extra package.

## Neovim (built-in LSP)

```lua
vim.api.nvim_create_autocmd("FileType", {
  pattern = "lisp",
  callback = function()
    vim.lsp.start({ name = "rusty-lsp", cmd = { "/path/to/rusty-lsp" } })
  end,
})
```

## Emacs (eglot)

```elisp
(add-to-list 'eglot-server-programs '(lisp-mode . ("/path/to/rusty-lsp")))
;; M-x eglot  in a .lisp buffer
```

## Helix (`languages.toml`)

```toml
[[language]]
name = "rusty"
scope = "source.rusty"
file-types = ["lisp"]
language-servers = ["rusty-lsp"]

[language-server.rusty-lsp]
command = "/path/to/rusty-lsp"
```

## Formatting

The LSP's formatter and the CLI are the same code (`src/fmt.rs`). From the shell:

```bash
rusty fmt path/to/file.lisp            # print canonical form to stdout
rusty fmt path/to/file.lisp --write    # rewrite the file in place
```

It is a re-indenter/spacing-normalizer: **semantics-preserving by construction**
(only whitespace between tokens changes; strings and comments are kept verbatim),
**idempotent**, and it preserves your line breaks (no reflow). It is opinionated
about indentation and inter-token spacing, so it will change files whose layout
differs from the canonical style — that is the point of a formatter, and it is
never run implicitly.
