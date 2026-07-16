// Copyright (c) 2026 Nicholas Vermeulen
// SPDX-License-Identifier: AGPL-3.0-or-later

//! interp.rs — shared interpreter core used by both main.rs (REPL/CLI)
//! and lib.rs (PyO3 Python bridge).

use crate::lexer::Lexer;
use crate::parser::Parser;
use crate::env::{Env, EnvFrame, Value, list, cons};
use crate::eval::Evaluator;

// ── Command categories (for the command registry / discovery) ─────────────
// name → category, populated by cat!() markers during setup_builtins and by
// the `categorize!` builtin from std.lisp. Static per thread; overwriting on a
// fresh env setup is idempotent. Read by the `(command-registry)` special form.
thread_local! {
    static CATEGORIES: std::cell::RefCell<rustc_hash::FxHashMap<String, String>> =
        std::cell::RefCell::new(rustc_hash::FxHashMap::default());
}
pub fn set_category(name: &str, cat: &str) {
    CATEGORIES.with(|c| { c.borrow_mut().insert(name.to_string(), cat.to_string()); });
}
pub fn category_of(name: &str) -> Option<String> {
    CATEGORIES.with(|c| c.borrow().get(name).cloned())
}

// ── Core run helper ───────────────────────────────────────────────────────

pub fn run_code(input: &str, env: &Env, eval: &Evaluator) -> Result<Value, String> {
    let tokens = Lexer::new(input).tokenize();
    // parse_checked, not parse: a truncated file must not run as if it were
    // whole (see parser::parse_checked). The REPL has already decided the input
    // is complete before it calls here.
    let ast    = Parser::new(tokens).parse_checked()?;
    eval.eval_all(&ast, env)
}

// ── Stdlib loader ─────────────────────────────────────────────────────────

pub fn load_stdlib(env: &Env, eval: &Evaluator) {
    for path in &["std.lisp", "/usr/local/share/rusty/std.lisp"] {
        if let Ok(code) = std::fs::read_to_string(path) {
            if let Err(e) = run_code(&code, env, eval) {
                eprintln!("Warning: stdlib error in {}: {}", path, e);
            }
            return;
        }
    }
    if let Err(e) = run_code(STDLIB, env, eval) {
        eprintln!("Warning: embedded stdlib error: {}", e);
    }
}

pub const STDLIB: &str = include_str!("../std.lisp");

// ── Package manager loader ────────────────────────────────────────────────
// pkg.lisp (the registry-less package manager) is embedded and auto-loaded so
// that `pkg-install`/`pkg-verify`/`pkg-drift` work in a stock `rusty` with no
// `(load "pkg.lisp")` first — the "one install" story the apps' package
// manifests rely on. Same disk-first-then-embedded shape as load_stdlib, and it
// runs AFTER it because pkg.lisp uses std.lisp helpers (foldl/assoc/when/...).
// Loading only defines functions — pkg.lisp has no top-level side effects.
pub fn load_pkg(env: &Env, eval: &Evaluator) {
    for path in &["pkg.lisp", "/usr/local/share/rusty/pkg.lisp"] {
        if let Ok(code) = std::fs::read_to_string(path) {
            if let Err(e) = run_code(&code, env, eval) {
                eprintln!("Warning: pkg error in {}: {}", path, e);
            }
            return;
        }
    }
    if let Err(e) = run_code(PKGLIB, env, eval) {
        eprintln!("Warning: embedded pkg error: {}", e);
    }
}

pub const PKGLIB: &str = include_str!("../pkg.lisp");

// ── Fresh environment factory ─────────────────────────────────────────────

pub fn make_env() -> Env {
    let env  = EnvFrame::new(None);
    let eval = Evaluator::new();
    setup_builtins(&env);
    load_stdlib(&env, &eval);
    load_pkg(&env, &eval);
    // Auto-load memory if it exists
    let mem = memory_path();
    if mem.exists() {
        if let Ok(code) = std::fs::read_to_string(&mem) {
            let _ = run_code(&code, &env, &eval);
        }
    }
    env
}

// ── Display helpers ───────────────────────────────────────────────────────

pub fn format_number(n: f64) -> String {
    if n.fract() == 0.0 && n.abs() < 1e15 { format!("{}", n as i64) }
    else { format!("{}", n) }
}

pub fn print_repr(v: &Value) -> String {
    match v {
        Value::String(s) => s.clone(),
        Value::List(xs) => {
            let inner: Vec<String> = xs.iter().map(print_repr).collect();
            format!("({})", inner.join(" "))
        }
        other => format!("{}", other),
    }
}

// ── Value helpers ─────────────────────────────────────────────────────────

pub fn num2(args: &[Value]) -> Result<(f64, f64), String> {
    if args.len() != 2 {
        return Err(format!("Expected 2 args, got {}", args.len()));
    }
    match (&args[0], &args[1]) {
        (Value::Number(a), Value::Number(b)) => Ok((*a, *b)),
        _ => Err(format!("Expected numbers, got {} and {}", args[0], args[1])),
    }
}

pub fn nums(args: &[Value]) -> Result<Vec<f64>, String> {
    args.iter().map(|v| match v {
        Value::Number(n) => Ok(*n),
        _ => Err(format!("Expected number, got {}", v)),
    }).collect()
}

// ── Symbolic-regression native fitness (v0.38.0) ──────────────────────────
// GP fitness (symreg.lisp sr-fitness) evaluated every candidate through the
// full interpreter per data row — measured ~35% of the symreg benchmark, with
// sr-pdiv paying a whole extra lambda call per division. `sr-eval-mse`
// compiles the candidate tree ONCE to an index-resolved node tree, then
// sweeps the rows natively. Bit-identity contract with the interpreted path:
// same f64 operations (each op mirrors the builtin exactly — binary `/` is
// a/b with a "Division by zero" raise, log is ln, sr-pdiv is (if (= b 0) 1
// (/ a b))), same accumulation order (left fold from 0 in row order, one
// final division by the row count). Vocabulary it doesn't know (ops added
// via symreg-ops!, macro building blocks) returns Nil at compile time so the
// Lisp side can fall back to the eval path — extensibility is untouched.

enum SrNode {
    Const(f64),
    Var(usize),
    Bin(SrBin, Box<SrNode>, Box<SrNode>),
    Un(SrUn, Box<SrNode>),
}
#[derive(Clone, Copy)]
enum SrBin { Add, Sub, Mul, Div, Pdiv, Expt, Atan2 }
#[derive(Clone, Copy)]
enum SrUn { Sin, Cos, Tan, Atan, Exp, Log, Sqrt, Abs }

fn sr_compile(v: &Value, vars: &[String]) -> Option<SrNode> {
    match v {
        Value::Number(n) => Some(SrNode::Const(*n)),
        Value::Symbol(s) => vars.iter().position(|p| p == s).map(SrNode::Var),
        Value::List(items) => {
            let op = match items.first()? { Value::Symbol(s) => s.as_str(), _ => return None };
            let bin = |o: SrBin, items: &[Value]| -> Option<SrNode> {
                if items.len() != 3 { return None; }
                Some(SrNode::Bin(o, Box::new(sr_compile(&items[1], vars)?),
                                    Box::new(sr_compile(&items[2], vars)?)))
            };
            let un = |o: SrUn, items: &[Value]| -> Option<SrNode> {
                if items.len() != 2 { return None; }
                Some(SrNode::Un(o, Box::new(sr_compile(&items[1], vars)?)))
            };
            match op {
                "+"       => bin(SrBin::Add,   items),
                "-"       => bin(SrBin::Sub,   items),
                "*"       => bin(SrBin::Mul,   items),
                "/"       => bin(SrBin::Div,   items),
                "sr-pdiv" => bin(SrBin::Pdiv,  items),
                "expt"    => bin(SrBin::Expt,  items),
                "atan2"   => bin(SrBin::Atan2, items),
                "sin"  => un(SrUn::Sin,  items),
                "cos"  => un(SrUn::Cos,  items),
                "tan"  => un(SrUn::Tan,  items),
                "atan" => un(SrUn::Atan, items),
                "exp"  => un(SrUn::Exp,  items),
                "log"  => un(SrUn::Log,  items),
                "sqrt" => un(SrUn::Sqrt, items),
                "abs"  => un(SrUn::Abs,  items),
                _ => None,
            }
        }
        _ => None,
    }
}

fn sr_eval(n: &SrNode, args: &[f64]) -> Result<f64, String> {
    Ok(match n {
        SrNode::Const(c) => *c,
        SrNode::Var(i)   => args[*i],
        SrNode::Un(op, a) => {
            let x = sr_eval(a, args)?;
            match op {
                SrUn::Sin => x.sin(), SrUn::Cos => x.cos(), SrUn::Tan => x.tan(),
                SrUn::Atan => x.atan(), SrUn::Exp => x.exp(), SrUn::Log => x.ln(),
                SrUn::Sqrt => x.sqrt(), SrUn::Abs => x.abs(),
            }
        }
        SrNode::Bin(op, a, b) => {
            let x = sr_eval(a, args)?;
            let y = sr_eval(b, args)?;
            match op {
                SrBin::Add => x + y,
                SrBin::Sub => x - y,
                SrBin::Mul => x * y,
                SrBin::Div => { if y == 0.0 { return Err("Division by zero".into()); } x / y }
                SrBin::Pdiv => { if y == 0.0 { 1.0 } else { x / y } }
                SrBin::Expt => x.powf(y),
                SrBin::Atan2 => x.atan2(y),
            }
        }
    })
}

fn sr_eval_mse(args: &[Value]) -> Result<Value, String> {
    if args.len() != 3 { return Err("sr-eval-mse: expected (expr vars data)".into()); }
    let vars: Vec<String> = match &args[1] {
        Value::List(l) => l.iter().map(|v| match v {
            Value::Symbol(s) => Ok(s.clone()),
            other => Err(format!("sr-eval-mse: vars must be symbols, got {}", other)),
        }).collect::<Result<_, _>>()?,
        Value::Nil => vec![],
        other => return Err(format!("sr-eval-mse: vars must be a list, got {}", other)),
    };
    let node = match sr_compile(&args[0], &vars) {
        Some(n) => n,
        None => return Ok(Value::Nil), // unknown vocabulary — caller falls back to eval
    };
    let data = match &args[2] {
        Value::List(l) => l,
        _ => return Err("sr-eval-mse: data must be a non-empty list of rows".into()),
    };
    if data.is_empty() { return Err("Division by zero".into()); } // mirrors (/ sum 0)
    let mut acc = 0.0f64;
    for row in data.iter() {
        let (xs, target) = match row {
            Value::List(r) if r.len() == 2 => {
                let xs: Vec<f64> = match &r[0] {
                    Value::List(a) => nums(a)?,
                    Value::Nil => vec![],
                    other => return Err(format!("sr-eval-mse: row args must be a list, got {}", other)),
                };
                let t = match &r[1] {
                    Value::Number(n) => *n,
                    other => return Err(format!("sr-eval-mse: row target must be a number, got {}", other)),
                };
                (xs, t)
            }
            other => return Err(format!("sr-eval-mse: bad row {}", other)),
        };
        if xs.len() != vars.len() {
            return Err(format!("Arity error: expected {} args, got {}", vars.len(), xs.len()));
        }
        let d = sr_eval(&node, &xs)? - target;
        acc += d * d;
    }
    Ok(Value::Number(acc / data.len() as f64))
}

