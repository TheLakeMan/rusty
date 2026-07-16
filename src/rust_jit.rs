// Copyright (c) 2026 Nicholas Vermeulen
// SPDX-License-Identifier: AGPL-3.0-or-later

//! rust_jit.rs — `defrust` / `defrust*`: compile a restricted numeric Lisp
//! subset to real Rust, via `rustc` + dynamic loading.
//!
//! Scope (deliberately numeric-only — see docs/ROADMAP.md 1.2 / 3.3):
//! a body may contain numbers, params, `let`/`let*` locals, `+ - * /`,
//! the numeric builtins (`sqrt expt abs mod floor ceiling round min max
//! sin cos tan atan atan2 exp log` — `log` is natural log, Rust's `ln`),
//! `if`/`cond` with comparison/`and`/`or`/`not` conditions, self-recursive
//! calls, and — inside a `(defrust* ...)` group — calls to the other
//! functions of the same group (all compiled into one `.so`, so mutual
//! recursion works without cross-library linking). Still no
//! lists/strings/closures/global capture: everything is `f64`.
//!
//! ABI: every compiled function is exposed as
//! `extern "C" fn(args: *const f64, len: usize) -> f64` — one fixed shape
//! regardless of arity, so the interpreter has exactly one unsafe call-through
//! path (`call`, below) instead of one per arity.

use crate::env::Value;
use crate::parser::Expr;
use std::collections::HashMap;
use std::hash::{Hash, Hasher};
use std::path::PathBuf;
use std::rc::Rc;

fn cache_dir() -> PathBuf {
    let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("."));
    let dir = home.join(".rusty").join("jit-cache");
    let _ = std::fs::create_dir_all(&dir);
    dir
}

/// Lisp identifiers allow characters (`-`, `?`, `!`, ...) that Rust
/// identifiers don't. Map every Lisp name to a distinct, always-valid Rust
/// identifier: non `[A-Za-z0-9_]` bytes become `_`, and a fixed `rusty_`
/// prefix rules out both a leading digit and any collision with a Rust
/// keyword (no keyword starts with `rusty_`).
fn sanitize_ident(s: &str) -> String {
    let mut out = String::from("rusty_");
    for c in s.chars() {
        if c.is_ascii_alphanumeric() || c == '_' { out.push(c); } else { out.push('_'); }
    }
    out
}

/// One function being compiled (alone for `defrust`, together for `defrust*`).
pub struct FnDef {
    pub name:   String,
    pub params: Vec<String>,
    pub body:   Expr,
}

struct Ctx {
    raw_params:   Vec<String>,
    rust_params:  Vec<String>,
    /// Every function of the compilation unit (just one for `defrust`):
    /// Lisp name → (Rust `_impl` base name, arity). Self-recursion and
    /// intra-group calls both resolve here.
    fns:          HashMap<String, (String, usize)>,
    /// `let`/`let*` bindings in scope, innermost last: Lisp name → Rust name.
    locals:       Vec<(String, String)>,
    local_counter: usize,
}

impl Ctx {
    fn fresh_local(&mut self, lisp_name: &str) -> String {
        // Suffix with a counter so distinct Lisp names that sanitize to the
        // same Rust identifier (and shadowed re-bindings) stay distinct.
        let rn = format!("{}_l{}", sanitize_ident(lisp_name), self.local_counter);
        self.local_counter += 1;
        self.locals.push((lisp_name.to_string(), rn.clone()));
        rn
    }
    fn lookup(&self, name: &str) -> Option<String> {
        if let Some((_, rn)) = self.locals.iter().rev().find(|(ln, _)| ln == name) {
            return Some(rn.clone());
        }
        self.raw_params.iter().position(|p| p == name).map(|i| self.rust_params[i].clone())
    }
}

// ── Codegen: restricted Expr subset → Rust source ────────────────────────

