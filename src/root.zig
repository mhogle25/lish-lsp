//! lish-lsp as a reusable library.
//!
//! This is the module surface a sibling language server (folio-lsp) imports: the
//! LSP analysis engines (completion, hover, signature help, go-to-definition,
//! semantic tokens, diagnostics, scope analysis, the AST walkers, the vocabulary
//! registry) plus the generic plumbing (JSON-RPC protocol, document store, URI
//! helpers). These all operate on lish source given a registry, so a folio
//! server can call them on the lish inside a `{...}` block.
//!
//! The lish-lsp *binary* (`main.zig` + `server.zig`) is deliberately NOT part of
//! this surface: `root.zig` is the gate, and anything it doesn't re-export is
//! private to the binary. Each language server (lish's own, folio's) owns its
//! thin `server.zig` and reuses everything here.

// Generic LSP plumbing (language-agnostic).
pub const protocol = @import("protocol.zig");
pub const document_store = @import("document_store.zig");
pub const uri = @import("uri.zig");
pub const server_core = @import("server_core.zig");

// lish analysis engines (operate on lish source + a registry).
pub const ast_walk = @import("ast_walk.zig");
pub const macro_walk = @import("macro_walk.zig");
pub const lish_registry = @import("lish_registry.zig");
pub const scope = @import("scope.zig");
pub const snippet = @import("snippet.zig");
pub const completion = @import("completion.zig");
pub const hover = @import("hover.zig");
pub const signature_help = @import("signature_help.zig");
pub const definition = @import("definition.zig");
pub const semantic_tokens = @import("semantic_tokens.zig");
pub const diagnostics = @import("diagnostics.zig");
pub const workspace_index = @import("workspace_index.zig");
pub const feature_encode = @import("feature_encode.zig");

test {
    // Pull every library module's test blocks into the lib test binary. Without
    // this, `addTest` on root.zig compiles the modules but runs none of their
    // tests (the bare re-exports above don't reference their test decls).
    @import("std").testing.refAllDecls(@This());
}

