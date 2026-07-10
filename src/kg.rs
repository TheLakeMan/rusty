// Copyright (c) 2026 Nicholas Vermeulen
// SPDX-License-Identifier: AGPL-3.0-or-later

//! kg.rs — a self-contained knowledge graph (ROADMAP 1.3, resolved the
//! house way: RDF is a *format*, not a database, so Rusty gets a native
//! triple store with N-Triples import/export instead of a binding to
//! someone else's system. Zero new dependencies.
//!
//! - Store: thread-local (the runtime is single-threaded by design),
//!   deduplicated, with S/P/O hash indexes so pattern lookups don't scan.
//! - Query: conjunctive patterns with `?var` symbols, solved left to
//!   right with binding propagation; each pattern uses the best index
//!   available after substitution.
//! - Interop: N-Triples (line-based, trivially parseable — any RDF tool
//!   can exchange data with Rusty). Symbols export as `<urn:rusty:name>`,
//!   strings as literals, numbers as xsd:double literals; foreign IRIs
//!   import as symbols named by the IRI text.

use crate::env::{list, Value};
use std::cell::RefCell;
use std::collections::HashMap;

#[derive(Clone)]
struct Triple(Value, Value, Value);

#[derive(Default)]
struct Store {
    triples: Vec<Triple>,
    // display-string keys: Value isn't Hash, but Display is injective
    // across the data types we store (strings print quoted, symbols bare)
    s_idx: HashMap<String, Vec<usize>>,
    p_idx: HashMap<String, Vec<usize>>,
    o_idx: HashMap<String, Vec<usize>>,
    spo:   HashMap<String, ()>, // dedupe
}

thread_local! {
    static KG: RefCell<Store> = RefCell::new(Store::default());
}

fn key(v: &Value) -> String { format!("{}", v) }
fn triple_key(s: &Value, p: &Value, o: &Value) -> String {
    format!("{} {} {}", key(s), key(p), key(o))
}

pub fn clear() {
    KG.with(|kg| *kg.borrow_mut() = Store::default());
}

pub fn add(s: Value, p: Value, o: Value) -> bool {
    KG.with(|kg| {
        let mut st = kg.borrow_mut();
        let tk = triple_key(&s, &p, &o);
        if st.spo.contains_key(&tk) { return false; }
        let i = st.triples.len();
        st.s_idx.entry(key(&s)).or_default().push(i);
        st.p_idx.entry(key(&p)).or_default().push(i);
        st.o_idx.entry(key(&o)).or_default().push(i);
        st.spo.insert(tk, ());
        st.triples.push(Triple(s, p, o));
        true
    })
}

pub fn count() -> usize {
    KG.with(|kg| kg.borrow().triples.len())
}

pub fn triples() -> Value {
    KG.with(|kg| list(kg.borrow().triples.iter()
        .map(|Triple(s, p, o)| list(vec![s.clone(), p.clone(), o.clone()]))
        .collect()))
}

fn is_var(v: &Value) -> bool {
    matches!(v, Value::Symbol(s) if s.starts_with('?'))
}

fn matches(pat: &Value, val: &Value, binds: &mut Vec<(String, Value)>) -> bool {
    if let Value::Symbol(name) = pat {
        if name.starts_with('?') {
            if let Some((_, bound)) = binds.iter().find(|(n, _)| n == name) {
                return crate::interp::value_equal(bound, val);
            }
            binds.push((name.clone(), val.clone()));
            return true;
        }
    }
    crate::interp::value_equal(pat, val)
}

/// Solve one pattern under current bindings; call `emit` per solution.
fn solve(patterns: &[(Value, Value, Value)],
         binds: &Vec<(String, Value)>,
         out: &mut Vec<Vec<(String, Value)>>) {
    let Some(((ps, pp, po), rest)) = patterns.split_first() else {
        out.push(binds.clone());
        return;
    };
    // substitute already-bound vars, then pick the narrowest index
    let subst = |v: &Value| -> Value {
        if let Value::Symbol(n) = v {
            if n.starts_with('?') {
                if let Some((_, b)) = binds.iter().find(|(bn, _)| bn == n) {
                    return b.clone();
                }
            }
        }
        v.clone()
    };
    let (s, p, o) = (subst(ps), subst(pp), subst(po));
    KG.with(|kg| {
        let st = kg.borrow();
        let candidates: Vec<usize> = if !is_var(&s) {
            st.s_idx.get(&key(&s)).cloned().unwrap_or_default()
        } else if !is_var(&o) {
            st.o_idx.get(&key(&o)).cloned().unwrap_or_default()
        } else if !is_var(&p) {
            st.p_idx.get(&key(&p)).cloned().unwrap_or_default()
        } else {
            (0..st.triples.len()).collect()
        };
        for i in candidates {
            let Triple(ts, tp, to) = &st.triples[i];
            let mut b2 = binds.clone();
            if matches(&s, ts, &mut b2) && matches(&p, tp, &mut b2) && matches(&o, to, &mut b2) {
                solve(rest, &b2, out);
            }
        }
    });
}

