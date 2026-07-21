;;; Copyright (c) 2026 Nicholas Vermeulen
;;; SPDX-License-Identifier: AGPL-3.0-or-later

;; signal.lisp — DFT / radix-2 FFT / circular convolution with EXACT verified
;; identities on exact-twiddle sizes. Pure Lisp, zero interpreter changes.
;;
;; Complex numbers are `(re im)` lists. The twiddle factors W_N^k = e^(-2πik/N)
;; are EXACT INTEGERS for N ∈ {1, 2, 4} (the 4th roots of unity: 1, -i, -1, i),
;; so at N=4 the whole transform is integer arithmetic — round-trip, Parseval,
;; the convolution theorem, and FFT≡DFT are all provable by check-exhaustive
;; with exact `=` over declared entry grids. No epsilon, no trig.
;;
;; For other N the twiddles need sin/cos — libm. DOCUMENTED BOUNDARY: any
;; libm-twiddle result must stay inside an epsilon-comparison (a boolean),
;; NEVER printed — a 1-ULP platform difference in sin/cos would otherwise
;; break golden portability (same rule as ode.lisp's exp).
;;
;; CLAIM DISCIPLINE: "these DFT identities hold EXACTLY for every vector over
;; the declared entry grid at the declared exact-twiddle size", and "FFT
;; agrees with the naive DFT within ε on this fixture at N=8". NEVER
;; "DSP-correct", never a claim about audio, windows, or general N.

;; ── Complex helpers ───────────────────────────────────────────────────────
(define (c-re z) (car z))
(define (c-im z) (cadr z))
(define (c+ a b) (list (+ (c-re a) (c-re b)) (+ (c-im a) (c-im b))))
(define (c- a b) (list (- (c-re a) (c-re b)) (- (c-im a) (c-im b))))
(define (c* a b) (list (- (* (c-re a) (c-re b)) (* (c-im a) (c-im b)))
                       (+ (* (c-re a) (c-im b)) (* (c-im a) (c-re b)))))
(define (c-conj z) (list (c-re z) (- 0 (c-im z))))
(define (c-scale s z) (list (* s (c-re z)) (* s (c-im z))))
(define (c-abs2 z) (+ (* (c-re z) (c-re z)) (* (c-im z) (c-im z))))
(define (c-from-real x) (list x 0))
(define (reals->complex xs) (map c-from-real xs))

;; mod that is safe for negative a under either mod semantics.
(define (imod a n) (mod (+ (mod a n) n) n))

;; ── Twiddle factors W_N^k, k = 0..N-1 ─────────────────────────────────────
;; Exact for N ∈ {1,2,4}; trig (libm — ε-comparisons only) otherwise.
(define (dft-twiddles n)
  (cond ((= n 1) (list (list 1 0)))
        ((= n 2) (list (list 1 0) (list -1 0)))
        ((= n 4) (list (list 1 0) (list 0 -1) (list -1 0) (list 0 1)))
        (else
          (let ((pi4 (* 4 (atan 1))))
            (define (go k acc)
              (if (>= k n) (reverse acc)
                  (let ((th (/ (* 2 pi4 k) n)))
                    (go (+ k 1) (cons (list (cos th) (- 0 (sin th))) acc)))))
            (go 0 '())))))

;; ── Naive DFT / inverse DFT (input: list of complex) ──────────────────────
;; X_j = Σ_k x_k · W^(jk mod N)
(define (dft xs)
  (let* ((n (length xs)) (W (dft-twiddles n)))
    (define (coef j)
      (define (go k acc)
        (if (>= k n) acc
            (go (+ k 1) (c+ acc (c* (nth xs k) (nth W (imod (* j k) n)))))))
      (go 0 (list 0 0)))
    (define (rows j acc)
      (if (>= j n) (reverse acc) (rows (+ j 1) (cons (coef j) acc))))
    (rows 0 '())))

;; idft_j = (1/N) Σ_k X_k · conj(W^(jk mod N)) — conjugated table, no negative mod.
(define (idft Xs)
  (let* ((n (length Xs)) (W (dft-twiddles n)))
    (define (coef j)
      (define (go k acc)
        (if (>= k n) acc
            (go (+ k 1) (c+ acc (c* (nth Xs k) (c-conj (nth W (imod (* j k) n))))))))
      (go 0 (list 0 0)))
    (define (rows j acc)
      (if (>= j n) (reverse acc) (rows (+ j 1) (cons (c-scale (/ 1 n) (coef j)) acc))))
    (rows 0 '())))

(define (dft-real xs) (dft (reals->complex xs)))

;; ── Radix-2 FFT (N a power of 2) ──────────────────────────────────────────
(define (list-evens xs) (if (null? xs) '() (cons (car xs) (if (null? (cdr xs)) '() (list-evens (cddr xs))))))
(define (list-odds xs)  (if (or (null? xs) (null? (cdr xs))) '() (cons (cadr xs) (list-odds (cddr xs)))))

(define (fft xs)
  (let ((n (length xs)))
    (if (= n 1) xs
        (let* ((E (fft (list-evens xs)))
               (O (fft (list-odds xs)))
               (W (dft-twiddles n))
               (half (/ n 2)))
          (define (top j acc)                     ; X_j       = E_j + W^j·O_j
            (if (>= j half) (reverse acc)
                (top (+ j 1) (cons (c+ (nth E j) (c* (nth W j) (nth O j))) acc))))
          (define (bot j acc)                     ; X_{j+n/2} = E_j − W^j·O_j
            (if (>= j half) (reverse acc)
                (bot (+ j 1) (cons (c- (nth E j) (c* (nth W j) (nth O j))) acc))))
          (append (top 0 '()) (bot 0 '()))))))

(define (fft-real xs) (fft (reals->complex xs)))

;; ── Circular convolution (real vectors) ───────────────────────────────────
(define (circ-conv x y)
  (let ((n (length x)))
    (define (coef j)
      (define (go k acc)
        (if (>= k n) acc
            (go (+ k 1) (+ acc (* (nth x k) (nth y (imod (- j k) n)))))))
      (go 0 0))
    (define (rows j acc)
      (if (>= j n) (reverse acc) (rows (+ j 1) (cons (coef j) acc))))
    (rows 0 '())))

;; Energies for Parseval: Σ|X_j|² and Σ x_k² (real input).
(define (spec-energy Xs) (foldl (lambda (z acc) (+ acc (c-abs2 z))) 0 Xs))
(define (real-energy xs) (foldl (lambda (x acc) (+ acc (* x x))) 0 xs))

;; ── Exhaustive verification at N=4 (exact twiddles, exact =) ──────────────
;; (1) Round-trip: idft(dft(x)) reproduces x exactly for EVERY x over the grid.
(define (verify-roundtrip dom)
  (check-exhaustive
    (lambda (a b c d)
      (equal? (idft (dft-real (list a b c d)))
              (reals->complex (list a b c d))))
    (list dom dom dom dom)))

;; (2) Parseval: Σ|X|² = N·Σx² exactly, for every x over the grid.
(define (verify-parseval dom)
  (check-exhaustive
    (lambda (a b c d)
      (let ((x (list a b c d)))
        (= (spec-energy (dft-real x)) (* 4 (real-energy x)))))
    (list dom dom dom dom)))

;; The wrong claim (Parseval WITHOUT the factor N) must be refused — every
;; nonzero-energy vector is a witness; the zero vector genuinely passes.
(define (verify-parseval-wrong dom)
  (check-exhaustive
    (lambda (a b c d)
      (let ((x (list a b c d)))
        (= (spec-energy (dft-real x)) (real-energy x))))
    (list dom dom dom dom)))

;; (3) FFT ≡ naive DFT exactly (both integer arithmetic at N=4).
(define (verify-fft-dft dom)
  (check-exhaustive
    (lambda (a b c d)
      (equal? (fft-real (list a b c d)) (dft-real (list a b c d))))
    (list dom dom dom dom)))

;; (4) Convolution theorem: dft(x ⊛ y) = dft(x)·dft(y) pointwise, exactly,
;; for every x,y over the grid (8 domains — the full x×y product).
(define (c-zipmul as bs)
  (if (null? as) '() (cons (c* (car as) (car bs)) (c-zipmul (cdr as) (cdr bs)))))
(define (verify-conv-theorem dom)
  (check-exhaustive
    (lambda (x0 x1 x2 x3 y0 y1 y2 y3)
      (let ((x (list x0 x1 x2 x3)) (y (list y0 y1 y2 y3)))
        (equal? (dft-real (circ-conv x y))
                (c-zipmul (dft-real x) (dft-real y)))))
    (list dom dom dom dom dom dom dom dom)))

;; ── N=8: FFT agrees with naive DFT within ε (libm twiddles — boolean only) ─
(define (fft-matches-dft-8? xs eps)
  (let ((F (fft-real xs)) (D (dft-real xs)))
    (all? (lambda (i)
            (let ((f (nth F i)) (d (nth D i)))
              (and (< (abs (- (c-re f) (c-re d))) eps)
                   (< (abs (- (c-im f) (c-im d))) eps))))
          (list 0 1 2 3 4 5 6 7))))
