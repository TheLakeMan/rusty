;;; Copyright (c) 2026 Nicholas Vermeulen
;;; SPDX-License-Identifier: AGPL-3.0-or-later

;; linalg.lisp — dense LU-style Gaussian elimination: determinant, linear
;; solve, and residual, on small matrices. Pure Lisp, zero interpreter
;; changes. No BLAS, no external anything.
;;
;; Matrices are lists-of-rows (row-major); vectors are lists. Elimination uses
;; PARTIAL PIVOTING (largest-magnitude pivot in the column). A zero pivot is a
;; NAMED certificate `(status pivot-failure) (row k)` — never a silent NaN.
;; Results are alist certificates: `(status ok) (det D)` / `(status ok) (x V)`.
;;
;; DETERMINISM / PORTABILITY — `/` is float division (not rational), so choose
;; fixtures whose elimination stays on EXACT dyadic values (pivots ±1/±2,
;; triangular systems) — then dets/residuals are exact and the golden is
;; bit-portable. The exhaustive det check runs over entries in {-1,0,1,2}
;; precisely because every pivot there is ±1 or ±2, so `/` is exact and the
;; float det equals the integer formula exactly. Off that domain (e.g. a pivot
;; of 3 → 1/3) results are still IEEE-deterministic but no longer integer-exact,
;; so residual checks would need an epsilon — never print such a float.
;;
;; CLAIM DISCIPLINE — the caveat is the crack:
;;   "det matches the 2×2 formula for EVERY entry grid in {-1,0,1,2}"
;;   "residual ‖Ax−b‖ = 0 for every b in the declared grid, for this A"
;; NEVER "numerically stable", NEVER "correct for ill-conditioned systems".
;; Everything proven is on tiny finite grids with exact arithmetic.

;; ── List / matrix helpers ─────────────────────────────────────────────────
(define (set-nth lst i v)
  (if (= i 0) (cons v (cdr lst)) (cons (car lst) (set-nth (cdr lst) (- i 1) v))))