// ── Native GP tree surgery (v0.39.0) ──────────────────────────────────────
// symreg.lisp's crossover/mutation is preorder-indexed list surgery: sr-size
// counts nodes, sr-get returns the subtree at a preorder index, sr-put
// rebuilds the tree with a subtree replaced. Interpreted, each is a recursive
// tree-walk through the trampoline — and sr-get/sr-put recompute sr-size on
// sibling subtrees as they descend, so a single operation is ~O(n^2) in tree
// size (~50% of the symreg benchmark, measured). These natives preserve the
// exact node count and preorder indexing (a "node" is one list cell or atom;
// the operator symbol at a list's head belongs to its parent node and is not
// separately indexable — sr-size only counts the arguments), so PRNG draw
// order and discovered equations stay bit-identical. Purely structural: any
// tree works regardless of vocabulary, so there's no eval fallback here.

fn sr_size_v(v: &Value) -> usize {
    match v {
        Value::List(items) if !items.is_empty() =>
            1 + items[1..].iter().map(sr_size_v).sum::<usize>(),
        _ => 1,
    }
}

fn sr_get_v(t: &Value, i: usize) -> Value {
    if i == 0 { return t.clone(); }
    match t {                                   // descend into (cdr t) at i-1
        Value::List(items) => sr_get_in(&items[1..], i - 1),
        _ => Value::Nil,                        // out of range (caller stays in-range)
    }
}
fn sr_get_in(ts: &[Value], i: usize) -> Value {
    if ts.is_empty() { return Value::Nil; }
    let s = sr_size_v(&ts[0]);
    if i < s { sr_get_v(&ts[0], i) } else { sr_get_in(&ts[1..], i - s) }
}

fn sr_put_v(t: &Value, i: usize, sub: &Value) -> Value {
    if i == 0 { return sub.clone(); }
    match t {                                   // cons (car t) (sr-put-in (cdr t) ...)
        Value::List(items) => {
            let mut out = Vec::with_capacity(items.len());
            out.push(items[0].clone());
            sr_put_in(&items[1..], i - 1, sub, &mut out);
            list(out)
        }
        _ => sub.clone(),                       // out of range (caller stays in-range)
    }
}
fn sr_put_in(ts: &[Value], i: usize, sub: &Value, out: &mut Vec<Value>) {
    if ts.is_empty() { return; }
    let s = sr_size_v(&ts[0]);
    if i < s {                                  // replace within car ts, keep (cdr ts)
        out.push(sr_put_v(&ts[0], i, sub));
        out.extend(ts[1..].iter().cloned());
    } else {                                    // keep car ts, recurse into (cdr ts)
        out.push(ts[0].clone());
        sr_put_in(&ts[1..], i - s, sub, out);
    }
}

fn sr_index(v: &Value, who: &str) -> Result<usize, String> {
    match v {
        Value::Number(n) if *n >= 0.0 => Ok(*n as usize),
        other => Err(format!("{}: index must be a non-negative number, got {}", who, other)),
    }
}

fn sr_size(args: &[Value]) -> Result<Value, String> {
    match args.first() {
        Some(v) => Ok(Value::Number(sr_size_v(v) as f64)),
        None => Err("sr-size: expected (tree)".into()),
    }
}
fn sr_get(args: &[Value]) -> Result<Value, String> {
    if args.len() != 2 { return Err("sr-get: expected (tree index)".into()); }
    Ok(sr_get_v(&args[0], sr_index(&args[1], "sr-get")?))
}
fn sr_put(args: &[Value]) -> Result<Value, String> {
    if args.len() != 3 { return Err("sr-put: expected (tree index subtree)".into()); }
    Ok(sr_put_v(&args[0], sr_index(&args[1], "sr-put")?, &args[2]))
}

pub fn apply_value(f: &Value, args: &[Value], eval: &Evaluator) -> Result<Value, String> {
    match f {
        Value::Builtin(_, func) => func(args),
        Value::Lambda { params, rest, body, env } => {
            let child = EnvFrame::extend(env, params, rest, args.to_vec())?;
            let last  = body.len() - 1;
            for e in &body[..last] { eval.eval(e, &child)?; }
            eval.eval(&body[last], &child)
        }
        Value::Tool { name, params, body, env, .. } => {
            let t0 = crate::trace::start();
            let child = EnvFrame::extend(env, params, &None, args.to_vec())?;
            let last  = body.len() - 1;
            for e in &body[..last] { eval.eval(e, &child)?; }
            let result = eval.eval(&body[last], &child);
            crate::trace::record_since("tool-call", name, t0, None);
            result
        }
        Value::Native { name, arity, fn_ptr, .. } => {
            if args.len() != *arity {
                return Err(format!("{}: expected {} arg(s), got {}", name, arity, args.len()));
            }
            let nums: Result<Vec<f64>, String> = args.iter().map(|a| match a {
                Value::Number(n) => Ok(*n),
                other => Err(format!("{}: expected a number, got {}", name, other)),
            }).collect();
            Ok(Value::Number(crate::rust_jit::call(*fn_ptr, &nums?)))
        }
        Value::NativeGrad { name, fn_ptr, in_shapes, out_shapes, .. } =>
            crate::rust_jit::call_native_grad(name, *fn_ptr, in_shapes, out_shapes, args),
        _ => Err(format!("Not callable: {}", f)),
    }
}

pub fn value_equal(a: &Value, b: &Value) -> bool {
    match (a, b) {
        (Value::Number(x),  Value::Number(y))  => x == y,
        (Value::Bool(x),    Value::Bool(y))    => x == y,
        (Value::String(x),  Value::String(y))  => x == y,
        (Value::Symbol(x),  Value::Symbol(y))  => x == y,
        (Value::Nil,        Value::Nil)        => true,
        (Value::List(xs),   Value::List(ys))   =>
            xs.len() == ys.len() && xs.iter().zip(ys.iter()).all(|(a,b)| value_equal(a,b)),
        (Value::Tensor { data: xd, shape: xs }, Value::Tensor { data: yd, shape: ys }) =>
            xs == ys && xd == yd,
        _ => false,
    }
}

// ── Tensor helpers ────────────────────────────────────────────────────────

fn nested_to_tensor(v: &Value) -> Result<(Vec<f64>, Vec<usize>), String> {
    match v {
        Value::Number(n) => Ok((vec![*n], vec![])),
        Value::List(items) if !items.is_empty() => {
            let mut sub_shape: Option<Vec<usize>> = None;
            let mut data = Vec::new();
            for item in items.iter() {
                let (d, s) = nested_to_tensor(item)?;
                match &sub_shape {
                    None => sub_shape = Some(s),
                    Some(prev) if *prev == s => {}
                    _ => return Err("tensor: ragged nested list — all rows must have the same shape".into()),
                }
                data.extend(d);
            }
            let mut shape = vec![items.len()];
            shape.extend(sub_shape.unwrap());
            Ok((data, shape))
        }
        _ => Err("tensor: elements must be numbers or non-empty nested lists of numbers".into()),
    }
}

pub fn tensor_to_nested(data: &[f64], shape: &[usize]) -> Value {
    if shape.is_empty() { return Value::Number(data[0]); }
    if shape.len() == 1 { return list(data.iter().map(|n| Value::Number(*n)).collect()); }
    let chunk = data.len() / shape[0];
    list(data.chunks(chunk).map(|c| tensor_to_nested(c, &shape[1..])).collect())
}

fn tensor_fill(args: &[Value], fill: f64, name: &str) -> Result<Value, String> {
    match args.first() {
        Some(Value::List(dims)) => {
            let shape: Vec<usize> = dims.iter().map(|v| match v {
                Value::Number(n) if *n >= 1.0 => Ok(*n as usize),
                _ => Err(format!("{}: dimensions must be positive numbers", name)),
            }).collect::<Result<Vec<_>, _>>()?;
            let len = shape.iter().product();
            Ok(Value::Tensor { data: std::rc::Rc::new(vec![fill; len]), shape })
        }
        _ => Err(format!("{}: ({} '(dim...))", name, name)),
    }
}

// Elementwise op over tensor⊕tensor (same shape) or tensor⊕scalar in
// either order (scalar broadcasts).
fn tensor_binop2(args: &[Value], name: &str, f: fn(f64, f64) -> f64) -> Result<Value, String> {
    if args.len() != 2 { return Err(format!("{}: 2 args", name)); }
    match (&args[0], &args[1]) {
        (Value::Tensor { data: a, shape: ash }, Value::Tensor { data: b, shape: bsh }) => {
            if ash != bsh {
                return Err(format!("{}: shape mismatch {:?} vs {:?}", name, ash, bsh));
            }
            Ok(Value::Tensor {
                data:  std::rc::Rc::new(a.iter().zip(b.iter()).map(|(x, y)| f(*x, *y)).collect()),
                shape: ash.clone(),
            })
        }
        (Value::Tensor { data, shape }, Value::Number(k)) => Ok(Value::Tensor {
            data: std::rc::Rc::new(data.iter().map(|x| f(*x, *k)).collect()), shape: shape.clone(),
        }),
        (Value::Number(k), Value::Tensor { data, shape }) => Ok(Value::Tensor {
            data: std::rc::Rc::new(data.iter().map(|x| f(*k, *x)).collect()), shape: shape.clone(),
        }),
        _ => Err(format!("{}: arguments must be tensors or numbers", name)),
    }
}

// ── Builtins ──────────────────────────────────────────────────────────────

