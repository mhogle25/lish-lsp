import * as vscode from 'vscode';
import {
    LanguageClient,
    LanguageClientOptions,
    ServerOptions,
    TransportKind,
} from 'vscode-languageclient/node';
import { onTypeFormatting } from './indent';
import { runFile } from './run';

let client: LanguageClient | undefined;

export function activate(context: vscode.ExtensionContext): void {
    const config = vscode.workspace.getConfiguration('lish');
    const serverPath = config.get<string>('server.path', 'lish-lsp');

    const serverOptions: ServerOptions = {
        run: { command: serverPath, transport: TransportKind.stdio },
        debug: { command: serverPath, transport: TransportKind.stdio },
    };

    const clientOptions: LanguageClientOptions = {
        documentSelector: [{ scheme: 'file', language: 'lish' }],
    };

    client = new LanguageClient('lish-lsp', 'Lish Language Server', serverOptions, clientOptions);
    client.start();

    // Structural indent on Enter and on a typed closer. Needs `editor.formatOnType`,
    // which the extension enables by default for lish (see configurationDefaults).
    context.subscriptions.push(
        vscode.languages.registerOnTypeFormattingEditProvider(
            { scheme: 'file', language: 'lish' },
            onTypeFormatting,
            '\n', ')', ']', '}',
        ),
    );

    // :LishRun equivalent — run the active .lish file via the lish CLI.
    context.subscriptions.push(
        vscode.commands.registerCommand('lish.run', runFile),
    );
}

export function deactivate(): Thenable<void> | undefined {
    if (!client) return undefined;
    return client.stop();
}
