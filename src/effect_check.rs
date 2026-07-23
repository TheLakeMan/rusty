// Copyright (c) 2026 Nicholas Vermeulen
// SPDX-License-Identifier: AGPL-3.0-or-later

//! effect_check.rs — effect tracking (ROADMAP.md 2.2, "ensure pure
//! functions remain pure"). `check-effects` walks a lambda's body *without
//! executing it* and reports any operation it can prove is effectful, from
//! a fixed classification of known builtins/special forms. Same
//! conservative philosophy as `type_check.rs`: an unrecognized or
//! user-defined call is never flagged — purity can't be proven or
//! disproven for it without a whole-program analysis this deliberately
//! doesn't attempt — so this only ever reports known side effects, never
//! guesses at unknown ones.
//!
//! `quote`d data is skipped entirely (it's never executed); inside
//! `quasiquote`, literal template parts are skipped the same way, but
//! `unquote`/`unquote-splicing` contents *are* checked, since those run.

use crate::parser::Expr;

pub fn effect_reason(op: &str) -> Option<&'static str> {
    match op {
        "set!" | "set" => Some("mutates a variable"),
        "print" | "println" | "display" | "newline" => Some("performs I/O"),
        "error" => Some("raises an error (a control-flow side effect)"),
        "shell" | "shell-run" => Some("runs a shell command"),
        "proc-eval" | "proc-pmap" => Some("spawns a subprocess"),
        "read-file" | "write-file" | "append-file" | "delete-file" | "file-exists" | "list-dir"
        | "file-read" | "file-write" | "file-append" | "file-delete" | "file-exists?"
        | "dir-create" | "dir-list" | "file-realpath" | "file-symlink?" | "file-hash"
        | "checkpoint"
            => Some("touches the filesystem"),
        "llm" | "tool-call" | "react-loop" => Some("calls an external LLM/tool"),
        // Executes arbitrary code at runtime — anything reachable through it
        // escapes this static analysis, so it must itself be treated as
        // maximally effectful (this is what a `(lambda (x) (eval-string x))`
        // body used to hide: it certified pure yet could do anything).
        "eval" | "eval-string" => Some("evaluates arbitrary code (may perform any effect)"),
        // Compile paths shell out to rustc and write the cached .so — a
        // subprocess plus filesystem writes.
        "defrust" | "defrust*" | "graph-compile" | "graph-compile-grad"
            => Some("compiles native code (spawns rustc, touches the filesystem)"),
        "remember" | "recall" | "forget" | "memory-list" => Some("reads or writes persistent memory"),
        "kg-add!" | "kg-clear!" | "kg-query" | "kg-count" | "kg-triples"
        | "kg-load-ntriples" | "kg-save-ntriples"
            => Some("reads or writes the knowledge graph"),
        "gensym" => Some("non-deterministic — returns a different value each call"),
        "sandbox-enable!" => Some("changes the sandbox confinement (process state)"),
        "load" | "load-relative" => Some("loads and executes another file"),
        _ => None,
    }
}

pub fn check(expr: &Expr, findings: &mut Vec<String>) {
    if let Expr::List(items) = expr {
        if items.is_empty() { return; }
        // Resolved refs (lexical addressing) carry the same name the source
        // wrote — a rewritten head is still the operation it names.
        let head = match &items[0] {
            Expr::Symbol(s) => Some(s.as_str()),
            Expr::LocalRef { name, .. } | Expr::GlobalRef { name, .. } => Some(&**name),
            _ => None,
        };
        if let Some(head) = head {
            match head {
                "quote" => return, // quoted data is never executed
                "quasiquote" if items.len() == 2 => { check_quasi(&items[1], findings); return; }
                _ => {
                    if let Some(reason) = effect_reason(head) {
                        findings.push(format!("{}: {}", head, reason));
                    }
                }
            }
        }
        for item in items.iter() { check(item, findings); }
    }
}

fn check_quasi(expr: &Expr, findings: &mut Vec<String>) {
    if let Expr::List(items) = expr {
        if let Some(Expr::Symbol(s)) = items.first() {
            if (s == "unquote" || s == "unquote-splicing") && items.len() == 2 {
                check(&items[1], findings); // this part is evaluated, not literal template
                return;
            }
        }
        for item in items.iter() { check_quasi(item, findings); }
    }
}
