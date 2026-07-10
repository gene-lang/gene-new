// Gene VS Code extension (docs/vscode-extension.md).
//
// Grammar-based highlighting works with no setup; this client additionally
// spawns `gene lsp` (src/gene/lsp) for diagnostics, outline, go to
// definition, hover, and workspace symbols. Plain JavaScript on purpose —
// no build step beyond `npm install`.

const fs = require('fs');
const path = require('path');
const { window, workspace } = require('vscode');
const { LanguageClient } = require('vscode-languageclient/node');

let client;

function findGeneBinary() {
  const configured = workspace.getConfiguration('gene').get('lsp.path');
  if (configured && configured.length > 0) {
    return configured;
  }
  const folders = workspace.workspaceFolders || [];
  for (const folder of folders) {
    const candidate = path.join(folder.uri.fsPath, 'bin', 'gene');
    if (fs.existsSync(candidate)) {
      return candidate;
    }
  }
  return 'gene'; // rely on PATH
}

function activate(context) {
  const config = workspace.getConfiguration('gene');
  if (!config.get('lsp.enabled')) {
    return;
  }
  const command = findGeneBinary();

  client = new LanguageClient(
    'gene',
    'Gene Language Server',
    { command, args: ['lsp'] },
    {
      documentSelector: [{ scheme: 'file', language: 'gene' }],
      synchronize: {
        fileEvents: workspace.createFileSystemWatcher('**/*.gene'),
      },
    }
  );

  client.start().catch((err) => {
    window.showWarningMessage(
      `Gene language server failed to start (${command} lsp): ${err.message}. ` +
        'Syntax highlighting still works; set "gene.lsp.path" to your gene binary ' +
        'for navigation and diagnostics.'
    );
  });
  context.subscriptions.push({ dispose: () => client && client.stop() });
}

function deactivate() {
  return client ? client.stop() : undefined;
}

module.exports = { activate, deactivate };