fn codegen_num(expr: &Expr, ctx: &mut Ctx) -> Result<String, String> {
    match expr {
        Expr::Number(n) => Ok(format!("({:?}_f64)", n)),
        Expr::Symbol(s) => ctx.lookup(s).ok_or_else(|| format!(
            "defrust: unsupported reference to '{}' — only params, let/let* locals, numbers, \
             arithmetic and the numeric builtins are available in a defrust body", s
        )),
        Expr::List(items) if !items.is_empty() => {
            if let Expr::Symbol(head) = &items[0] {
                match head.as_str() {
                    "+" | "-" | "*" | "/" if items.len() >= 2 => {
                        let parts = items[1..].iter()
                            .map(|e| codegen_num(e, ctx))
                            .collect::<Result<Vec<_>, _>>()?;
                        if head == "-" && parts.len() == 1 { return Ok(format!("(-{})", parts[0])); }
                        Ok(format!("({})", parts.join(&format!(" {} ", head))))
                    }
                    "sqrt" | "abs" | "floor" | "ceiling" | "round"
                    | "sin" | "cos" | "tan" | "atan" | "exp" | "log" if items.len() == 2 => {
                        let a = codegen_num(&items[1], ctx)?;
                        let m = match head.as_str() { "ceiling" => "ceil", "log" => "ln", h => h };
                        Ok(format!("{}.{}()", a, m))
                    }
                    "expt" if items.len() == 3 => {
                        let a = codegen_num(&items[1], ctx)?;
                        let b = codegen_num(&items[2], ctx)?;
                        Ok(format!("{}.powf({})", a, b))
                    }
                    "atan2" if items.len() == 3 => {
                        let a = codegen_num(&items[1], ctx)?;
                        let b = codegen_num(&items[2], ctx)?;
                        Ok(format!("{}.atan2({})", a, b))
                    }
                    "mod" if items.len() == 3 => {
                        // Same as the interpreter's Rust `%` — except a zero
                        // divisor yields NaN here instead of an error (a
                        // compiled body has no error channel).
                        let a = codegen_num(&items[1], ctx)?;
                        let b = codegen_num(&items[2], ctx)?;
                        Ok(format!("({} % {})", a, b))
                    }
                    "min" | "max" if items.len() == 2 => codegen_num(&items[1], ctx),
                    "min" | "max" if items.len() >= 3 => {
                        let mut acc = codegen_num(&items[1], ctx)?;
                        for e in &items[2..] {
                            acc = format!("{}.{}({})", acc, head, codegen_num(e, ctx)?);
                        }
                        Ok(acc)
                    }
                    "if" if items.len() == 4 => {
                        let c = codegen_bool(&items[1], ctx)?;
                        let t = codegen_num(&items[2], ctx)?;
                        let e = codegen_num(&items[3], ctx)?;
                        Ok(format!("(if {} {{ {} }} else {{ {} }})", c, t, e))
                    }
                    "cond" if items.len() >= 2 => codegen_cond(&items[1..], ctx),
                    "let" | "let*" if items.len() == 3 => codegen_let(head == "let*", &items[1], &items[2], ctx),
                    "let" | "let*" => Err(
                        "defrust: let/let* takes exactly (let ((name init)...) body) — one body \
                         expression (the subset is pure, earlier ones would be dead code); \
                         named let is not supported, use self-recursion".into()
                    ),
                    s if ctx.fns.contains_key(s) => {
                        if ctx.lookup(s).is_some() {
                            return Err(format!(
                                "defrust: '{}' is shadowed by a local/param here and cannot be called", s));
                        }
                        let (impl_name, arity) = ctx.fns[s].clone();
                        if items.len() - 1 != arity {
                            return Err(format!(
                                "defrust: '{}' called with {} arg(s), expected {}",
                                s, items.len() - 1, arity
                            ));
                        }
                        let args = items[1..].iter()
                            .map(|e| codegen_num(e, ctx))
                            .collect::<Result<Vec<_>, _>>()?;
                        Ok(format!("{}_impl({})", impl_name, args.join(", ")))
                    }
                    other => Err(format!(
                        "defrust: unsupported call to '{}' — only self-recursion, functions in the \
                         same defrust* group, and the numeric builtins \
                         (sqrt expt abs mod floor ceiling round min max sin cos tan atan atan2 exp log) \
                         are supported", other
                    )),
                }
            } else {
                Err("defrust: unsupported expression in body".into())
            }
        }
        _ => Err("defrust: only numbers, params, locals, arithmetic, numeric builtins, \
                  if/cond and let/let* are supported in the body".into()),
    }
}

