// Copyright (c) 2026 Nicholas Vermeulen
// SPDX-License-Identifier: AGPL-3.0-or-later

//! effect_check.rs — effect tracking (ROADMAP.md 2.2, "ensure pure
//! functions remain pure"). `check-effects` walks a lambda's body *without
//! executing it* and reports any operation it can prove is effectful, from
//! a fixed classification of known builtins/special forms (`effect_reason`).
//! Same conservative philosophy as `type_check.rs`: it only ever reports
//! known side effects, never guesses at unknown ones.
//!
//! TRANSITIVE since 0.82.0 (`check_env`): a call whose head resolves in the
//! lambda's closure env to a user-defined `Lambda` also has THAT lambda's
//! body walked (cycle-guarded, in the callee's own closure env), so an
//! effect reachable only through a helper — or a chain of them — is
//! surfaced. This closes the "hide a `shell` behind a user function"
//! backdoor the shallow walk missed (an effect gate could be bypassed by one
//! level of indirection). Still conservative: only HEAD-position symbols are
//! resolved (an actual call, not a function merely passed as an argument),
//! and a callee that resolves to a `Native`/`Builtin` (non-Lisp) is left
//! alone — we can't walk what isn't an Expr body. Two effects do NOT
//! propagate across a user-function boundary (`propagates_transitively`):
//! `error` (nearly every function can raise, so propagating it would flood
//! every caller and certify nothing pure) and `gensym` (local
//! nondeterminism) — both remain honest DIRECT findings.
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

/// Effects that propagate TRANSITIVELY through a user-defined callee. These are
/// the ones that reach the outside world or mutate shared state — the class the
/// package/gate blind-spot is about (a `shell`/filesystem/`eval` hidden behind a
/// helper). Deliberately EXCLUDES `error` (raises — nearly every library
/// function can, so propagating it would flood every caller and certify nothing
/// pure) and `gensym` (a local nondeterminism), which are honest DIRECT findings
/// but too common to be meaningful once reached only through a call chain. A
/// direct call still reports every effect via `effect_reason`; this predicate
/// only gates what crosses a user-function boundary.
fn propagates_transitively(op: &str) -> bool {
    !matches!(op, "error" | "gensym")
}

/// Transitive effect walk: like `check`, but a call whose head resolves in `env`
/// to a user-defined `Lambda` ALSO has that lambda's body walked (in ITS closure
/// env), so an effect reachable only through a helper is surfaced — closing the
/// "hide a `shell` behind a user function" backdoor. `visited` breaks cycles
/// (mutual recursion) and avoids re-walking a shared helper. Only HEAD-position
/// symbols are resolved (an actual call); a function merely passed as an argument
/// is left alone, since whether it is invoked is beyond this static reach.
pub fn check_env(body: &[Expr], env: &crate::env::Env) -> Vec<String> {
    let mut findings = Vec::new();
    let mut visited = std::collections::HashSet::new();
    for stmt in body { check_t(stmt, &mut findings, env, &mut visited); }
    findings
}

fn check_t(expr: &Expr, findings: &mut Vec<String>,
           env: &crate::env::Env, visited: &mut std::collections::HashSet<String>) {
    if let Expr::List(items) = expr {
        if items.is_empty() { return; }
        let head = match &items[0] {
            Expr::Symbol(s) => Some(s.as_str()),
            Expr::LocalRef { name, .. } | Expr::GlobalRef { name, .. } => Some(&**name),
            _ => None,
        };
        if let Some(head) = head {
            match head {
                "quote" => return,
                "quasiquote" if items.len() == 2 => { check_quasi_t(&items[1], findings, env, visited); return; }
                _ => {
                    if let Some(reason) = effect_reason(head) {
                        findings.push(format!("{}: {}", head, reason));
                    } else if !visited.contains(head) {
                        // Not a known effect and not yet analyzed — if it names a
                        // user function in scope, walk its body (in the callee's
                        // OWN closure env) and keep only the transitively-relevant
                        // effects. A Native/Builtin/Tensor resolves to non-Lambda
                        // → we stay conservative (can't walk what isn't Lisp).
                        if let Some(crate::env::Value::Lambda { body, env: closure_env, .. }) =
                            crate::env::EnvFrame::get(env, head)
                        {
                            visited.insert(head.to_string());
                            let mut sub = Vec::new();
                            for stmt in body.iter() { check_t(stmt, &mut sub, &closure_env, visited); }
                            for f in sub {
                                let op = f.split(':').next().unwrap_or("");
                                if propagates_transitively(op) { findings.push(f); }
                            }
                        }
                    }
                }
            }
        }
        for item in items.iter() { check_t(item, findings, env, visited); }
    }
}

fn check_quasi_t(expr: &Expr, findings: &mut Vec<String>,
                 env: &crate::env::Env, visited: &mut std::collections::HashSet<String>) {
    if let Expr::List(items) = expr {
        if let Some(Expr::Symbol(s)) = items.first() {
            if (s == "unquote" || s == "unquote-splicing") && items.len() == 2 {
                check_t(&items[1], findings, env, visited);
                return;
            }
        }
        for item in items.iter() { check_quasi_t(item, findings, env, visited); }
    }
}
