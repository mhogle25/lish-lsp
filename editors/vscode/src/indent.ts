import * as vscode from 'vscode';

const OPENERS = new Set(['(', '[', '{']);
const CLOSERS = new Set([')', ']', '}']);

// Structural indent level for the text preceding a line, mirroring the lish
// REPL/editor rule: the count of unclosed (/[/{, plus one level when the file's
// head is an identifier (a bare top-level call, whose args on later lines indent
// in). Brackets inside "strings" and ## comments do not count.
export function structuralIndentLevel(text: string): number {
    let depth = 0;
    let head: string | null = null;
    let i = 0;
    const n = text.length;
    while (i < n) {
        const c = text[i];
        if (c === '"') {
            // String literal: skip to the closing quote, honoring \ escapes.
            if (head === null) { head = c; }
            i++;
            while (i < n) {
                const d = text[i];
                if (d === '\\') { i += 2; }
                else if (d === '"') { i++; break; }
                else { i++; }
            }
        } else if (c === '#' && text[i + 1] === '#') {
            while (i < n && text[i] !== '\n') { i++; } // ## comment: skip to EOL
        } else {
            if (head === null && !/\s/.test(c)) { head = c; }
            if (OPENERS.has(c)) { depth++; }
            else if (CLOSERS.has(c) && depth > 0) { depth--; }
            i++;
        }
    }
    // Bare top-level call: head is an identifier, not a bracket / string / number.
    if (head !== null && !OPENERS.has(head) && head !== '"' && !/[0-9]/.test(head)) {
        depth++;
    }
    return depth;
}

// Reindents the line at the cursor to its structural level when Enter or a
// closing bracket is typed. This covers what VSCode's regex indentationRules
// cannot: the bare-call `+1` for a `proc` body with no enclosing bracket.
export const onTypeFormatting: vscode.OnTypeFormattingEditProvider = {
    provideOnTypeFormattingEdits(document, position, _ch, options) {
        const line = position.line;
        const lineText = document.lineAt(line).text;
        const before = document.getText(new vscode.Range(0, 0, line, 0));

        let level = structuralIndentLevel(before);
        // A line that opens with a closer aligns with the line that opened it.
        const firstChar = lineText.trim().charAt(0);
        if (firstChar && CLOSERS.has(firstChar) && level > 0) { level--; }

        const unit = options.insertSpaces ? ' '.repeat(options.tabSize) : '\t';
        const indent = unit.repeat(level);
        const currentIndentLen = lineText.length - lineText.replace(/^\s*/, '').length;
        if (indent === lineText.slice(0, currentIndentLen)) { return []; }
        return [vscode.TextEdit.replace(new vscode.Range(line, 0, line, currentIndentLen), indent)];
    },
};