(define (zeros n) (if (= n 0) '() (cons 0 (zeros (- n 1)))))
(define (m-rows A) (length A))
(define (m-ref A i j) (nth (nth A i) j))
(define (m-row A i) (nth A i))
(define (m-set-row A i row) (set-nth A i row))
(define (m-swap A i j)
  (if (= i j) A
      (let ((ri (m-row A i)) (rj (m-row A j)))
        (m-set-row (m-set-row A i rj) j ri))))

;; row + s*other, elementwise (works on augmented rows of any length).
(define (row-axpy a b s)
  (if (null? a) '() (cons (+ (car a) (* s (car b))) (row-axpy (cdr a) (cdr b) s))))

;; Index of the largest-|value| entry in column k among rows k..n-1.
(define (pivot-row M k n)
  (define (go i best bi)
    (if (>= i n) bi
        (let ((v (abs (m-ref M i k))))
          (if (> v best) (go (+ i 1) v i) (go (+ i 1) best bi)))))
  (go k (abs (m-ref M k k)) k))

;; Zero out column k below the pivot row: for each i>k, row_i += -(M[i][k]/piv)·row_k.
;; Operates on all columns present (so it also transforms an augmented b column).
(define (eliminate-below M k n)
  (let ((piv (m-ref M k k)) (rowk (m-row M k)))
    (define (go i M2)
      (if (>= i n) M2
          (let* ((f (/ (m-ref M2 i k) piv))
                 (newrow (row-axpy (m-row M2 i) rowk (- 0 f))))
            (go (+ i 1) (m-set-row M2 i newrow)))))
    (go (+ k 1) M)))

;; ── Certificate accessors ─────────────────────────────────────────────────
(define (la-get c k) (let ((e (assoc k c))) (if e (cadr e) #f)))
(define (la-status c) (la-get c 'status))

;; ── Determinant (partial-pivot Gaussian elimination) ──────────────────────
;; det = det-sign · Π pivots. Zero pivot ⇒ pivot-failure (matrix is singular).
(define (mat-det A)
  (let ((n (m-rows A)))
    (define (go k M sign acc)
      (if (>= k n)
          (list (list 'status 'ok) (list 'det (* sign acc)))
          (let ((p (pivot-row M k n)))
            (if (= (m-ref M p k) 0)
                (list (list 'status 'pivot-failure) (list 'row k))
                (let* ((M1   (m-swap M k p))
                       (sgn1 (if (= p k) sign (- 0 sign)))
                       (pivk (m-ref M1 k k)))
                  (go (+ k 1) (eliminate-below M1 k n) sgn1 (* acc pivk)))))))
    (go 0 A 1 1)))

;; ── Linear solve  A x = b  (augmented elimination + back-substitution) ────
(define (augment A b)
  (if (null? A) '()
      (cons (append (car A) (list (car b))) (augment (cdr A) (cdr b)))))

(define (mat-solve A b)
  (let ((n (m-rows A)))
    (define (fwd k M)
      (if (>= k n) (list 'ok M)
          (let ((p (pivot-row M k n)))
            (if (= (m-ref M p k) 0) (list 'pivot-failure k)
                (fwd (+ k 1) (eliminate-below (m-swap M k p) k n))))))
    ;; back-substitute the upper-triangular augmented matrix U|c (n+1 cols).
    (define (back M)
      (define (sum-tail i j acc x)
        (if (>= j n) acc
            (sum-tail i (+ j 1) (+ acc (* (m-ref M i j) (nth x j))) x)))
      (define (go i x)
        (if (< i 0) x
            (let ((xi (/ (- (m-ref M i n) (sum-tail i (+ i 1) 0 x)) (m-ref M i i))))
              (go (- i 1) (set-nth x i xi)))))
      (go (- n 1) (zeros n)))
    (let ((r (fwd 0 (augment A b))))
      (if (equal? (car r) 'pivot-failure)
          (list (list 'status 'pivot-failure) (list 'row (cadr r)))
          (list (list 'status 'ok) (list 'x (back (cadr r))))))))

;; ── Residual ‖Ax−b‖₁ ──────────────────────────────────────────────────────
(define (linalg-dot a b) (if (or (null? a) (null? b)) 0 (+ (* (car a) (car b)) (linalg-dot (cdr a) (cdr b)))))
(define (mat-vec A x) (map (lambda (row) (linalg-dot row x)) A))
(define (vec-sub a b) (if (null? a) '() (cons (- (car a) (car b)) (vec-sub (cdr a) (cdr b)))))
(define (vec-norm1 v) (foldl (lambda (x acc) (+ acc (abs x))) 0 v))
(define (residual A x b) (vec-norm1 (vec-sub (mat-vec A x) b)))

;; ── Exhaustive verification ───────────────────────────────────────────────
(define (det2 a b c d) (- (* a d) (* b c)))

;; (1) LU determinant equals the 2×2 closed form for EVERY matrix over the grid.
;; Singular matrices (pivot-failure) must have formula 0 — the honest match.
;; Exact over {-1,0,1,2} (pivots ±1/±2 → `/` exact). Real 4-D domain.
(define (verify-det2 domain)
  (check-exhaustive
    (lambda (a b c d)
      (let ((f (det2 a b c d)) (r (mat-det (list (list a b) (list c d)))))
        (if (equal? (la-status r) 'pivot-failure) (= f 0) (= (la-get r 'det) f))))
    (list domain domain domain domain)))

;; A deliberately wrong formula ("det is always 1") must be refused with a witness.
(define (verify-det2-wrong domain)
  (check-exhaustive
    (lambda (a b c d)
      (let ((r (mat-det (list (list a b) (list c d)))))
        (if (equal? (la-status r) 'pivot-failure) #t (= (la-get r 'det) 1))))
    (list domain domain domain domain)))

;; (2) Solve consistency: for a FIXED invertible A whose elimination stays exact,
;; every b in the grid solves with residual EXACTLY 0. Real 2-D domain over b.
(define (verify-solve-consistent A b-domain)
  (check-exhaustive
    (lambda (b0 b1)
      (let ((r (mat-solve A (list b0 b1))))
        (and (equal? (la-status r) 'ok)
             (= (residual A (la-get r 'x) (list b0 b1)) 0))))
    (list b-domain b-domain)))
