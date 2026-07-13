const path = require('path')
const fs = require('fs')
const vscode = require('vscode')
const { LanguageClient } = require('vscode-languageclient/node')

let client

const BUNDLED = {
  'darwin-arm64': 'jai-lsp-scratch-darwin-arm64',
  'darwin-x64': 'jai-lsp-scratch-darwin-x64',
  'linux-x64': 'jai-lsp-scratch-linux-x64',
  'linux-arm64': 'jai-lsp-scratch-linux-arm64',
  'win32-x64': 'jai-lsp-scratch-windows-x64.exe',
}

const bundledServerPath = (ctx) => {
  const name = BUNDLED[`${process.platform}-${process.arch}`]
  if (!name) return null
  const p = ctx.asAbsolutePath(path.join('bin', name))
  return fs.existsSync(p) ? p : null
}

exports.activate = (ctx) => {
  const cfg = vscode.workspace.getConfiguration('jaiLspScratch')
  const serverPath = cfg.get('serverPath') || bundledServerPath(ctx)
  if (!serverPath) {
    vscode.window.showErrorMessage(
      `Jai LSP: no bundled server binary for ${process.platform}-${process.arch}. ` +
        'Set "jaiLspScratch.serverPath" to a locally built binary.',
    )
    return
  }
  const compilerPath = cfg.get('compilerPath') || 'jai'
  const spaceAfterArrayType = cfg.get('spaceAfterArrayType', true)

  client = new LanguageClient(
    'jaiLspScratch',
    'Jai LSP Scratch',
    { command: serverPath },
    {
      documentSelector: [{ scheme: 'file', language: 'jai' }],
      initializationOptions: { compilerPath, spaceAfterArrayType },
    },
  )
  client.start()
}

exports.deactivate = () => (client ? client.stop() : undefined)
