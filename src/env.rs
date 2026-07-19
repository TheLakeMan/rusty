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

/// The backing store of a list: element cells plus the exposure watermark
/// that makes O(1) `cons` sound (0.53.0). `floor` is the MINIMUM start any
/// LSlice on this buffer has ever had — monotonically decreasing — so every
/// slot below `floor` has never been visible to any view, live or dead, and
/// `cons` may claim slot `floor-1` in place even while the buffer is shared.
/// Cells are `UnsafeCell` (repr(transparent), so a cell range reads as
/// `&[Value]`) purely to make that one never-exposed-slot write legal; gap
/// slots hold `Nil` until claimed. Single-threaded by construction (`Rc`).
struct ListBuf {
    cells: Vec<std::cell::UnsafeCell<Value>>,
    floor: std::cell::Cell<usize>,
}

// Dropping a deeply *nested* list (a chain of single-element lists, or any
// list-of-list-of-... structure) would otherwise recurse on the native stack —
// each ListBuf drop dropping a Value::List whose ListBuf drop drops another —
// and overflow (an unrecoverable Rust abort) past ~150k depth. Dismantle
// iteratively through a heap work-list instead, so nesting depth costs heap,
// not stack. Only engaged when a cell actually holds a solely-owned nested list
// (the `Rc::try_unwrap` gate), so flat lists and shared tails pay nothing beyond
// the normal per-element drop.
impl Drop for ListBuf {
    fn drop(&mut self) {
        let mut pending: Vec<Value> = Vec::new();
        // Seed with this buffer's own cells, then walk owned nested buffers.
        for cell in self.cells.drain(..) {
            if let Value::List(ls) = cell.into_inner() {
                // try_unwrap succeeds only when we're the sole owner; a shared
                // buffer is left for its other owner to drop.
                if let Ok(mut buf) = Rc::try_unwrap(ls.data) {
                    // Take its cells before `buf` drops, so buf's Drop sees an
                    // empty Vec and does not recurse.
                    pending.extend(buf.cells.drain(..).map(|c| c.into_inner()));
                }
            }
        }
        while let Some(v) = pending.pop() {
            if let Value::List(ls) = v {
                if let Ok(mut buf) = Rc::try_unwrap(ls.data) {
                    pending.extend(buf.cells.drain(..).map(|c| c.into_inner()));
                }
            }
        }
    }
}