fn codegen_let(sequential: bool, bindings: &Expr, body: &Expr, ctx: &mut Ctx) -> Result<String, String> {
    let Expr::List(bs) = bindings else {
        return Err("defrust: let bindings must be a list of (name init) pairs".into());
    };
    let mut pairs = Vec::with_capacity(bs.len());
    for b in bs.iter() {
        match b {
            Expr::List(p) if p.len() == 2 => {
                if let Expr::Symbol(n) = &p[0] { pairs.push((n.clone(), &p[1])); }
                else { return Err("defrust: let binding name must be a symbol".into()); }
            }
            _ => return Err("defrust: let bindings must be (name init) pairs".into()),
        }
    }
    let saved = ctx.locals.len();
    let mut code = String::from("{ ");
    if sequential {
        for (name, init) in &pairs {
            let init_code = codegen_num(init, ctx)?; // sees earlier bindings (let*)
            let rn = ctx.fresh_local(name);
            code.push_str(&format!("let {} = {}; ", rn, init_code));
        }
    } else {
        // Parallel `let`: all inits evaluate in the outer scope, then bind
        // together (tuple destructuring), so bindings can't see each other.
        let inits = pairs.iter()
            .map(|(_, init)| codegen_num(init, ctx))
            .collect::<Result<Vec<_>, _>>()?;
        let names: Vec<String> = pairs.iter().map(|(n, _)| ctx.fresh_local(n)).collect();
        match names.len() {
            0 => {}
            1 => code.push_str(&format!("let {} = {}; ", names[0], inits[0])),
            _ => code.push_str(&format!("let ({}) = ({}); ", names.join(", "), inits.join(", "))),
        }
    }
    let body_code = codegen_num(body, ctx)?;
    ctx.locals.truncate(saved);
    code.push_str(&body_code);
    code.push_str(" }");
    Ok(code)
}

fn codegen_cond(clauses: &[Expr], ctx: &mut Ctx) -> Result<String, String> {
    let mut arms: Vec<(Option<String>, String)> = Vec::with_capacity(clauses.len());
    for (i, clause) in clauses.iter().enumerate() {
        let Expr::List(c) = clause else {
            return Err("defrust: cond clauses must be (test expr) lists".into());
        };
        if c.len() != 2 {
            return Err("defrust: cond clauses must have exactly one result expression".into());
        }
        let is_else = matches!(&c[0], Expr::Symbol(s) if s == "else");
        if is_else {
            if i != clauses.len() - 1 { return Err("defrust: cond `else` must be the last clause".into()); }
            arms.push((None, codegen_num(&c[1], ctx)?));
        } else {
            arms.push((Some(codegen_bool(&c[0], ctx)?), codegen_num(&c[1], ctx)?));
        }
    }
    if arms.last().map_or(true, |(c, _)| c.is_some()) {
        return Err("defrust: cond must end with an `else` clause — a compiled \
                    function always returns an f64, so every path needs a value".into());
    }
    let mut code = String::from("(");
    for (i, (cond, val)) in arms.iter().enumerate() {
        match cond {
            Some(c) if i == 0 => code.push_str(&format!("if {} {{ {} }}", c, val)),
            Some(c)           => code.push_str(&format!(" else if {} {{ {} }}", c, val)),
            None              => code.push_str(&format!(" else {{ {} }}", val)),
        }
    }
    code.push(')');
    Ok(code)
}

fn codegen_bool(expr: &Expr, ctx: &mut Ctx) -> Result<String, String> {
    if let Expr::List(items) = expr {
        if let Some(Expr::Symbol(head)) = items.first() {
            match head.as_str() {
                "<" | ">" | "<=" | ">=" | "=" if items.len() == 3 => {
                    let a = codegen_num(&items[1], ctx)?;
                    let b = codegen_num(&items[2], ctx)?;
                    let op = if head == "=" { "==" } else { head.as_str() };
                    return Ok(format!("({} {} {})", a, op, b));
                }
                "and" if items.len() >= 2 => {
                    let parts = items[1..].iter()
                        .map(|e| codegen_bool(e, ctx))
                        .collect::<Result<Vec<_>, _>>()?;
                    return Ok(format!("({})", parts.join(" && ")));
                }
                "or" if items.len() >= 2 => {
                    let parts = items[1..].iter()
                        .map(|e| codegen_bool(e, ctx))
                        .collect::<Result<Vec<_>, _>>()?;
                    return Ok(format!("({})", parts.join(" || ")));
                }
                "not" if items.len() == 2 => {
                    return Ok(format!("(!{})", codegen_bool(&items[1], ctx)?));
                }
                _ => {}
            }
        }
    }
    Err("defrust: an `if`/`cond` condition must be a comparison (< > <= >= =) or and/or/not of comparisons".into())
}

