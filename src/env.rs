use std::collections::HashMap;
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

/// A Rusty value.
#[derive(Clone, Debug)]
pub enum Value {
    Number(f64),
    Bool(bool),
    String(String),
    Symbol(String),
    List(Rc<Vec<Value>>),           // Rc for cheap sharing — clone is O(1)
    Builtin(&'static str, fn(&[Value]) -> Result<Value, String>),
    Lambda {
        params: Vec<String>,
        rest:   Option<String>,
        body:   Vec<Expr>,
        env:    Env,
    },
    Macro {
        params: Vec<String>,
        rest:   Option<String>,
        body:   Vec<Expr>,
        env:    Env,
    },
    Tool {
        name: String,
        description: String,
        params: Vec<String>,
        body: Vec<Expr>,
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
            Value::Nil => write!(f, "()"),
        }
    }
}

/// Shared, ref-counted environment frame.
pub type Env = Rc<RefCell<EnvFrame>>;

#[derive(Debug)]
pub struct EnvFrame {
    pub vars:   HashMap<String, Value>,
    pub parent: Option<Env>,
}

impl EnvFrame {
    pub fn new(parent: Option<Env>) -> Env {
        Rc::new(RefCell::new(EnvFrame { vars: HashMap::new(), parent }))
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
    Value::List(Rc::new(vals))
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
