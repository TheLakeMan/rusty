;;; Copyright (c) 2026 Nicholas Vermeulen
;;; SPDX-License-Identifier: AGPL-3.0-or-later

; New features tests for SimpleLisp v2.2

(def assert-equal (expected actual label)
  (if (eq expected actual)
      (print label)
      (begin
        (print "FAIL:" label)
        (div 1 0))))

(def assert-true (value label)
  (if value
      (print label)
      (begin
        (print "FAIL: expected true")
        (print label)
        (div 1 0))))

; let / let*
(def test-let ()
  (begin
    (assert-equal 42 (let ((x 40) (y 2)) (add x y)) "let")
    (assert-equal 7 (let* ((x 5) (y (add x 2))) y) "let*")
    "let-ok"))

; letrec
(def test-letrec ()
  (assert-equal 120 (letrec ((fact (lambda (n) (if (eq n 0) 1 (mul n (fact (sub n 1))))))) (fact 5)) "letrec factorial")
  "letrec-ok")

; cond, and, or
(def test-cond ()
  (begin
    (assert-equal 1 (cond ((gt 5 3) 1) (else 0)) "cond")
    (assert-equal 42 (cond ((eq 1 2) 0) (else 42)) "cond else")
    "cond-ok"))

; List ops
(def test-lists-extra ()
  (begin
    (assert-equal (quote (3 2 1)) (reverse (quote (1 2 3))) "reverse")
    (assert-equal 20 (nth (quote (10 20 30)) 1) "nth")
    (assert-true (member 2 (quote (1 2 3))) "member")
    "lists-extra-ok"))

; Load test would need files, skip for now

; Macros (basic) - simplified for now
(def test-macro ()
  (begin
    (print "Macro support loaded")
    "macro-ok"))

; Math builtins (trig/exp/log) and their grad rules
(def close? (a b) (lt (abs (sub a b)) 1e-12))

(def test-math ()
  (begin
    (assert-equal 0 (sin 0) "sin")
    (assert-equal 1 (cos 0) "cos")
    (assert-equal 0 (tan 0) "tan")
    (assert-equal 0 (atan 0) "atan")
    (assert-equal 0 (atan2 0 1) "atan2")
    (assert-equal 1 (exp 0) "exp")
    (assert-equal 0 (log 1) "log")
    (assert-true (close? (log (exp 5)) 5) "log/exp inverse")
    (assert-true (close? (atan2 1 1) (atan 1)) "atan2 = atan on x=1")
    (assert-true (close? (sin 1) 0.8414709848078965) "sin 1")
    (assert-true (close? ((grad (lambda (x) (sin x))) 0) 1) "grad sin")
    (assert-true (close? ((grad (lambda (x) (cos x))) 0) 0) "grad cos")
    (assert-true (close? ((grad (lambda (x) (tan x))) 0) 1) "grad tan")
    (assert-true (close? ((grad (lambda (x) (atan x))) 1) 0.5) "grad atan")
    (assert-true (close? ((grad (lambda (x) (exp x))) 0) 1) "grad exp")
    (assert-true (close? ((grad (lambda (x) (log x))) 2) 0.5) "grad log")
    "math-ok"))

; Native check-exhaustive (v0.36.0): a defrust-compiled property is swept
; by direct native calls (parallel above 16k states). Convention: the
; property returns nonzero for "holds". Must agree with the interpreted
; path on verdicts and counterexamples.
(defrust ce-prop (x y) (if (< (+ x y) 18) 1 0))
(def test-native-ce ()
  (begin
    (assert-equal (quote verified)
      (check-exhaustive ce-prop (list (range 0 5) (range 0 5)))
      "native check-exhaustive verified")
    (assert-equal (quote (((9 9) "false")))
      (check-exhaustive ce-prop (quote ((9) (9))))
      "native counterexample")
    (assert-true
      (equal? (check-exhaustive ce-prop (list (range 0 12) (range 0 12)))
              (check-exhaustive (lambda (x y) (< (+ x y) 18))
                                (list (range 0 12) (range 0 12))))
      "native = interpreted, incl. counterexamples")
    "native-ce-ok"))

; Types
(def test-types ()
  (begin
    (assert-true (number? 42) "number?")
    (assert-true (list? (quote (1 2))) "list?")
    (assert-true (procedure? (lambda (x) x)) "procedure?")
    "types-ok"))

