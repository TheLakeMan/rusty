;;; Copyright (c) 2026 Nicholas Vermeulen
;;; SPDX-License-Identifier: AGPL-3.0-or-later

;; fsm-test.lisp — golden test for fsm.lisp.
;; A microwave interlock FSM. State = (door heater), door ∈ {closed open},
;; heater ∈ {off on}; events = start stop open-door close-door. Everything
;; is a symbol pair (equal?-comparable), the whole state space is 2×2 and
;; the alphabet is 4, so both verification methods run exhaustively.
;; The SAFETY property: never heating with the door open — (open on) is the
;; bad state. Deterministic; no timings, no randomness.

(load "fsm.lisp")
(load "prover.lisp")

;; ── The safe machine: opening the door FORCES the heater off (interlock),
;; and the heater refuses to start while the door is open. ────────────────
(define microwave-states  '((closed off) (closed on) (open off) (open on)))
(define microwave-events  '(start stop open-door close-door))
(define microwave-trans
  '(((closed off) start      (closed on))
    ((closed off) stop       (closed off))
    ((closed off) open-door  (open off))
    ((closed off) close-door (closed off))
    ((closed on)  start      (closed on))
    ((closed on)  stop       (closed off))
    ((closed on)  open-door  (open off))    ; INTERLOCK: door opening kills heat
    ((closed on)  close-door (closed on))
    ((open off)   start      (open off))    ; refuse to heat with door open
    ((open off)   stop       (open off))
    ((open off)   open-door  (open off))
    ((open off)   close-door (closed off))))
(define oven (fsm-make microwave-states microwave-events microwave-trans '(closed off)))

;; The safety predicates.
(define (heating-open? s) (and (equal? (car s) 'open) (equal? (cadr s) 'on)))
(define (safe? s)         (not (heating-open? s)))

;; ── Structure ─────────────────────────────────────────────────────────────
(print (list 'deterministic (fsm-deterministic? oven)
             'step-interlock (fsm-step oven '(closed on) 'open-door)))

;; ── Reachability: the bad state is never reached from the start ──────────
(print (list 'reachable (fsm-reachable oven)))
(print (list 'reaches-open-off (fsm-reaches? oven '(open off))
             'reaches-bad      (fsm-reaches? oven '(open on))))

;; ── Both proofs pass for the safe machine ────────────────────────────────
(print (list 'inductive       (fsm-verify-invariant oven safe?)))
(print (list 'bad-unreachable (fsm-verify-unreachable oven heating-open?)))
(print (fsm-safety-report oven safe? heating-open?))

;; ...and the inductive step as a REGISTERED THEOREM via the 4.3 prover.
(print (defproof microwave-interlock
         (forall ((door (closed open)) (heater (off on)))
           (implies (safe? (list door heater))
                    (or (equal? (fsm-step oven (list door heater) 'start) 'fsm-stuck)
                        (safe? (fsm-step oven (list door heater) 'start)))))
         (auto)))

;; ── A buggy machine: the interlock is removed, so opening the door while
;; heating leaves the heater ON — (open on) becomes reachable. BOTH methods
;; catch it, each with a witness. ─────────────────────────────────────────
(define bad-trans
  (cons '((closed on) open-door (open on))          ; no interlock
        (filter (lambda (t) (not (and (equal? (car t) '(closed on))
                                      (equal? (cadr t) 'open-door))))
                microwave-trans)))
(define bad-oven (fsm-make microwave-states microwave-events bad-trans '(closed off)))

(define bad-induction (fsm-verify-invariant bad-oven safe?))
(print (list 'buggy-inductive-rejected (not (equal? bad-induction 'verified))
             'inductive-witness (car bad-induction)))
(print (list 'buggy-bad-reachable (fsm-verify-unreachable bad-oven heating-open?)))

;; ── The verifier is not a rubber stamp on structure either: a
;; nondeterministic table is detected. ────────────────────────────────────
(define nd-oven
  (fsm-make microwave-states microwave-events
            (cons '((closed off) start (closed off)) microwave-trans)   ; two `to` for one (from,event)
            '(closed off)))
(print (list 'nondeterministic-detected (not (fsm-deterministic? nd-oven))
             'safe-oven-complete (fsm-complete? oven)))

(print "FSM TESTS DONE")