fn generate_fn_source(def: &FnDef, fns: &HashMap<String, (String, usize)>) -> Result<String, String> {
    let mut ctx = Ctx {
        raw_params:    def.params.clone(),
        rust_params:   def.params.iter().map(|p| sanitize_ident(p)).collect(),
        fns:           fns.clone(),
        locals:        Vec::new(),
        local_counter: 0,
    };
    let body_rust = codegen_num(&def.body, &mut ctx)?;
    let rust_name = &fns[&def.name].0;
    let unpack: String = ctx.rust_params.iter().enumerate()
        .map(|(i, p)| format!("    let {} = unsafe {{ *args.add({}) }};\n", p, i))
        .collect();
    let call_args = ctx.rust_params.join(", ");
    let typed_params = ctx.rust_params.iter().map(|p| format!("{}: f64", p)).collect::<Vec<_>>().join(", ");
    Ok(format!(
        "#[no_mangle]\npub extern \"C\" fn {name}(args: *const f64, len: usize) -> f64 {{\n\
         \x20   debug_assert_eq!(len, {arity});\n{unpack}\x20   {name}_impl({call_args})\n}}\n\n\
         fn {name}_impl({typed_params}) -> f64 {{\n    {body}\n}}\n",
        name = rust_name, arity = ctx.rust_params.len(), unpack = unpack, call_args = call_args,
        typed_params = typed_params, body = body_rust,
    ))
}

// ── Compile (rustc, cached by source hash) + dynamically load ───────────

/// Compile one or more functions into a single `.so` (one function for
/// `defrust`, a whole group for `defrust*` — that's what makes calls between
/// them plain Rust calls instead of cross-library linking). Returns one
/// `Value::Native` per input, in order, all sharing the same loaded Library.
pub fn compile_and_load_group(defs: &[FnDef]) -> Result<Vec<Value>, String> {
    if defs.is_empty() { return Err("defrust*: at least one function required".into()); }
    let mut fns: HashMap<String, (String, usize)> = HashMap::new();
    for d in defs {
        if fns.insert(d.name.clone(), (sanitize_ident(&d.name), d.params.len())).is_some() {
            return Err(format!("defrust*: duplicate function name '{}'", d.name));
        }
    }
    let source = defs.iter()
        .map(|d| generate_fn_source(d, &fns))
        .collect::<Result<Vec<_>, _>>()?
        .join("\n");
    let wants: Vec<(String, String, usize)> = defs.iter()
        .map(|d| (d.name.clone(), fns[&d.name].0.clone(), d.params.len()))
        .collect();
    build_and_load(&source, &wants)
}

/// Shared back half of every compilation path (`defrust`, `defrust*`,
/// `graph-compile`): write source, `rustc` it (cached by source hash),
/// load the `.so`, and resolve one `Value::Native` per requested symbol.
/// `wants` is (Lisp name, Rust symbol, arity) per function.
fn build_and_load(source: &str, wants: &[(String, String, usize)]) -> Result<Vec<Value>, String> {
    let lib = build_lib(source, &wants[0].1)?;
    wants.iter().map(|(lisp_name, rust_name, arity)| {
        let fn_ptr: *const () = unsafe {
            let sym: libloading::Symbol<unsafe extern "C" fn(*const f64, usize) -> f64> = lib
                .get(rust_name.as_bytes())
                .map_err(|e| format!("defrust: symbol '{}' not found in compiled library: {}", rust_name, e))?;
            *sym as *const ()
        };
        Ok(Value::Native { name: lisp_name.clone(), arity: *arity, lib: lib.clone(), fn_ptr })
    }).collect()
}

/// Write source, `rustc` it (cached on disk by source hash), load the `.so`.
/// Symbol resolution is the caller's job — ABIs differ per compilation path.
const RUSTC_FLAGS: [&str; 6] = ["--edition", "2021", "-C", "opt-level=3", "--crate-type", "cdylib"];

/// AVX2 is enabled only when the *running* CPU has it (the cache is
/// per-machine, but a copied ~/.rusty must not SIGILL a smaller box), and as
/// explicit target features rather than `target-cpu=native` so the flag —
/// and therefore the cache hash — says exactly what the .so contains.
/// Bit-exactness survives: Rust never contracts mul+add into FMA and never
/// reassociates float reductions, so wider vectors change speed, not values.
fn rustc_flags() -> Vec<&'static str> {
    let mut flags = RUSTC_FLAGS.to_vec();
    #[cfg(target_arch = "x86_64")]
    if std::arch::is_x86_feature_detected!("avx2") {
        flags.push("-C");
        flags.push("target-feature=+avx,+avx2");
    }
    flags
}

