use std::collections::HashMap;
use std::rc::Rc;
use std::cell::RefCell;
use crate::parser::Expr;

/// A Rusty value.
#[derive(Clone, Debug)]
pub enum Value {
    Number(f64),
    Bool(bool),
    String(String),
    Symbol(String),
    List(Vec<Value>),
    /// Native built-in function
    Builtin(&'static str, fn(&[Value]) -> Result<Value, String>),
    /// User-defined lambda with captured env
    Lambda {
        params: Vec<String>,
        rest:   Option<String>,
        body:   Vec<Expr>,
        env:    Env,
    },
    /// defmacro — like Lambda but args passed unevaluated
    Macro {
        params: Vec<String>,
        rest:   Option<String>,
        body:   Vec<Expr>,
        env:    Env,
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
            Value::Nil => write!(f, "()"),
        }
    }
}

/// Shared, ref-counted environment frame.
pub type Env = Rc<RefCell<EnvFrame>>;

#[derive(Debug)]
pub struct EnvFrame {
    vars:   HashMap<String, Value>,
    parent: Option<Env>,
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
            EnvFrame::set(&child, r.clone(), Value::List(tail));
        }
        Ok(child)
    }
}
