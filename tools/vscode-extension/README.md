# Gene Language for VS Code

Syntax highlighting plus language-server support (diagnostics, outline,
go to definition, hover, workspace symbols) for the
[Gene programming language](https://github.com/gene-lang/gene-new).

The `gene lsp` server and the other editor tools are described in
[docs/book/tools.md#editors](https://github.com/gene-lang/gene-new/blob/main/docs/book/tools.md#editors).

Quick start:

```bash
cd tools/vscode-extension
npm install
# development: open this folder in VS Code and press F5
# or package + install:
npx @vscode/vsce package
code --install-extension gene-lang-0.1.0.vsix
```

The client looks for the `gene` binary via the `gene.lsp.path` setting,
then `bin/gene` in the workspace root, then `gene` on PATH.