fn build_lib(source: &str, base: &str) -> Result<Rc<libloading::Library>, String> {
    let flags = rustc_flags();
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    source.hash(&mut hasher);
    flags.hash(&mut hasher); // changed flags must invalidate cached .so's
    let hash = hasher.finish();

    let so_ext = if cfg!(target_os = "macos") { "dylib" } else if cfg!(target_os = "windows") { "dll" } else { "so" };
    let dir = cache_dir();
    let so_path  = dir.join(format!("{}_{:x}.{}", base, hash, so_ext));
    let src_path = dir.join(format!("{}_{:x}.rs", base, hash));

    if !so_path.exists() {
        std::fs::write(&src_path, source)
            .map_err(|e| format!("defrust: cannot write {}: {}", src_path.display(), e))?;
        let output = std::process::Command::new("rustc")
            .args(&flags)
            .arg("-o")
            .arg(&so_path)
            .arg(&src_path)
            .output()
            .map_err(|e| format!("defrust: failed to run rustc (is it on PATH?): {}", e))?;
        if !output.status.success() {
            return Err(format!("defrust: rustc failed:\n{}", String::from_utf8_lossy(&output.stderr)));
        }
    }

    Ok(Rc::new(unsafe { libloading::Library::new(&so_path) }
        .map_err(|e| format!("defrust: failed to load {}: {}", so_path.display(), e))?))
}

// ── Kernel fusion: optimized Graph IR → one fused native function ───────

/// Compile an already-optimized scalar graph (Phase 3.3 "kernel fusion"):
/// the whole DAG becomes ONE straight-line Rust function — every node a
/// `let`, in topological order (`Node::args` are always < the node's own
/// index), CSE/folding/DCE already done by `optimize()`. Matches
/// `eval_graph`'s semantics exactly, including its eager `If` (a select
/// between two already-computed values, not a branch).
pub fn compile_graph(name: &str, graph: &crate::graph_ir::Graph, nparams: usize) -> Result<Value, String> {
    use crate::graph_ir::Op;
    let rust_name = sanitize_ident(name);
    let mut body = String::new();
    for (i, node) in graph.nodes.iter().enumerate() {
        let a = node.args.first().copied().unwrap_or(0);
        let b = node.args.get(1).copied().unwrap_or(0);
        let expr = match &node.op {
            Op::Const(bits) => format!("f64::from_bits({}u64) /* {:?} */", bits, f64::from_bits(*bits)),
            Op::Param(p)    => format!("p{}", p),
            Op::Add => format!("v{} + v{}", a, b),
            Op::Sub => format!("v{} - v{}", a, b),
            Op::Mul => format!("v{} * v{}", a, b),
            Op::Div => format!("v{} / v{}", a, b),
            Op::Lt  => format!("if v{} <  v{} {{ 1.0_f64 }} else {{ 0.0_f64 }}", a, b),
            Op::Gt  => format!("if v{} >  v{} {{ 1.0_f64 }} else {{ 0.0_f64 }}", a, b),
            Op::Le  => format!("if v{} <= v{} {{ 1.0_f64 }} else {{ 0.0_f64 }}", a, b),
            Op::Ge  => format!("if v{} >= v{} {{ 1.0_f64 }} else {{ 0.0_f64 }}", a, b),
            Op::Eq  => format!("if v{} == v{} {{ 1.0_f64 }} else {{ 0.0_f64 }}", a, b),
            Op::If  => format!("if v{} != 0.0 {{ v{} }} else {{ v{} }}", a, b, node.args[2]),
            Op::Relu => format!("v{}.max(0.0)", a),
            Op::Step => format!("if v{} > 0.0 {{ 1.0_f64 }} else {{ 0.0_f64 }}", a),
            other => return Err(format!(
                "graph-compile: '{}' is a tensor op — compiled graph kernels are scalar-only \
                 (tensor fusion is shape-specialized, see graph-grad)", crate::graph_ir::op_name(other)
            )),
        };
        body.push_str(&format!("    let v{} = {};\n", i, expr));
    }
    body.push_str(&format!("    v{}", graph.output));

    let unpack: String = (0..nparams)
        .map(|i| format!("    let p{} = unsafe {{ *args.add({}) }};\n", i, i))
        .collect();
    let source = format!(
        "#[allow(unused_variables)]\n#[no_mangle]\n\
         pub extern \"C\" fn {name}(args: *const f64, len: usize) -> f64 {{\n\
         \x20   debug_assert_eq!(len, {arity});\n{unpack}{body}\n}}\n",
        name = rust_name, arity = nparams, unpack = unpack, body = body,
    );
    Ok(build_and_load(&source, &[(name.to_string(), rust_name, nparams)])?.pop().unwrap())
}