; truthiness (v0.37.0, B1): #f is the ONLY false value. Nil, empty list, 0
; are all truthy; Nil stays distinct from the empty list (JSON null / void).
(def test-truthiness ()
  (begin
    (assert-equal 1 (if () 1 0) "nil is truthy")
    (assert-equal 1 (if (quote ()) 1 0) "empty-list is truthy")
    (assert-equal 0 (if #f 1 0) "#f is false")
    (assert-equal 1 (if 0 1 0) "zero is truthy")
    (assert-true (null? ()) "null? nil")
    (assert-true (null? (quote ())) "null? empty-list")
    (assert-equal #f (equal? () (quote ())) "nil distinct from empty-list")
    "truthiness-ok"))

(def run-new-tests ()
  (begin
    (test-let)
    (test-letrec)
    (test-cond)
    (test-lists-extra)
    (test-macro)
    (test-math)
    (test-native-ce)
    (test-types)
    (test-truthiness)
    (print "NEW FEATURES PASSED")))

(run-new-tests)

;; ── did-you-mean on Undefined (v0.41.0) ─────────────────────────────────
(println "-- did-you-mean --")
(println (try-catch (filtr even? (list 1 2)) (e) e))
(println (try-catch (defin x 5) (e) e))
(println (try-catch (string-upcase "hi") (e) e))
(println (try-catch (zzqx 1) (e) e))

;; ── symlink-safety primitives (v0.42.0) ─────────────────────────────────
;; The symlink=true case needs a real symlink (no Lisp primitive makes one) and
;; is proven in wuwei's suite; here we lock the no-fixture properties.
(println "-- symlink-safety --")
(println (file-symlink? "Cargo.toml"))                  ; a regular file: #f
(println (string? (file-realpath "Cargo.toml")))        ; resolves to a real path: #t
(println (file-symlink? "/tmp/rusty-nope-xyz"))         ; missing path: #f
(println (nil? (file-realpath "/tmp/rusty-nope-xyz")))  ; unresolvable: nil
(println "-- hardlink-detect --")
(shell "rm -f /tmp/rusty-hl-a /tmp/rusty-hl-b; printf x > /tmp/rusty-hl-a; ln /tmp/rusty-hl-a /tmp/rusty-hl-b")
(println (file-hardlink? "/tmp/rusty-hl-a"))            ; regular file, 2 links: #t
(println (file-symlink? "/tmp/rusty-hl-a"))             ; not a symlink: #f
(println (file-hardlink? "Cargo.toml"))                 ; single-link regular file: #f
(println (file-hardlink? "/tmp"))                       ; a directory (nlink>=2, not a file): #f
(println (file-hardlink? "/tmp/rusty-nope-xyz"))        ; missing path: #f
(shell "rm -f /tmp/rusty-fifo-a /tmp/rusty-fifo-b; mkfifo /tmp/rusty-fifo-a; ln /tmp/rusty-fifo-a /tmp/rusty-fifo-b")
(println (file-hardlink? "/tmp/rusty-fifo-a"))          ; hardlinked fifo (non-regular, 2 links): #t
(shell "rm -f /tmp/rusty-hl-a /tmp/rusty-hl-b /tmp/rusty-fifo-a /tmp/rusty-fifo-b")

;; ── file-hash (v0.45.0) ─────────────────────────────────────────────────
;; Known-answer test: these are the published SHA-256 vectors for "abc" and
;; for the empty input, so this pins us to real SHA-256 — not merely to
;; whatever we happen to compute today. Fixtures live under /tmp, like
;; pkg-test.lisp's; the real ~/.rusty is never touched.
(println "-- file-hash --")
(file-write "/tmp/rusty-hash-abc.txt" "abc")
(file-write "/tmp/rusty-hash-empty.txt" "")
(println (file-hash "/tmp/rusty-hash-abc.txt"))
(println (file-hash "/tmp/rusty-hash-empty.txt"))
(println (nil? (file-hash "/tmp/rusty-nope-xyz")))     ; unreadable: nil
;; content, not path, decides the hash — and a one-byte edit changes it
(file-write "/tmp/rusty-hash-copy.txt" "abc")
(println (equal? (file-hash "/tmp/rusty-hash-abc.txt")
                 (file-hash "/tmp/rusty-hash-copy.txt")))
(file-write "/tmp/rusty-hash-copy.txt" "abd")
(println (equal? (file-hash "/tmp/rusty-hash-abc.txt")
                 (file-hash "/tmp/rusty-hash-copy.txt")))
(file-delete "/tmp/rusty-hash-abc.txt")
(file-delete "/tmp/rusty-hash-empty.txt")
(file-delete "/tmp/rusty-hash-copy.txt")
(println (nil? (file-hash "/tmp/rusty-hash-abc.txt")))  ; deleted: nil again

;; ── ed25519 signatures (v0.79.0) ─────────────────────────────────────────
;; Known-answer test against RFC 8032 §7.1 test-1's 32-byte seed: the public
;; key and the empty-message signature below were cross-checked byte-for-byte
;; against pyca/cryptography (OpenSSL), so this pins us to real Ed25519 — not
;; to whatever we happen to compute today. Deterministic signatures, so the
;; fixtures are golden-stable.
(println "-- ed25519 --")
(define ED-SEED "9d61b19deffebc3a44e135e058c2d68e08b71fc63d34d5a25d75c1bd7cbb8bce")
(define ED-KP (ed25519-keygen ED-SEED))
(println (cadr ED-KP))   ; RFC8032#1 public key: 15382cb2...fee764b4
(define ED-SIG0 (ed25519-sign (car ED-KP) ""))
(println ED-SIG0)        ; RFC8032#1 signature over the empty message: 241d8908...fecbd70d
;; round-trip on a real message, and every failure mode is a refusal (#f), never a raise
(define ED-MSG "48 28 20")
(define ED-SIG (ed25519-sign (car ED-KP) ED-MSG))
(println (ed25519-verify (cadr ED-KP) ED-MSG ED-SIG))          ; #t
(println (ed25519-verify (cadr ED-KP) "99 99 99" ED-SIG))      ; wrong message: #f
(println (ed25519-verify (cadr ED-KP) ED-MSG ED-SIG0))         ; wrong signature: #f
(println (ed25519-verify (cadr ED-KP) ED-MSG "deadbeef"))      ; malformed sig: #f
(println (ed25519-verify "zz" ED-MSG ED-SIG))                  ; malformed key: #f
;; a one-character flip in the signature hex breaks it (tamper-evident)
(println (ed25519-verify (cadr ED-KP) ED-MSG
                         (string-append "00" (substring ED-SIG 2 128))))
;; determinism: the same key+message always yields the same signature
(println (equal? ED-SIG (ed25519-sign (car ED-KP) ED-MSG)))    ; #t
;; a different seed yields a different key that CANNOT verify the first's signature
(define ED-KP2 (ed25519-keygen "0000000000000000000000000000000000000000000000000000000000000001"))
(println (ed25519-verify (cadr ED-KP2) ED-MSG ED-SIG))         ; #f

;; ── truncated source is an error, not a shorter program (v0.47.0) ────────
;; The parser used to close an unclosed '(' at EOF and stop dead at a stray
;; ')' — so a half-written file (partial clone, interrupted write) LOADED
;; CLEAN with its tail swallowed into the last open form, or dropped. That is
;; the worst kind of wrong: silent. Both are now load errors.
(println "-- truncated source --")
(file-write "/tmp/rusty-trunc.lisp" "(define (whole) 1)\n(define (half) 2")
(println (try-catch (load "/tmp/rusty-trunc.lisp") (e) 'load-refused))
(println (try-catch (whole) (e) 'never-defined))   ; the file did not take effect
(file-write "/tmp/rusty-stray.lisp" "(define (a) 1)\n)\n(define (b) 2)")
(println (try-catch (load "/tmp/rusty-stray.lisp") (e) 'load-refused))
(println (try-catch (b) (e) 'never-defined))       ; nothing after ')' ran
;; ...and a balanced file still loads, so the check isn't just refusing everything
(file-write "/tmp/rusty-ok.lisp" "(define (fine) 7)")
(load "/tmp/rusty-ok.lisp")
(println (fine))
(file-delete "/tmp/rusty-trunc.lisp")
(file-delete "/tmp/rusty-stray.lisp")
(file-delete "/tmp/rusty-ok.lisp")
;; NB (whole) above was never-defined even though its definition was complete
;; and came FIRST: parsing happens before evaluation, so a load is all-or-
;; nothing. A truncated file can't half-apply.
(println (nil? (file-hash "/tmp/rusty-trunc.lisp")))

;; ── safe-call-with-spec: enforce the spec you were HANDED (v0.48.0) ──────
;; *tool-specs* is global, keyed by tool name, and deftool-spec replaces that
;; name's entry — so a caller that certified a tool at boot cannot trust that
;; the spec it certified is the one safe-call will look up later. It cannot even
;; compare them: code values are never equal? to anything (SPEC §equality), and
;; a precondition is a code value. safe-call-with-spec takes the spec, so a
;; caller can hold onto the one it certified. wuwei's gate does exactly this.
(println "-- safe-call-with-spec --")
(deftool sc-echo (x) "Echo" (str "echoed " x))
(deftool-spec sc-echo '((x string)) '() (lambda (x) (string-starts-with? x "ok")) '())
(define PINNED (tool-spec 'sc-echo))
(define SNAP (registry-snapshot '(sc-echo)))               ; freeze the whole tool set once
(println (safe-call sc-echo "ok-1"))                       ; global spec: allowed
(println (try-catch (safe-call sc-echo "no-1") (e) 'refused))
;; Now REPLACE the spec — as a second tenant registering the same tool name would
(deftool-spec sc-echo '((x string)) '() (lambda (x) (string-starts-with? x "zz")) '())
(println (try-catch (safe-call sc-echo "ok-1") (e) 'refused))   ; global changed: now refused
(println (safe-call-with-spec PINNED sc-echo "ok-1"))           ; pinned spec: still enforced
(println (try-catch (safe-call-with-spec PINNED sc-echo "zz-1") (e) 'refused))
;; Immutable registry snapshot (#2/#3): the frozen snapshot dispatches by NAME
;; against the specs captured before the poison, so the widened global cannot
;; reach it — the certified "ok" precondition is still enforced.
(println (list 'snap-has-spec (not (equal? (snapshot-spec SNAP 'sc-echo) #f))
               'snap-unknown  (snapshot-spec SNAP 'no-such-tool)))
(println (safe-call-in SNAP sc-echo "ok-1"))                    ; snapshot spec: allowed
(println (try-catch (safe-call-in SNAP sc-echo "zz-1") (e) 'refused))  ; snapshot rejects the poison's new rule

; ── Lexical addressing (v0.56.0) — resolved refs must be invisible ──────
; Slot-resolved variables (resolve.rs) rewrite lambda bodies created at
; the global env; these cases pin the dynamic guards: a runtime define
; into a live frame (dirty flag), eval-in-current-env injection,
; function→macro flip (args degrade to symbols), and grad/check-effects
; reading through resolved refs. Output must match the unresolved
; interpreter exactly.
(define lx-x 10)
(define (lx-f1)
  (begin
    (display (list 'lx-before-define lx-x)) (newline)
    (define lx-x 2)
    (display (list 'lx-after-define lx-x)) (newline)))
(lx-f1)
(display (list 'lx-global-untouched lx-x)) (newline)
(define (lx-f3 a)
  (let ((b 1))
    (begin (eval '(define a 99)) (+ a b))))
(display (list 'lx-eval-shadow (lx-f3 5))) (newline)
(define (lx-g) 1)
(define (lx-caller) (lx-g))
(define lx-first (lx-caller))
(define (lx-g) 2)
(display (list 'lx-redefine lx-first (lx-caller))) (newline)
(define (lx-h a) a)
(define (lx-uses-h) (lx-h lx-undefined-name))
(defmacro lx-h (a) `(quote ,a))
(display (list 'lx-macro-flip (lx-uses-h))) (newline)
(define (lx-adder n) (lambda (v) (+ v n)))
(define (lx-f7 p) (let* ((p (+ p 1)) (q (* p 2))) (+ p q)))
(define (lx-f9)
  (let loop ((i 0) (acc 0)) (if (= i 5) acc (loop (+ i 1) (+ acc i)))))
(display (list 'lx-capture ((lx-adder 3) 4)
               'lx-letstar (lx-f7 10)
               'lx-named-let (lx-f9))) (newline)
(define lx-df (grad (lambda (t) (* t t))))
(display (list 'lx-grad (lx-df 3)
               'lx-effects (check-effects (lambda (p) (file-read p))))) (newline)
(define (lx-f14 max) (+ max 1))
(display (list 'lx-shadow-builtin (lx-f14 9))) (newline)

;; Robustness (0.61.0): recursion/parser/display/drop guards refuse cleanly,
;; never core-dump (a Rust stack overflow aborts and can't be caught). See
;; benchmarks/stress_crash_probe.sh for the abort-boundary reproductions.
(define (rb-nontail n) (if (= n 0) 0 (+ 1 (rb-nontail (- n 1)))))
(define (rb-nest n x) (if (= n 0) x (rb-nest (- n 1) (list x))))
(define rb-deep-src (string-append (string-repeat "(car " 9000) "'(1)" (string-repeat ")" 9000)))
(rb-nest 300000 1)   ; built + dropped mid-program: iterative drop, no overflow
(display (list 'rb-recursion (try-catch (begin (rb-nontail 10000000) 'no-error)
                                        (e) (if (string-contains? e "recursion limit") 'refused 'other))
               'rb-nesting (try-catch (begin (eval-string rb-deep-src) 'no-error)
                                      (e) (if (string-contains? e "nesting too deep") 'refused 'other))
               'rb-drop 'ok)) (newline)

;; Verification honesty (0.62.1, Grok-review fixes): check-exhaustive is
;; boolean-strict (a truthy non-boolean is a NAMED counterexample, never a
;; silent verify), verify-candidate refuses a spec with no dynamic gate,
;; and `not` agrees with `if` (SPEC §3: #f is the ONLY false value).
(display (list 'vh-strict (check-exhaustive (lambda (x) 0) (list (list 1)))
               'vh-bool (check-exhaustive (lambda (x) (> x 0)) (list (list 1 2))))) (newline)
(display (list 'vh-unchecked (verify-candidate (lambda (x) x) (list (list 'pure #t)))
               'vh-full (verify-candidate (lambda (x) (* x x))
                          (list (list 'domains (list (list 0 1 2)))
                                (list 'invariant (lambda (f x) (>= (f x) 0))))))) (newline)

;; Security fix: check-effects no longer certifies a body that runs arbitrary
;; code (eval/eval-string) or compiles native code (defrust/graph-compile) as
;; PURE — the exact hole a `(lambda (x) (eval-string x))` used to slip through
;; (it admitted no effect yet could do anything). Each is now a named effect,
;; so wuwei/shouzhong purity gates that trust check-effects catch it.
(display (list 'ce-eval-string (check-effects (lambda (x) (eval-string x)))
               'ce-eval (check-effects (lambda (d) (eval d)))
               'ce-defrust (check-effects (lambda () (defrust (f x) (* x x))))
               'ce-graph (check-effects (lambda () (graph-compile g))))) (newline)

;; Transitive (0.82.0): a call to a user-defined helper has ITS body walked too,
;; so an effect hidden behind a function — or a chain of them — is surfaced. This
;; closes the "hide a shell behind a helper" backdoor the shallow walk missed.
(define (cet-helper) (shell "echo x"))
(define (cet-a) (cet-b))
(define (cet-b) (file-write "/x" "y"))
(define (cet-sq x) (* x x))
(define (cet-quad x) (cet-sq (cet-sq x)))
;; error/gensym are DIRECT effects but must NOT propagate through a call (nearly
;; every fn can raise — propagating would flood every caller and certify nothing).
(define (cet-safe x) (if (equal? x 0) (error "div0") (/ 1 x)))
(display (list 'cet-hidden (check-effects (lambda () (cet-helper)))
               'cet-chain  (check-effects (lambda () (cet-a)))
               'cet-pure   (check-effects (lambda (x) (cet-quad x)))
               'cet-err-hidden (check-effects (lambda (x) (cet-safe x)))
               'cet-err-direct (check-effects (lambda () (error "boom"))))) (newline)
(display (list 'vh-not-nil (not nil) 'vh-not-false (not #f) 'vh-not-zero (not 0)
               'vh-if-nil (if nil 'then 'else)
               'vh-not-arity (try-catch (not) (e) 'raised))) (newline)
