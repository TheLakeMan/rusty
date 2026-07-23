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
//! KERNEL LAYER (Linux >=5.13, owner crate-decision 2026-07-23): on top of the
//! userspace funnel above, `enable()` also applies a **Landlock** ruleset that
//! confines this thread (and its children) to read/write ONLY beneath the root,
//! then `restrict_self()`s — a one-way, kernel-enforced latch that mirrors the
//! userspace one. This is DEFENSE IN DEPTH: because the kernel checks EVERY
//! `open()`, it closes the two residuals the userspace guard alone couldn't —
//! (1) the check-vs-open TOCTOU (an intermediate component swapped between our
//! `canonicalize` and the kernel `open`), and (2) a *forgotten* guard on a
//! future file builtin. It is BEST-EFFORT: on a kernel without Landlock (or a
//! non-Linux build) it is a silent no-op, so it can only ever HARDEN, never
//! weaken, the userspace floor.
//!
//! HONEST SCOPE: the userspace latch is the guaranteed floor on every platform;
//! the Landlock layer adds kernel enforcement only where it is available, and
//! never claims to be present when it is not (verify with the manual probe
//! `benchmarks/sandbox_landlock_probe.sh`, not a golden — Landlock availability
//! is kernel-dependent, so it can't be a portable expected-output row). The
//! claim is "no path escapes the root; on a Landlock-capable kernel the kernel
//! enforces it too", never "unbreakable". CONSEQUENCE of real kernel
//! confinement: while sandboxed, the process may open ONLY files beneath the
//! root — so anything that reads outside it (e.g. `llm`'s DNS resolver touching
//! `/etc/resolv.conf`) will fail. That is the confinement working as intended,
//! not a bug; don't sandbox a run that needs the network.

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
        // Kernel layer: best-effort Landlock confinement to `canon`. The userspace
        // latch above is the guaranteed floor; this only hardens it, so a failure
        // (old kernel, Landlock off, non-Linux) is a silent no-op — never fatal.
        // Applied AFTER the userspace latch is set so the two can't disagree, and
        // on every narrow too (Landlock rulesets stack by intersection → narrower).
        apply_kernel_confinement(&canon);
        Ok(canon)
    })
}

/// Apply a Landlock ruleset confining this thread to read/write beneath `root`,
/// then `restrict_self`. Best-effort and infallible from the caller's view:
/// swallows every error so the userspace floor is never weakened by a kernel that
/// can't (or won't) enforce this. See the module docs' KERNEL LAYER note.
#[cfg(target_os = "linux")]
fn apply_kernel_confinement(root: &Path) {
    use landlock::{
        Access, AccessFs, CompatLevel, Compatible, PathBeneath, PathFd, Ruleset,
        RulesetAttr, RulesetCreatedAttr, ABI,
    };
    // Request the widest access set the crate knows; BestEffort downgrades the
    // handled rights to whatever THIS kernel actually supports (or to nothing on a
    // kernel with no Landlock at all — a clean no-op, not an error).
    let abi = ABI::V5;
    let all = AccessFs::from_all(abi);
    let result = (|| -> Result<landlock::RestrictionStatus, Box<dyn std::error::Error>> {
        let fd = PathFd::new(root)?; // opens the root dir to anchor the rule
        Ok(Ruleset::default()
            .set_compatibility(CompatLevel::BestEffort)
            .handle_access(all)?
            .create()?
            .add_rule(PathBeneath::new(fd, all))?
            .restrict_self()?)
    })();
    // Golden-safe introspection: only when RUSTY_SANDBOX_DEBUG is set, and only to
    // STDERR (run_tests.sh diffs stdout, so this can never move a golden). Lets the
    // manual probe confirm the kernel actually enforced the ruleset on this kernel.
    if std::env::var_os("RUSTY_SANDBOX_DEBUG").is_some() {
        match &result {
            Ok(s) => eprintln!("landlock: {:?}", s.ruleset),
            Err(e) => eprintln!("landlock: not applied ({})", e),
        }
    }
}

#[cfg(not(target_os = "linux"))]
fn apply_kernel_confinement(_root: &Path) { /* no Landlock off Linux — floor only */ }

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
