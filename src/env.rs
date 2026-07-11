// Copyright (c) 2026 Nicholas Vermeulen
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Frame variable map. FxHash instead of the std default: SipHash's
/// DoS-resistance buys nothing for interpreter-internal short var names
/// and costs real time on every lookup/insert (Phase 3.3).
pub type VarMap = rustc_hash::FxHashMap<String, Value>;
use std::rc::Rc;
use std::cell::RefCell;
use std::sync::atomic::{AtomicU64, Ordering};
use crate::parser::Expr;

// ── Fresh-name generation ────────────────────────────────────────────────
// Shared counter backing both the `gensym` builtin and the macro hygiene
// rename pass, so every generated name is globally unique.
static GENSYM_CTR: AtomicU64 = AtomicU64::new(0);

pub fn gensym_name(prefix: &str) -> String {
    let n = GENSYM_CTR.fetch_add(1, Ordering::Relaxed);
    format!("{}__{}", prefix, n)
}

/// A shared list slice: an Rc'd buffer plus a start offset. Cloning is an
/// O(1) refcount bump (as before), and `tail()` — the representation of
/// `cdr` — is O(1) too: same buffer, offset bumped by one. Before this,
/// cdr copied the whole tail, which made every recursive list traversal
/// O(n²); a 30k-element walk took 6.4 s and now takes ~3 ms.
///
/// Deref gives `&[Value]`, so every read site treats it exactly like the
/// old `Rc<Vec<Value>>` contents. Trade-off (deliberate, same as slices
/// everywhere): a live tail keeps the WHOLE original buffer alive — a
/// 1-element cdr chain end pins its 30k-element ancestor until dropped.
/// `cons` still copies (prepending can't share a buffer that grows left);
/// build lists with accumulate+reverse or `range`, both linear.
#[derive(Clone, Debug)]
pub struct LSlice {
    data:  Rc<Vec<Value>>,
    start: usize,
}

impl LSlice {
    pub fn new(vals: Vec<Value>) -> Self { LSlice { data: Rc::new(vals), start: 0 } }
    /// O(1) suffix: same buffer, offset advanced by n (n ≤ len; n == len
    /// gives the empty list). Backs cdr, member, and list-tail.
    pub fn advance(&self, n: usize) -> LSlice {
        debug_assert!(n <= self.len(), "LSlice::advance past end");
        LSlice { data: self.data.clone(), start: self.start + n }
    }
    /// O(1) cdr: same buffer, next offset. Caller guarantees non-empty.
    pub fn tail(&self) -> LSlice {
        debug_assert!(!self.is_empty(), "LSlice::tail of empty list");
        self.advance(1)
    }
}

impl std::ops::Deref for LSlice {
    type Target = [Value];
    #[inline]
    fn deref(&self) -> &[Value] { &self.data[self.start..] }
}

/// A Rusty value.
#[derive(Clone, Debug)]
pub enum Value {
    Number(f64),
    Bool(bool),
    String(String),
    Symbol(String),
    List(LSlice),                   // shared slice — clone AND cdr are O(1)
    Builtin(&'static str, fn(&[Value]) -> Result<Value, String>),
    // params/body are Rc'd (v0.32.0 profiling): every call site looks a
    // lambda up and CLONES the Value — with plain Vecs that deep-copied
    // the param strings and body exprs on every single call (~25% of
    // call-heavy runtime). Rc makes the clone three refcount bumps.
    Lambda {
        params: Rc<Vec<String>>,
        rest:   Option<String>,
        body:   Rc<Vec<Expr>>,
        env:    Env,
    },
    Macro {
        params: Rc<Vec<String>>,
        rest:   Option<String>,
        body:   Rc<Vec<Expr>>,
        env:    Env,
    },
    Tool {
        name: String,
        description: String,
        params: Rc<Vec<String>>,
        body: Rc<Vec<Expr>>,
        env: Env,
    },
    // Native tensor (Phase 3.1): flat row-major f64 buffer + shape.
    // Rc'd like List, so clone is a refcount bump. No external ML crate —
    // this is Rusty's own tensor, per the no-external-deps constraint.
    Tensor {
        data:  Rc<Vec<f64>>,
        shape: Vec<usize>,
    },
    // A `defrust`-compiled function: real Rust, compiled via rustc and
    // dynamically loaded. `fn_ptr` is a raw `extern "C" fn(*const f64, usize)
    // -> f64` transmuted to a data pointer (dodges fighting libloading's
    // Symbol lifetime — see eval.rs's `rust_jit` module for the call site).
    // `lib` is kept alive only to keep the .so mapped; it's never touched
    // again after load.
    Native {
        name:  String,
        arity: usize,
        #[allow(dead_code)] // never read — held only to keep the .so mapped
        lib:     Rc<libloading::Library>,
        fn_ptr:  *const (),
    },
    // A `graph-compile-grad` fused training kernel (Phase 3.3 kernel fusion,
    // tensor half): the whole forward+backward graph compiled to native code,
    // shape-specialized to the example arguments it was compiled with.
    // `fn_ptr` is `extern "C" fn(*const f64, *mut f64)` — flattened inputs
    // in, loss + flattened gradients out. `None` in a shape slot = scalar.
    NativeGrad {
        name:       String,
        #[allow(dead_code)] // never read — held only to keep the .so mapped
        lib:        Rc<libloading::Library>,
        fn_ptr:     *const (),
        in_shapes:  Rc<Vec<Option<Vec<usize>>>>,
        out_shapes: Rc<Vec<Option<Vec<usize>>>>,
    },
    Nil,
}

impl std::fmt::Display for Value {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Value::Number(n) => {
                if n.fract() == 0.0 && n.abs() < 1e15 {
                    write!(f, "{}", *n as i64)
                } else {
                    write!(f, "{}", n)
                }
            }
            Value::Bool(true)  => write!(f, "#t"),
            Value::Bool(false) => write!(f, "#f"),
            Value::String(s)   => write!(f, "\"{}\"", s),
            Value::Symbol(s)   => write!(f, "{}", s),
            Value::List(vs) => {
                write!(f, "(")?;
                for (i, v) in vs.iter().enumerate() {
                    if i > 0 { write!(f, " ")?; }
                    write!(f, "{}", v)?;
                }
                write!(f, ")")
            }
            Value::Builtin(name, _) => write!(f, "#<builtin:{}>", name),
            Value::Macro { params, .. } => write!(f, "#<macro ({})>", params.join(" ")),
            Value::Lambda { params, rest, .. } => {
                write!(f, "#<lambda ({}", params.join(" "))?;
                if let Some(r) = rest { write!(f, " . {}", r)?; }
                write!(f, ")>")
            }
            Value::Tool { name, .. } => write!(f, "#<tool:{}>", name),
            Value::Tensor { data, shape } => {
                let dims: Vec<String> = shape.iter().map(|d| d.to_string()).collect();
                if data.len() <= 8 {
                    let vals: Vec<String> = data.iter().map(|v| {
                        if v.fract() == 0.0 && v.abs() < 1e15 { format!("{}", *v as i64) } else { format!("{}", v) }
                    }).collect();
                    write!(f, "#<tensor {} [{}]>", dims.join("x"), vals.join(" "))
                } else {
                    write!(f, "#<tensor {}>", dims.join("x"))
                }
            }
            Value::Native { name, arity, .. } => write!(f, "#<native:{}/{}>", name, arity),
            Value::NativeGrad { name, in_shapes, .. } => {
                let dims: Vec<String> = in_shapes.iter().map(|s| match s {
                    None => "scalar".to_string(),
                    Some(sh) => sh.iter().map(|d| d.to_string()).collect::<Vec<_>>().join("x"),
                }).collect();
                write!(f, "#<native-grad:{} ({})>", name, dims.join(" "))
            }
            Value::Nil => write!(f, "()"),
        }
    }
}