pub fn compile_and_load(name: &str, params: &[String], body: &Expr) -> Result<Value, String> {
    let defs = [FnDef { name: name.to_string(), params: params.to_vec(), body: body.clone() }];
    Ok(compile_and_load_group(&defs)?.pop().unwrap())
}

/// Call a loaded `defrust` function. `fn_ptr` must have come from
/// `compile_and_load` (same fixed ABI), and the backing `Library` (kept
/// alive by `Value::Native`'s `Rc`) must still be alive.
pub fn call(fn_ptr: *const (), args: &[f64]) -> f64 {
    let f: unsafe extern "C" fn(*const f64, usize) -> f64 = unsafe { std::mem::transmute(fn_ptr) };
    unsafe { f(args.as_ptr(), args.len()) }
}

// ── Tensor kernel fusion (Phase 3.3, tensor half) ────────────────────────
//
// `graph-compile-grad` compiles a whole forward+backward training graph to
// ONE native function, shape-specialized: every buffer size, loop bound,
// and matmul dimension is a compile-time constant in the generated Rust.
// ABI: `extern "C" fn(inp: *const f64, out: *mut f64)` — inputs flattened
// and concatenated in param order; outputs are loss then each gradient,
// flattened, at statically known offsets.

use crate::graph_ir::{Graph, Op, SShape};

fn ssize(s: &SShape) -> usize {
    match s { None => 1, Some(sh) => sh.iter().product() }
}

