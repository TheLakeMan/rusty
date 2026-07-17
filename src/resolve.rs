// Copyright (c) 2026 Nicholas Vermeulen
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Lexical addressing: resolve a lambda body's variable references to
//! `Expr::LocalRef(depth, slot)` / `Expr::GlobalRef` at closure creation.
//!
//! Runs ONLY on closures created at the global env (top-level `define`/
//! `lambda` — the hot case; a closure nested inside another lambda already
//! executes a resolved body if its enclosing lambda was resolved... no:
//! nested lambda bodies are deliberately left verbatim, see below). The
//! output AST is what `eval` executes; everything else (checkpoint, grad,
//! check-effects, display, macro argument conversion) either reads the
//! resolved tree and degrades refs to their names, or never sees it.
//!
//! Soundness split:
//! - STATIC (this file): depth/slot arithmetic must mirror eval's
//!   frame-creating forms exactly — lambda calls (`extend`), let, let*,
//!   letrec, named-let, do. Anything not fully modeled (try-catch, match,
//!   quasiquote, nested lambdas, unknown special forms) is left verbatim;
//!   an unresolved Symbol always takes the full name walk and is correct
//!   by definition.
//! - DYNAMIC (env.rs): runtime defines into live frames (internal define,
//!   `eval`-in-current-env, macro-expanded defines) mark the frame dirty;
//!   `get_slot`/`get_global` fall back to the name walk across dirty
//!   frames. Slot reads verify the name and fall back on mismatch or
//!   promotion, so resolver drift degrades to a slowdown, never a wrong
//!   answer. GlobalRefs additionally cache their root-table index (root
//!   slots are append-only, so a filled cache never goes stale).

use crate::parser::{elist, Expr};
use std::cell::Cell;
use std::rc::Rc;

/// Head symbols eval dispatches as special forms BEFORE any env lookup.
/// These must never be rewritten in head position (and unmodeled ones make
/// their whole form verbatim). Over-inclusion is safe — a head left as a
/// Symbol just takes today's dynamic path; omission would break dispatch.
const SPECIALS: &[&str] = &[
    "llm", "deftool", "tool-call", "list-tools", "react-loop",
    "load", "load-relative", "checkpoint", "command-registry",
    "try-catch", "match", "quote", "eval", "quasiquote",
    "if", "when", "unless", "cond", "and", "or", "begin", "eval-when",
    "define", "def", "set!", "set", "lambda", "fn", "λ",
    "defmacro", "define-macro", "defrust", "defrust*",
    "let", "let*", "letrec", "letrec*", "do",
];

fn is_special(name: &str) -> bool {
    SPECIALS.contains(&name)
}

/// One statically-modeled runtime frame. `names` is deduped in insertion
/// order = runtime slot order. Slot refs are only emitted while the frame
/// provably stays Small (static names ≤ SMALL_MAX; runtime growth is the
/// dirty flag's problem).
struct Scope {
    names: Vec<String>,
}

const SMALL_MAX: usize = 8; // keep in sync with env.rs

struct Resolver {
    scopes: Vec<Scope>,
}

impl Resolver {
    fn push_names(&mut self, names: Vec<String>) {
        let mut deduped: Vec<String> = Vec::new();
        for n in names {
            if !deduped.contains(&n) { deduped.push(n); }
        }
        self.scopes.push(Scope { names: deduped });
    }

    fn resolve_symbol(&self, s: &str) -> Expr {
        for (up, scope) in self.scopes.iter().rev().enumerate() {
            if let Some(slot) = scope.names.iter().position(|n| n == s) {
                if scope.names.len() <= SMALL_MAX {
                    return Expr::LocalRef {
                        depth: up as u16,
                        slot: slot as u16,
                        name: Rc::from(s),
                    };
                }
                // Bound here but the frame may promote — name walk.
                return Expr::Symbol(s.to_string());
            }
        }
        Expr::GlobalRef { name: Rc::from(s), idx: Cell::new(u32::MAX) }
    }

    fn resolve_expr(&mut self, e: &Expr) -> Expr {
        match e {
            Expr::Symbol(s) => self.resolve_symbol(s),
            Expr::List(items) => self.resolve_list(items),
            other => other.clone(),
        }
    }