/// Shared, ref-counted environment frame.
pub type Env = Rc<RefCell<EnvFrame>>;

#[derive(Debug)]
pub struct EnvFrame {
    pub vars:   VarMap,
    pub parent: Option<Env>,
}

// Frame maps are pooled (Phase 3.3 memory pooling — see src/arena.rs):
// construction takes a recycled map, Drop hands the cleared map back.
impl Drop for EnvFrame {
    fn drop(&mut self) {
        if self.vars.capacity() == 0 { return; } // never allocated — nothing to recycle
        let mut m = std::mem::take(&mut self.vars);
        // Clear BEFORE touching the pool: dropping the contained values can
        // recursively drop other EnvFrames, which also borrow the pool.
        m.clear();
        crate::arena::recycle_map(m);
    }
}

impl EnvFrame {
    pub fn new(parent: Option<Env>) -> Env {
        Rc::new(RefCell::new(EnvFrame { vars: crate::arena::take_map(), parent }))
    }

    pub fn get(env: &Env, name: &str) -> Option<Value> {
        let frame = env.borrow();
        if let Some(v) = frame.vars.get(name) { return Some(v.clone()); }
        frame.parent.as_ref().and_then(|p| EnvFrame::get(p, name))
    }

    pub fn set(env: &Env, name: String, value: Value) {
        env.borrow_mut().vars.insert(name, value);
    }

    pub fn set_existing(env: &Env, name: &str, value: Value) -> bool {
        let mut frame = env.borrow_mut();
        if frame.vars.contains_key(name) {
            frame.vars.insert(name.to_string(), value);
            true
        } else if let Some(ref parent) = frame.parent.clone() {
            EnvFrame::set_existing(parent, name, value)
        } else {
            false
        }
    }

    pub fn extend(parent: &Env, params: &[String], rest: &Option<String>, args: Vec<Value>) -> Result<Env, String> {
        if rest.is_none() && args.len() != params.len() {
            return Err(format!("Arity error: expected {} args, got {}", params.len(), args.len()));
        }
        if rest.is_some() && args.len() < params.len() {
            return Err(format!("Arity error: expected at least {} args, got {}", params.len(), args.len()));
        }
        let child = EnvFrame::new(Some(parent.clone()));
        for (p, a) in params.iter().zip(args.iter()) {
            EnvFrame::set(&child, p.clone(), a.clone());
        }
        if let Some(r) = rest {
            let tail: Vec<Value> = args[params.len()..].to_vec();
            EnvFrame::set(&child, r.clone(), list(tail));
        }
        Ok(child)
    }
}

// ── List helpers ──────────────────────────────────────────────────────────────
// Use these everywhere instead of Value::List(vec![...]) directly.
// list() wraps a Vec in Rc — clone is O(1) reference count bump.

pub fn list(vals: Vec<Value>) -> Value {
    Value::List(LSlice::new(vals))
}

pub fn cons(head: Value, tail: Value) -> Value {
    match tail {
        Value::List(rc) => {
            let mut v = vec![head];
            v.extend_from_slice(&rc);
            list(v)
        }
        Value::Nil => list(vec![head]),
        other      => list(vec![head, other]),
    }
}