pub fn compile_graph_grad(
    name: &str,
    graph: &Graph,
    outputs: &[usize],
    in_shapes: &[SShape],
) -> Result<Value, String> {
    let shapes = crate::graph_ir::infer_shapes(graph, in_shapes)?;
    if shapes[outputs[0]].is_some() {
        return Err("graph-grad: the loss must evaluate to a scalar (use tensor-sum or a mean)".into());
    }

    let mut body = String::new();
    for (i, node) in graph.nodes.iter().enumerate() {
        let a = node.args.first().copied().unwrap_or(0);
        let b = node.args.get(1).copied().unwrap_or(0);
        let (sa, sb) = (node.args.first().map(|&x| &shapes[x]), node.args.get(1).map(|&x| &shapes[x]));
        let expr = match &node.op {
            Op::Const(bits) => format!("f64::from_bits({}u64) /* {:?} */", bits, f64::from_bits(*bits)),
            // `inp` is one pointer per param (see the ABI note on the signature
            // below), so a tensor param borrows the caller's own buffer in
            // place: no copy in, and nothing to flatten. Every op below only
            // reads its arguments (`.iter()`, indexing, slicing, `.as_ptr()`),
            // so an owned Vec would buy nothing. The two sites that do need an
            // owned value (`If` arms, `SumTo` identity) say so themselves with
            // `.to_vec()`, which works on slice and Vec alike — that is what
            // keeps the generated types uniform.
            Op::Param(p) => match &in_shapes[*p] {
                None => format!("unsafe {{ *(*inp.add({})) }}", p),
                Some(sh) => format!(
                    "unsafe {{ std::slice::from_raw_parts(*inp.add({}), {}) }}",
                    p, sh.iter().product::<usize>()),
            },
            Op::Add => format!("v{} + v{}", a, b),
            Op::Sub => format!("v{} - v{}", a, b),
            Op::Mul => format!("v{} * v{}", a, b),
            Op::Div => format!("v{} / v{}", a, b),
            Op::Lt  => format!("if v{} <  v{} {{ 1.0_f64 }} else {{ 0.0_f64 }}", a, b),
            Op::Gt  => format!("if v{} >  v{} {{ 1.0_f64 }} else {{ 0.0_f64 }}", a, b),
            Op::Le  => format!("if v{} <= v{} {{ 1.0_f64 }} else {{ 0.0_f64 }}", a, b),
            Op::Ge  => format!("if v{} >= v{} {{ 1.0_f64 }} else {{ 0.0_f64 }}", a, b),
            Op::Eq  => format!("if v{} == v{} {{ 1.0_f64 }} else {{ 0.0_f64 }}", a, b),
            Op::If  => {
                let (t, e) = (node.args[1], node.args[2]);
                if shapes[t].is_some() {
                    // to_vec, not clone: an arm may be a borrowed param slice
                    // while the other is an owned Vec, and both arms of an `if`
                    // must have the same type.
                    format!("if v{} != 0.0 {{ v{}.to_vec() }} else {{ v{}.to_vec() }}", a, t, e)
                } else {
                    format!("if v{} != 0.0 {{ v{} }} else {{ v{} }}", a, t, e)
                }
            }
            Op::TAdd | Op::TSub | Op::TMul | Op::TDiv => {
                let o = match node.op { Op::TAdd => "+", Op::TSub => "-", Op::TMul => "*", _ => "/" };
                match (sa.unwrap(), sb.unwrap()) {
                    (Some(_), Some(_)) => format!(
                        "v{}.iter().zip(v{}.iter()).map(|(x, y)| x {} y).collect::<Vec<f64>>()", a, b, o),
                    (Some(_), None) => format!(
                        "v{}.iter().map(|x| x {} v{}).collect::<Vec<f64>>()", a, o, b),
                    (None, Some(_)) => format!(
                        "v{}.iter().map(|y| v{} {} y).collect::<Vec<f64>>()", b, a, o),
                    (None, None) => format!("v{} {} v{}", a, o, b),
                }
            }
            Op::MatMul => {
                let (x, y) = (sa.unwrap().as_ref().unwrap(), sb.unwrap().as_ref().unwrap());
                let (m, k, n) = (x[0], x[1], y[1]);
                // ikj order with row slices: same per-element accumulation
                // order as the interpreter's t_matmul (p ascending — results
                // stay bit-identical), but contiguous access on both sides
                // and an inner loop that is elementwise FMA into distinct
                // slots, so LLVM can vectorize it without reassociating.
                format!(
                    "{{ let mut o = vec![0.0_f64; {m} * {n}]; \
                       for i in 0..{m} {{ \
                       let a_row = &v{a}[i * {k}..(i + 1) * {k}]; \
                       let o_row = &mut o[i * {n}..(i + 1) * {n}]; \
                       for p in 0..{k} {{ let x = a_row[p]; \
                       let b_row = &v{b}[p * {n}..(p + 1) * {n}]; \
                       for j in 0..{n} {{ o_row[j] += x * b_row[j]; }} }} }} o }}",
                    m = m, k = k, n = n, a = a, b = b)
            }
            Op::Transpose => {
                let x = sa.unwrap().as_ref().unwrap();
                let (m, n) = (x[0], x[1]);
                format!(
                    "{{ let mut o = vec![0.0_f64; {n} * {m}]; \
                       for i in 0..{m} {{ for j in 0..{n} {{ o[j * {m} + i] = v{a}[i * {n} + j]; }} }} o }}",
                    m = m, n = n, a = a)
            }
            Op::TSum => match sa.unwrap() {
                Some(_) => format!("v{}.iter().sum::<f64>()", a),
                None => format!("v{}", a),
            },
            Op::Relu => match sa.unwrap() {
                Some(_) => format!("v{}.iter().map(|x| x.max(0.0)).collect::<Vec<f64>>()", a),
                None => format!("v{}.max(0.0)", a),
            },
            Op::Step => match sa.unwrap() {
                Some(_) => format!(
                    "v{}.iter().map(|x| if *x > 0.0 {{ 1.0_f64 }} else {{ 0.0_f64 }}).collect::<Vec<f64>>()", a),
                None => format!("if v{} > 0.0 {{ 1.0_f64 }} else {{ 0.0_f64 }}", a),
            },
            // Inference already validated these, so each is one exact arm here:
            Op::SumTo => match (sa.unwrap(), sb.unwrap()) {
                (Some(_), None) => format!("v{}.iter().sum::<f64>()", a),
                (None, None)    => format!("v{}", a),
                // Same-shape identity — borrow it. This arm fires once per
                // gradient accumulation, so cloning here copied the whole
                // tensor several times per call to produce a value nothing
                // mutates. Consumers all auto-deref through the reference.
                _               => format!("&v{}", a),
            },
            Op::Expand => match sb.unwrap() {
                None => format!("v{}", a),
                Some(sh) => format!("vec![v{}; {}]", a, sh.iter().product::<usize>()),
            },
        };
        body.push_str(&format!("    let v{} = {};\n", i, expr));
    }

    // Outputs: loss first, then each gradient — one caller-owned buffer each,
    // written in place, so the caller never copies a result back out.
    let out_shapes: Vec<SShape> = outputs.iter().map(|&o| shapes[o].clone()).collect();
    for (k, (&o, s)) in outputs.iter().zip(&out_shapes).enumerate() {
        match s {
            None => body.push_str(&format!("    unsafe {{ *(*out.add({})) = v{}; }}\n", k, o)),
            Some(sh) => body.push_str(&format!(
                "    unsafe {{ std::ptr::copy_nonoverlapping(v{}.as_ptr(), *out.add({}), {}); }}\n",
                o, k, sh.iter().product::<usize>())),
        }
    }

    let rust_name = sanitize_ident(name);
    let source = format!(
        "#[allow(unused_variables)]\n#[no_mangle]\n\
         pub extern \"C\" fn {name}(inp: *const *const f64, out: *const *mut f64) {{\n{body}}}\n",
        name = rust_name, body = body,
    );
    let lib = build_lib(&source, &rust_name)?;
    let fn_ptr: *const () = unsafe {
        let sym: libloading::Symbol<unsafe extern "C" fn(*const *const f64, *const *mut f64)> = lib
            .get(rust_name.as_bytes())
            .map_err(|e| format!("graph-compile-grad: symbol '{}' not found: {}", rust_name, e))?;
        *sym as *const ()
    };
    Ok(Value::NativeGrad {
        name: name.to_string(),
        lib,
        fn_ptr,
        in_shapes: Rc::new(in_shapes.to_vec()),
        out_shapes: Rc::new(out_shapes),
    })
}