pub fn setup_builtins(env: &Env) {
    // Current category for the command registry; cat!("…") sets it at each
    // section boundary, and b!/alias! tag every command they register with it.
    let cur_cat = std::cell::Cell::new("other");
    macro_rules! cat { ($c:expr) => { cur_cat.set($c); }; }
    macro_rules! b {
        ($name:expr, $f:expr) => {{
            EnvFrame::set(env, $name.to_string(), Value::Builtin($name, $f));
            crate::interp::set_category($name, cur_cat.get());
        }};
    }
    macro_rules! alias {
        ($from:expr, $to:expr) => {{
            if let Some(v) = EnvFrame::get(env, $to) {
                EnvFrame::set(env, $from.to_string(), v);
                crate::interp::set_category($from, cur_cat.get());
            }
        }};
    }

    // ── Arithmetic ────────────────────────────────────────────────────────
    cat!("arithmetic");
    b!("+", |args| {
        if args.is_empty() { return Ok(Value::Number(0.0)); }
        Ok(Value::Number(nums(args)?.iter().sum()))
    });
    b!("-", |args| {
        if args.is_empty() { return Err("- requires at least 1 arg".into()); }
        let vs = nums(args)?;
        if vs.len() == 1 { return Ok(Value::Number(-vs[0])); }
        Ok(Value::Number(vs[0] - vs[1..].iter().sum::<f64>()))
    });
    b!("*", |args| {
        if args.is_empty() { return Ok(Value::Number(1.0)); }
        Ok(Value::Number(nums(args)?.iter().product()))
    });
    b!("/", |args| {
        if args.len() < 2 { return Err("/ requires at least 2 args".into()); }
        let vs = nums(args)?;
        if vs[1..].iter().any(|&x| x == 0.0) { return Err("Division by zero".into()); }
        Ok(Value::Number(vs[0] / vs[1..].iter().product::<f64>()))
    });
    b!("mod",  |args| { let (a,b)=num2(args)?; if b==0.0{return Err("mod: division by zero".into());} Ok(Value::Number(a%b)) });
    b!("expt", |args| { let (a,b)=num2(args)?; Ok(Value::Number(a.powf(b))) });
    b!("abs",  |args| { let (Value::Number(n),) = (args.first().ok_or("abs: 1 arg")?,) else { return Err("abs: not a number".into()); }; Ok(Value::Number(n.abs())) });
    b!("sqrt", |args| { if let Some(Value::Number(n))=args.first(){Ok(Value::Number(n.sqrt()))}else{Err("sqrt: not a number".into())} });
    b!("floor",   |args| { if let Some(Value::Number(n))=args.first(){Ok(Value::Number(n.floor()))}else{Err("floor: not a number".into())} });
    b!("ceiling", |args| { if let Some(Value::Number(n))=args.first(){Ok(Value::Number(n.ceil()))}else{Err("ceiling: not a number".into())} });
    b!("round",   |args| { if let Some(Value::Number(n))=args.first(){Ok(Value::Number(n.round()))}else{Err("round: not a number".into())} });
    b!("sin",  |args| { if let Some(Value::Number(n))=args.first(){Ok(Value::Number(n.sin()))}else{Err("sin: not a number".into())} });
    b!("cos",  |args| { if let Some(Value::Number(n))=args.first(){Ok(Value::Number(n.cos()))}else{Err("cos: not a number".into())} });
    b!("tan",  |args| { if let Some(Value::Number(n))=args.first(){Ok(Value::Number(n.tan()))}else{Err("tan: not a number".into())} });
    b!("atan", |args| { if let Some(Value::Number(n))=args.first(){Ok(Value::Number(n.atan()))}else{Err("atan: not a number".into())} });
    b!("atan2",|args| { let (a,b)=num2(args)?; Ok(Value::Number(a.atan2(b))) });
    b!("exp",  |args| { if let Some(Value::Number(n))=args.first(){Ok(Value::Number(n.exp()))}else{Err("exp: not a number".into())} });
    // Natural log. Like sqrt on a negative, log of a non-positive number
    // follows IEEE (NaN / -inf) rather than raising.
    b!("log",  |args| { if let Some(Value::Number(n))=args.first(){Ok(Value::Number(n.ln()))}else{Err("log: not a number".into())} });
    b!("max", |args| { let vs=nums(args)?; Ok(Value::Number(vs.iter().cloned().fold(f64::NEG_INFINITY,f64::max))) });
    b!("min", |args| { let vs=nums(args)?; Ok(Value::Number(vs.iter().cloned().fold(f64::INFINITY,f64::min))) });
    // Native symreg fitness fast path — see the sr_* section above apply_value.
    b!("sr-eval-mse", sr_eval_mse);
    // Native GP tree surgery (crossover/mutation hot path) — same section.
    b!("sr-size", sr_size);
    b!("sr-get",  sr_get);
    b!("sr-put",  sr_put);

    // ── Comparison ────────────────────────────────────────────────────────
    cat!("comparison");
    b!("=",  |args| { let (a,b)=num2(args)?; Ok(Value::Bool(a==b)) });
    b!("<",  |args| { let (a,b)=num2(args)?; Ok(Value::Bool(a<b))  });
    b!(">",  |args| { let (a,b)=num2(args)?; Ok(Value::Bool(a>b))  });
    b!("<=", |args| { let (a,b)=num2(args)?; Ok(Value::Bool(a<=b)) });
    b!(">=", |args| { let (a,b)=num2(args)?; Ok(Value::Bool(a>=b)) });
    b!("not",|args| Ok(Value::Bool(matches!(args.first(), Some(Value::Bool(false))|Some(Value::Nil)|None))));
    b!("eq?",    |args| { if args.len()!=2{return Err("eq?: 2 args".into());} Ok(Value::Bool(value_equal(&args[0],&args[1]))) });
    b!("equal?", |args| { if args.len()!=2{return Err("equal?: 2 args".into());} Ok(Value::Bool(value_equal(&args[0],&args[1]))) });
    b!("zero?",     |args| { if let Some(Value::Number(n))=args.first(){Ok(Value::Bool(*n==0.0))}else{Err("zero?: not a number".into())} });
    b!("positive?", |args| { if let Some(Value::Number(n))=args.first(){Ok(Value::Bool(*n>0.0))}else{Err("positive?: not a number".into())} });
    b!("negative?", |args| { if let Some(Value::Number(n))=args.first(){Ok(Value::Bool(*n<0.0))}else{Err("negative?: not a number".into())} });
    b!("odd?",      |args| { if let Some(Value::Number(n))=args.first(){Ok(Value::Bool((*n as i64)%2!=0))}else{Err("odd?: not a number".into())} });
    b!("even?",     |args| { if let Some(Value::Number(n))=args.first(){Ok(Value::Bool((*n as i64)%2==0))}else{Err("even?: not a number".into())} });

    // SimpleLisp aliases
    b!("eq",  |args| { if args.len()!=2{return Err("eq: 2 args".into());} Ok(Value::Bool(value_equal(&args[0],&args[1]))) });
    b!("neq", |args| { let (a,b)=num2(args)?; Ok(Value::Bool(a!=b)) });
    cat!("arithmetic");
    alias!("add","+"  ); alias!("sub","-"); alias!("mul","*"); alias!("div","/");
    cat!("comparison");
    alias!("gt", ">"  ); alias!("lt","<"); alias!("ge",">="); alias!("le","<=");

    // ── Lists ─────────────────────────────────────────────────────────────
    cat!("lists");
    b!("cons", |args| {
        if args.len()!=2{return Err("cons: 2 args".into());}
        Ok(cons(args[0].clone(), args[1].clone()))
    });
    b!("car",   |args| match args.first() {
        Some(Value::List(xs)) if !xs.is_empty() => Ok(xs[0].clone()),
        Some(Value::Nil) => Err("car: empty list".into()),
        _ => Err("car: not a pair".into()),
    });
    b!("cdr",   |args| match args.first() {
        // O(1): shares the buffer at the next offset (see env::LSlice)
        Some(Value::List(xs)) if !xs.is_empty() => Ok(Value::List(xs.tail())),
        Some(Value::Nil) => Err("cdr: empty list".into()),
        _ => Err("cdr: not a pair".into()),
    });
    b!("list",  |args| Ok(list(args.to_vec())));
    b!("null?", |args| Ok(Value::Bool(match args.first() {
        Some(Value::Nil)|None => true,
        Some(Value::List(v)) => v.is_empty(),
        _ => false,
    })));
    b!("pair?", |args| Ok(Value::Bool(matches!(args.first(), Some(Value::List(v)) if !v.is_empty()))));
    b!("list?", |args| Ok(Value::Bool(matches!(args.first(), Some(Value::List(_))|Some(Value::Nil)))));
    b!("length",|args| match args.first() {
        Some(Value::List(xs)) => Ok(Value::Number(xs.len() as f64)),
        Some(Value::Nil)      => Ok(Value::Number(0.0)),
        _ => Err("length: not a list".into()),
    });
    b!("append",|args| {
        let mut out = Vec::new();
        for a in args {
            match a {
                Value::List(xs) => out.extend_from_slice(&xs),
                Value::Nil      => {}
                _ => return Err(format!("append: not a list: {}", a)),
            }
        }
        Ok(list(out))
    });
    b!("reverse",|args| match args.first() {
        Some(Value::List(xs)) => Ok(list(xs.iter().cloned().rev().collect())),
        Some(Value::Nil)      => Ok(Value::Nil),
        _ => Err("reverse: not a list".into()),
    });
    b!("nth",|args| {
        if args.len()!=2{return Err("nth: 2 args".into());}
        // Support both (nth list index) and (nth index list) by detecting types
        let (xs, i) = match (&args[0], &args[1]) {
            (Value::List(xs), Value::Number(i)) => (xs, *i as usize),  // (nth list index)
            (Value::Number(i), Value::List(xs)) => (xs, *i as usize),  // (nth index list)
            _ => return Err("nth: (nth list index)".into()),
        };
        xs.get(i).cloned().ok_or_else(|| format!("nth: index {} out of range", i))
    });
    b!("member",|args| {
        if args.len()!=2{return Err("member: 2 args".into());}
        if let Value::List(xs)=&args[1] {
            let idx = xs.iter().position(|x| value_equal(x,&args[0]));
            // O(1) suffix share — Scheme member returns the tail from the match
            Ok(match idx { Some(i)=>Value::List(xs.advance(i)), None=>Value::Bool(false) })
        } else { Err("member: second arg must be a list".into()) }
    });
    b!("list-tail",|args| {
        if args.len()!=2{return Err("list-tail: 2 args".into());}
        if let (Value::List(xs),Value::Number(n))=(&args[0],&args[1]) {
            let i=*n as usize;
            if i>xs.len(){return Err(format!("list-tail: index {} too large",i));}
            Ok(Value::List(xs.advance(i)))   // O(1) suffix share
        } else { Err("list-tail: (list-tail list n)".into()) }
    });
    b!("map",|args| {
        if args.len()!=2{return Err("map: 2 args".into());}
        let xs = match &args[1] {
            Value::List(xs) => xs.clone(),
            Value::Nil      => return Ok(list(vec![])),
            _ => return Err("map: second arg must be a list".into()),
        };
        let eval = Evaluator::new();
        let results: Result<Vec<Value>,_> = xs.iter().map(|x| apply_value(&args[0],&[x.clone()],&eval)).collect();
        Ok(list(results?))
    });
    b!("filter",|args| {
        if args.len()!=2{return Err("filter: 2 args".into());}
        let xs = match &args[1] {
            Value::List(xs) => xs.clone(),
            Value::Nil      => return Ok(list(vec![])),
            _ => return Err("filter: second arg must be a list".into()),
        };
        let eval = Evaluator::new();
        let mut out = Vec::new();
        for x in xs.iter().cloned() {
            if matches!(apply_value(&args[0],&[x.clone()],&eval)?, Value::Bool(false)|Value::Nil) {} else { out.push(x); }
        }
        Ok(list(out))
    });
    b!("for-each",|args| {
        if args.len()!=2{return Err("for-each: 2 args".into());}
        let xs = match &args[1] {
            Value::List(xs) => xs.clone(),
            Value::Nil      => return Ok(Value::Nil),
            _ => return Err("for-each: second arg must be a list".into()),
        };
        let eval = Evaluator::new();
        for x in xs.iter().cloned() { apply_value(&args[0],&[x.clone()],&eval)?; }
        Ok(Value::Nil)
    });
    b!("foldl",|args| {
        if args.len()!=3{return Err("foldl: 3 args".into());}
        let xs = match &args[2] { Value::List(xs)=>xs.clone(), _=>return Err("foldl: third arg must be a list".into()) };
        let eval = Evaluator::new();
        let mut acc = args[1].clone();
        for x in xs.iter().cloned() { acc = apply_value(&args[0],&[x,acc],&eval)?; }
        Ok(acc)
    });
    b!("foldr",|args| {
        if args.len()!=3{return Err("foldr: 3 args".into());}
        let xs = match &args[2] { Value::List(xs)=>xs.clone(), _=>return Err("foldr: third arg must be a list".into()) };
        let eval = Evaluator::new();
        let mut acc = args[1].clone();
        for x in xs.iter().cloned().rev() { acc = apply_value(&args[0],&[x,acc],&eval)?; }
        Ok(acc)
    });
    b!("apply",|args| {
        if args.len()<2{return Err("apply: needs function and args-list".into());}
        let last = args.last().unwrap();
        let mut call_args: Vec<Value> = args[1..args.len()-1].to_vec();
        match last {
            Value::List(xs) => call_args.extend_from_slice(&xs),
            Value::Nil      => {}
            _ => return Err("apply: last arg must be a list".into()),
        }
        let eval = Evaluator::new();
        apply_value(&args[0], &call_args, &eval)
    });

    // ── Type predicates ───────────────────────────────────────────────────
    cat!("types");
    b!("number?",    |args| Ok(Value::Bool(matches!(args.first(), Some(Value::Number(_))))));
    b!("string?",    |args| Ok(Value::Bool(matches!(args.first(), Some(Value::String(_))))));
    b!("boolean?",   |args| Ok(Value::Bool(matches!(args.first(), Some(Value::Bool(_))))));
    b!("symbol?",    |args| Ok(Value::Bool(matches!(args.first(), Some(Value::Symbol(_))))));
    b!("nil?",       |args| Ok(Value::Bool(match args.first() {
        Some(Value::Nil)|None => true,
        Some(Value::List(v))  => v.is_empty(),
        _ => false,
    })));
    b!("list?",      |args| Ok(Value::Bool(matches!(args.first(), Some(Value::List(_))|Some(Value::Nil)))));
    b!("pair?",      |args| Ok(Value::Bool(matches!(args.first(), Some(Value::List(v)) if !v.is_empty()))));
    b!("procedure?", |args| Ok(Value::Bool(matches!(args.first(),
        Some(Value::Builtin(..))|Some(Value::Lambda{..})|Some(Value::Macro{..})|Some(Value::Tool{..})|Some(Value::Native{..})|Some(Value::NativeGrad{..})))));
    b!("macro?",     |args| Ok(Value::Bool(matches!(args.first(), Some(Value::Macro{..})))));
    b!("native?",    |args| Ok(Value::Bool(matches!(args.first(), Some(Value::Native{..})|Some(Value::NativeGrad{..})))));
    b!("type-of",    |args| Ok(Value::Symbol(match args.first() {
        Some(Value::Number(_))   => "number",
        Some(Value::Bool(_))     => "boolean",
        Some(Value::String(_))   => "string",
        Some(Value::Symbol(_))   => "symbol",
        Some(Value::List(_))     => "list",
        Some(Value::Nil)         => "nil",
        Some(Value::Builtin(..)) => "builtin",
        Some(Value::Lambda{..})  => "lambda",
        Some(Value::Macro{..})   => "macro",
        Some(Value::Tool{..})   => "tool",
        Some(Value::Tensor{..}) => "tensor",
        Some(Value::Native{..}) => "native",
        Some(Value::NativeGrad{..}) => "native-grad",
        None                     => "nil",
    }.to_string())));
    b!("tensor?", |args| Ok(Value::Bool(matches!(args.first(), Some(Value::Tensor{..})))));

    // ── Strings ───────────────────────────────────────────────────────────
    cat!("strings");
    b!("string-length",  |args| {
        if let Some(Value::String(s))=args.first(){Ok(Value::Number(s.chars().count() as f64))}
        else{Err("string-length: not a string".into())}
    });
    b!("string-append", |args| {
        let mut out = String::new();
        for a in args { match a { Value::String(s)=>out.push_str(s), _=>return Err(format!("string-append: not a string: {}",a)) } }
        Ok(Value::String(out))
    });
    b!("string-append-list", |args| {
        match args.first() {
            Some(Value::List(xs)) => {
                let mut out = String::new();
                for v in xs.iter() { match v { Value::String(s)=>out.push_str(s), other=>out.push_str(&print_repr(other)) } }
                Ok(Value::String(out))
            }
            _ => Err("string-append-list: expected a list".into()),
        }
    });
    b!("substring", |args| {
        if args.len()<2{return Err("substring: needs string start [end]".into());}
        if let Value::String(s)=&args[0] {
            let chars: Vec<char> = s.chars().collect();
            let start = match &args[1]{Value::Number(n)=>*n as usize,_=>return Err("substring: start must be number".into())};
            let end   = if args.len()>2{match &args[2]{Value::Number(n)=>*n as usize,_=>return Err("substring: end must be number".into())}}else{chars.len()};
            Ok(Value::String(chars[start.min(chars.len())..end.min(chars.len())].iter().collect()))
        } else { Err("substring: not a string".into()) }
    });
    b!("string-ref", |args| {
        if args.len()!=2{return Err("string-ref: 2 args".into());}
        if let (Value::String(s),Value::Number(i))=(&args[0],&args[1]) {
            let c = s.chars().nth(*i as usize).ok_or("string-ref: index out of range")?;
            Ok(Value::String(c.to_string()))
        } else { Err("string-ref: expected string and number".into()) }
    });
    b!("string=?", |args| {
        if args.len()!=2{return Err("string=?: 2 args".into());}
        match (&args[0],&args[1]) {
            (Value::String(a),Value::String(b))=>Ok(Value::Bool(a==b)),
            _=>Err("string=?: expected strings".into()),
        }
    });
    b!("number->string", |args| {
        if let Some(Value::Number(n))=args.first(){Ok(Value::String(format_number(*n)))}
        else{Err("number->string: not a number".into())}
    });
    b!("string->number", |args| {
        if let Some(Value::String(s))=args.first(){
            match s.parse::<f64>(){Ok(n)=>Ok(Value::Number(n)),Err(_)=>Ok(Value::Bool(false))}
        }else{Err("string->number: not a string".into())}
    });
    b!("symbol->string", |args| {
        if let Some(Value::Symbol(s))=args.first(){Ok(Value::String(s.clone()))}
        else{Err("symbol->string: not a symbol".into())}
    });
    b!("string->symbol", |args| {
        if let Some(Value::String(s))=args.first(){Ok(Value::Symbol(s.clone()))}
        else{Err("string->symbol: not a string".into())}
    });
    b!("string->list", |args| {
        if let Some(Value::String(s))=args.first(){
            Ok(list(s.chars().map(|c| Value::String(c.to_string())).collect()))
        }else{Err("string->list: not a string".into())}
    });
    b!("str", |args| {
        let mut r = String::new();
        for a in args { r.push_str(&print_repr(a)); }
        Ok(Value::String(r))
    });

    // ── format ~a ~s ~% ~~ ────────────────────────────────────────────────
    cat!("strings");
    b!("format", |args| {
        if args.is_empty() { return Err("format: needs a template string".into()); }
        let tmpl = match &args[0] { Value::String(s)=>s.clone(), _=>return Err("format: first arg must be a string".into()) };
        let mut out = String::new();
        let mut chars = tmpl.chars().peekable();
        let mut idx = 1usize;
        while let Some(c) = chars.next() {
            if c != '~' { out.push(c); continue; }
            match chars.next() {
                Some('a')|Some('A') => { let v=args.get(idx).ok_or_else(||format!("format: not enough args"))?; out.push_str(&print_repr(v)); idx+=1; }
                Some('s')|Some('S') => { let v=args.get(idx).ok_or_else(||format!("format: not enough args"))?; out.push_str(&format!("{}",v)); idx+=1; }
                Some('%')           => out.push('\n'),
                Some('~')           => out.push('~'),
                Some('t')|Some('T') => out.push('\t'),
                Some(x)             => { out.push('~'); out.push(x); }
                None                => out.push('~'),
            }
        }
        Ok(Value::String(out))
    });

    // ── gensym ────────────────────────────────────────────────────────────
    cat!("macros");
    b!("gensym", |args| {
        let prefix = match args.first() {
            Some(Value::String(s))|Some(Value::Symbol(s)) => s.clone(),
            _ => "g".to_string(),
        };
        Ok(Value::Symbol(crate::env::gensym_name(&prefix)))
    });

    // ── Symbolic differentiation ──────────────────────────────────────────
    cat!("math");
    b!("grad", |args| {
        match args.first() {
            Some(Value::Lambda { params, rest, body, env }) => {
                if params.is_empty() { return Err("grad: lambda must have at least one parameter".into()); }
                if body.len() != 1 { return Err("grad: lambda body must be a single expression".into()); }
                let derivative = crate::eval::symbolic_derivative(&body[0], &params[0])?;
                Ok(Value::Lambda {
                    params: params.clone(), rest: rest.clone(),
                    body: std::rc::Rc::new(vec![derivative]), env: env.clone(),
                })
            }
            _ => Err("grad: (grad (lambda (x ...) expr)) — argument must be a lambda".into()),
        }
    });

    // ── Native tensors (Phase 3.1) ──────────────────────────────────────────
    cat!("tensors");
    b!("tensor", |args| {
        let v = args.first().ok_or("tensor: (tensor nested-list)")?;
        let (data, shape) = nested_to_tensor(v)?;
        Ok(Value::Tensor { data: std::rc::Rc::new(data), shape })
    });
    b!("tensor-shape", |args| {
        match args.first() {
            Some(Value::Tensor { shape, .. }) =>
                Ok(list(shape.iter().map(|d| Value::Number(*d as f64)).collect())),
            _ => Err("tensor-shape: argument must be a tensor".into()),
        }
    });
    b!("tensor->list", |args| {
        match args.first() {
            Some(Value::Tensor { data, shape }) => Ok(tensor_to_nested(data, shape)),
            _ => Err("tensor->list: argument must be a tensor".into()),
        }
    });
    b!("zeros", |args| tensor_fill(args, 0.0, "zeros"));
    b!("ones",  |args| tensor_fill(args, 1.0, "ones"));
    b!("tensor-ref", |args| {
        match args.first() {
            Some(Value::Tensor { data, shape }) => {
                let idx: Vec<usize> = args[1..].iter().map(|v| match v {
                    Value::Number(n) => Ok(*n as usize),
                    _ => Err("tensor-ref: indices must be numbers".to_string()),
                }).collect::<Result<Vec<_>, _>>()?;
                if idx.len() != shape.len() {
                    return Err(format!("tensor-ref: {} index(es) for a rank-{} tensor", idx.len(), shape.len()));
                }
                let mut flat = 0usize;
                for (i, (&ix, &dim)) in idx.iter().zip(shape.iter()).enumerate() {
                    if ix >= dim { return Err(format!("tensor-ref: index {} out of range for axis {} (size {})", ix, i, dim)); }
                    flat = flat * dim + ix;
                }
                Ok(Value::Number(data[flat]))
            }
            _ => Err("tensor-ref: first argument must be a tensor".into()),
        }
    });
    b!("tensor-add", |args| tensor_binop2(args, "tensor-add", |a, b| a + b));
    b!("tensor-sub", |args| tensor_binop2(args, "tensor-sub", |a, b| a - b));
    b!("tensor-mul", |args| tensor_binop2(args, "tensor-mul", |a, b| a * b));
    b!("tensor-div", |args| tensor_binop2(args, "tensor-div", |a, b| a / b));
    b!("tensor-sum", |args| {
        match args.first() {
            Some(Value::Tensor { data, .. }) => Ok(Value::Number(data.iter().sum())),
            _ => Err("tensor-sum: argument must be a tensor".into()),
        }
    });
    b!("relu", |args| {
        match args.first() {
            Some(Value::Number(n)) => Ok(Value::Number(n.max(0.0))),
            Some(Value::Tensor { data, shape }) => Ok(Value::Tensor {
                data: std::rc::Rc::new(data.iter().map(|x| x.max(0.0)).collect()),
                shape: shape.clone(),
            }),
            _ => Err("relu: argument must be a number or tensor".into()),
        }
    });
    b!("tensor-map", |args| {
        if args.len() != 2 { return Err("tensor-map: (tensor-map fn tensor)".into()); }
        match &args[1] {
            Value::Tensor { data, shape } => {
                let eval = Evaluator::new();
                let mapped: Result<Vec<f64>, String> = data.iter().map(|x| {
                    match apply_value(&args[0], &[Value::Number(*x)], &eval)? {
                        Value::Number(n) => Ok(n),
                        other => Err(format!("tensor-map: fn must return a number, got {}", other)),
                    }
                }).collect();
                Ok(Value::Tensor { data: std::rc::Rc::new(mapped?), shape: shape.clone() })
            }
            _ => Err("tensor-map: second argument must be a tensor".into()),
        }
    });
    b!("matmul", |args| {
        match (args.first(), args.get(1)) {
            (Some(Value::Tensor { data: a, shape: ash }), Some(Value::Tensor { data: b, shape: bsh })) => {
                if ash.len() != 2 || bsh.len() != 2 {
                    return Err("matmul: both tensors must be rank 2".into());
                }
                let (m, k) = (ash[0], ash[1]);
                let (k2, n) = (bsh[0], bsh[1]);
                if k != k2 { return Err(format!("matmul: inner dimensions differ ({}x{} · {}x{})", m, k, k2, n)); }
                let mut out = vec![0.0; m * n];
                for i in 0..m {
                    let a_row = &a[i * k..(i + 1) * k];
                    let o_row = &mut out[i * n..(i + 1) * n];
                    for p in 0..k {
                        let aip = a_row[p];
                        let b_row = &b[p * n..(p + 1) * n];
                        for j in 0..n {
                            o_row[j] += aip * b_row[j];
                        }
                    }
                }
                Ok(Value::Tensor { data: std::rc::Rc::new(out), shape: vec![m, n] })
            }
            _ => Err("matmul: both arguments must be tensors".into()),
        }
    });
    b!("transpose", |args| {
        match args.first() {
            Some(Value::Tensor { data, shape }) if shape.len() == 2 => {
                let (m, n) = (shape[0], shape[1]);
                let mut out = vec![0.0; m * n];
                for i in 0..m {
                    for j in 0..n {
                        out[j * m + i] = data[i * n + j];
                    }
                }
                Ok(Value::Tensor { data: std::rc::Rc::new(out), shape: vec![n, m] })
            }
            _ => Err("transpose: argument must be a rank-2 tensor".into()),
        }
    });

    // ── Flow-sensitive static type checking ────────────────────────────────
    cat!("checkers");
    // Called by define-typed's expansion (std.lisp) to record a declared
    // signature so check-types can see through user-defined calls.
    // 'unknown is accepted for unannotated params/returns.
    b!("register-signature", |args| {
        if args.len() != 3 {
            return Err("register-signature: (register-signature 'name '(param-types...) 'return-type)".into());
        }
        let name = match &args[0] {
            Value::Symbol(s) | Value::String(s) => s.clone(),
            _ => return Err("register-signature: name must be a symbol".into()),
        };
        let parse_ty = |v: &Value| -> Result<crate::type_check::Ty, String> {
            match v {
                Value::Symbol(t) if t == "unknown" => Ok(crate::type_check::Ty::Unknown),
                Value::Symbol(t) => crate::type_check::Ty::from_name(t)
                    .ok_or_else(|| format!("register-signature: unknown type '{}'", t)),
                _ => Err("register-signature: types must be symbols".into()),
            }
        };
        let params = match &args[1] {
            Value::List(ts) => ts.iter().map(&parse_ty).collect::<Result<Vec<_>, _>>()?,
            Value::Nil => vec![],
            _ => return Err("register-signature: param types must be a list".into()),
        };
        let ret = parse_ty(&args[2])?;
        crate::type_check::register_signature(&name, params, ret);
        Ok(Value::Nil)
    });
    b!("check-types", |args| {
        if args.len() != 2 {
            return Err("check-types: (check-types (lambda (params...) expr) '((param type)...))".into());
        }
        let (params, body) = match &args[0] {
            Value::Lambda { params, body, .. } => (params, body),
            _ => return Err("check-types: first argument must be a lambda".into()),
        };
        if body.len() != 1 { return Err("check-types: lambda body must be a single expression".into()); }
        let entries = match &args[1] {
            Value::List(entries) => entries.clone(),
            _ => return Err("check-types: second argument must be a list of (param type) pairs".into()),
        };
        let mut env = std::collections::HashMap::new();
        for entry in entries.iter() {
            let (name, tyname) = match entry {
                Value::List(pair) if pair.len() == 2 => match (&pair[0], &pair[1]) {
                    (Value::Symbol(n), Value::Symbol(t)) => (n, t),
                    _ => return Err("check-types: each type entry must be (param-symbol type-symbol)".into()),
                },
                _ => return Err("check-types: each type entry must be (param-symbol type-symbol)".into()),
            };
            if !params.iter().any(|p| p == name) {
                return Err(format!("check-types: '{}' is not a parameter of the given lambda", name));
            }
            let ty = crate::type_check::Ty::from_name(tyname)
                .ok_or_else(|| format!("check-types: unknown type '{}'", tyname))?;
            env.insert(name.clone(), ty);
        }
        let mut errors = Vec::new();
        crate::type_check::infer(&body[0], &env, &mut errors);
        if errors.is_empty() {
            Ok(Value::Symbol("ok".to_string()))
        } else {
            Ok(list(errors.into_iter().map(Value::String).collect()))
        }
    });

    // ── eval-string ─────────────────────────────────────────────────────────
    cat!("eval");
    // Parses and evaluates a string of Rusty code in a FRESH environment
    // (builtins + stdlib, not the caller's definitions). Exists for the
    // proof-by-checker loop (std.lisp), where LLM-proposed candidate code
    // arrives as text. Isolation from the session is a scoping property,
    // not a security boundary — the real guard is that verify-candidate
    // runs static checks (check-effects) before anything executes.
    b!("eval-string", |args| {
        match args.first() {
            Some(Value::String(code)) => {
                let env  = make_env();
                let eval = Evaluator::new();
                run_code(code, &env, &eval)
            }
            _ => Err("eval-string: argument must be a string".into()),
        }
    });

    // ── Bounded exhaustive checking ─────────────────────────────────────────
    cat!("checkers");
    // (check-exhaustive property '((domain1...) (domain2...) ...))
    // Runs `property` on EVERY combination of the given finite domains (one
    // domain list per parameter) and returns 'verified, or a list of
    // counterexamples — each ((args...) reason) where reason is "false" or
    // the raised error's message. This is exhaustive proof over a finite
    // state space, not sampling: if it says verified, the property holds
    // everywhere in the domain. Capped at 1,000,000 combinations so a typo'd
    // domain can't hang the interpreter.
    b!("check-exhaustive", |args| {
        if args.len() != 2 {
            return Err("check-exhaustive: (check-exhaustive property '((domain...)...))".into());
        }
        let property = &args[0];
        let domains: Vec<Vec<Value>> = match &args[1] {
            Value::List(ds) => ds.iter().map(|d| match d {
                Value::List(vs) => Ok(vs.iter().cloned().collect()),
                _ => Err("check-exhaustive: each domain must be a non-empty list".to_string()),
            }).collect::<Result<Vec<_>, _>>()?,
            _ => return Err("check-exhaustive: domains must be a list of lists".into()),
        };
        if domains.is_empty() || domains.iter().any(|d| d.is_empty()) {
            return Err("check-exhaustive: each domain must be a non-empty list".into());
        }
        let total: usize = domains.iter().map(|d| d.len()).try_fold(1usize, |acc, n| acc.checked_mul(n))
            .ok_or("check-exhaustive: state space overflows")?;
        if total > 1_000_000 {
            return Err(format!("check-exhaustive: state space too large ({} > 1000000 combinations)", total));
        }
        // ── Native property fast path (v0.36.0) ─────────────────────────
        // A defrust-compiled property is a pure extern "C" fn over f64s:
        // call it directly per point (no interpreter dispatch), and split
        // the flat index space across threads — only f64s cross a thread
        // boundary, the Rc'd Lisp world never leaves this thread, and the
        // .so outlives the scope because the Value holding its Rc<Library>
        // is borrowed for the duration. Convention: result != 0.0 means
        // the property HOLDS (defrust has no booleans — return 1.0/0.0).
        // Counterexamples are collected per chunk and merged in chunk
        // order, so output is bit-identical to the serial sweep.
        if let Value::Native { arity, fn_ptr, .. } = property {
            if *arity != domains.len() {
                return Err(format!(
                    "check-exhaustive: native property takes {} args, got {} domains",
                    arity, domains.len()));
            }
            let doms: Vec<Vec<f64>> = domains.iter().map(|d| d.iter().map(|v| match v {
                Value::Number(n) => Ok(*n),
                other => Err(format!(
                    "check-exhaustive: a native property needs all-numeric domains, got {}", other)),
            }).collect::<Result<Vec<_>, String>>()).collect::<Result<_, _>>()?;
            let nd = doms.len();
            let fp = *fn_ptr as usize;
            // RUSTY_CE_THREADS overrides (benchmarking, core-pinned embedded)
            let threads = match std::env::var("RUSTY_CE_THREADS").ok().and_then(|s| s.parse::<usize>().ok()) {
                Some(n) => n.max(1),
                None if total >= 16_384 =>
                    std::thread::available_parallelism().map(|n| n.get().min(16)).unwrap_or(1),
                None => 1,
            };
            let chunk = total.div_ceil(threads);
            let mut failures: Vec<Vec<f64>> = Vec::new();
            std::thread::scope(|s| {
                let mut handles = Vec::new();
                for t in 0..threads {
                    let lo = t * chunk;
                    let hi = ((t + 1) * chunk).min(total);
                    if lo >= hi { break; }
                    let doms = &doms;
                    handles.push(s.spawn(move || {
                        let f: extern "C" fn(*const f64, usize) -> f64 =
                            unsafe { std::mem::transmute(fp as *const ()) };
                        let mut idx = vec![0usize; nd];
                        let mut rem = lo;
                        for pos in (0..nd).rev() { idx[pos] = rem % doms[pos].len(); rem /= doms[pos].len(); }
                        let mut buf = vec![0f64; nd];
                        let mut cex = Vec::new();
                        for _ in lo..hi {
                            for (k, &i) in idx.iter().enumerate() { buf[k] = doms[k][i]; }
                            if f(buf.as_ptr(), nd) == 0.0 { cex.push(buf.clone()); }
                            for pos in (0..nd).rev() {
                                idx[pos] += 1;
                                if idx[pos] < doms[pos].len() { break; }
                                idx[pos] = 0;
                            }
                        }
                        cex
                    }));
                }
                for h in handles { failures.extend(h.join().expect("check-exhaustive worker panicked")); }
            });
            return if failures.is_empty() {
                Ok(Value::Symbol("verified".to_string()))
            } else {
                Ok(list(failures.into_iter().map(|args| list(vec![
                    list(args.into_iter().map(Value::Number).collect()),
                    Value::String("false".to_string()),
                ])).collect()))
            };
        }

        let eval = Evaluator::new();
        let mut counterexamples = Vec::new();
        let mut indices = vec![0usize; domains.len()];
        for _ in 0..total {
            let combo: Vec<Value> = indices.iter().zip(domains.iter()).map(|(&i, d)| d[i].clone()).collect();
            let reason = match apply_value(property, &combo, &eval) {
                Ok(v) if matches!(v, Value::Bool(false) | Value::Nil) => Some("false".to_string()),
                Ok(_) => None,
                Err(e) => Some(e),
            };
            if let Some(r) = reason {
                counterexamples.push(list(vec![list(combo), Value::String(r)]));
            }
            // odometer increment
            for pos in (0..indices.len()).rev() {
                indices[pos] += 1;
                if indices[pos] < domains[pos].len() { break; }
                indices[pos] = 0;
            }
        }
        if counterexamples.is_empty() {
            Ok(Value::Symbol("verified".to_string()))
        } else {
            Ok(list(counterexamples))
        }
    });

    // ── Effect tracking ─────────────────────────────────────────────────────
    cat!("checkers");
    b!("check-effects", |args| {
        match args.first() {
            Some(Value::Lambda { body, .. }) | Some(Value::Tool { body, .. }) => {
                let mut findings = Vec::new();
                for stmt in body.iter() { crate::effect_check::check(stmt, &mut findings); }
                if findings.is_empty() {
                    Ok(Value::Symbol("pure".to_string()))
                } else {
                    Ok(list(findings.into_iter().map(Value::String).collect()))
                }
            }
            _ => Err("check-effects: argument must be a lambda or tool".into()),
        }
    });
    b!("effectful?", |args| {
        match args.first() {
            Some(Value::Symbol(s)) => Ok(Value::Bool(crate::effect_check::effect_reason(s).is_some())),
            _ => Err("effectful?: argument must be a symbol".into()),
        }
    });

    // ── Graph IR ───────────────────────────────────────────────────────────
    cat!("graph");
    b!("graph-ir", |args| {
        match args.first() {
            Some(Value::Lambda { params, body, .. }) => {
                if body.len() != 1 { return Err("graph-ir: lambda body must be a single expression".into()); }
                let graph = crate::graph_ir::build(params, &body[0])?;
                Ok(crate::graph_ir::to_value(&crate::graph_ir::optimize(&graph)))
            }
            _ => Err("graph-ir: (graph-ir (lambda (params...) expr)) — argument must be a lambda".into()),
        }
    });
    b!("graph-node-count", |args| {
        match args.first() {
            Some(Value::Lambda { params, body, .. }) => {
                if body.len() != 1 { return Err("graph-node-count: lambda body must be a single expression".into()); }
                let graph = crate::graph_ir::build(params, &body[0])?;
                Ok(Value::Number(crate::graph_ir::optimize(&graph).nodes.len() as f64))
            }
            _ => Err("graph-node-count: argument must be a lambda".into()),
        }
    });
    b!("graph-eval", |args| {
        let (params, body, rest) = match args.split_first() {
            Some((Value::Lambda { params, body, .. }, rest)) => (params, body, rest),
            _ => return Err("graph-eval: (graph-eval (lambda (params...) expr) args...)".into()),
        };
        if body.len() != 1 { return Err("graph-eval: lambda body must be a single expression".into()); }
        if rest.len() != params.len() {
            return Err(format!("graph-eval: expected {} arg(s), got {}", params.len(), rest.len()));
        }
        let inputs: Result<Vec<crate::graph_ir::GVal>, String> = rest.iter().map(|a| match a {
            Value::Number(n) => Ok(crate::graph_ir::GVal::Num(*n)),
            Value::Tensor { data, shape } =>
                Ok(crate::graph_ir::GVal::Tensor { data: data.clone(), shape: shape.clone() }),
            other => Err(format!("graph-eval: expected a number or tensor, got {}", other)),
        }).collect();
        let graph = crate::graph_ir::build(params, &body[0])?;
        match crate::graph_ir::eval_graph(&crate::graph_ir::optimize(&graph), &inputs?)? {
            crate::graph_ir::GVal::Num(n) => Ok(Value::Number(n)),
            crate::graph_ir::GVal::Tensor { data, shape } => Ok(Value::Tensor { data, shape }),
        }
    });
    // (graph-compile (lambda (params...) expr)) → a callable Value::Native.
    // Phase 3.3 kernel fusion, scalar half: the optimized DAG (CSE + folding
    // + DCE already applied) is emitted as ONE straight-line Rust function
    // and compiled through the same rustc/cache/libloading pipeline as
    // defrust. Call it like any function: ((graph-compile f) 1 2).
    b!("graph-compile", |args| {
        match args.first() {
            Some(Value::Lambda { params, body, .. }) => {
                if body.len() != 1 { return Err("graph-compile: lambda body must be a single expression".into()); }
                let graph = crate::graph_ir::optimize(&crate::graph_ir::build(params, &body[0])?);
                crate::rust_jit::compile_graph("graph-kernel", &graph, params.len())
            }
            _ => Err("graph-compile: (graph-compile (lambda (params...) expr)) — argument must be a lambda".into()),
        }
    });
    // (graph-grad (lambda (params...) scalar-loss-expr) args...) →
    //   (loss grad-per-param...)
    // Reverse-mode autodiff: one backward sweep over the Graph IR yields the
    // gradient of the loss w.r.t. *every* argument, evaluated in a single
    // pass over the shared forward+backward graph.
    b!("graph-grad", |args| {
        let (params, body, rest) = match args.split_first() {
            Some((Value::Lambda { params, body, .. }, rest)) => (params, body, rest),
            _ => return Err("graph-grad: (graph-grad (lambda (params...) loss-expr) args...)".into()),
        };
        if body.len() != 1 { return Err("graph-grad: lambda body must be a single expression".into()); }
        if rest.len() != params.len() {
            return Err(format!("graph-grad: expected {} arg(s), got {}", params.len(), rest.len()));
        }
        let inputs: Result<Vec<crate::graph_ir::GVal>, String> = rest.iter().map(|a| match a {
            Value::Number(n) => Ok(crate::graph_ir::GVal::Num(*n)),
            Value::Tensor { data, shape } =>
                Ok(crate::graph_ir::GVal::Tensor { data: data.clone(), shape: shape.clone() }),
            other => Err(format!("graph-grad: expected a number or tensor, got {}", other)),
        }).collect();
        let forward = crate::graph_ir::optimize(&crate::graph_ir::build(params, &body[0])?);
        let (grown, grad_nodes) = crate::graph_ir::backward(&forward, params.len())?;
        let mut outputs = vec![grown.output];
        outputs.extend(grad_nodes);
        let (opt, outs) = crate::graph_ir::optimize_outputs(&grown, &outputs);
        let results = crate::graph_ir::eval_graph_outputs(&opt, &inputs?, &outs)?;
        if !matches!(results[0], crate::graph_ir::GVal::Num(_)) {
            return Err("graph-grad: the loss must evaluate to a scalar (use tensor-sum or a mean)".into());
        }
        Ok(list(results.into_iter().map(|g| match g {
            crate::graph_ir::GVal::Num(n) => Value::Number(n),
            crate::graph_ir::GVal::Tensor { data, shape } => Value::Tensor { data, shape },
        }).collect()))
    });
    // (graph-compile-grad (lambda (params...) loss-expr) example-args...) →
    //   a callable #<native-grad> returning (loss grad-per-param...).
    // Phase 3.3 kernel fusion, tensor half: the whole forward+backward graph
    // compiles to ONE native function, shape-specialized to the example
    // arguments (their VALUES are only used for shapes). Unlike graph-grad —
    // which rebuilds and re-optimizes the graph on every call — all graph
    // work happens once, here. Calling the result with differently-shaped
    // tensors is an error: compile again for new shapes.
    b!("graph-compile-grad", |args| {
        let (params, body, rest) = match args.split_first() {
            Some((Value::Lambda { params, body, .. }, rest)) => (params, body, rest),
            _ => return Err("graph-compile-grad: (graph-compile-grad (lambda (params...) loss-expr) example-args...)".into()),
        };
        if body.len() != 1 { return Err("graph-compile-grad: lambda body must be a single expression".into()); }
        if rest.len() != params.len() {
            return Err(format!("graph-compile-grad: expected {} example arg(s), got {}", params.len(), rest.len()));
        }
        let in_shapes: Result<Vec<crate::graph_ir::SShape>, String> = rest.iter().map(|a| match a {
            Value::Number(_) => Ok(None),
            Value::Tensor { shape, .. } => Ok(Some(shape.clone())),
            other => Err(format!("graph-compile-grad: expected a number or tensor, got {}", other)),
        }).collect();
        let in_shapes = in_shapes?;
        let forward = crate::graph_ir::optimize(&crate::graph_ir::build(params, &body[0])?);
        // Check the loss is scalar on the FORWARD graph, before backward() —
        // otherwise shape inference trips on a generated gradient node (the
        // scalar seed meeting e.g. a matmul) with a misleading internal error.
        let fwd_shapes = crate::graph_ir::infer_shapes(&forward, &in_shapes)?;
        if fwd_shapes[forward.output].is_some() {
            return Err("graph-compile-grad: the loss must evaluate to a scalar (use tensor-sum or a mean)".into());
        }
        let (grown, grad_nodes) = crate::graph_ir::backward(&forward, params.len())?;
        let mut outputs = vec![grown.output];
        outputs.extend(grad_nodes);
        let (opt, outs) = crate::graph_ir::optimize_outputs(&grown, &outputs);
        crate::rust_jit::compile_graph_grad("grad-kernel", &opt, &outs, &in_shapes)
    });

    // ── Execution tracing (Phase 3.2) ─────────────────────────────────────
    cat!("trace");
    b!("trace-on", |_| { crate::trace::clear(); crate::trace::set_enabled(true); Ok(Value::Nil) });
    b!("trace-off", |_| { crate::trace::set_enabled(false); Ok(Value::Nil) });
    b!("trace-clear", |_| { crate::trace::clear(); Ok(Value::Nil) });
    b!("trace-report", |_| Ok(crate::trace::report()));
    b!("trace-dropped", |_| Ok(Value::Number(crate::trace::dropped() as f64)));
    // (trace-event kind name [data]) — record a custom event from Lisp.
    // Cheap no-op when tracing is off, so library code (e.g. the actor
    // scheduler in std.lisp) can call it unconditionally.
    b!("trace-event", |args| {
        let sym = |v: &Value| match v {
            Value::Symbol(s) | Value::String(s) => Ok(s.clone()),
            other => Err(format!("trace-event: expected symbol or string, got {}", other)),
        };
        match args {
            [kind, name] => { crate::trace::record_dyn(sym(kind)?, sym(name)?, None); Ok(Value::Nil) }
            [kind, name, data] => {
                let d = match data { Value::String(s) => s.clone(), other => format!("{}", other) };
                crate::trace::record_dyn(sym(kind)?, sym(name)?, Some(d));
                Ok(Value::Nil)
            }
            _ => Err("trace-event: (trace-event kind name [data])".into()),
        }
    });

    // ── Macro profiler ───────────────────────────────────────────────────
    cat!("macros");
    b!("macro-profile-on", |_| { crate::eval::macro_profile::set_enabled(true); Ok(Value::Nil) });
    b!("macro-profile-off", |_| { crate::eval::macro_profile::set_enabled(false); Ok(Value::Nil) });
    b!("macro-profile-reset", |_| { crate::eval::macro_profile::reset(); Ok(Value::Nil) });
    b!("macro-profile-report", |_| {
        let rows: Vec<Value> = crate::eval::macro_profile::report().into_iter()
            .map(|(name, count, micros)| list(vec![
                Value::Symbol(name), Value::Number(count as f64), Value::Number(micros as f64),
            ]))
            .collect();
        Ok(list(rows))
    });

    // ── Math extras ───────────────────────────────────────────────────────
    cat!("math");
    b!("gcd", |args| {
        fn gcd(a: u64, b: u64) -> u64 { if b==0{a}else{gcd(b,a%b)} }
        let vs = nums(args)?;
        if vs.len()<2{return Err("gcd: 2+ args".into());}
        Ok(Value::Number(vs.iter().map(|&n| n.abs() as u64).reduce(gcd).unwrap_or(0) as f64))
    });

    // ── JSON ──────────────────────────────────────────────────────────────
    cat!("json");
    b!("json-encode", |args| {
        if args.len()!=1{return Err("json-encode: 1 arg".into());}
        Ok(Value::String(json_encode(&args[0])))
    });
    b!("json-decode", |args| {
        if let Some(Value::String(s))=args.first() {
            json_decode(s.trim()).map_err(|e| format!("json-decode: {}",e))
        } else { Err("json-decode: expected a string".into()) }
    });

    // ── Model serialization (Phase 3.1) ──────────────────────────────────
    cat!("serialization");
    // Rusty's own model format: a versioned JSON envelope over *data* values
    // (numbers, strings, bools, symbols, lists, tensors) via serde_json.
    // Symbols and tensors are tagged objects so they round-trip losslessly —
    // unlike json-encode, which flattens symbols to strings. Code values
    // (lambdas/tools/macros) are deliberately rejected: serializing live
    // environments is Phase 3.2's checkpoint/restore, not model data.
    b!("save-model", |args| {
        match (args.first(), args.get(1)) {
            (Some(Value::String(path)), Some(v)) => {
                let body = model_to_json(v)?;
                let envelope = serde_json::json!({ "rusty-model": 1, "value": body });
                let text = serde_json::to_string_pretty(&envelope)
                    .map_err(|e| format!("save-model: {}", e))?;
                std::fs::write(path, text)
                    .map_err(|e| format!("save-model: cannot write {}: {}", path, e))?;
                Ok(Value::String(path.clone()))
            }
            _ => Err("save-model: (save-model \"path\" value)".into()),
        }
    });
    b!("load-model", |args| {
        match args.first() {
            Some(Value::String(path)) => {
                let text = std::fs::read_to_string(path)
                    .map_err(|e| format!("load-model: cannot read {}: {}", path, e))?;
                let envelope: serde_json::Value = serde_json::from_str(&text)
                    .map_err(|e| format!("load-model: {} is not valid JSON: {}", path, e))?;
                match envelope.get("rusty-model").and_then(|v| v.as_i64()) {
                    Some(1) => {}
                    Some(n) => return Err(format!("load-model: unsupported rusty-model version {}", n)),
                    None => return Err(format!("load-model: {} is not a Rusty model file (missing \"rusty-model\" tag)", path)),
                }
                let body = envelope.get("value")
                    .ok_or_else(|| format!("load-model: {} has no \"value\" field", path))?;
                model_from_json(body)
            }
            _ => Err("load-model: (load-model \"path\")".into()),
        }
    });

    // ── Time ─────────────────────────────────────────────────────────────
    cat!("time");
    b!("now-micros", |_| {
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)
            .map(|d| Value::Number(d.as_micros() as f64))
            .map_err(|e| format!("now-micros: {}", e))
    });

    // ── I/O ───────────────────────────────────────────────────────────────
    cat!("io");
    b!("display", |args| {
        for a in args { match a { Value::String(s)=>print!("{}",s), other=>print!("{}",other) } }
        Ok(Value::Nil)
    });
    b!("newline", |_| { println!(); Ok(Value::Nil) });
    b!("print",   |args| { let parts: Vec<String>=args.iter().map(print_repr).collect(); println!("{}",parts.join(" ")); Ok(Value::Nil) });
    b!("println", |args| { let parts: Vec<String>=args.iter().map(print_repr).collect(); println!("{}",parts.join(" ")); Ok(Value::Nil) });
    b!("error",   |args| { Err(args.iter().map(|v| print_repr(v)).collect::<Vec<_>>().join(" ")) });

    // ── System / shell ────────────────────────────────────────────────────
    cat!("system");
    b!("shell", |args| {
        if args.is_empty() { return Err("shell: needs a command string".into()); }
        let cmd = match &args[0] {
            Value::String(s) => s.clone(),
            other => format!("{}", other),
        };
        let t0 = crate::trace::start();
        let output = std::process::Command::new("sh")
            .arg("-c")
            .arg(&cmd)
            .output()
            .map_err(|e| format!("shell: {}", e))?;
        crate::trace::record_since("shell", "shell", t0, Some(cmd.clone()));
        let stdout = String::from_utf8_lossy(&output.stdout).to_string();
        let stderr = String::from_utf8_lossy(&output.stderr).to_string();
        if !output.status.success() && !stderr.is_empty() {
            Ok(Value::String(format!("{}{}", stdout, stderr)))
        } else {
            Ok(Value::String(stdout))
        }
    });

    // ── Filesystem (all classified effectful in effect_check.rs) ─────────
    cat!("filesystem");
    // These existed only as agent-tool NAMES until 0.26.0 — the tool
    // bodies called builtins that were never implemented, and since tool
    // bodies don't run at registration, nothing noticed.
    fn one_path<'a>(args: &'a [Value], who: &str) -> Result<&'a str, String> {
        match args.first() {
            Some(Value::String(p)) => Ok(p),
            _ => Err(format!("{}: first argument must be a path string", who)),
        }
    }
    b!("file-read", |args| {
        let p = one_path(args, "file-read")?;
        std::fs::read_to_string(p).map(Value::String)
            .map_err(|e| format!("file-read: {}: {}", p, e))
    });
    b!("file-write", |args| {
        let p = one_path(args, "file-write")?;
        let c = match args.get(1) { Some(Value::String(s)) => s.clone(),
                                    Some(other) => format!("{}", other),
                                    None => return Err("file-write: (file-write path content)".into()) };
        std::fs::write(p, c).map(|_| Value::Bool(true))
            .map_err(|e| format!("file-write: {}: {}", p, e))
    });
    b!("file-append", |args| {
        use std::io::Write;
        let p = one_path(args, "file-append")?;
        let c = match args.get(1) { Some(Value::String(s)) => s.clone(),
                                    Some(other) => format!("{}", other),
                                    None => return Err("file-append: (file-append path content)".into()) };
        std::fs::OpenOptions::new().create(true).append(true).open(p)
            .and_then(|mut f| f.write_all(c.as_bytes()))
            .map(|_| Value::Bool(true))
            .map_err(|e| format!("file-append: {}: {}", p, e))
    });
    b!("file-exists?", |args| {
        Ok(Value::Bool(std::path::Path::new(one_path(args, "file-exists?")?).exists()))
    });
    // Symlink safety primitives (0.42.0). file-read/write/etc. all FOLLOW
    // symlinks, so a string-prefix "under the box?" guard is defeated by a
    // symlink inside the box pointing out. These two let a guard resolve the
    // REAL location before checking — see wuwei's safe-under?.
    // file-symlink? is no-follow (lstat): #t iff the path itself is a symlink
    // (including a dangling one); #f for a regular file or a missing path.
    b!("file-symlink?", |args| {
        let p = one_path(args, "file-symlink?")?;
        Ok(Value::Bool(std::fs::symlink_metadata(p)
            .map(|m| m.file_type().is_symlink()).unwrap_or(false)))
    });
    // file-realpath canonicalizes: resolves symlinks + ".." to a real absolute
    // path. Nil (not an error) when the path can't be resolved — it must exist,
    // so a guard tests the parent for a not-yet-created file. Nil-on-miss keeps
    // guard predicates branch-free, like recall.
    b!("file-realpath", |args| {
        let p = one_path(args, "file-realpath")?;
        Ok(std::fs::canonicalize(p)
            .map(|pb| Value::String(pb.to_string_lossy().into_owned()))
            .unwrap_or(Value::Nil))
    });
    // file-hash (0.45.0): lowercase-hex SHA-256 of a file's bytes, streamed so a
    // large file never lands in memory. Nil (not an error) when the path can't
    // be read — a missing file is a *result* for an integrity check (the file
    // vanishing is exactly what you're checking for), not a crash; same
    // Nil-on-miss shape as file-realpath, and it keeps comparisons branch-free.
    // Follows symlinks, like every other content-reading builtin: it hashes what
    // is at the resolved path. Pair with file-symlink?/file-realpath if the
    // identity of the path itself matters.
    b!("file-hash", |args| {
        use sha2::{Digest, Sha256};
        let p = one_path(args, "file-hash")?;
        let mut f = match std::fs::File::open(p) { Ok(f) => f, Err(_) => return Ok(Value::Nil) };
        let mut hasher = Sha256::new();
        if std::io::copy(&mut f, &mut hasher).is_err() { return Ok(Value::Nil); }
        Ok(Value::String(format!("{:x}", hasher.finalize())))
    });
    b!("file-delete", |args| {
        let p = one_path(args, "file-delete")?;
        std::fs::remove_file(p).map(|_| Value::Bool(true))
            .map_err(|e| format!("file-delete: {}: {}", p, e))
    });
    b!("dir-create", |args| {
        let p = one_path(args, "dir-create")?;
        std::fs::create_dir_all(p).map(|_| Value::Bool(true))
            .map_err(|e| format!("dir-create: {}: {}", p, e))
    });
    b!("dir-list", |args| {
        let p = one_path(args, "dir-list")?;
        let mut names: Vec<String> = std::fs::read_dir(p)
            .map_err(|e| format!("dir-list: {}: {}", p, e))?
            .filter_map(|ent| ent.ok().map(|e| e.file_name().to_string_lossy().into_owned()))
            .collect();
        names.sort(); // deterministic — golden tests may list directories
        Ok(list(names.into_iter().map(Value::String).collect()))
    });
    // Pure string utility (lived only in tutorial prose until 0.26.0):
    // splits on a separator string, dropping empty pieces.
    b!("string-split", |args| {
        match (args.first(), args.get(1)) {
            (Some(Value::String(s)), Some(Value::String(sep))) if !sep.is_empty() =>
                Ok(list(s.split(sep.as_str())
                        .filter(|p| !p.is_empty())
                        .map(|p| Value::String(p.to_string())).collect())),
            _ => Err("string-split: (string-split string separator)".into()),
        }
    });

    // ── Knowledge graph (Phase 1.3, self-built — src/kg.rs) ──────────────
    cat!("kg");
    b!("kg-clear!", |_| { crate::kg::clear(); Ok(Value::Bool(true)) });
    b!("kg-add!", |args| {
        match (args.first(), args.get(1), args.get(2)) {
            (Some(s), Some(p), Some(o)) =>
                Ok(Value::Bool(crate::kg::add(s.clone(), p.clone(), o.clone()))),
            _ => Err("kg-add!: (kg-add! subject predicate object)".into()),
        }
    });
    b!("kg-count", |_| Ok(Value::Number(crate::kg::count() as f64)));
    b!("kg-triples", |_| Ok(crate::kg::triples()));
    // (kg-query '((s p o)...)) — ?vars unify across patterns; returns a
    // list of binding alists, one per solution.
    b!("kg-query", |args| {
        match args.first() {
            Some(v) => crate::kg::query(v),
            None => Err("kg-query: (kg-query '((s p o) ...))".into()),
        }
    });
    b!("kg-save-ntriples", |args| {
        match args.first() {
            Some(Value::String(p)) => crate::kg::save_ntriples(p).map(|n| Value::Number(n as f64)),
            _ => Err("kg-save-ntriples: (kg-save-ntriples path)".into()),
        }
    });
    b!("kg-load-ntriples", |args| {
        match args.first() {
            Some(Value::String(p)) => crate::kg::load_ntriples(p).map(|n| Value::Number(n as f64)),
            _ => Err("kg-load-ntriples: (kg-load-ntriples path)".into()),
        }
    });

    // ── Tool predicate ────────────────────────────────────────────────────
    cat!("tools");
    b!("tool?", |args| Ok(Value::Bool(matches!(args.first(), Some(Value::Tool{..})))));
    b!("tool-name", |args| {
        match args.first() {
            Some(Value::Tool { name, .. }) => Ok(Value::Symbol(name.clone())),
            _ => Err("tool-name: argument must be a tool".into()),
        }
    });

    // ── Memory system ─────────────────────────────────────────────────────
    cat!("memory");
    // Stored as ~/.rusty/memory.lisp — plain Lisp defines, human readable
    b!("remember", |args| {
        if args.len() < 2 { return Err("remember: (remember key value)".into()); }
        let key = match &args[0] {
            Value::String(s) | Value::Symbol(s) => s.clone(),
            _ => return Err("remember: key must be a string or symbol".into()),
        };
        let val = &args[1];
        let mem_path = memory_path();
        // Read existing, remove old entry for this key, append new one
        let existing = std::fs::read_to_string(&mem_path).unwrap_or_default();
        let filtered: Vec<&str> = existing.lines()
            .filter(|l| !l.contains(&format!("(define {} ", key)))
            .collect();
        let mut new_content = filtered.join("\n");
        if !new_content.is_empty() && !new_content.ends_with('\n') {
            new_content.push('\n');
        }
        new_content.push_str(&format!("(define {} {})\n", key, val));
        std::fs::create_dir_all(memory_dir())
            .map_err(|e| format!("remember: cannot create memory dir: {}", e))?;
        std::fs::write(&mem_path, &new_content)
            .map_err(|e| format!("remember: {}", e))?;
        Ok(Value::String(format!("Remembered: {} = {}", key, val)))
    });

    b!("recall", |args| {
        if args.is_empty() { return Err("recall: (recall key)".into()); }
        let key = match &args[0] {
            Value::String(s) | Value::Symbol(s) => s.clone(),
            _ => return Err("recall: key must be a string or symbol".into()),
        };
        let mem_path = memory_path();
        let content = std::fs::read_to_string(&mem_path).unwrap_or_default();
        // Find the last define for this key
        for line in content.lines().rev() {
            let trimmed = line.trim();
            let prefix = format!("(define {} ", key);
            if trimmed.starts_with(&prefix) {
                // Extract value — everything between prefix and last )
                let val_str = &trimmed[prefix.len()..trimmed.len()-1];
                // Parse as a Value — strip string quotes if present
                let val = if val_str.starts_with('"') && val_str.ends_with('"') {
                    Value::String(val_str[1..val_str.len()-1].to_string())
                } else if val_str == "#t" {
                    Value::Bool(true)
                } else if val_str == "#f" {
                    Value::Bool(false)
                } else if let Ok(n) = val_str.parse::<f64>() {
                    Value::Number(n)
                } else {
                    Value::String(val_str.to_string())
                };
                return Ok(val);
            }
        }
        Ok(Value::Nil)
    });

    b!("forget", |args| {
        if args.is_empty() { return Err("forget: (forget key)".into()); }
        let key = match &args[0] {
            Value::String(s) | Value::Symbol(s) => s.clone(),
            _ => return Err("forget: key must be string or symbol".into()),
        };
        let mem_path = memory_path();
        let existing = std::fs::read_to_string(&mem_path).unwrap_or_default();
        let filtered: String = existing.lines()
            .filter(|l| !l.contains(&format!("(define {} ", key)))
            .map(|l| format!("{}\n", l))
            .collect();
        std::fs::write(&mem_path, filtered)
            .map_err(|e| format!("forget: {}", e))?;
        Ok(Value::String(format!("Forgot: {}", key)))
    });

    b!("memory-list", |_args| {
        let mem_path = memory_path();
        let content = std::fs::read_to_string(&mem_path).unwrap_or_default();
        let entries: Vec<Value> = content.lines()
            .filter(|l| l.trim().starts_with("(define "))
            .map(|l| Value::String(l.trim().to_string()))
            .collect();
        Ok(list(entries))
    });

    b!("memory-path", |_args| {
        Ok(Value::String(memory_path().to_string_lossy().to_string()))
    });
    b!("nil",     |_| Ok(Value::Nil));

    // ── Help ──────────────────────────────────────────────────────────────
    cat!("meta");
    // (categorize! 'category '(name1 name2 ...)) — tag std.lisp functions so
    // the command registry can group them. Writes into the CATEGORIES table.
    b!("categorize!", |args| {
        let cat = match args.first() {
            Some(Value::Symbol(s)) => s.clone(),
            _ => return Err("categorize!: first arg must be a category symbol".into()),
        };
        match args.get(1) {
            Some(Value::List(names)) => {
                for n in names.iter() {
                    if let Value::Symbol(s) = n { crate::interp::set_category(s, &cat); }
                }
                Ok(Value::Nil)
            }
            _ => Err("categorize!: second arg must be a list of name symbols".into()),
        }
    });
    // NOTE: no `help` builtin here — std.lisp defines `(help)`/`(help 'cat)`
    // as registry-driven discovery (see std.lisp's "Command discovery"
    // section) and, loading after builtins, shadows any binding of that name
    // in the global env. A static builtin here would just be dead weight.
}

