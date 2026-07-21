;;; Copyright (c) 2026 Nicholas Vermeulen
;;; SPDX-License-Identifier: AGPL-3.0-or-later

;; simplex.lisp — tableau simplex (Bland's rule) for tiny dense LPs, with an
;; exhaustive cross-check against brute-force vertex enumeration. Pure Lisp,
;; zero interpreter changes.
;;
;; Solves  maximize c·x  subject to  A x ≤ b,  x ≥ 0,  with b ≥ 0  (so the
;; all-slack origin is a feasible start — a DOCUMENTED restriction that avoids
;; a phase-1; infeasible-start LPs are out of scope, not silently mishandled).
;; Result is a certificate: `(status optimal) (x V) (z Z)` or `(status unbounded)`.
;; Bland's rule (smallest-index entering/leaving) guarantees termination — no
;; cycling on degenerate problems.
;;
;; THE VERIFICATION BITE — the oracle is honest, not the algorithm's word:
;; `lp-brute` independently enumerates every vertex of the feasible polygon and
;; takes the best; `verify-simplex-agrees` proves, over EVERY tiny LP in a
;; declared finite grid, that simplex's objective equals brute's within ε and
;; their unbounded/optimal status agrees. A simplex bug shows up as a
;; counterexample LP — the brute enumerator is the trusted reference.
;;
;; PORTABILITY: simplex pivots produce non-dyadic fractions, so the exhaustive
;; check compares objectives within ε (never prints a raw pivoted float); the
;; known-answer fixtures are chosen with integer optima so their printed z is
;; exact. Only + - * / — no libm.
;;
;; CLAIM DISCIPLINE: "simplex agrees with brute vertex enumeration on the
;; declared tiny LPs (2 vars, 2 constraints, entries in a small set)". NEVER an
;; industrial-LP claim, NEVER "optimal for large / ill-conditioned problems".

(define *lp-eps* (/ 1 1000000))                       ; 1e-6 feasibility / compare tol

;; ── List helpers ──────────────────────────────────────────────────────────
(define (lp-set-nth lst i v)
  (if (= i 0) (cons v (cdr lst)) (cons (car lst) (lp-set-nth (cdr lst) (- i 1) v))))
(define (lp-zeros n) (if (= n 0) '() (cons 0 (lp-zeros (- n 1)))))
(define (lp-dot a b) (if (or (null? a) (null? b)) 0 (+ (* (car a) (car b)) (lp-dot (cdr a) (cdr b)))))

;; ── Tableau simplex ───────────────────────────────────────────────────────
;; Tableau: m constraint rows then 1 objective row; columns are
;; [x_1..x_n | s_1..s_m | rhs]. Objective row starts as [-c | 0 | 0]; a negative
;; entry there means the objective can still improve.
(define (lp-build-tableau A b c)
  (let* ((m (length A)) (n (length c)))
    (define (con i)                                    ; constraint row i: [A_i | e_i | b_i]
      (append (nth A i)
              (let loop ((j 0) (acc '()))
                (if (>= j m) (reverse acc)
                    (loop (+ j 1) (cons (if (= j i) 1 0) acc))))
              (list (nth b i))))
    (define (rows i acc)
      (if (>= i m) (reverse acc) (rows (+ i 1) (cons (con i) acc))))
    (let ((obj (append (map (lambda (cj) (- 0 cj)) c) (lp-zeros m) (list 0))))
      (append (rows 0 '()) (list obj)))))

;; Entering column: smallest index j with objective-row reduced cost < -eps (Bland).
(define (lp-entering tab m ncol)
  (let ((objrow (nth tab m)))
    (define (go j)
      (cond ((>= j (- ncol 1)) -1)                     ; last col is rhs
            ((< (nth objrow j) (- 0 *lp-eps*)) j)
            (else (go (+ j 1)))))
    (go 0)))

;; Leaving row: min-ratio rhs/col over positive column entries; Bland ties by
;; smallest basic-variable index. Returns -1 if the column has no positive entry
;; (⇒ unbounded).
(define (lp-leaving tab m col basis)
  (define (go i best bi bvar)
    (if (>= i m)
        bi
        (let ((aij (nth (nth tab i) col)))
          (if (> aij *lp-eps*)
              (let ((ratio (/ (nth (nth tab i) (- (length (nth tab i)) 1)) aij)))
                (cond ((< bi 0) (go (+ i 1) ratio i (nth basis i)))
                      ((< ratio (- best *lp-eps*)) (go (+ i 1) ratio i (nth basis i)))
                      ((and (< (abs (- ratio best)) *lp-eps*) (< (nth basis i) bvar))
                       (go (+ i 1) ratio i (nth basis i)))
                      (else (go (+ i 1) best bi bvar))))
              (go (+ i 1) best bi bvar)))))
  (go 0 0 -1 0))

;; Pivot on (row, col): normalize the pivot row, eliminate the column elsewhere.
(define (lp-pivot tab prow pcol)
  (let* ((piv (nth (nth tab prow) pcol))
         (nrow (map (lambda (v) (/ v piv)) (nth tab prow))))
    (define (elim i acc)
      (if (>= i (length tab)) (reverse acc)
          (if (= i prow) (elim (+ i 1) (cons nrow acc))
              (let* ((f (nth (nth tab i) pcol))
                     (r (lp-row-comb (nth tab i) nrow f)))            ; row_i - f·nrow
                (elim (+ i 1) (cons r acc))))))
    (elim 0 '())))
;; a[k] - f·b[k], elementwise (Rusty has no dotted pairs — recurse two lists).
(define (lp-row-comb a b f)
  (if (or (null? a) (null? b)) '()
      (cons (- (car a) (* f (car b))) (lp-row-comb (cdr a) (cdr b) f))))
(define (lp-zip a b) (if (or (null? a) (null? b)) '() (cons (list (car a) (car b)) (lp-zip (cdr a) (cdr b)))))

(define (lp-cert-get c k) (let ((e (assoc k c))) (if e (cadr e) #f)))

(define (lp-simplex A b c)
  (let* ((m (length A)) (n (length c))
         (ncol (+ n m 1)))
    (define (loop tab basis)
      (let ((col (lp-entering tab m ncol)))
        (if (< col 0)
            ;; optimal: read x from basis, z from objective-row rhs
            (let ((x (lp-zeros n)))
              (define (readx i xs)
                (if (>= i m) xs
                    (let ((bv (nth basis i)))
                      (readx (+ i 1)
                             (if (< bv n)
                                 (lp-set-nth xs bv (nth (nth tab i) (- ncol 1)))
                                 xs)))))
              (list (list 'status 'optimal)
                    (list 'x (readx 0 x))
                    (list 'z (nth (nth tab m) (- ncol 1)))))
            (let ((row (lp-leaving tab m col basis)))
              (if (< row 0)
                  (list (list 'status 'unbounded))
                  (loop (lp-pivot tab row col) (lp-set-nth basis row col)))))))
    ;; initial basis = slack columns n..n+m-1
    (loop (lp-build-tableau A b c)
          (let loop2 ((i 0) (acc '()))
            (if (>= i m) (reverse acc) (loop2 (+ i 1) (cons (+ n i) acc)))))))

;; ── Brute-force vertex enumeration (2 vars) — the trusted oracle ──────────
;; Unbounded (with A ≥ 0, b ≥ 0): a variable with c_j>0 whose column is all 0.
(define (lp-col-all-zero? A j)
  (foldl (lambda (row acc) (and acc (= (nth row j) 0))) #t A))
(define (lp-unbounded2? A c)
  (or (and (> (nth c 0) 0) (lp-col-all-zero? A 0))
      (and (> (nth c 1) 0) (lp-col-all-zero? A 1))))

;; Solve the 2×2 [p q][r s]·x = [u v]; Nil if singular.
(define (lp-solve2 p q r s u v)
  (let ((det (- (* p s) (* q r))))
    (if (= det 0) '()
        (list (/ (- (* u s) (* q v)) det) (/ (- (* p v) (* u r)) det)))))

;; Every candidate vertex = intersection of two of the four boundary lines
;; {con1, con2, x1=0, x2=0}. Feasible ones satisfy all constraints and x≥0.
(define (lp-feasible2? A b x)
  (and (>= (car x) (- 0 *lp-eps*)) (>= (cadr x) (- 0 *lp-eps*))
       (foldl (lambda (pair acc)
                (and acc (<= (lp-dot (car pair) x) (+ (cadr pair) *lp-eps*))))
              #t (lp-zip A b))))

(define (lp-brute A b c)
  (if (lp-unbounded2? A c)
      (list (list 'status 'unbounded))
      (let* ((a11 (nth (nth A 0) 0)) (a12 (nth (nth A 0) 1)) (b1 (nth b 0))
             (a21 (nth (nth A 1) 0)) (a22 (nth (nth A 1) 1)) (b2 (nth b 1))
             ;; six line pairs → candidate vertices (drop singular / infeasible)
             (cands (list (lp-solve2 a11 a12 a21 a22 b1 b2)       ; con1 ∩ con2
                          (lp-solve2 a11 a12 1 0 b1 0)            ; con1 ∩ x1=0
                          (lp-solve2 a11 a12 0 1 b1 0)            ; con1 ∩ x2=0
                          (lp-solve2 a21 a22 1 0 b2 0)            ; con2 ∩ x1=0
                          (lp-solve2 a21 a22 0 1 b2 0)            ; con2 ∩ x2=0
                          (list 0 0)))                            ; origin
             (feas (filter (lambda (x) (and (not (null? x)) (lp-feasible2? A b x))) cands)))
        (list (list 'status 'optimal)
              (list 'z (foldl (lambda (x best) (max best (lp-dot c x)))
                              (lp-dot c (car feas)) (cdr feas)))))))

;; ── Exhaustive cross-check: simplex ≡ brute over a tiny LP grid ───────────
;; For every (a11 a12 a21 a22 b1 b2) with c fixed, simplex and brute must agree:
;; same unbounded/optimal status and, when optimal, objective within ε.
(define (lp-status r) (lp-cert-get r 'status))
(define (verify-simplex-agrees c a-domain b-domain)
  (check-exhaustive
    (lambda (a11 a12 a21 a22 b1 b2)
      (let* ((A (list (list a11 a12) (list a21 a22)))
             (b (list b1 b2))
             (rs (lp-simplex A b c))
             (rb (lp-brute A b c)))
        (if (equal? (lp-status rb) 'unbounded)
            (equal? (lp-status rs) 'unbounded)
            (and (equal? (lp-status rs) 'optimal)
                 (< (abs (- (lp-cert-get rs 'z) (lp-cert-get rb 'z))) (/ 1 1000))))))
    (list a-domain a-domain a-domain a-domain b-domain b-domain)))

;; The false claim "every optimum is 0" must be refused with a witness LP.
(define (verify-simplex-wrong c a-domain b-domain)
  (check-exhaustive
    (lambda (a11 a12 a21 a22 b1 b2)
      (let ((r (lp-simplex (list (list a11 a12) (list a21 a22)) (list b1 b2) c)))
        (if (equal? (lp-status r) 'unbounded) #t
            (< (abs (lp-cert-get r 'z)) *lp-eps*))))
    (list a-domain a-domain a-domain a-domain b-domain b-domain)))