/// (kg-query '((s p o) ...)) → list of binding alists ((?var value) ...)
pub fn query(patterns_val: &Value) -> Result<Value, String> {
    let Value::List(pats) = patterns_val else {
        return Err("kg-query: patterns must be a list of (s p o) triples".into());
    };
    let mut patterns = Vec::with_capacity(pats.len());
    for p in pats.iter() {
        match p {
            Value::List(t) if t.len() == 3 =>
                patterns.push((t[0].clone(), t[1].clone(), t[2].clone())),
            _ => return Err("kg-query: each pattern must be (subject predicate object)".into()),
        }
    }
    let mut out = Vec::new();
    solve(&patterns, &Vec::new(), &mut out);
    Ok(list(out.into_iter().map(|binds| {
        list(binds.into_iter().map(|(n, v)| {
            list(vec![Value::Symbol(n), v])
        }).collect())
    }).collect()))
}

// ── N-Triples interop ─────────────────────────────────────────────────────

fn escape_literal(s: &str) -> String {
    s.replace('\\', "\\\\").replace('"', "\\\"").replace('\n', "\\n")
}
fn unescape_literal(s: &str) -> String {
    s.replace("\\n", "\n").replace("\\\"", "\"").replace("\\\\", "\\")
}

fn to_nt(v: &Value) -> Result<String, String> {
    match v {
        Value::Symbol(s) if s.contains(':') && !s.starts_with('?') =>
            Ok(format!("<{}>", s)),                       // already IRI-shaped
        Value::Symbol(s) => Ok(format!("<urn:rusty:{}>", s)),
        Value::String(s) => Ok(format!("\"{}\"", escape_literal(s))),
        Value::Number(n) => Ok(format!(
            "\"{}\"^^<http://www.w3.org/2001/XMLSchema#double>", n)),
        other => Err(format!("kg-save-ntriples: {} cannot map to N-Triples", other)),
    }
}

fn from_nt(tok: &str) -> Result<Value, String> {
    if let Some(iri) = tok.strip_prefix('<').and_then(|t| t.strip_suffix('>')) {
        return Ok(match iri.strip_prefix("urn:rusty:") {
            Some(name) => Value::Symbol(name.to_string()),
            None => Value::Symbol(iri.to_string()),
        });
    }
    if tok.starts_with('"') {
        // "literal" or "literal"^^<type>
        let end = tok.rfind('"').ok_or("kg-load-ntriples: bad literal")?;
        let body = unescape_literal(&tok[1..end]);
        let suffix = &tok[end + 1..];
        if suffix.contains("XMLSchema#double") || suffix.contains("XMLSchema#integer")
            || suffix.contains("XMLSchema#decimal") {
            return body.parse::<f64>().map(Value::Number)
                .map_err(|_| format!("kg-load-ntriples: bad numeric literal {}", body));
        }
        return Ok(Value::String(body));
    }
    if let Some(b) = tok.strip_prefix("_:") {
        return Ok(Value::Symbol(format!("_:{}", b)));
    }
    Err(format!("kg-load-ntriples: cannot parse term {}", tok))
}

/// Split one N-Triples line into its three terms (quote- and IRI-aware).
fn split_terms(line: &str) -> Vec<String> {
    let mut terms = Vec::new();
    let mut cur = String::new();
    let mut in_str = false;
    let mut esc = false;
    for c in line.chars() {
        if in_str {
            cur.push(c);
            if esc { esc = false; }
            else if c == '\\' { esc = true; }
            else if c == '"' { in_str = false; }
        } else if c == '"' {
            cur.push(c); in_str = true;
        } else if c.is_whitespace() {
            if !cur.is_empty() { terms.push(std::mem::take(&mut cur)); }
        } else {
            cur.push(c);
        }
    }
    if !cur.is_empty() { terms.push(cur); }
    terms
}

pub fn save_ntriples(path: &str) -> Result<usize, String> {
    let mut out = String::new();
    let n = KG.with(|kg| -> Result<usize, String> {
        let st = kg.borrow();
        for Triple(s, p, o) in &st.triples {
            out.push_str(&format!("{} {} {} .\n", to_nt(s)?, to_nt(p)?, to_nt(o)?));
        }
        Ok(st.triples.len())
    })?;
    std::fs::write(path, out).map_err(|e| format!("kg-save-ntriples: {}: {}", path, e))?;
    Ok(n)
}

pub fn load_ntriples(path: &str) -> Result<usize, String> {
    let text = std::fs::read_to_string(path)
        .map_err(|e| format!("kg-load-ntriples: {}: {}", path, e))?;
    let mut added = 0usize;
    for (lineno, line) in text.lines().enumerate() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') { continue; }
        let line = line.strip_suffix('.').unwrap_or(line).trim();
        let terms = split_terms(line);
        if terms.len() != 3 {
            return Err(format!("kg-load-ntriples: line {}: expected 3 terms, got {}",
                               lineno + 1, terms.len()));
        }
        if add(from_nt(&terms[0])?, from_nt(&terms[1])?, from_nt(&terms[2])?) {
            added += 1;
        }
    }
    Ok(added)
}