impl ListBuf {
    /// gap Nil-slots in front, then `head`, then `tail` — the layout the
    /// cons slow path allocates so subsequent conses are O(1) in-place.
    fn with_gap(gap: usize, head: Value, tail: &[Value]) -> LSlice {
        let mut cells = Vec::with_capacity(gap + 1 + tail.len());
        for _ in 0..gap { cells.push(std::cell::UnsafeCell::new(Value::Nil)); }
        cells.push(std::cell::UnsafeCell::new(head));
        for v in tail { cells.push(std::cell::UnsafeCell::new(v.clone())); }
        LSlice { data: Rc::new(ListBuf { cells, floor: std::cell::Cell::new(gap) }), start: gap }
    }
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
///
/// `cons` is amortized O(1) since 0.53.0: it claims the never-exposed slot
/// in front when `start == floor` (see `ListBuf` — the accumulate idiom
/// hits this every iteration, live clones of the tail included, because
/// the guard is on view ranges, not refcounts), and otherwise copies into
/// a fresh buffer with a proportional front gap so the NEXT cons is O(1).
/// Aliased tails (cons onto a cdr, two conses onto one list) fail the
/// guard and copy — value semantics are observably unchanged.
#[derive(Clone)]
pub struct LSlice {
    data:  Rc<ListBuf>,
    start: usize,
}

impl LSlice {
    pub fn new(vals: Vec<Value>) -> Self {
        let cells: Vec<std::cell::UnsafeCell<Value>> =
            vals.into_iter().map(std::cell::UnsafeCell::new).collect();
        LSlice { data: Rc::new(ListBuf { cells, floor: std::cell::Cell::new(0) }), start: 0 }
    }
    /// O(1) suffix: same buffer, offset advanced by n (n ≤ len; n == len
    /// gives the empty list). Backs cdr, member, and list-tail. Only ever
    /// RAISES the start, so `floor` is untouched.
    pub fn advance(&self, n: usize) -> LSlice {
        debug_assert!(n <= self.len(), "LSlice::advance past end");
        LSlice { data: self.data.clone(), start: self.start + n }
    }
    /// O(1) cdr: same buffer, next offset. Caller guarantees non-empty.
    pub fn tail(&self) -> LSlice {
        debug_assert!(!self.is_empty(), "LSlice::tail of empty list");
        self.advance(1)
    }
    /// Amortized-O(1) prepend. Fast path: `start == floor && start > 0`
    /// means slot `start-1` was never inside any view — claim it in place.
    /// Slow path: copy into a fresh buffer with a front gap proportional
    /// to the length (Vec-doubling amortization, leftward).
    pub fn prepend(&self, head: Value) -> LSlice {
        if self.start > 0 && self.start == self.data.floor.get() {
            // Sound: no LSlice (live or dead) ever exposed a start below
            // `floor`, so no `&[Value]` view can include slot start-1; the
            // old value there is an unclaimed gap Nil.
            unsafe { *self.data.cells[self.start - 1].get() = head; }
            self.data.floor.set(self.start - 1);
            return LSlice { data: self.data.clone(), start: self.start - 1 };
        }
        ListBuf::with_gap((self.len() + 1).max(4), head, self)
    }
}

impl std::ops::Deref for LSlice {
    type Target = [Value];
    #[inline]
    fn deref(&self) -> &[Value] {
        // UnsafeCell<Value> is repr(transparent); slots at start.. are never
        // written after exposure (prepend only touches slots below floor).
        unsafe {
            std::slice::from_raw_parts(
                self.data.cells.as_ptr().add(self.start) as *const Value,
                self.data.cells.len() - self.start,
            )
        }
    }
}

impl std::fmt::Debug for LSlice {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        (**self).fmt(f)
    }
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

// Display recursion guard — see the List arm below and interp::print_repr.
const MAX_DISPLAY_DEPTH: usize = 4_000;
thread_local! {
    static DISPLAY_DEPTH: std::cell::Cell<usize> = const { std::cell::Cell::new(0) };
}
struct DisplayDepthGuard;
impl Drop for DisplayDepthGuard {
    fn drop(&mut self) { DISPLAY_DEPTH.with(|d| d.set(d.get().saturating_sub(1))); }
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
                // Nested lists recurse here on the native stack; cap the depth
                // so a pathological structure elides instead of overflowing
                // (a Rust stack overflow aborts and can't be caught). Mirrors
                // interp::print_repr's guard.
                if DISPLAY_DEPTH.with(|d| d.get()) >= MAX_DISPLAY_DEPTH {
                    return write!(f, "(...)");
                }
                DISPLAY_DEPTH.with(|d| d.set(d.get() + 1));
                let _dec = DisplayDepthGuard;
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

/// Frame storage (0.54.0 hybrid): almost every frame binds 1–3 names
/// (lambda params, let bindings), where a linear scan over an inline vec
/// beats hashing (measured 1.7× on the frame-op mix). A frame starts
/// `Small` (insertion-ordered, pooled vec) and promotes to the pooled
/// `Map` the moment it exceeds SMALL_MAX names — the global frame promotes
/// almost immediately, so the walk order cold paths see there (checkpoint,
/// command-registry, LSP completion) is the same hash order as before.
#[derive(Debug)]
pub enum Slots {
    Small(Vec<(String, Value)>),
    Map(VarMap),
    // Root frame storage (lexical addressing): name → index into an
    // append-only value table. Indices are stable for the life of the env
    // (rebinding overwrites vals[idx]; names are never removed), which is
    // what lets a GlobalRef cache its index. Iteration goes through the
    // name map so cold paths (checkpoint, command-registry) see the same
    // FxHashMap order they always did.
    Root { map: rustc_hash::FxHashMap<String, u32>, vals: Vec<Value> },
}

/// Promotion threshold: params/let bindings rarely exceed this; a body
/// with many `define`s promotes once and stays a map.
const SMALL_MAX: usize = 8;

#[derive(Debug)]
pub struct EnvFrame {
    slots: Slots,
    pub parent: Option<Env>,
    // Set when a runtime `define` (or defmacro/deftool/defrust) injects a
    // NEW name into this frame after construction — i.e. the frame's name
    // set no longer matches what the resolver could see statically. Ref
    // lookups check this on every intermediate frame and fall back to the
    // full name walk, which is what makes lexical addressing sound under
    // `eval`-in-current-env, macro-expanded defines, and internal defines.
    dirty: bool,
}

// Frame storage is pooled (Phase 3.3 memory pooling — see src/arena.rs):
// construction takes a recycled small vec, promotion takes a recycled map,
// Drop hands the cleared container back.
impl Drop for EnvFrame {
    fn drop(&mut self) {
        // Clear BEFORE touching the pool: dropping the contained values can
        // recursively drop other EnvFrames, which also borrow the pool.
        match std::mem::replace(&mut self.slots, Slots::Small(Vec::new())) {
            Slots::Small(mut v) => {
                if v.capacity() == 0 { return; }
                v.clear();
                crate::arena::recycle_small(v);
            }
            Slots::Map(mut m) => {
                if m.capacity() == 0 { return; }
                m.clear();
                crate::arena::recycle_map(m);
            }
            // One per env, never pooled — drop normally.
            Slots::Root { .. } => {}
        }
    }
}

impl EnvFrame {
    pub fn new(parent: Option<Env>) -> Env {
        Rc::new(RefCell::new(EnvFrame { slots: Slots::Small(crate::arena::take_small()), parent, dirty: false }))
    }

