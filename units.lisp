;;; Copyright (c) 2026 Nicholas Vermeulen
;;; SPDX-License-Identifier: AGPL-3.0-or-later

;; units.lisp — dimensional-consistency checking as a STATIC gate. Pure Lisp,
;; zero interpreter changes; a walker over the same restricted numeric AST
;; subset as `grad` / `check-effects` / `check-types` (numbers, symbols,
;; + - * / expt sqrt, the numeric unary fns, comparisons, if).
;;
;; A DIMENSION is a 7-vector of integer exponents over the SI base dimensions
;; [ M  L  T  I  Θ  N  J ] = (mass length time current temperature amount
;; luminous). `check-units` derives the dimension of every subexpression and
;; refuses a dimensionally illegal one (`m + s`, `sin(m)`, …) as DATA — an
;; `(unit-error …)` list, never a raise — so it composes as a cheap gate
;; placed BEFORE the numeric work (check-exhaustive / defrust) runs.
;;
;; Claim discipline: "dimensionally consistent on this AST", per the
;; bounded-verification rule — NOT "physically correct". A subset caveat:
;; only MULTIPLICATIVE units (no temperature offsets like °C/°F — those aren't
;; a pure scaling and would need an affine model); exponents are INTEGER, so
;; `sqrt` of an odd-exponent dimension is refused rather than faked as
;; fractional. Everything is symbol/integer data — deterministic.

;; ── Dimension algebra (7 integer exponents) ──────────────────────────────
(define (dim-map2 f a b)
  (if (or (null? a) (null? b)) '()
      (cons (f (car a) (car b)) (dim-map2 f (cdr a) (cdr b)))))
