// Copyright (c) 2026 Nicholas Vermeulen
// SPDX-License-Identifier: AGPL-3.0-or-later

//! rusty-lsp — a minimal Language Server for Rusty (Phase 5.2).
//!
//! JSON-RPC over stdio, hand-framed (Content-Length headers) — no LSP
//! crate, per the no-new-heavyweight-deps rule; serde_json was already
//! here. Capabilities, honestly scoped:
//!   - diagnostics: unbalanced parentheses / unterminated strings, with
//!     exact line/column (computed by our own scanner — the interpreter
//!     has no source positions yet, a known gap)
//!   - completion: every global binding of a real interpreter env
//!     (builtins + std.lisp + special forms), harvested at startup
//!   - hover: the kind and printed form of a global (lambda params,
//!     tool description, builtin name)
//! Debugging/profiling deliberately stay *in-language* (trace-*,
//! macro-profile-*) rather than behind the DAP protocol.
//!
//! Wire it into an editor as: command = "rusty-lsp" (stdio transport).

mod lexer;
mod parser;
mod resolve;
mod env;
mod eval;
mod interp;
mod arena;
mod rust_jit;
mod graph_ir;
mod checkpoint;
mod trace;
mod type_check;
mod effect_check;
mod kg;

use serde_json::{json, Value as J};
use std::collections::HashMap;
use std::io::{Read, Write};

fn read_message(stdin: &mut impl Read) -> Option<J> {
    // Content-Length: N\r\n\r\n{...}
    let mut header = Vec::new();
    let mut byte = [0u8; 1];
    loop {
        if stdin.read_exact(&mut byte).is_err() { return None; }
        header.push(byte[0]);
        if header.ends_with(b"\r\n\r\n") { break; }
    }
    let text = String::from_utf8_lossy(&header);
    let len: usize = text.lines()
        .find_map(|l| l.strip_prefix("Content-Length:").map(|v| v.trim().parse().ok()))??;
    let mut body = vec![0u8; len];
    stdin.read_exact(&mut body).ok()?;
    serde_json::from_slice(&body).ok()
}

fn send(stdout: &mut impl Write, msg: &J) {
    let body = msg.to_string();
    let _ = write!(stdout, "Content-Length: {}\r\n\r\n{}", body.len(), body);
    let _ = stdout.flush();
}

fn reply(stdout: &mut impl Write, id: &J, result: J) {
    send(stdout, &json!({"jsonrpc": "2.0", "id": id, "result": result}));
}

/// Paren/string scanner with positions — diagnostics the parser can't
/// give us yet. Returns (line, col, message) triples, 0-indexed.
fn scan_diagnostics(text: &str) -> Vec<(u32, u32, String)> {
    let mut diags = Vec::new();
    let mut stack: Vec<(u32, u32)> = Vec::new();
    let (mut line, mut col) = (0u32, 0u32);
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '\n' => { line += 1; col = 0; continue; }
            ';' => { // comment to end of line
                for c2 in chars.by_ref() { if c2 == '\n' { line += 1; col = 0; break; } }
                continue;
            }
            '"' => {
                let (sl, sc) = (line, col);
                let mut closed = false;
                while let Some(c2) = chars.next() {
                    col += 1;
                    match c2 {
                        '\\' => { let _ = chars.next(); col += 1; }
                        '"' => { closed = true; break; }
                        '\n' => { line += 1; col = 0; }
                        _ => {}
                    }
                }
                if !closed { diags.push((sl, sc, "unterminated string".into())); }
            }
            '(' => stack.push((line, col)),
            ')' => {
                if stack.pop().is_none() {
                    diags.push((line, col, "unmatched closing parenthesis".into()));
                }
            }
            _ => {}
        }
        col += 1;
    }
    for (l, c) in stack {
        diags.push((l, c, "unclosed parenthesis".into()));
    }
    diags
}

fn describe(v: &env::Value) -> String {
    match v {
        env::Value::Builtin(name, _) => format!("builtin `{}`", name),
        env::Value::Lambda { params, rest, .. } => {
            let mut p = params.join(" ");
            if let Some(r) = rest { p.push_str(&format!(" . {}", r)); }
            format!("lambda ({})", p)
        }
        env::Value::Macro { params, .. } => format!("macro ({})", params.join(" ")),
        env::Value::Tool { description, params, .. } =>
            format!("tool ({}) — {}", params.join(" "), description),
        env::Value::Native { arity, .. } => format!("compiled native, {} arg(s)", arity),
        other => format!("{}", other),
    }
}

