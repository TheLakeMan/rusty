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
mod env;
mod eval;
mod interp;
mod arena;
mod rust_jit;
mod graph_ir;
mod type_check;
mod effect_check;

use eval::Evaluator;
use interp::{make_env, run_code, print_repr};

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
        let env = make_env();
        match run_code(code, &env, &Evaluator::new()) {
            Ok(v)  => Ok(print_repr(&v)),
            Err(e) => Err(pyo3::exceptions::PyRuntimeError::new_err(e)),
        }
    }

    /// Evaluate and return the Lisp display form (strings stay quoted).
    fn eval_repr(&self, code: &str) -> PyResult<String> {
        let env = make_env();
        match run_code(code, &env, &Evaluator::new()) {
            Ok(v)  => Ok(format!("{}", v)),
            Err(e) => Err(pyo3::exceptions::PyRuntimeError::new_err(e)),
        }
    }

    /// Returns True if the code is syntactically valid.
    fn check(&self, code: &str) -> bool {
        let tokens = lexer::Lexer::new(code).tokenize();
        !parser::Parser::new(tokens).parse().is_empty()
    }

    fn __repr__(&self) -> &str { "<Rusty interpreter>" }
}

// ── Stateful session ──────────────────────────────────────────────────────

/// Stateful session. Definitions persist across eval() calls by replaying
/// history into a fresh env each time (safe, no Rc across threads).
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
        let env  = make_env();
        let eval = Evaluator::new();
        for prev in &self.history {
            let _ = run_code(prev, &env, &eval);
        }
        match run_code(code, &env, &eval) {
            Ok(v) => {
                self.history.push(code.to_string());
                Ok(print_repr(&v))
            }
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
    let env = make_env();
    match run_code(code, &env, &Evaluator::new()) {
        Ok(v)  => Ok(print_repr(&v)),
        Err(e) => Err(pyo3::exceptions::PyRuntimeError::new_err(e)),
    }
}
