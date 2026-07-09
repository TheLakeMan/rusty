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
        "read-file" | "write-file" | "append-file" | "delete-file" | "file-exists" | "list-dir"
        | "file-read" | "file-write" | "file-append" | "file-delete" | "file-exists?"
        | "dir-create" | "dir-list" | "checkpoint"
            => Some("touches the filesystem"),
        "llm" | "tool-call" | "react-loop" => Some("calls an external LLM/tool"),
        "remember" | "recall" | "forget" | "memory-list" => Some("reads or writes persistent memory"),
        "kg-add!" | "kg-clear!" | "kg-query" | "kg-count" | "kg-triples"
        | "kg-load-ntriples" | "kg-save-ntriples"
            => Some("reads or writes the knowledge graph"),
        "gensym" => Some("non-deterministic — returns a different value each call"),
        "load" | "load-relative" => Some("loads and executes another file"),
        _ => None,
    }
}

pub fn check(expr: &Expr, findings: &mut Vec<String>) {
    if let Expr::List(items) = expr {
        if items.is_empty() { return; }
        if let Expr::Symbol(head) = &items[0] {
            match head.as_str() {
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