fn word_at(text: &str, line: u32, character: u32) -> Option<String> {
    let l = text.lines().nth(line as usize)?;
    let chars: Vec<char> = l.chars().collect();
    let is_sym = |c: char| !c.is_whitespace() && !matches!(c, '(' | ')' | '"' | '\'' | '`' | ',');
    let pos = (character as usize).min(chars.len());
    let start = (0..pos).rev().take_while(|&i| is_sym(chars[i])).last().unwrap_or(pos);
    let end = (pos..chars.len()).take_while(|&i| is_sym(chars[i])).last().map(|i| i + 1).unwrap_or(pos);
    if start < end { Some(chars[start..end].iter().collect()) } else { None }
}

fn main() {
    // Run on the main thread with the recursion guard sized to `ulimit -s`,
    // like the CLI (see src/main.rs).
    eval::set_interp_stack(eval::native_stack_limit_bytes());
    run_lsp();
}

fn run_lsp() {
    // A real interpreter env: its root frame is the completion universe.
    let genv = interp::make_env();
    interp::load_stdlib(&genv, &eval::Evaluator::new());

    let mut stdin = std::io::stdin().lock();
    let mut stdout = std::io::stdout().lock();
    let mut docs: HashMap<String, String> = HashMap::new();

    while let Some(msg) = read_message(&mut stdin) {
        let method = msg["method"].as_str().unwrap_or("");
        let id = msg["id"].clone();
        match method {
            "initialize" => reply(&mut stdout, &id, json!({
                "capabilities": {
                    "textDocumentSync": 1,   // full
                    "completionProvider": {},
                    "hoverProvider": true
                },
                "serverInfo": {"name": "rusty-lsp", "version": env!("CARGO_PKG_VERSION")}
            })),
            "shutdown" => reply(&mut stdout, &id, J::Null),
            "exit" => break,
            "textDocument/didOpen" | "textDocument/didChange" => {
                let uri = msg["params"]["textDocument"]["uri"].as_str().unwrap_or("").to_string();
                let text = if method.ends_with("didOpen") {
                    msg["params"]["textDocument"]["text"].as_str().unwrap_or("").to_string()
                } else {
                    msg["params"]["contentChanges"][0]["text"].as_str().unwrap_or("").to_string()
                };
                let diags: Vec<J> = scan_diagnostics(&text).into_iter().map(|(l, c, m)| json!({
                    "range": {"start": {"line": l, "character": c},
                              "end":   {"line": l, "character": c + 1}},
                    "severity": 1,
                    "source": "rusty",
                    "message": m
                })).collect();
                docs.insert(uri.clone(), text);
                send(&mut stdout, &json!({
                    "jsonrpc": "2.0", "method": "textDocument/publishDiagnostics",
                    "params": {"uri": uri, "diagnostics": diags}
                }));
            }
            "textDocument/completion" => {
                let mut names: Vec<String> = Vec::new();
                    genv.borrow().for_each_local(|k, _| names.push(k.clone()));
                names.extend(crate::eval::SPECIAL_FORMS.iter().map(|s| s.to_string()));
                names.sort();
                names.dedup();
                let items: Vec<J> = names.into_iter()
                    .map(|n| json!({"label": n, "kind": 3}))
                    .collect();
                reply(&mut stdout, &id, json!(items));
            }
            "textDocument/hover" => {
                let uri = msg["params"]["textDocument"]["uri"].as_str().unwrap_or("");
                let line = msg["params"]["position"]["line"].as_u64().unwrap_or(0) as u32;
                let ch = msg["params"]["position"]["character"].as_u64().unwrap_or(0) as u32;
                let hover = docs.get(uri)
                    .and_then(|text| word_at(text, line, ch))
                    .and_then(|word| {
                        let v = crate::env::EnvFrame::get(&genv, &word);
                        v.map(|v| format!("**{}** — {}", word, describe(&v)))
                            .or_else(|| crate::eval::SPECIAL_FORMS.contains(&word.as_str())
                                .then(|| format!("**{}** — special form (see docs/SPEC.md §6)", word)))
                    });
                match hover {
                    Some(text) => reply(&mut stdout, &id, json!({
                        "contents": {"kind": "markdown", "value": text}})),
                    None => reply(&mut stdout, &id, J::Null),
                }
            }
            _ if !id.is_null() => reply(&mut stdout, &id, J::Null), // politely answer unknowns
            _ => {} // notifications we don't handle
        }
    }
}
