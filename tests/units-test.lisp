;;; Copyright (c) 2026 Nicholas Vermeulen
;;; SPDX-License-Identifier: AGPL-3.0-or-later

;; units-test.lisp — golden test for units.lisp.
;; A known-answer table for the dimensional walker: legal expressions derive
;; the expected unit (as a recognized name or a raw exponent vector), illegal
;; ones surface an (unit-error …) as data. Plus a check-exhaustive proof that
;; a unit conversion round-trips. Symbols/integers only — deterministic.

(load "units.lisp")

;; ── Legal expressions derive the right dimension ─────────────────────────
(print (list 'velocity (unit-of '(/ m s))))              ; (0 1 -1 …)
(print (list 'area     (unit-name (unit-of '(* m m)))))  ; vector (0 2 0 …)
(print (list 'expt-area (unit-name (unit-of '(expt m 2)))))
(print (list 'force    (unit-name (unit-of '(/ (* kg m) (* s s))))))   ; -> N
(print (list 'energy   (unit-name (unit-of '(* (/ (* kg m) (* s s)) m))))) ; N·m -> J
(print (list 'kinetic  (unit-name (unit-of '(* kg (* (/ m s) (/ m s))))))) ; kg·v² -> J
(print (list 'sqrt-area (unit-name (unit-of '(sqrt (* m m))))))            ; -> m
(print (list 'dimensionless-sin (unit-of '(sin (/ m m)))))                 ; (0 0 0 …)

;; ── Variables carry declared dimensions through the walk ─────────────────
(print (list 'distance/time
             (unit-name (check-units '(/ d t) (unit-env '((d m) (t s)))))))

;; ── Illegal expressions are refused as DATA (never a raise) ──────────────
(print (list 'refuse-add       (unit-of '(+ m s))))
(print (list 'refuse-sin-metre (unit-of '(sin m))))
(print (list 'refuse-sqrt-odd  (unit-of '(sqrt m))))
(print (list 'refuse-if-branch (unit-of '(if 1 m s))))
(print (list 'refuse-unknown   (unit-of '(* m foo))))

;; ── The gate is boolean too, for placing before check-exhaustive/defrust ─
(print (list 'ok-velocity  (units-ok? '(/ m s) '())
             'bad-add       (units-ok? '(+ m s) '())))

;; ── Conversion: a value converts, an incompatible one is refused, and the
;; round-trip is EXHAUSTIVELY proven over an integer grid. ─────────────────
(print (list 'convert-5m->mm (convert 5 'm 'mm)
             'incompatible   (convert 5 'm 's)))
(print (list 'roundtrip-verified (convert-roundtrip-verified 'm 'mm (range 0 21))))

(print "UNITS TESTS DONE")