    fn resolve_all(&mut self, exprs: &[Expr]) -> Vec<Expr> {
        exprs.iter().map(|e| self.resolve_expr(e)).collect()
    }

    fn resolve_list(&mut self, items: &Rc<Vec<Expr>>) -> Expr {
        if items.is_empty() {
            return Expr::List(items.clone());
        }
        let head = match &items[0] {
            Expr::Symbol(s) => s.as_str(),
            // Computed head (e.g. ((car fs) x)) — resolve every element.
            _ => {
                return elist(self.resolve_all(items));
            }
        };
        if !is_special(head) {
            // Ordinary call (or a macro call — macro args degrade back to
            // symbols via expr_to_value, so rewriting them is transparent).
            return elist(self.resolve_all(items));
        }
        match head {
            // Inert or unmodeled regions: copy verbatim (shares the Rc).
            // Nested lambda bodies stay verbatim so every Value::Lambda's
            // body field remains ref-free unless it was resolved itself.
            "quote" | "quasiquote" | "lambda" | "fn" | "λ"
            | "defmacro" | "define-macro" | "deftool" | "defrust" | "defrust*"
            | "try-catch" | "match" | "do"
            | "llm" | "tool-call" | "list-tools" | "react-loop"
            | "load" | "load-relative" | "checkpoint" | "command-registry"
            | "eval-when" => Expr::List(items.clone()),

            // (define name expr) — name stays a Symbol (eval's define arm
            // requires it); the value expression evaluates in the current
            // env, so resolve it. (define (f ..) body...) and def's
            // 4-element function form (def f (params) body...) create
            // closures at a non-root env — verbatim.
            "define" | "def" => {
                let value_form = matches!(items.get(1), Some(Expr::Symbol(_)))
                    && if head == "def" { items.len() == 3 } else { items.len() >= 3 };
                if value_form {
                    let mut out = vec![items[0].clone(), items[1].clone()];
                    out.extend(self.resolve_all(&items[2..]));
                    elist(out)
                } else {
                    Expr::List(items.clone())
                }
            }

            // (set! name expr) — target name stays a Symbol.
            "set!" | "set" => {
                if items.len() >= 3 {
                    let mut out = vec![items[0].clone(), items[1].clone()];
                    out.extend(self.resolve_all(&items[2..]));
                    elist(out)
                } else {
                    Expr::List(items.clone())
                }
            }

            // No frame, all subexpressions evaluate in the current env.
            "if" | "when" | "unless" | "begin" | "and" | "or" | "eval" => {
                let mut out = vec![items[0].clone()];
                out.extend(self.resolve_all(&items[1..]));
                elist(out)
            }

            // (cond (test body...)... (else body...)) — the `else` keyword
            // is matched literally by eval and must stay a Symbol.
            "cond" => {
                let mut out = vec![items[0].clone()];
                for clause in &items[1..] {
                    match clause {
                        Expr::List(c) if !c.is_empty() => {
                            let mut nc = Vec::with_capacity(c.len());
                            if matches!(&c[0], Expr::Symbol(s) if s == "else") {
                                nc.push(c[0].clone());
                            } else {
                                nc.push(self.resolve_expr(&c[0]));
                            }
                            nc.extend(self.resolve_all(&c[1..]));
                            out.push(elist(nc));
                        }
                        other => out.push(self.resolve_expr(other)),
                    }
                }
                elist(out)
            }

            "let" => {
                // Named let: (let loop ((var init)...) body...) — two runtime
                // frames: [loop-name], then the call frame [vars].
                if let Some(Expr::Symbol(lname)) = items.get(1) {
                    if items.len() >= 4 {
                        return self.resolve_named_let(items, lname.clone());
                    }
                    return Expr::List(items.clone());
                }
                // Plain let: inits evaluate in the OUTER env, body in the
                // child frame.
                let Some((names, resolved_bindings)) = self.resolve_bindings(items, false) else {
                    return Expr::List(items.clone());
                };
                self.push_names(names);
                let body = self.resolve_all(&items[2..]);
                self.scopes.pop();
                let mut out = vec![items[0].clone(), resolved_bindings];
                out.extend(body);
                elist(out)
            }

            // let*: one frame; init k evaluates inside the child with
            // names[0..k] already bound. letrec: one frame; every name is
            // pre-bound (to Nil) before any init runs.
            "let*" | "letrec" | "letrec*" => {
                let Some(binding_list) = as_binding_list(items) else {
                    return Expr::List(items.clone());
                };
                let seq = head == "let*";
                if seq {
                    self.push_names(Vec::new());
                } else {
                    let mut names = Vec::new();
                    for b in binding_list.iter() {
                        match binding_name(b) {
                            Some(n) => names.push(n),
                            None => return Expr::List(items.clone()),
                        }
                    }
                    self.push_names(names);
                }
                let mut nb = Vec::with_capacity(binding_list.len());
                let mut ok = true;
                for b in binding_list.iter() {
                    let (Expr::List(pair), Some(n)) = (b, binding_name(b)) else {
                        ok = false;
                        break;
                    };
                    let init = self.resolve_expr(&pair[1]);
                    nb.push(elist(vec![pair[0].clone(), init]));
                    if seq {
                        let scope = self.scopes.last_mut().unwrap();
                        if !scope.names.contains(&n) { scope.names.push(n); }
                    }
                }
                if !ok {
                    self.scopes.pop();
                    return Expr::List(items.clone());
                }
                let body = self.resolve_all(&items[2..]);
                self.scopes.pop();
                let mut out = vec![items[0].clone(), elist(nb)];
                out.extend(body);
                elist(out)
            }

            // Modeled specials that fell through a malformed shape, plus
            // anything added to SPECIALS later: verbatim is always safe.
            _ => Expr::List(items.clone()),
        }
    }