// ── JSON encode/decode ────────────────────────────────────────────────────

// ── Model serialization helpers (Phase 3.1) ──────────────────────────────
// Encoding: JSON scalars map directly (number/string/bool/null), JSON arrays
// are lists, and objects are reserved for tags — {"t":"sym"} for symbols,
// {"t":"tensor"} for tensors — so decoding is unambiguous. serde_json prints
// f64 with shortest-round-trip precision (ryu), so finite values survive
// save/load bit-exactly; NaN/Inf have no JSON form and are rejected up front.

fn model_to_json(v: &Value) -> Result<serde_json::Value, String> {
    match v {
        Value::Nil       => Ok(serde_json::Value::Null),
        Value::Bool(b)   => Ok(serde_json::json!(b)),
        Value::Number(n) => {
            if !n.is_finite() {
                return Err("save-model: cannot serialize a non-finite number (NaN/Infinity has no JSON form)".into());
            }
            Ok(serde_json::json!(n))
        }
        Value::String(s) => Ok(serde_json::json!(s)),
        Value::Symbol(s) => Ok(serde_json::json!({ "t": "sym", "v": s })),
        Value::List(xs)  => xs.iter().map(model_to_json)
            .collect::<Result<Vec<_>, _>>().map(serde_json::Value::Array),
        Value::Tensor { data, shape } => {
            if data.iter().any(|x| !x.is_finite()) {
                return Err("save-model: tensor contains a non-finite value (NaN/Infinity has no JSON form)".into());
            }
            Ok(serde_json::json!({ "t": "tensor", "shape": shape, "data": &**data }))
        }
        other => Err(format!(
            "save-model: cannot serialize {} — models are data (numbers, strings, symbols, lists, tensors); \
             serializing code/environments is checkpoint/restore (roadmap 3.2)", other
        )),
    }
}

