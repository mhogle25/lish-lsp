# lish-lsp for VS Code

VS Code extension that wires the lish language server into the editor.
Provides syntax-aware diagnostics and semantic-token coloring for `.lish`
and `.lishmacro` files.

## Build

```sh
cd editors/vscode
npm install
npm run compile
```

## Run in development

Open this folder in VS Code, then `F5` to launch an Extension Development Host
with the extension loaded. The host needs `lish-lsp` reachable — either set
the `lish.server.path` setting or put the binary on `PATH`.

## Package as `.vsix`

```sh
npm install -g @vscode/vsce
vsce package
```

The resulting `lish-lsp-vscode-*.vsix` can be installed via
`code --install-extension <file>` or the Extensions view.

## Settings

- `lish.server.path` — absolute path to the `lish-lsp` binary. Defaults to
  `lish-lsp` (must be on `$PATH`).