(define (dim-zero)     (list 0 0 0 0 0 0 0))
(define (dim+ a b)     (dim-map2 + a b))
(define (dim- a b)     (dim-map2 - a b))
(define (dim-scale a k)(map (lambda (e) (* e k)) a))          ; k integer (expt)
(define (dim=? a b)    (equal? a b))
(define (dim-zero? a)  (all? (lambda (e) (= e 0)) a))
(define (dim-halve a)                                         ; sqrt; 'odd if any odd
  (if (all? (lambda (e) (= 0 (mod e 2))) a)
      (map (lambda (e) (floor (/ e 2))) a)
      'odd))

;; ── Unit table: name -> dimension vector (base + a few derived) ──────────
(define *unit-table*
  (list (list 'm   (list 0 1 0 0 0 0 0))       ; length
        (list 'kg  (list 1 0 0 0 0 0 0))       ; mass
        (list 's   (list 0 0 1 0 0 0 0))       ; time
        (list 'A   (list 0 0 0 1 0 0 0))       ; current
        (list 'K   (list 0 0 0 0 1 0 0))       ; temperature
        (list 'mol (list 0 0 0 0 0 1 0))       ; amount
        (list 'cd  (list 0 0 0 0 0 0 1))       ; luminous
        (list 'N   (list 1 1 -2 0 0 0 0))      ; newton   kg·m/s²
        (list 'J   (list 1 2 -2 0 0 0 0))      ; joule    N·m
        (list 'W   (list 1 2 -3 0 0 0 0))      ; watt     J/s
        (list 'Pa  (list 1 -1 -2 0 0 0 0))     ; pascal   N/m²
        (list 'Hz  (list 0 0 -1 0 0 0 0))))    ; hertz    1/s
(define (unit-dim name) (let ((e (assoc name *unit-table*))) (if e (cadr e) #f)))
;; Reverse lookup for readable output: a known unit name, else the vector.
(define (unit-name dim)
  (let ((e (find (lambda (row) (dim=? (cadr row) dim)) *unit-table*)))
    (if e (car e) dim)))

;; ── The walker ────────────────────────────────────────────────────────────
(define (unit-error? d)
  (and (list? d) (not (null? d)) (equal? (car d) 'unit-error)))

(define (check-units expr env)
  (cond
    ((number? expr) (dim-zero))                       ; a bare number is dimensionless
    ((symbol? expr)
     (let ((v (assoc expr env)))
       (cond (v (cadr v))                             ; a declared variable's dimension
             ((unit-dim expr) (unit-dim expr))        ; a unit literal
             (else (list 'unit-error 'unknown-symbol expr)))))
    ((list? expr) (check-units-op (car expr) (cdr expr) env))
    (else (list 'unit-error 'bad-expr expr))))

;; expt/sqrt are special: expt's exponent is a literal, not a quantity.
(define (check-units-op op args env)
  (cond
    ((equal? op 'expt) (check-expt args env))
    ((equal? op 'sqrt) (check-sqrt args env))
    (else
      (let ((ds (map (lambda (a) (check-units a env)) args)))
        (let ((err (find unit-error? ds)))
          (if err err (units-apply op ds args)))))))

(define (check-expt args env)
  (let ((bd (check-units (car args) env)) (e (cadr args)))
    (cond ((unit-error? bd) bd)
          ((not (number? e)) (list 'unit-error 'non-constant-exponent (cadr args)))
          (else (dim-scale bd e)))))

(define (check-sqrt args env)
  (let ((bd (check-units (car args) env)))
    (cond ((unit-error? bd) bd)
          (else (let ((h (dim-halve bd)))
                  (if (equal? h 'odd)
                      (list 'unit-error 'sqrt-odd-exponent (unit-name bd))
                      h))))))

;; Operator families (all operands' dimensions already derived, error-free).
(define (all-equal? ds)                                ; every dimension identical
  (all? (lambda (d) (dim=? d (car ds))) ds))
(define *unit-additive*      '(+ - min max))           ; equal dims -> that dim
(define *unit-transcendental* '(sin cos tan atan exp log))  ; dimensionless -> dimensionless
(define *unit-preserving*    '(abs floor ceiling round)) ; 1 arg, dim unchanged
(define *unit-comparison*    '(< > <= >= =))            ; equal dims -> dimensionless

(define (units-apply op ds args)
  (cond
    ((member op *unit-additive*)
     (if (all-equal? ds) (car ds)
         (list 'unit-error 'mismatch op (map unit-name ds))))
    ((equal? op '*) (foldl (lambda (d acc) (dim+ acc d)) (dim-zero) ds))
    ((equal? op '/)
     (if (null? (cdr ds)) (dim- (dim-zero) (car ds))   ; (/ x) = reciprocal
         (foldl (lambda (d acc) (dim- acc d)) (car ds) (cdr ds))))
    ((member op *unit-preserving*) (car ds))
    ((member op *unit-transcendental*)
     (if (dim-zero? (car ds)) (dim-zero)
         (list 'unit-error 'needs-dimensionless op (unit-name (car ds)))))
    ((equal? op 'atan2)                                 ; angle: equal dims -> dimensionless
     (if (all-equal? ds) (dim-zero)
         (list 'unit-error 'mismatch op (map unit-name ds))))
    ((member op *unit-comparison*)
     (if (all-equal? ds) (dim-zero)
         (list 'unit-error 'mismatch op (map unit-name ds))))
    ((equal? op 'if)                                    ; (if cond then else): then/else agree
     (if (dim=? (cadr ds) (caddr ds)) (cadr ds)
         (list 'unit-error 'branch-mismatch (unit-name (cadr ds)) (unit-name (caddr ds)))))
    (else (list 'unit-error 'unknown-op op))))

;; ── Convenience ──────────────────────────────────────────────────────────
(define (unit-of expr)        (check-units expr '()))          ; empty variable env
(define (units-ok? expr env)  (not (unit-error? (check-units expr env))))
;; Build a variable env from (var unit-name) declarations.
(define (unit-env decls)
  (map (lambda (d) (list (car d) (unit-dim (cadr d)))) decls))

;; ── Multiplicative conversion + an EXHAUSTIVE round-trip proof ───────────
;; Scale table: name -> (dim factor) where factor is the size in the finest
;; unit of that dimension (INTEGER, so a multiply-first round-trip is exact).
(define *scale-table*
  (list (list 'mm (list 0 1 0 0 0 0 0) 1)
        (list 'm  (list 0 1 0 0 0 0 0) 1000)
        (list 'km (list 0 1 0 0 0 0 0) 1000000)
        (list 'ms (list 0 0 1 0 0 0 0) 1)
        (list 's  (list 0 0 1 0 0 0 0) 1000)))
(define (unit-scale name) (assoc name *scale-table*))
(define (convert x from to)
  (let ((f (unit-scale from)) (t (unit-scale to)))
    (cond ((not f) (list 'unit-error 'unknown-unit from))
          ((not t) (list 'unit-error 'unknown-unit to))
          ((not (dim=? (cadr f) (cadr t))) (list 'unit-error 'incompatible from to))
          (else (/ (* x (caddr f)) (caddr t))))))

;; Prove that converting to a finer unit and back is the identity over a
;; finite integer grid — a real check-exhaustive 'verified (multiply-first is
;; exact for integers). from must be the COARSER unit (multiply first).
(define (convert-roundtrip-verified from to grid)
  (check-exhaustive
    (lambda (x) (= (convert (convert x from to) to from) x))
    (list grid)))
