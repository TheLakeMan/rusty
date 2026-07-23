;;; coverage-allowlist.lisp — commands intentionally NOT exercised by the
;;; golden suite. Each needs a reason. "We stand for truth": keep this minimal
;;; and honest; the check FAILS if an entry here is actually exercised (stale).
(define *coverage-allow* '(
  ;; ── LLM / live model ────────────────────────────────────────────────────
  llm            ; needs a live model endpoint
  react-loop     ; LLM agent loop
  agent          ; LLM agent loop (wraps react-loop)
  ask-llm        ; agent tool that calls llm
  llm-proposer   ; calls llm to propose code

  ;; ── Host / owner side effects we won't touch in goldens ─────────────────
  ;; remember/forget/memory-list ARE exercised by sandbox-test.lisp — called
  ;; under an active sandbox, so they're REFUSED before touching ~/.rusty (no
  ;; side effect), which is exactly what lets the golden exercise them safely.
  recall         ; reads the owner's real memory store (not exercised)
  memory-seal    ; Ed25519-signs the owner's real ~/.rusty store (would write a .sig + need a key)
  memory-verify  ; verifies the owner's real store against a seal that isn't present in a golden
  ;; memory-path is exercised (string? only) in commands-test.lisp

  ;; ── Compile-to-Rust / slow / cache-dependent ────────────────────────────
  ;; defrust is exercised by the new-features golden (not listed)
  defrust*       ; multi-fn JIT group; shells out to rustc
  graph-compile  ; scalar graph JIT via rustc
  graph-compile-grad ; tensor graph JIT via rustc

  ;; ── Nondeterministic output ─────────────────────────────────────────────
  time           ; wall-clock macro; prints timings (uses now-micros)
  show-macro-profile ; pretty-prints call counts + total-us (timing noise)
  ;; now-micros itself IS exercised by robot/testkit libraries — not listed

  ;; ── Parse-time only (never a runtime call head) ─────────────────────────
  unquote        ; desugars at parse; cannot appear as an eval call head
  unquote-splicing ; same
))