fn model_from_json(j: &serde_json::Value) -> Result<Value, String> {
    match j {
        serde_json::Value::Null      => Ok(Value::Nil),
        serde_json::Value::Bool(b)   => Ok(Value::Bool(*b)),
        serde_json::Value::Number(n) => n.as_f64().map(Value::Number)
            .ok_or_else(|| format!("load-model: number {} does not fit an f64", n)),
        serde_json::Value::String(s) => Ok(Value::String(s.clone())),
        serde_json::Value::Array(items) => items.iter().map(model_from_json)
            .collect::<Result<Vec<_>, _>>().map(list),
        serde_json::Value::Object(map) => match map.get("t").and_then(|t| t.as_str()) {
            Some("sym") => map.get("v").and_then(|v| v.as_str())
                .map(|s| Value::Symbol(s.to_string()))
                .ok_or_else(|| "load-model: sym tag without a string \"v\"".to_string()),
            Some("tensor") => {
                let shape: Vec<usize> = map.get("shape").and_then(|s| s.as_array())
                    .ok_or_else(|| "load-model: tensor tag without a \"shape\" array".to_string())?
                    .iter().map(|d| d.as_u64().map(|d| d as usize)
                        .ok_or_else(|| "load-model: tensor shape must be non-negative integers".to_string()))
                    .collect::<Result<Vec<_>, _>>()?;
                let data: Vec<f64> = map.get("data").and_then(|d| d.as_array())
                    .ok_or_else(|| "load-model: tensor tag without a \"data\" array".to_string())?
                    .iter().map(|x| x.as_f64()
                        .ok_or_else(|| "load-model: tensor data must be numbers".to_string()))
                    .collect::<Result<Vec<_>, _>>()?;
                let expected: usize = shape.iter().product();
                if expected != data.len() {
                    return Err(format!(
                        "load-model: tensor shape {:?} implies {} element(s), data has {}",
                        shape, expected, data.len()
                    ));
                }
                Ok(Value::Tensor { data: std::rc::Rc::new(data), shape })
            }
            Some(other) => Err(format!("load-model: unrecognized tag \"{}\"", other)),
            None => Err("load-model: JSON object without a \"t\" tag is not valid model data".into()),
        },
    }
}

