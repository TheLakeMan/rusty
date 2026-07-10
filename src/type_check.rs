// Copyright (c) 2026 Nicholas Vermeulen
// SPDX-License-Identifier: AGPL-3.0-or-later

//! type_check.rs — flow-sensitive static type checking (ROADMAP.md 2.2).
//!
//! `check-types` (interp.rs builtin) walks a lambda's body *without
//! executing it*, tracking each variable's statically-known type through
//! `if`/`let`/`let*` — narrowing on a recognized `<type>?` predicate test in
//! an `if` condition, propagating through `let`/`let*` init expressions —
//! and reports any operation it can *prove* runs on a value of the wrong
//! type. Deliberately conservative: an unresolvable type is `Unknown`, and
//! `Unknown` is never flagged, so this only ever reports provable mismatches,
//! never guesses. This is separate from (and doesn't touch) `define-typed`
//! (std.lisp), which is a runtime contract check, not static analysis.
//!
//! v1 scope, each a clean extension point rather than a dead end: only
//! `if`/`let`/`let*` are understood (not `cond`/`when`/`letrec`/named-`let`);
//! only a single type per variable (no unions); user-defined function calls
//! always return `Unknown` (no cross-function return-type registry yet, so
//! `define-typed`'s declared return types aren't consulted here).

use crate::parser::Expr;
use std::collections::HashMap;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Ty { Number, Str, Boolean, Symbol, ListT, Procedure, Unknown }

impl Ty {
    pub fn name(self) -> &'static str {
        match self {
            Ty::Number => "number", Ty::Str => "string", Ty::Boolean => "boolean",
            Ty::Symbol => "symbol", Ty::ListT => "list", Ty::Procedure => "procedure",
            Ty::Unknown => "unknown",
        }
    }
    pub fn from_name(s: &str) -> Option<Ty> {
        match s {
            "number" => Some(Ty::Number), "string" => Some(Ty::Str), "boolean" => Some(Ty::Boolean),
            "symbol" => Some(Ty::Symbol), "list" => Some(Ty::ListT), "procedure" => Some(Ty::Procedure),
            _ => None,
        }
    }
}

pub type TyEnv = HashMap<String, Ty>;

// ── Cross-checker signature registry ─────────────────────────────────────
// `define-typed` (std.lisp) registers each declared signature here at
// definition time via the `register-signature` builtin, so this static
// checker and the runtime contracts share one source of truth. Before this
// existed, every user-defined call inferred as `Unknown`; now a call to a
// `define-typed` function checks args against its declared param types and
// infers its declared return type. Unannotated params/returns register as
// `Unknown` and behave exactly as before (never flagged).
thread_local! {
    static SIGNATURES: std::cell::RefCell<HashMap<String, (Vec<Ty>, Ty)>> =
        std::cell::RefCell::new(HashMap::new());
}

pub fn register_signature(name: &str, params: Vec<Ty>, ret: Ty) {
    SIGNATURES.with(|s| { s.borrow_mut().insert(name.to_string(), (params, ret)); });
}

fn lookup_signature(name: &str) -> Option<(Vec<Ty>, Ty)> {
    SIGNATURES.with(|s| s.borrow().get(name).cloned())
}

/// Known operator -> (expected arg type, if checkable; return type).
fn builtin_signature(op: &str) -> Option<(Option<Ty>, Ty)> {
    match op {
        "+" | "-" | "*" | "/" => Some((Some(Ty::Number), Ty::Number)),
        "<" | ">" | "<=" | ">=" | "=" => Some((Some(Ty::Number), Ty::Boolean)),
        "string-append" => Some((Some(Ty::Str), Ty::Str)),
        "string-length" => Some((Some(Ty::Str), Ty::Number)),
        "not" => Some((None, Ty::Boolean)),
        "car" | "cdr" => Some((Some(Ty::ListT), Ty::Unknown)),
        "cons" | "list" => Some((None, Ty::ListT)),
        "number?" | "string?" | "boolean?" | "symbol?" | "list?" | "procedure?" => Some((None, Ty::Boolean)),
        _ => None,
    }
}

fn narrow_predicate(op: &str) -> Option<Ty> {
    match op {
        "number?" => Some(Ty::Number), "string?" => Some(Ty::Str), "boolean?" => Some(Ty::Boolean),
        "symbol?" => Some(Ty::Symbol), "list?" => Some(Ty::ListT), "procedure?" => Some(Ty::Procedure),
        _ => None,
    }
}