/// Point a fused grad kernel at its arguments, run it, and return
/// `(loss grad-per-param...)` — the exact result shape `graph-grad` produces.
/// Shared by the eval dispatch and `apply`.
///
/// ABI: `fn(*const *const f64, *const *mut f64)` — one pointer per argument and
/// one per output, rather than two flat buffers at static offsets. Tensors are
/// already contiguous `Rc<Vec<f64>>`, so the kernel reads them where they lie
/// and writes each result into the buffer that becomes that result's tensor:
/// nothing is copied in or out. The flat-buffer ABI this replaced copied every
/// input in and every output back (~885 KB per call on a 64×256→64 layer).
pub fn call_native_grad(
    name: &str,
    fn_ptr: *const (),
    in_shapes: &[SShape],
    out_shapes: &[SShape],
    args: &[Value],
) -> Result<Value, String> {
    if args.len() != in_shapes.len() {
        return Err(format!("{}: expected {} arg(s), got {}", name, in_shapes.len(), args.len()));
    }
    // Validate, and stash scalar args. This Vec must be filled completely
    // before any pointer into it is taken — a later push could reallocate and
    // dangle the earlier ones.
    let mut scalars: Vec<f64> = Vec::with_capacity(in_shapes.len());
    for (arg, want) in args.iter().zip(in_shapes) {
        match (arg, want) {
            (Value::Number(n), None) => scalars.push(*n),
            (Value::Tensor { data: _, shape }, Some(sh)) if shape == sh => {}
            (Value::Tensor { shape, .. }, Some(sh)) => return Err(format!(
                "{}: compiled for shape {:?}, got {:?} — run graph-compile-grad again for new shapes",
                name, sh, shape)),
            (other, want) => return Err(format!(
                "{}: expected {}, got {}", name,
                match want { None => "a number".to_string(), Some(sh) => format!("a tensor of shape {:?}", sh) },
                other)),
        }
    }

    // One pointer per argument: a tensor hands over its own buffer, so nothing
    // is copied in. `args` (and the `Rc`s inside it) outlive the call, and
    // `scalars` is complete, so every pointer stays valid for the whole call.
    let mut si = 0usize;
    let mut in_ptrs: Vec<*const f64> = Vec::with_capacity(args.len());
    for arg in args {
        match arg {
            Value::Tensor { data, .. } => in_ptrs.push(data.as_ptr()),
            _ => { in_ptrs.push(&scalars[si] as *const f64); si += 1; }
        }
    }

    // One buffer per output, written in place by the kernel, then handed
    // straight to the Value — so a result is never copied back out either.
    let mut out_bufs: Vec<Vec<f64>> = out_shapes.iter().map(|s| vec![0.0_f64; ssize(s)]).collect();
    let mut out_ptrs: Vec<*mut f64> = out_bufs.iter_mut().map(|b| b.as_mut_ptr()).collect();

    let f: unsafe extern "C" fn(*const *const f64, *const *mut f64) = unsafe { std::mem::transmute(fn_ptr) };
    unsafe { f(in_ptrs.as_ptr(), out_ptrs.as_mut_ptr()) };

    let results = out_bufs.into_iter().zip(out_shapes).map(|(buf, s)| match s {
        None => Value::Number(buf[0]),
        Some(sh) => Value::Tensor { data: Rc::new(buf), shape: sh.clone() },
    }).collect();
    Ok(crate::env::list(results))
}