pub fn json_encode(v: &Value) -> String {
    match v {
        Value::Nil       => "null".to_string(),
        Value::Bool(b)   => b.to_string(),
        Value::Number(n) => format_number(*n),
        Value::String(s) => {
            let e = s.replace('\\', "\\\\").replace('"',"\\\"")
                     .replace('\n',"\\n").replace('\t',"\\t");
            format!("\"{}\"", e)
        }
        Value::Symbol(s) => format!("\"{}\"", s),
        Value::List(xs) if xs.is_empty() => "[]".to_string(),
        Value::List(xs) => {
            let is_alist = xs.iter().all(|x| matches!(x,
                Value::List(p) if p.len()==2 && matches!(&p[0], Value::String(_)|Value::Symbol(_))));
            if is_alist {
                let pairs: Vec<String> = xs.iter().map(|x| {
                    if let Value::List(p) = x {
                        let k = match &p[0] { Value::String(s)|Value::Symbol(s)=>s.clone(), o=>json_encode(o) };
                        format!("\"{}\": {}", k, json_encode(&p[1]))
                    } else { "null".to_string() }
                }).collect();
                format!("{{{}}}", pairs.join(", "))
            } else {
                format!("[{}]", xs.iter().map(json_encode).collect::<Vec<_>>().join(", "))
            }
        }
        other => format!("\"{}\"", other),
    }
}

