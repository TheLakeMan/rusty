// Copyright (c) 2026 Nicholas Vermeulen
// SPDX-License-Identifier: AGPL-3.0-or-later

//! checkpoint.rs — snapshot the global environment as plain Lisp source
//! (Phase 3.2 checkpoint/restore).
//!
//! `(checkpoint "file.lisp")` walks the *root* env frame and writes one
//! `define`/`defmacro`/`deftool` form per user binding, so restore is just
//! `(load "file.lisp")` into a fresh interpreter — no separate format, and
//! the checkpoint is human-readable and hand-editable Lisp.
//!
//! What "user binding" means: names that a pristine environment (builtins +
//! std.lisp + ~/.rusty/memory.lisp) doesn't have, plus baseline *data* names
//! whose values have changed (e.g. the actor system's `*agents*`/
//! `*mailboxes*` — stdlib-defined, but their current contents are user
//! state). Baseline names holding code (stdlib functions) are assumed
//! unmodified and skipped — redefining a stdlib function and expecting it
//! checkpointed is out of scope.
//!
//! Closures are serialized as their `(lambda ...)` source and re-closed over
//! the restored global env on load. Top-level definitions round-trip
//! faithfully; a closure over *local* (let-bound) state loses that capture —
//! checkpointable actors should keep state in globals via `set!` (which the
//! std.lisp actor examples already do). `defrust` natives can't be
//! serialized (compiled .so) and are listed in a header comment instead.

use crate::env::{Env, Value};
use crate::parser::Expr;
use std::cell::RefCell;
use crate::env::VarMap;

// ── Baseline: what a pristine environment binds ─────────────────────────

thread_local! {
    static BASELINE: RefCell<Option<VarMap>> = RefCell::new(None);
}

fn with_baseline<R>(f: impl FnOnce(&VarMap) -> R) -> R {
    BASELINE.with(|b| {
        if b.borrow().is_none() {
            let env = crate::interp::make_env();
            crate::interp::load_stdlib(&env, &crate::eval::Evaluator::new());
            let vars = env.borrow().vars_snapshot();
            *b.borrow_mut() = Some(vars);
        }
        f(b.borrow().as_ref().unwrap())
    })
}

// ── Source printers ──────────────────────────────────────────────────────

fn escape_str(s: &str) -> String {
    s.replace('\\', "\\\\").replace('"', "\\\"")
     .replace('\n', "\\n").replace('\t', "\\t")
}

fn num_source(n: f64) -> String {
    if n.fract() == 0.0 && n.abs() < 1e15 { format!("{}", n as i64) } else { format!("{}", n) }
}

pub fn expr_to_source(e: &Expr) -> String {
    match e {
        Expr::Number(n) => num_source(*n),
        Expr::Bool(true) => "#t".into(),
        Expr::Bool(false) => "#f".into(),
        Expr::String(s) => format!("\"{}\"", escape_str(s)),
        Expr::Symbol(s) => s.clone(),
        Expr::Nil => "()".into(),
        Expr::List(items) => {
            let parts: Vec<String> = items.iter().map(expr_to_source).collect();
            format!("({})", parts.join(" "))
        }
    }
}

/// Is this value plain data (safe to embed under one `quote`)?
fn is_pure_data(v: &Value) -> bool {
    match v {
        Value::Number(_) | Value::Bool(_) | Value::String(_) | Value::Symbol(_) | Value::Nil => true,
        Value::List(xs) => xs.iter().all(is_pure_data),
        _ => false,
    }
}

/// Datum syntax for a pure-data value (goes inside a `quote`).
fn datum_source(v: &Value) -> String {
    match v {
        Value::Number(n) => num_source(*n),
        Value::Bool(true) => "#t".into(),
        Value::Bool(false) => "#f".into(),
        Value::String(s) => format!("\"{}\"", escape_str(s)),
        Value::Symbol(s) => s.clone(),
        Value::Nil => "()".into(),
        Value::List(xs) => {
            let parts: Vec<String> = xs.iter().map(datum_source).collect();
            format!("({})", parts.join(" "))
        }
        _ => unreachable!("datum_source called on non-data (guarded by is_pure_data)"),
    }
}

fn params_source(params: &[String], rest: &Option<String>) -> String {
    match rest {
        Some(r) if params.is_empty() => r.clone(), // (lambda args ...) — but keep list form for clarity
        Some(r) => format!("({} . {})", params.join(" "), r),
        None => format!("({})", params.join(" ")),
    }
}