    /// Root-frame constructor (lexical addressing): stable-index storage so
    /// GlobalRefs can cache a slot. Every environment root (make_env) goes
    /// through here; child frames never do.
    pub fn new_root() -> Env {
        Rc::new(RefCell::new(EnvFrame {
            slots: Slots::Root { map: rustc_hash::FxHashMap::default(), vals: Vec::new() },
            parent: None,
            dirty: false,
        }))
    }

    /// Local-frame lookup+clone (no parent walk).
    #[inline]
    fn get_here(&self, name: &str) -> Option<Value> {
        match &self.slots {
            Slots::Small(v) => v.iter().find(|(k, _)| k == name).map(|(_, val)| val.clone()),
            Slots::Map(m) => m.get(name).cloned(),
            Slots::Root { map, vals } => map.get(name).map(|i| vals[*i as usize].clone()),
        }
    }

    #[inline]
    fn has_here(&self, name: &str) -> bool {
        match &self.slots {
            Slots::Small(v) => v.iter().any(|(k, _)| k == name),
            Slots::Map(m) => m.contains_key(name),
            Slots::Root { map, .. } => map.contains_key(name),
        }
    }

    /// Bind or rebind `name` in THIS frame, promoting Small → Map past
    /// SMALL_MAX distinct names.
    fn insert_here(&mut self, name: String, value: Value) {
        match &mut self.slots {
            Slots::Small(v) => {
                if let Some(slot) = v.iter_mut().find(|(k, _)| *k == name) {
                    slot.1 = value;
                    return;
                }
                if v.len() < SMALL_MAX {
                    v.push((name, value));
                    return;
                }
                let mut m = crate::arena::take_map();
                for (k, val) in v.drain(..) { m.insert(k, val); }
                m.insert(name, value);
                let old = std::mem::replace(&mut self.slots, Slots::Map(m));
                if let Slots::Small(sv) = old { crate::arena::recycle_small(sv); }
            }
            Slots::Map(m) => { m.insert(name, value); }
            Slots::Root { map, vals } => {
                match map.get(&name) {
                    Some(i) => vals[*i as usize] = value,
                    None => {
                        vals.push(value);
                        map.insert(name, (vals.len() - 1) as u32);
                    }
                }
            }
        }
    }

