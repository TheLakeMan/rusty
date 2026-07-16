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
