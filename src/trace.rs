//! trace.rs — Rusty's own lightweight execution-trace format (Phase 3.2).
//!
//! Same philosophy as `eval::macro_profile`, generalized: a thread-local,
//! off-by-default event log around agent/tool/LLM/shell execution. No OTel
//! collector, no external dependency — `(trace-report)` returns plain Lisp
//! data (pure data, so it `save-model`s and `json-encode`s as-is), and
//! whoever consumes it can export to OpenTelemetry or anything else.
//!
//! Event kinds recorded by the interpreter: `tool-call` (with duration, via
//! the `tool-call` form or `apply`), `tool-enter` (no duration — the
//! first-class call path is a TCO `continue`, so its end isn't observable
//! without breaking tail calls), `llm` (duration + prompt/response sizes),
//! `shell` (duration + command), `react-step`. Lisp code can add its own
//! via the `trace-event` builtin — std.lisp's actor scheduler logs `send`
//! and `agent-handle` events that way.

use std::cell::{Cell, RefCell};
use std::time::Instant;
use crate::env::{list, Value};

const MAX_EVENTS: usize = 100_000;

pub struct Event {
    pub seq: u64,
    pub t_micros: u64,       // since trace-on
    pub kind: &'static str,  // interpreter-side kinds are static;
    pub kind_dyn: Option<String>, // trace-event supplies its own
    pub name: String,
    pub dur_micros: Option<u64>,
    pub data: Option<String>,
}

thread_local! {
    static ENABLED: Cell<bool> = Cell::new(false);
    static EPOCH:   RefCell<Option<Instant>> = RefCell::new(None);
    static EVENTS:  RefCell<Vec<Event>> = RefCell::new(Vec::new());
    static SEQ:     Cell<u64> = Cell::new(0);
    static DROPPED: Cell<u64> = Cell::new(0);
}

pub fn enabled() -> bool {
    ENABLED.with(|e| e.get())
}

pub fn set_enabled(on: bool) {
    ENABLED.with(|e| e.set(on));
    if on {
        EPOCH.with(|t| *t.borrow_mut() = Some(Instant::now()));
    }
}

pub fn clear() {
    EVENTS.with(|ev| ev.borrow_mut().clear());
    SEQ.with(|s| s.set(0));
    DROPPED.with(|d| d.set(0));
    EPOCH.with(|t| *t.borrow_mut() = Some(Instant::now()));
}

fn now_micros() -> u64 {
    EPOCH.with(|t| t.borrow().map(|e| e.elapsed().as_micros() as u64).unwrap_or(0))
}

/// Timestamp for bracketing a call: capture before, pass to `record_since`.
pub fn start() -> Option<Instant> {
    if enabled() { Some(Instant::now()) } else { None }
}

pub fn record(kind: &'static str, name: &str, dur_micros: Option<u64>, data: Option<String>) {
    if !enabled() { return; }
    push(Event {
        seq: 0, t_micros: now_micros(), kind, kind_dyn: None,
        name: name.to_string(), dur_micros, data,
    });
}

/// Record with duration measured from a `start()` timestamp (no-op if
/// tracing was off at start time).
pub fn record_since(kind: &'static str, name: &str, t0: Option<Instant>, data: Option<String>) {
    if let Some(t0) = t0 {
        if enabled() {
            let dur = t0.elapsed().as_micros() as u64;
            record(kind, name, Some(dur), data);
        }
    }
}

/// Lisp-side events via the `trace-event` builtin.
pub fn record_dyn(kind: String, name: String, data: Option<String>) {
    if !enabled() { return; }
    push(Event {
        seq: 0, t_micros: now_micros(), kind: "", kind_dyn: Some(kind),
        name, dur_micros: None, data,
    });
}

fn push(mut ev: Event) {
    EVENTS.with(|events| {
        let mut events = events.borrow_mut();
        if events.len() >= MAX_EVENTS {
            DROPPED.with(|d| d.set(d.get() + 1));
            return;
        }
        let seq = SEQ.with(|s| { let n = s.get(); s.set(n + 1); n });
        ev.seq = seq;
        events.push(ev);
    });
}

/// `(trace-report)` → list of `(seq t-micros kind name dur-micros data)`,
/// oldest first; `dur-micros`/`data` are `()` when absent. Pure data.
pub fn report() -> Value {
    EVENTS.with(|events| {
        let rows: Vec<Value> = events.borrow().iter().map(|e| {
            let kind = e.kind_dyn.clone().unwrap_or_else(|| e.kind.to_string());
            list(vec![
                Value::Number(e.seq as f64),
                Value::Number(e.t_micros as f64),
                Value::Symbol(kind),
                Value::Symbol(e.name.clone()),
                e.dur_micros.map(|d| Value::Number(d as f64)).unwrap_or(Value::Nil),
                e.data.clone().map(Value::String).unwrap_or(Value::Nil),
            ])
        }).collect();
        list(rows)
    })
}

pub fn dropped() -> u64 {
    DROPPED.with(|d| d.get())
}