pub fn json_decode(s: &str) -> Result<Value, String> {
    let s = s.trim();
    if s=="null"||s=="()" { return Ok(Value::Nil); }
    if s=="true"           { return Ok(Value::Bool(true)); }
    if s=="false"          { return Ok(Value::Bool(false)); }
    if let Ok(n) = s.parse::<f64>() { return Ok(Value::Number(n)); }
    if s.starts_with('"') && s.ends_with('"') && s.len()>=2 {
        return Ok(Value::String(s[1..s.len()-1]
            .replace("\\n","\n").replace("\\t","\t")
            .replace("\\\"","\"").replace("\\\\","\\")));
    }
    if s.starts_with('[') && s.ends_with(']') {
        let inner = s[1..s.len()-1].trim();
        if inner.is_empty() { return Ok(list(vec![])); }
        let vals: Result<Vec<Value>,_> = json_split(inner)?.iter().map(|i| json_decode(i)).collect();
        return Ok(list(vals?));
    }
    if s.starts_with('{') && s.ends_with('}') {
        let inner = s[1..s.len()-1].trim();
        if inner.is_empty() { return Ok(list(vec![])); }
        let mut alist = Vec::new();
        for pair in json_split(inner)? {
            if let Some(colon) = find_json_colon(pair.trim()) {
                let key = json_decode(pair[..colon].trim())?;
                let val = json_decode(pair[colon+1..].trim())?;
                alist.push(list(vec![key, val]));
            }
        }
        return Ok(list(alist));
    }
    Err(format!("Cannot parse JSON: {}", &s[..s.len().min(40)]))
}