    /// Visit every binding in THIS frame (cold-path API: checkpoint,
    /// command-registry, LSP completion, did-you-mean).
    pub fn for_each_local<F: FnMut(&String, &Value)>(&self, mut f: F) {
        match &self.slots {
            Slots::Small(v) => { for (k, val) in v { f(k, val); } }
            Slots::Map(m) => { for (k, val) in m { f(k, val); } }
            // Iterate via the name map so hash-order-dependent cold paths
            // (checkpoint, command-registry) see the same order as the old
            // VarMap root.
            Slots::Root { map, vals } => { for (k, i) in map { f(k, &vals[*i as usize]); } }
        }
    }

    /// Snapshot of this frame's bindings as a plain map (cold paths that
    /// used to clone `.vars`).
    pub fn vars_snapshot(&self) -> VarMap {
        let mut out = VarMap::default();
        self.for_each_local(|k, v| { out.insert(k.clone(), v.clone()); });
        out
    }

    pub fn get(env: &Env, name: &str) -> Option<Value> {
        let frame = env.borrow();
        if let Some(v) = frame.get_here(name) { return Some(v); }
        frame.parent.as_ref().and_then(|p| EnvFrame::get(p, name))
    }

    /// Slot-resolved local lookup (lexical addressing): hop `depth` parents,
    /// read the slot directly. Returns None — caller falls back to the full
    /// name walk — when any intermediate frame is dirty (a runtime define
    /// may have shadowed the binding), the target frame promoted past Small,
    /// or the slot's name doesn't verify (resolver model drift; the verify
    /// makes that a slowdown, never a wrong answer).
    pub fn get_slot(env: &Env, depth: u16, slot: u16, name: &str) -> Option<Value> {
        let mut cur = env.clone();
        for _ in 0..depth {
            let next = {
                let f = cur.borrow();
                if f.dirty { return None; }
                f.parent.clone()?
            };
            cur = next;
        }
        let f = cur.borrow();
        match &f.slots {
            Slots::Small(v) => {
                let (k, val) = v.get(slot as usize)?;
                if k == name { Some(val.clone()) } else { None }
            }
            _ => None,
        }
    }

    /// Root-resolved global lookup (lexical addressing): walk to the root,
    /// scanning by name only in dirty frames (a runtime define may have
    /// created a closer binding). At a Root frame the index cache answers
    /// without hashing; first hit fills it.
    pub fn get_global(env: &Env, name: &str, idx: &std::cell::Cell<u32>) -> Option<Value> {
        let mut cur = env.clone();
        loop {
            let next = {
                let f = cur.borrow();
                match &f.parent {
                    Some(p) => {
                        if f.dirty {
                            if let Some(v) = f.get_here(name) { return Some(v); }
                        }
                        p.clone()
                    }
                    None => {
                        return match &f.slots {
                            Slots::Root { map, vals } => {
                                let i = idx.get();
                                if i != u32::MAX {
                                    Some(vals[i as usize].clone())
                                } else {
                                    let i = *map.get(name)?;
                                    idx.set(i);
                                    Some(vals[i as usize].clone())
                                }
                            }
                            _ => f.get_here(name),
                        };
                    }
                }
            };
            cur = next;
        }
    }

    pub fn set(env: &Env, name: String, value: Value) {
        env.borrow_mut().insert_here(name, value);
    }

    /// Bind via a runtime `define` (or defmacro/deftool/defrust). Unlike
    /// `set` (construction-time binding), inserting a NEW name into a
    /// non-root frame marks it dirty so resolved refs stop trusting the
    /// frame's static name set.
    pub fn define(env: &Env, name: String, value: Value) {
        let mut f = env.borrow_mut();
        if f.parent.is_some() && !f.has_here(&name) {
            f.dirty = true;
        }
        f.insert_here(name, value);
    }

    pub fn set_existing(env: &Env, name: &str, value: Value) -> bool {
        let mut frame = env.borrow_mut();
        if frame.has_here(name) {
            frame.insert_here(name.to_string(), value);
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
        Value::List(rc) => Value::List(rc.prepend(head)),
        // A build starting from '() gets a small runway too.
        Value::Nil => Value::List(ListBuf::with_gap(4, head, &[])),
        other      => list(vec![head, other]),
    }
}
