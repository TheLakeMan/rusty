// Copyright (c) 2026 Nicholas Vermeulen
// SPDX-License-Identifier: AGPL-3.0-or-later

//! arena.rs — memory pooling for the evaluator (Phase 3.3, activated).
//!
//! This file used to hold a dormant mark/sweep arena sketch. That design
//! was a mismatch for Rusty's memory model and was replaced, not activated:
//! every `Value` is `Rc`-based, so reclamation already happens the moment a
//! refcount hits zero — a tracing collector has nothing to collect — and
//! the sketch's `mark()` had no value→slot mapping, so it could never know
//! which slots were live (see git history for the original).
//!
//! What the evaluator actually pays for is *allocation churn*, and that is
//! what this module pools: every function call and `let` builds an
//! `EnvFrame` around a hash map whose table is allocated and dropped
//! moments later. Dropped frames hand their cleared map (allocation and
//! capacity intact) back here, and frame construction takes one out again —
//! the table allocation is paid once and recycled, not once per call.
//!
//! Thread-local because `Value`/`Env` are `Rc`-based (single-threaded by
//! design). `try_with` everywhere: during thread teardown the pool may
//! already be destroyed while environments are still dropping.
//!
//! Shipped alongside two sibling churn fixes measured in the same pass
//! (docs/ROADMAP.md 3.3): `Expr::List` became `Rc<Vec<Expr>>` (cloning a
//! function body per call was a deep copy with a String allocation per
//! symbol; now it's a refcount bump) and frame maps use FxHash instead of
//! SipHash. Together: ~4× on call/let/actor-heavy workloads.

use crate::env::VarMap;
use std::cell::RefCell;

thread_local! {
    static FRAME_POOL: RefCell<Vec<VarMap>> = RefCell::new(Vec::new());
}

/// Keep at most this many maps; beyond it, dropped maps just deallocate.
const FRAME_POOL_CAP: usize = 1024;

/// Take a recycled (empty, capacity-preserving) frame map, or a fresh one.
pub fn take_map() -> VarMap {
    FRAME_POOL.try_with(|p| p.borrow_mut().pop()).ok().flatten().unwrap_or_default()
}

/// Return a frame's map to the pool. The caller must pass it *already
/// cleared*: clearing drops the contained values, which can recursively
/// drop other `EnvFrame`s that also borrow the pool.
pub fn recycle_map(m: VarMap) {
    debug_assert!(m.is_empty());
    let _ = FRAME_POOL.try_with(|p| {
        let mut pool = p.borrow_mut();
        if pool.len() < FRAME_POOL_CAP { pool.push(m); }
    });
}

// ── Small-frame vec pool (0.54.0 hybrid frames) ─────────────────────────
// Same discipline as the map pool, for the inline (String, Value) vecs
// that back `Slots::Small`: cleared before recycling, thread-local,
// capped. See env.rs `Slots` for why most frames never touch a map.

type SmallVec = Vec<(String, crate::env::Value)>;

thread_local! {
    static SMALL_POOL: RefCell<Vec<SmallVec>> = RefCell::new(Vec::new());
}

/// Take a recycled (empty, capacity-preserving) small vec, or a fresh one.
pub fn take_small() -> SmallVec {
    SMALL_POOL.try_with(|p| p.borrow_mut().pop()).ok().flatten().unwrap_or_default()
}

/// Return a small vec to the pool. Caller passes it *already cleared* —
/// clearing drops values, which can recursively drop other EnvFrames.
pub fn recycle_small(v: SmallVec) {
    debug_assert!(v.is_empty());
    let _ = SMALL_POOL.try_with(|p| {
        let mut pool = p.borrow_mut();
        if pool.len() < FRAME_POOL_CAP { pool.push(v); }
    });
}