fn json_split(s: &str) -> Result<Vec<String>, String> {
    let mut items=Vec::new(); let mut depth=0i32;
    let mut in_str=false; let mut escape=false; let mut start=0usize;
    for (i,c) in s.char_indices() {
        if escape { escape=false; continue; }
        if in_str { if c=='\\'{escape=true;} else if c=='"'{in_str=false;} continue; }
        match c {
            '"'     => in_str=true,
            '['|'{' => depth+=1,
            ']'|'}' => depth-=1,
            ',' if depth==0 => { items.push(s[start..i].trim().to_string()); start=i+1; }
            _ => {}
        }
    }
    items.push(s[start..].trim().to_string());
    Ok(items)
}

fn find_json_colon(s: &str) -> Option<usize> {
    let mut in_str=false; let mut escape=false;
    for (i,c) in s.char_indices() {
        if escape{escape=false;continue;}
        if in_str{if c=='\\'{escape=true;}else if c=='"'{in_str=false;}continue;}
        if c=='"'{in_str=true;continue;}
        if c==':'{return Some(i);}
    }
    None
}

// ── Memory helpers ────────────────────────────────────────────────────────

fn memory_dir() -> std::path::PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| ".".to_string());
    std::path::PathBuf::from(home).join(".rusty")
}

fn memory_path() -> std::path::PathBuf {
    memory_dir().join("memory.lisp")
}
