// Copyright (c) 2026 Nicholas Vermeulen
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Rusty Python bindings via PyO3
//!
//! Usage:
//!   import rusty
//!   print(rusty.eval("(+ 1 2)"))          # => "3"
//!   r = rusty.Rusty()
//!   r.eval("(define x 42)")
//!   r.eval("(* x 2)")                     # => "84" (stateless: x not persisted)
//!
//!   s = rusty.RustySession()
//!   s.eval("(define x 42)")
//!   s.eval("(* x 2)")                     # => "84" (stateful: x persisted)

use pyo3::prelude::*;
use pyo3::wrap_pyfunction;

mod lexer;
mod parser;
mod resolve;
mod env;
mod eval;
mod interp;
mod arena;
mod rust_jit;
mod graph_ir;
mod checkpoint;
mod trace;
mod type_check;
mod effect_check;
mod kg;

use eval::Evaluator;
use interp::{make_env, run_code, print_repr};

/// Run `f` on a worker thread with a large stack and return its result. The
/// interpreter recurses on the native stack for non-tail eval / recursive
/// parsing / value display, and its guard is calibrated for this stack size
/// (see src/main.rs and eval.rs). The Rc-based env is built *inside* `f`, so
/// nothing non-Send crosses the boundary; a scoped thread lets `f` borrow the
/// caller's `code`/history.
fn on_big_stack<R: Send>(f: impl FnOnce() -> R + Send) -> R {
    let stack = eval::interp_stack_bytes();
    std::thread::scope(|s| {
        std::thread::Builder::new()
            .stack_size(stack)
            .spawn_scoped(s, || { eval::set_interp_stack(stack); f() })
            .expect("failed to spawn interpreter thread")
            .join()
            .expect("interpreter thread panicked")
    })
}

// ── Stateless interpreter ─────────────────────────────────────────────────

/// Stateless Rusty interpreter. Each eval() call gets a fresh environment.
/// Fast for one-shot tool calls and expression evaluation.
#[pyclass(name = "Rusty")]
pub struct RustyInterp;

#[pymethods]
impl RustyInterp {
    #[new]
    fn new() -> Self { RustyInterp }

    /// Evaluate Rusty/Lisp code. Returns result as string (unquoted).
    fn eval(&self, code: &str) -> PyResult<String> {
        on_big_stack(|| {
            let env = make_env();
            run_code(code, &env, &Evaluator::new()).map(|v| print_repr(&v))
        }).map_err(pyo3::exceptions::PyRuntimeError::new_err)
    }

    /// Evaluate and return the Lisp display form (strings stay quoted).
    fn eval_repr(&self, code: &str) -> PyResult<String> {
        on_big_stack(|| {
            let env = make_env();
            run_code(code, &env, &Evaluator::new()).map(|v| format!("{}", v))
        }).map_err(pyo3::exceptions::PyRuntimeError::new_err)
    }

    /// Returns True if the code is syntactically valid.
    fn check(&self, code: &str) -> bool {
        on_big_stack(|| {
            let tokens = lexer::Lexer::new(code).tokenize();
            // It says "syntactically valid", so it has to mean it: unbalanced
            // parens used to pass here.
            match parser::Parser::new(tokens).parse_checked() {
                Ok(ast) => !ast.is_empty(),
                Err(_) => false,
            }
        })
    }

    fn __repr__(&self) -> &str { "<Rusty interpreter>" }
}

// ── Stateful session ──────────────────────────────────────────────────────

/// Stateful session. Definitions persist across eval() calls by replaying
/// history into a fresh env each time (an Rc-isolation choice, not a
/// correctness guarantee: side effects replay too, and a form whose replay
/// FAILS — e.g. a file op that only succeeds once — now surfaces as an
/// error naming the failing form instead of silently leaving a partial env).
#[pyclass]
pub struct RustySession {
    history: Vec<String>,
}

#[pymethods]
impl RustySession {
    #[new]
    fn new() -> Self { RustySession { history: Vec::new() } }

    /// Eval code, preserving all previous definitions.
    fn eval(&mut self, code: &str) -> PyResult<String> {
        let history = &self.history;
        let result = on_big_stack(|| {
            let env  = make_env();
            let eval = Evaluator::new();
            for (i, prev) in history.iter().enumerate() {
                if let Err(e) = run_code(prev, &env, &eval) {
                    return Err(format!(
                        "session history replay failed at form {} ({}): {}",
                        i + 1,
                        prev.chars().take(40).collect::<String>(),
                        e));
                }
            }
            run_code(code, &env, &eval).map(|v| print_repr(&v))
        });
        match result {
            Ok(s)  => { self.history.push(code.to_string()); Ok(s) }
            Err(e) => Err(pyo3::exceptions::PyRuntimeError::new_err(e)),
        }
    }

    /// Clear all session state.
    fn reset(&mut self) { self.history.clear(); }

    /// Number of expressions in history.
    fn history_len(&self) -> usize { self.history.len() }

    fn __repr__(&self) -> String {
        format!("<RustySession history={}>", self.history.len())
    }
}

// ── Module ────────────────────────────────────────────────────────────────

#[pymodule]
fn rusty(m: &Bound<'_, PyModule>) -> PyResult<()> {
    m.add_class::<RustyInterp>()?;
    m.add_class::<RustySession>()?;
    m.add_function(wrap_pyfunction!(eval_fn, m)?)?;
    Ok(())
}

/// Top-level rusty.eval("code") convenience function.
#[pyfunction]
#[pyo3(name = "eval")]
fn eval_fn(code: &str) -> PyResult<String> {
    on_big_stack(|| {
        let env = make_env();
        run_code(code, &env, &Evaluator::new()).map(|v| print_repr(&v))
    }).map_err(pyo3::exceptions::PyRuntimeError::new_err)
}