/// An *expression* that reconstructs `v` when evaluated in the restored
/// global env. None if the value can't be reconstructed (Native).
fn value_to_expr(v: &Value) -> Option<String> {
    match v {
        _ if is_pure_data(v) => Some(match v {
            // Scalars are self-evaluating; only symbols/lists need quoting.
            Value::Number(_) | Value::Bool(_) | Value::String(_) => datum_source(v),
            _ => format!("(quote {})", datum_source(v)),
        }),
        Value::List(xs) => {
            // Mixed data+code list (e.g. *agents*): rebuild with (list ...)
            let parts: Vec<String> = xs.iter().map(value_to_expr).collect::<Option<_>>()?;
            Some(format!("(list {})", parts.join(" ")))
        }
        Value::Tensor { data, shape } => {
            let nested = crate::interp::tensor_to_nested(data, shape);
            Some(format!("(tensor (quote {}))", datum_source(&nested)))
        }
        Value::Lambda { params, rest, body, .. } => {
            let body_src: Vec<String> = body.iter().map(expr_to_source).collect();
            Some(format!("(lambda {} {})", params_source(params, rest), body_src.join(" ")))
        }
        // A builtin inside a data structure: reference it by name — the
        // restored env resolves it to the same builtin.
        Value::Builtin(name, _) => Some((*name).to_string()),
        // Tools are env-bound by name too; reference works if the tool
        // itself is also checkpointed (it is — see value_to_defform).
        Value::Tool { name, .. } => Some(name.clone()),
        Value::Macro { .. } | Value::Native { .. } | Value::NativeGrad { .. } => None,
        _ => None,
    }
}

/// A top-level form that recreates the binding `name` → `v`. None = skip
/// (with a reason recorded by the caller).
fn value_to_defform(name: &str, v: &Value) -> Option<String> {
    match v {
        Value::Macro { params, rest, body, .. } => {
            let body_src: Vec<String> = body.iter().map(expr_to_source).collect();
            Some(format!("(defmacro {} {} {})", name, params_source(params, rest), body_src.join(" ")))
        }
        Value::Tool { name: tname, description, params, body, .. } => {
            let body_src: Vec<String> = body.iter().map(expr_to_source).collect();
            Some(format!("(deftool {} ({}) \"{}\" {})",
                tname, params.join(" "), escape_str(description), body_src.join(" ")))
        }
        _ => value_to_expr(v).map(|e| format!("(define {} {})", name, e)),
    }
}

// ── The checkpoint writer ────────────────────────────────────────────────

pub fn write_checkpoint(path: &str, env: &Env) -> Result<Value, String> {
    // Snapshot the root (global) frame — checkpoint is about durable state,
    // not whatever local scope the call happens to be in.
    let mut root = env.clone();
    loop {
        let parent = root.borrow().parent.clone();
        match parent { Some(p) => root = p, None => break }
    }
    let vars = root.borrow().vars_snapshot();
    let mut names: Vec<&String> = vars.keys().collect();
    names.sort(); // deterministic output

    let mut forms = Vec::new();
    let mut skipped = Vec::new();
    with_baseline(|baseline| {
        for name in names {
            let v = &vars[name];
            match v {
                Value::Builtin(..) => continue,
                Value::Native { .. } => { skipped.push(format!("{} (defrust native — re-run its defrust to restore)", name)); continue }
                Value::NativeGrad { .. } => { skipped.push(format!("{} (fused grad kernel — re-run graph-compile-grad to restore)", name)); continue }
                // Baseline code (stdlib functions/macros): assumed unmodified.
                Value::Lambda { .. } | Value::Macro { .. } | Value::Tool { .. }
                    if baseline.contains_key(name.as_str()) => continue,
                _ => {}
            }
            // Baseline data whose value is unchanged: skip; changed: emit.
            if let Some(bv) = baseline.get(name.as_str()) {
                if is_pure_data(v) && is_pure_data(bv) && crate::interp::value_equal(bv, v) {
                    continue;
                }
            }
            match value_to_defform(name, v) {
                Some(form) => forms.push(form),
                None => skipped.push(name.clone()),
            }
        }
    });

    let mut out = String::from(";; Rusty checkpoint — restore with (load \"this-file\")\n");
    if !skipped.is_empty() {
        out.push_str(&format!(";; not serialized: {}\n", skipped.join(", ")));
    }
    out.push('\n');
    for f in &forms {
        out.push_str(f);
        out.push('\n');
    }
    std::fs::write(path, &out)
        .map_err(|e| format!("checkpoint: cannot write {}: {}", path, e))?;
    Ok(Value::String(path.to_string()))
}