    /// (let name ((var init)...) body...) — inits resolve in the outer
    /// scope; body sees [loop-frame with `name`] then [param frame].
    fn resolve_named_let(&mut self, items: &Rc<Vec<Expr>>, lname: String) -> Expr {
        let Some((names, resolved_bindings)) = self.resolve_bindings_at(items, 2) else {
            return Expr::List(items.clone());
        };
        self.push_names(vec![lname]);
        self.push_names(names);
        let body = self.resolve_all(&items[3..]);
        self.scopes.pop();
        self.scopes.pop();
        let mut out = vec![items[0].clone(), items[1].clone(), resolved_bindings];
        out.extend(body);
        elist(out)
    }

    /// Resolve a ((var init)...) binding list with inits in the CURRENT
    /// scope (plain let / named let). Returns the binding names in order
    /// plus the rebuilt binding list, or None on any non-(sym init) shape.
    fn resolve_bindings(&mut self, items: &Rc<Vec<Expr>>, _seq: bool) -> Option<(Vec<String>, Expr)> {
        self.resolve_bindings_at(items, 1)
    }

    fn resolve_bindings_at(&mut self, items: &Rc<Vec<Expr>>, pos: usize) -> Option<(Vec<String>, Expr)> {
        let Some(Expr::List(bs)) = items.get(pos) else { return None; };
        let mut names = Vec::with_capacity(bs.len());
        let mut nb = Vec::with_capacity(bs.len());
        for b in bs.iter() {
            let Expr::List(pair) = b else { return None; };
            if pair.len() != 2 { return None; }
            let Expr::Symbol(n) = &pair[0] else { return None; };
            names.push(n.clone());
            let init = self.resolve_expr(&pair[1]);
            nb.push(elist(vec![pair[0].clone(), init]));
        }
        Some((names, elist(nb)))
    }
}

fn as_binding_list(items: &Rc<Vec<Expr>>) -> Option<Rc<Vec<Expr>>> {
    match items.get(1) {
        Some(Expr::List(bs)) => Some(bs.clone()),
        _ => None,
    }
}

fn binding_name(b: &Expr) -> Option<String> {
    match b {
        Expr::List(pair) if pair.len() == 2 => match &pair[0] {
            Expr::Symbol(n) => Some(n.clone()),
            _ => None,
        },
        _ => None,
    }
}

/// Resolve a lambda body created at the global env. `params`/`rest` form
/// the call frame (rest binds after the fixed params, mirroring
/// `EnvFrame::extend`).
pub fn resolve_body(params: &[String], rest: &Option<String>, body: &[Expr]) -> Vec<Expr> {
    let mut frame: Vec<String> = params.to_vec();
    if let Some(r) = rest {
        frame.push(r.clone());
    }
    let mut r = Resolver { scopes: Vec::new() };
    r.push_names(frame);
    r.resolve_all(body)
}
