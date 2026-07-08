//! rust_jit.rs — `defrust`: compile a restricted numeric Lisp subset to real
//! Rust, via `rustc` + dynamic loading.
//!
//! Scope (deliberately small — see docs/ROADMAP.md 1.2 for the reasoning):
//! body may only contain numbers, the function's own params, `+ - * /`,
//! `if` with a comparison/`and`/`or`/`not` condition, and self-recursive
//! calls. No calls to *other* `defrust` functions (that needs cross-.so
//! linking, cut from v1), no lists/strings/closures/global capture.
//!
//! ABI: every compiled function is exposed as
//! `extern "C" fn(args: *const f64, len: usize) -> f64` — one fixed shape
//! regardless of arity, so the interpreter has exactly one unsafe call-through
//! path (`call`, below) instead of one per arity.

use crate::env::Value;
use crate::parser::Expr;
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

struct Ctx {
    raw_name:     String,   // the Lisp name, for matching self-recursive calls in the AST
    raw_params:   Vec<String>,
    rust_name:    String,   // sanitized, for emitting Rust source
    rust_params:  Vec<String>,
}

// ── Codegen: restricted Expr subset → Rust source ────────────────────────

fn codegen_num(expr: &Expr, ctx: &Ctx) -> Result<String, String> {
    match expr {
        Expr::Number(n) => Ok(format!("({:?}_f64)", n)),
        Expr::Symbol(s) => {
            if let Some(i) = ctx.raw_params.iter().position(|p| p == s) {
                Ok(ctx.rust_params[i].clone())
            } else {
                Err(format!(
                    "defrust: unsupported reference to '{}' — only params, numbers, + - * /, if, \
                     and self-recursive calls are supported in a defrust body", s
                ))
            }
        }
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
                    "if" if items.len() == 4 => {
                        let c = codegen_bool(&items[1], ctx)?;
                        let t = codegen_num(&items[2], ctx)?;
                        let e = codegen_num(&items[3], ctx)?;
                        Ok(format!("(if {} {{ {} }} else {{ {} }})", c, t, e))
                    }
                    s if s == ctx.raw_name => {
                        if items.len() - 1 != ctx.raw_params.len() {
                            return Err(format!(
                                "defrust: '{}' called with {} arg(s), expected {}",
                                ctx.raw_name, items.len() - 1, ctx.raw_params.len()
                            ));
                        }
                        let args = items[1..].iter()
                            .map(|e| codegen_num(e, ctx))
                            .collect::<Result<Vec<_>, _>>()?;
                        Ok(format!("{}_impl({})", ctx.rust_name, args.join(", ")))
                    }
                    other => Err(format!(
                        "defrust: unsupported call to '{}' — only self-recursion is supported, \
                         calls to other functions are not (v1 scope, see docs/ROADMAP.md)", other
                    )),
                }
            } else {
                Err("defrust: unsupported expression in body".into())
            }
        }
        _ => Err("defrust: only numbers, params, + - * /, and if are supported in the body".into()),
    }
}

fn codegen_bool(expr: &Expr, ctx: &Ctx) -> Result<String, String> {
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
    Err("defrust: an `if` condition must be a comparison (< > <= >= =) or and/or/not of comparisons".into())
}

fn generate_source(ctx: &Ctx, body_rust: &str) -> String {
    let unpack: String = ctx.rust_params.iter().enumerate()
        .map(|(i, p)| format!("    let {} = unsafe {{ *args.add({}) }};\n", p, i))
        .collect();
    let call_args = ctx.rust_params.join(", ");
    let typed_params = ctx.rust_params.iter().map(|p| format!("{}: f64", p)).collect::<Vec<_>>().join(", ");
    format!(
        "#[no_mangle]\npub extern \"C\" fn {name}(args: *const f64, len: usize) -> f64 {{\n\
         \x20   debug_assert_eq!(len, {arity});\n{unpack}\x20   {name}_impl({call_args})\n}}\n\n\
         fn {name}_impl({typed_params}) -> f64 {{\n    {body}\n}}\n",
        name = ctx.rust_name, arity = ctx.rust_params.len(), unpack = unpack, call_args = call_args,
        typed_params = typed_params, body = body_rust,
    )
}

// ── Compile (rustc, cached by source hash) + dynamically load ───────────

pub fn compile_and_load(name: &str, params: &[String], body: &Expr) -> Result<Value, String> {
    let ctx = Ctx {
        raw_name:    name.to_string(),
        raw_params:  params.to_vec(),
        rust_name:   sanitize_ident(name),
        rust_params: params.iter().map(|p| sanitize_ident(p)).collect(),
    };
    let body_rust = codegen_num(body, &ctx)?;
    let source = generate_source(&ctx, &body_rust);

    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    source.hash(&mut hasher);
    let hash = hasher.finish();

    let so_ext = if cfg!(target_os = "macos") { "dylib" } else if cfg!(target_os = "windows") { "dll" } else { "so" };
    let dir = cache_dir();
    let so_path  = dir.join(format!("{}_{:x}.{}", ctx.rust_name, hash, so_ext));
    let src_path = dir.join(format!("{}_{:x}.rs", ctx.rust_name, hash));

    if !so_path.exists() {
        std::fs::write(&src_path, &source)
            .map_err(|e| format!("defrust: cannot write {}: {}", src_path.display(), e))?;
        let output = std::process::Command::new("rustc")
            .args(["--edition", "2021", "-O", "--crate-type", "cdylib", "-o"])
            .arg(&so_path)
            .arg(&src_path)
            .output()
            .map_err(|e| format!("defrust: failed to run rustc (is it on PATH?): {}", e))?;
        if !output.status.success() {
            return Err(format!("defrust: rustc failed:\n{}", String::from_utf8_lossy(&output.stderr)));
        }
    }

    let lib = unsafe { libloading::Library::new(&so_path) }
        .map_err(|e| format!("defrust: failed to load {}: {}", so_path.display(), e))?;
    let fn_ptr: *const () = unsafe {
        let sym: libloading::Symbol<unsafe extern "C" fn(*const f64, usize) -> f64> = lib
            .get(ctx.rust_name.as_bytes())
            .map_err(|e| format!("defrust: symbol '{}' not found in compiled library: {}", ctx.rust_name, e))?;
        *sym as *const ()
    };

    Ok(Value::Native { name: name.to_string(), arity: params.len(), lib: Rc::new(lib), fn_ptr })
}

/// Call a loaded `defrust` function. `fn_ptr` must have come from
/// `compile_and_load` (same fixed ABI), and the backing `Library` (kept
/// alive by `Value::Native`'s `Rc`) must still be alive.
pub fn call(fn_ptr: *const (), args: &[f64]) -> f64 {
    let f: unsafe extern "C" fn(*const f64, usize) -> f64 = unsafe { std::mem::transmute(fn_ptr) };
    unsafe { f(args.as_ptr(), args.len()) }
}
