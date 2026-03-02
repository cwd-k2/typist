import * as path from "node:path";
import * as fs from "node:fs";
import { workspace, type ExtensionContext } from "vscode";
import { LanguageClient, type ServerOptions, type LanguageClientOptions } from "vscode-languageclient/node";

let client: LanguageClient | undefined;

export function activate(context: ExtensionContext) {
  const config = workspace.getConfiguration("typist");
  const configPath = config.get<string>("server.path", "");
  const root = workspace.workspaceFolders?.[0]?.uri.fsPath ?? ".";

  const serverOptions: ServerOptions = configPath
    ? { command: configPath }
    : localServerOptions(root) ?? { command: "typist-lsp" };

  const clientOptions: LanguageClientOptions = {
    documentSelector: [{ scheme: "file", language: "perl" }],
  };

  client = new LanguageClient("typist", "Typist", serverOptions, clientOptions);
  context.subscriptions.push(client);
  client.start();
}

export function deactivate() {
  return client?.stop();
}

// Workspace-local cpanm installation: local/bin/typist-lsp
function localServerOptions(root: string): ServerOptions | undefined {
  const lsp = path.join(root, "local", "bin", "typist-lsp");
  if (!fs.existsSync(lsp)) return undefined;

  const lib = path.join(root, "local", "lib", "perl5");
  return { command: "perl", args: ["-I", lib, lsp] };
}
