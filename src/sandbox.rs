// Copyright (c) 2026 Nicholas Vermeulen
// SPDX-License-Identifier: AGPL-3.0-or-later

//! sandbox.rs — opt-in, one-way filesystem + subprocess confinement.
//!
//! The interpreter's file builtins all FOLLOW symlinks and take a raw path, so
//! a string-prefix "under the box?" guard written in Lisp is defeated by a
//! symlink inside the box pointing out (this is documented, and was the escape
//! reproduced in the security review). This module closes that at the builtin
//! funnel, in Rust, for EVERY file/subprocess builtin at once:
//!
//! * `enable(root)` latches a canonicalized sandbox root. It is a ONE-WAY
//!   latch — once set, it can only be replaced by a *sub-path* of itself, never
//!   widened or cleared. So code running under a sandbox cannot escape by
//!   calling `sandbox-enable!` again with `/` or the parent.
//! * Reads/stats must canonicalize (symlinks + `..` fully resolved) to a
//!   location under the root, or they are refused — this is what defeats the
//!   symlink-out-of-box escape that a path-prefix check misses.
//! * Writes/creates/deletes require the parent to canonicalize under the root
//!   AND refuse a symlink final component (covering both live and dangling
//!   links that point out of the box).
//! * `shell` / `proc-eval` / `proc-pmap` / `defrust` / `graph-compile` are
//!   refused outright while active — a subprocess (or a compiled `.so`) runs
//!   arbitrary code this userspace guard cannot confine.
//!
//! HONEST SCOPE: this closes `..` traversal and symlink-at-check-time escapes,
//! and disables the subprocess vectors. It is NOT kernel confinement — a
//! sub-second TOCTOU where an *intermediate* path component is swapped between
//! the canonicalize check and the kernel open remains a real residual, closable
//! only with `openat2(RESOLVE_BENEATH)` / Landlock (a crate/OS dependency, an
//! owner decision). The claim is "no path escapes the root under a
//! single-threaded interpreter", never "unbreakable".

use std::cell::RefCell;
use std::path::{Path, PathBuf};

thread_local! {
    static ROOT: RefCell<Option<PathBuf>> = const { RefCell::new(None) };
}

fn deny(who: &str, path: &str, root: &Path) -> String {
    format!("{}: refused — path '{}' escapes the sandbox root {}",
            who, path, root.display())
}

/// Enable, or narrow, the sandbox. One-way latch (see module docs).
pub fn enable(root: &str) -> Result<PathBuf, String> {
    let canon = std::fs::canonicalize(root)
        .map_err(|e| format!("sandbox: cannot resolve root '{}': {}", root, e))?;
    ROOT.with(|r| {
        let mut cur = r.borrow_mut();
        if let Some(existing) = cur.as_ref() {
            if !canon.starts_with(existing) {
                return Err(format!(
                    "sandbox: already confined to {} — can only narrow, not widen to {}",
                    existing.display(), canon.display()));
            }
        }
        *cur = Some(canon.clone());
        Ok(canon)
    })
}

pub fn is_active() -> bool { ROOT.with(|r| r.borrow().is_some()) }
pub fn root() -> Option<PathBuf> { ROOT.with(|r| r.borrow().clone()) }

/// A path to be read/statted must resolve (symlinks + `..`) under the root.
pub fn check_read(path: &str, who: &str) -> Result<(), String> {
    ROOT.with(|r| {
        let cur = r.borrow();
        let root = match cur.as_ref() { None => return Ok(()), Some(p) => p };
        // Only refuse a path that actually RESOLVES to something out of the box.
        // If it can't be canonicalized (missing), the underlying op will fail to
        // find any out-of-box content anyway, so let it report its normal error.
        match std::fs::canonicalize(path) {
            Ok(canon) if canon.starts_with(root) => Ok(()),
            Ok(_) => Err(deny(who, path, root)),
            Err(_) => Ok(()),
        }
    })
}

/// A path to be written/created/deleted: its parent must resolve under the
/// root, and the final component must NOT be a symlink (which would follow out
/// of the box, live or dangling).
pub fn check_write(path: &str, who: &str) -> Result<(), String> {
    ROOT.with(|r| {
        let cur = r.borrow();
        let root = match cur.as_ref() { None => return Ok(()), Some(p) => p };
        let p = Path::new(path);
        if let Ok(md) = std::fs::symlink_metadata(p) {
            if md.file_type().is_symlink() { return Err(deny(who, path, root)); }
        }
        let parent = p.parent()
            .filter(|s| !s.as_os_str().is_empty())
            .map(Path::to_path_buf)
            .unwrap_or_else(|| PathBuf::from("."));
        let canon_parent = std::fs::canonicalize(&parent).map_err(|_| deny(who, path, root))?;
        if canon_parent.starts_with(root) { Ok(()) } else { Err(deny(who, path, root)) }
    })
}

/// A no-follow stat (`file-symlink?`/`file-hardlink?`/`file-realpath`): the
/// PARENT must resolve under the root, but the leaf itself may be a symlink —
/// reporting on a symlink leaf inside the box is exactly these guards' job.
pub fn check_stat(path: &str, who: &str) -> Result<(), String> {
    ROOT.with(|r| {
        let cur = r.borrow();
        let root = match cur.as_ref() { None => return Ok(()), Some(p) => p };
        let parent = Path::new(path).parent()
            .filter(|s| !s.as_os_str().is_empty())
            .map(Path::to_path_buf)
            .unwrap_or_else(|| PathBuf::from("."));
        match std::fs::canonicalize(&parent) {
            Ok(cp) if cp.starts_with(root) => Ok(()),
            Ok(_) => Err(deny(who, path, root)),
            Err(_) => Ok(()),
        }
    })
}

/// Subprocess / native-compile vectors are refused outright while sandboxed.
pub fn require_no_subprocess(who: &str) -> Result<(), String> {
    if is_active() {
        Err(format!("{}: refused — subprocess execution is disabled under an active sandbox", who))
    } else {
        Ok(())
    }
}
