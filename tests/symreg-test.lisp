;;; Copyright (c) 2026 Nicholas Vermeulen
;;; SPDX-License-Identifier: AGPL-3.0-or-later

;; symreg-test.lisp — golden test for symreg.lisp (equation discovery).
;; Deterministic (seeded PRNG): same discovered equations every run.

(load "symreg.lisp")

(define (make-data f xs) (map (lambda (x) (list (list x) (f x))) xs))
(define (frange a b step)
  (if (> a b) '() (cons a (frange (+ a step) b step))))

;; ── Problem 1: quadratic  y = x^2 + 2x + 1 ──────────────────────────────
(symreg-seed! 42)
(define quad (lambda (x) (+ (* x x) (* 2 x) 1)))
(define r1 (symreg (make-data quad (frange -2 2 0.25)) '(x)))
(print (list 'quadratic 'found (car r1) 'mse (cadr r1) 'gen (caddr r1)))

;; ── Problem 2: Koza-1  y = x^4 + x^3 + x^2 + x ──────────────────────────
(symreg-seed! 42)
(define koza1 (lambda (x) (+ (expt x 4) (expt x 3) (* x x) x)))
(define r2 (symreg (make-data koza1 (frange -1 1 0.1)) '(x)))
(print (list 'koza-1 'found (car r2) 'mse (cadr r2) 'gen (caddr r2)))

;; ── Problem 3: two variables  z = x*y + x ────────────────────────────────
(symreg-seed! 7)
(define bivar (lambda (x y) (+ (* x y) x)))
(define grid '((-2 1) (-1 3) (0 2) (1 -1) (2 4) (3 -2) (-3 -1) (2 -3)))
(define data3 (map (lambda (p) (list p (bivar (car p) (cadr p)))) grid))
(define r3 (symreg data3 '(x y)))
(print (list 'bivar 'found (car r3) 'mse (cadr r3) 'gen (caddr r3)))

;; ── Problem 4: Koza-1 again, with MACRO building blocks ─────────────────
;; Blocks are ordinary defmacros — fitness `eval`s candidates, which
;; expands them. Richer vocabulary at the same tree depth = the search
;; finds Koza-1 in fewer generations than the bare-ops run above.
(defmacro sq (e) `(* ,e ,e))
(defmacro cube (e) `(* ,e (* ,e ,e)))
(symreg-ops! '((sq 1) (cube 1) (+ 2) (- 2) (* 2)))
(symreg-seed! 42)
(define r4 (symreg (make-data koza1 (frange -1 1 0.1)) '(x)))
(print (list 'koza-1-with-blocks 'found (car r4) 'mse (cadr r4) 'gen (caddr r4)))
(print (list 'blocks-helped (< (caddr r4) (caddr r2))
             'gens (caddr r4) 'vs (caddr r2)))
(symreg-ops-reset!)

;; ── The discovered equations really are the equations ───────────────────
;; (checked on held-out inputs never seen during evolution)
(define (check-fn name got want inputs)
  (let ((ok (foldl (lambda (i acc) (and acc (= (apply got i) (apply want i))))
                   #t inputs)))
    (print (list name 'held-out-exact ok))))
(check-fn 'quadratic (eval (list 'lambda '(x) (car r1))) quad '((3.5) (-4.25) (10)))
(check-fn 'koza-1    (eval (list 'lambda '(x) (car r2))) koza1 '((1.5) (-2.5) (3)))
(check-fn 'bivar     (eval (list 'lambda '(x y) (car r3))) bivar '((5 7) (-4 2.5) (0.5 -3)))
(check-fn 'koza-1-with-blocks (eval (list 'lambda '(x) (car r4))) koza1 '((1.5) (-2.5) (3)))

(print "SYMREG TESTS DONE")