/// If `cond` is `(pred var)` for a recognized type predicate, narrow `var`
/// to that type in the then-branch env and to `Unknown` in the else-branch
/// env (we don't model "not X", so the else side just gives up narrowing
/// rather than asserting something unsound).
fn narrow_from_if(cond: &Expr, env: &TyEnv) -> (TyEnv, TyEnv) {
    if let Expr::List(items) = cond {
        if items.len() == 2 {
            if let (Expr::Symbol(op), Expr::Symbol(var)) = (&items[0], &items[1]) {
                if let Some(ty) = narrow_predicate(op) {
                    let mut then_env = env.clone();
                    then_env.insert(var.clone(), ty);
                    let mut else_env = env.clone();
                    else_env.insert(var.clone(), Ty::Unknown);
                    return (then_env, else_env);
                }
            }
        }
    }
    (env.clone(), env.clone())
}

pub fn infer(expr: &Expr, env: &TyEnv, errors: &mut Vec<String>) -> Ty {
    match expr {
        Expr::Number(_) => Ty::Number,
        Expr::String(_) => Ty::Str,
        Expr::Bool(_)   => Ty::Boolean,
        Expr::Nil       => Ty::Unknown,
        Expr::Symbol(s) => env.get(s).copied().unwrap_or(Ty::Unknown),
        Expr::List(items) if !items.is_empty() => {
            if let Expr::Symbol(head) = &items[0] {
                match head.as_str() {
                    "if" if items.len() >= 3 => {
                        infer(&items[1], env, errors); // condition may itself contain an error
                        let (then_env, else_env) = narrow_from_if(&items[1], env);
                        let then_ty = infer(&items[2], &then_env, errors);
                        let else_ty = if items.len() > 3 { Some(infer(&items[3], &else_env, errors)) } else { None };
                        match else_ty { Some(e) if e == then_ty => then_ty, _ => Ty::Unknown }
                    }
                    "let" | "let*" if items.len() >= 3 => {
                        match &items[1] {
                            Expr::List(bindings) => {
                                let mut child = env.clone();
                                for b in bindings.iter() {
                                    if let Expr::List(pair) = b {
                                        if pair.len() == 2 {
                                            if let Expr::Symbol(name) = &pair[0] {
                                                let src_env: &TyEnv = if head == "let" { env } else { &child };
                                                let ty = infer(&pair[1], src_env, errors);
                                                child.insert(name.clone(), ty);
                                                continue;
                                            }
                                        }
                                    }
                                }
                                let mut result = Ty::Unknown;
                                for stmt in &items[2..] { result = infer(stmt, &child, errors); }
                                result
                            }
                            _ => Ty::Unknown,
                        }
                    }
                    "begin" => {
                        let mut result = Ty::Unknown;
                        for stmt in &items[1..] { result = infer(stmt, env, errors); }
                        result
                    }
                    _ => {
                        let arg_types: Vec<Ty> = items[1..].iter().map(|a| infer(a, env, errors)).collect();
                        match builtin_signature(head) {
                            Some((Some(expected), ret)) => {
                                for (i, at) in arg_types.iter().enumerate() {
                                    if *at != Ty::Unknown && *at != expected {
                                        errors.push(format!(
                                            "{}: argument {} is statically known to be {}, expected {}",
                                            head, i + 1, at.name(), expected.name()
                                        ));
                                    }
                                }
                                ret
                            }
                            Some((None, ret)) => ret,
                            None => match lookup_signature(head) {
                                // A define-typed function: check args against its
                                // declared param types, infer its declared return.
                                Some((param_tys, ret)) => {
                                    for (i, (at, expected)) in arg_types.iter().zip(param_tys.iter()).enumerate() {
                                        if *at != Ty::Unknown && *expected != Ty::Unknown && at != expected {
                                            errors.push(format!(
                                                "{}: argument {} is statically known to be {}, expected {}",
                                                head, i + 1, at.name(), expected.name()
                                            ));
                                        }
                                    }
                                    ret
                                }
                                None => Ty::Unknown, // unrecognized call — conservative
                            },
                        }
                    }
                }
            } else {
                Ty::Unknown
            }
        }
        _ => Ty::Unknown,
    }
}
