;;; Copyright (c) 2026 Nicholas Vermeulen
;;; SPDX-License-Identifier: AGPL-3.0-or-later

;; fmt-test.lisp — golden test for the `fmt-string` builtin / `rusty fmt`.
;; Pins canonical layout on a messy fixture, plus the two load-bearing
;; properties: idempotency and behavioral semantics-preservation, plus that
;; comments survive.

;; ── A deliberately messy fixture → canonical layout ────────────────────────
(define messy
  (string-append
    ";; header\n"
    "(define   (f x)\n"
    "(if (> x 0)\n"
    "(list (quote pos) x)\n"
    "(list (quote neg) x)))\n"
    "\n\n\n"
    "(define (g   lst)\n"
    "(cond  ((null? lst) 0)\n"
    "((> (car lst) 0) (+ 1 (g (cdr lst))))\n"
    "(else (g (cdr lst)))))\n"
    "(let ((a 1)\n"
    "(b 2))\n"
    "(+ a b))   ; inline\n"))

(print "── canonical output ──")
(print (fmt-string messy))

;; ── Idempotency: fmt(fmt(x)) == fmt(x) ─────────────────────────────────────
(print (list 'idempotent (equal? (fmt-string (fmt-string messy)) (fmt-string messy))))

;; ── Behavioral semantics-preservation: eval(fmt(x)) == eval(x) ─────────────
(define (sem-preserved? src) (equal? (eval-string src) (eval-string (fmt-string src))))
(print (list 'sem-define+call
             (sem-preserved? "(define (sq x) (* x x))\n(map sq (list 1 2 3))")))
(print (list 'sem-let-cond
             (sem-preserved?
               (string-append "(let ((xs (list -1 0 2 -3 4)))\n"
                              "(length (filter (lambda (x) (> x 0)) xs)))"))))
(print (list 'sem-nested-quote
             (sem-preserved? "(list (quote (a b)) (quote c) (quasiquote (1 (unquote (+ 1 1)))))")))

;; ── Comments survive formatting ────────────────────────────────────────────
(define fmtd (fmt-string messy))
(print (list 'keeps-header (string-contains? fmtd ";; header")
             'keeps-inline (string-contains? fmtd "; inline")))

(print "FMT TESTS DONE")
