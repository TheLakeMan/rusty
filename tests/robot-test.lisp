;;; Copyright (c) 2026 Nicholas Vermeulen
;;; SPDX-License-Identifier: AGPL-3.0-or-later

;; robot-test.lisp — golden test for robot.lisp (Phase 4.4).
;; A 1-D corridor robot: position 0..20 (walls outside), velocity -2..2,
;; action = acceleration in {-1,0,1}. Everything integer → exact, and the
;; whole state space is small enough to check exhaustively. Deterministic.

(load "robot.lisp")
(load "prover.lisp")

;; ── World ─────────────────────────────────────────────────────────────────
(define (clamp v lo hi) (max lo (min hi v)))
(define (world-step s a)
  (let ((pos (car s)) (vel (cadr s)))
    (let ((v2 (clamp (+ vel a) -2 2)))
      (list (+ pos v2) v2))))

;; Safety: inside the corridor AND stoppable before a wall. Braking from
;; |vel|=2 travels one more cell (vel passes through 1) — that overshoot
;; is the brake-travel term; anything less stops in place.
(define (brake-travel v) (cond ((= v 2) 1) ((= v -2) -1) (else 0)))
(define (safe? s)
  (let ((pos (car s)) (vel (cadr s)))
    (and (>= pos 0) (<= pos 20)
         (>= (+ pos (brake-travel vel)) 0)
         (<= (+ pos (brake-travel vel)) 20))))

;; ── Controller: head for the target, brake guard wins over ambition ─────
(define target 15)
(define (controller s)
  (let ((pos (car s)) (vel (cadr s)))
    (let ((ambition (clamp (- (clamp (- target pos) -2 2) vel) -1 1)))
      (let ((try (world-step s ambition)))
        (if (safe? try)
            ambition
            (clamp (- 0 vel) -1 1))))))   ; can't have that: brake toward 0

;; ── The robot drives, deterministically, within its tick budget ─────────
(define run
  (control-until world-step controller '(0 0)
                 (lambda (s) (and (= (car s) target) (= (cadr s) 0)))
                 100 50000))
(print run)

;; full trajectory of a fixed 12-tick run from the far wall
(define run2 (control-loop world-step controller '(20 -2) 12 50000))
(print (list 'from-far-wall 'final (cadr run2)
             'positions (map car (nth run2 7))))

;; ── Safety, exhaustively verified over the WHOLE state space ────────────
(define all-pos '(0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20))
(define all-vel '(-2 -1 0 1 2))

;; actuator bounds: |action| <= 1 from EVERY state, safe or not
(print (list 'actuation
             (verify-actuation controller
                               (lambda (a) (and (>= a -1) (<= a 1)))
                               (list all-pos all-vel))))

;; the inductive step: safe stays safe, one tick at a time
(print (list 'inductive-step
             (verify-controller world-step controller safe?
                                (list all-pos all-vel))))

;; ...and as a REGISTERED THEOREM via the 4.3 prover
(print (defproof corridor-safety
         (forall ((pos (0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20))
                  (vel (-2 -1 0 1 2)))
           (implies (safe? (list pos vel))
                    (safe? (world-step (list pos vel)
                                       (controller (list pos vel))))))
         (auto)))

;; initial state safe + inductive step = never leaves the safe set
(print (list 'initial-safe (safe? '(0 0))))

;; ── The verifier is not a rubber stamp: a reckless controller fails ──────
(define (reckless s) 1)   ; full throttle, always
(define r-bad (verify-controller world-step reckless safe? (list all-pos all-vel)))
(print (list 'reckless-rejected (not (equal? r-bad 'verified))
             'first-counterexample (car r-bad)))

(print "ROBOT TESTS DONE")
