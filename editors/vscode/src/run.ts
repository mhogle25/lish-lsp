import * as vscode from 'vscode';
import { execFile } from 'child_process';
import * as path from 'path';

let channel: vscode.OutputChannel | undefined;

function output(): vscode.OutputChannel {
    if (!channel) channel = vscode.window.createOutputChannel('Lish Run');
    return channel;
}

// Runs the active .lish file through the lish CLI and streams stdout / stderr /
// exit code into the "Lish Run" output channel. Mirrors the nvim :LishRun
// command: sibling .lishmacro files load via `-m <file dir>`. `.lishmacro` files
// are not runnable scripts, so the command is gated to `.lish`.
export async function runFile(resource?: vscode.Uri): Promise<void> {
    // Explorer / editor-title menus invoke the command with the clicked file's
    // Uri; the palette and editor context menu pass nothing, so fall back to the
    // active editor.
    let doc: vscode.TextDocument;
    if (resource) {
        doc = await vscode.workspace.openTextDocument(resource);
    } else {
        const editor = vscode.window.activeTextEditor;
        if (!editor) {
            vscode.window.showWarningMessage('LishRun: no active editor');
            return;
        }
        doc = editor.document;
    }

    if (!doc.fileName.endsWith('.lish')) {
        vscode.window.showWarningMessage('LishRun: only .lish files');
        return;
    }
    await doc.save();

    const runPath = vscode.workspace.getConfiguration('lish').get<string>('run.path', 'lish');
    const file = doc.fileName;
    const dir = path.dirname(file);

    const out = output();
    out.clear();
    out.show(true);
    out.appendLine(`$ ${runPath} ${file} -m ${dir}`);

    execFile(runPath, [file, '-m', dir], (error, stdout, stderr) => {
        if (stdout) out.append(stdout.endsWith('\n') ? stdout : stdout + '\n');
        for (const line of stderr.split('\n')) {
            if (line.length > 0) out.appendLine('! ' + line);
        }
        // On a non-zero exit, execFile sets error.code to the numeric exit code.
        // A non-number code (e.g. 'ENOENT') means the binary itself couldn't run.
        if (error && typeof error.code !== 'number') {
            out.appendLine(`! failed to run '${runPath}': ${error.message}`);
            return;
        }
        out.appendLine(`[exit ${error ? (error.code as number) : 0}]`);
    });
}
