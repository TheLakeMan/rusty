;;; Copyright (c) 2026 Nicholas Vermeulen
;;; SPDX-License-Identifier: AGPL-3.0-or-later

;; signal-test.lisp — golden test for signal.lisp.
;; DFT / FFT / circular convolution with EXACT identities at N=4, where the
;; twiddles (4th roots of unity) are integers — everything printed is an exact
;; integer or a verdict. The only libm (N=8 trig twiddles) lives inside one
;; epsilon-comparison and prints as a boolean.

(load "signal.lisp")

;; ── Known-answer spectra (all integer-exact) ──────────────────────────────
(print (list 'impulse     (dft-real (list 1 0 0 0))))     ; flat spectrum
(print (list 'constant    (dft-real (list 1 1 1 1))))     ; all energy in bin 0
(print (list 'alternating (dft-real (list 1 -1 1 -1))))   ; all energy in bin 2
;; FFT computes the identical exact values.
(print (list 'fft4 (fft-real (list 3 -1 2 5))))
;; Circular convolution known-answer.
(print (list 'conv (circ-conv (list 1 2 0 0) (list 1 1 0 0))))

;; ── Exhaustive exact identities over the {-1,0,1}⁴ vector grid ────────────
(print (list 'roundtrip-verified (verify-roundtrip (list -1 0 1))))   ; idft∘dft = id
(print (list 'parseval-verified  (verify-parseval  (list -1 0 1))))   ; Σ|X|² = 4·Σx²
;; Parseval WITHOUT the factor N is refused — every nonzero-energy vector is
;; a witness (80 of 81; the zero vector genuinely passes).
(define pw (verify-parseval-wrong (list -1 0 1)))
(print (list 'parseval-wrong-refuted 'count (length pw) 'first (car pw)))
(print (list 'fft-eq-dft-verified (verify-fft-dft (list -1 0 1))))    ; exact, both integer

;; ── Convolution theorem over the full x×y product {0,1}⁸ (256 pairs) ──────
(print (list 'conv-theorem-verified (verify-conv-theorem (list 0 1))))

;; ── N=8: FFT agrees with naive DFT within 1e-9 (libm stays a boolean) ─────
(print (list 'fft8-matches-dft (fft-matches-dft-8? (list 1 2 0 -1 3 0 1 -2) (/ 1 1000000000))))

(print "SIGNAL TESTS DONE")
