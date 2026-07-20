;;; Copyright (c) 2026 Nicholas Vermeulen
;;; SPDX-License-Identifier: AGPL-3.0-or-later

;; fsm.lisp — verified finite-state machines. Pure Lisp, zero
;; interpreter changes, same library pattern as robot.lisp / prover.lisp.
;;
;; An FSM is DATA: a list of states, a list of events (the alphabet), a
;; list of `(from event to)` transition triples, and a start state. The
;; environment — not the machine — chooses which event fires, so unlike
;; robot.lisp (one controller action per state) an FSM BRANCHES: every
;; event is a possible successor. That branching is exactly what the two
;; verification methods here handle.
;;
;; SAFETY, two independent exact methods over the DECLARED domain:
;;
;;   (fsm-verify-invariant fsm inv?)  — the inductive step, discharged by
;;   check-exhaustive over states×events:  inv?(s) ⇒ inv?(step(s,e)) for
;;   every state s and every event e. With "the start state is safe",
;;   induction gives: the machine never leaves the inv? set. Proven on the
;;   declared state×event product, per the bounded-verification rule.
;;
;;   (fsm-verify-unreachable fsm bad?)  — a COMPLETE breadth-first search
;;   of the transition graph from the start state. Finite state set ⇒ BFS
;;   visits every reachable state exactly once, so "no reachable state is
;;   bad?" is exact, not sampled. Returns the bad reachable states as
;;   witnesses if the claim fails.
;;
;; The two can disagree instructively: an invariant that isn't inductive
;; still fails (1), yet its bad states may be unreachable and pass (2), or
;; vice-versa. Neither is "safe" in general — both are proven only over the
;; transitions, states and events you DECLARE. A transition missing from
;; the table, or an event outside the alphabet, is outside the claim.

;; ── Construction + accessors (an FSM is plain, inspectable data) ─────────
(define (fsm-make states events transitions start)
  (list 'fsm states events transitions start))
(define (fsm-states fsm)      (cadr fsm))
(define (fsm-events fsm)      (caddr fsm))
(define (fsm-transitions fsm) (cadddr fsm))
(define (fsm-start fsm)       (nth fsm 4))

;; ── Stepping. Partial FSMs are allowed: an undefined (state,event) yields
;; the sentinel 'fsm-stuck (no transition taken), never an error. ─────────
(define (fsm-step fsm state event)
  (let ((tr (find (lambda (t) (and (equal? (car t) state)
                                   (equal? (cadr t) event)))
                  (fsm-transitions fsm))))
    (if tr (caddr tr) 'fsm-stuck)))

;; Every next-state reachable from `state` in one step, over ANY event
;; (the environment's choice) — deduped. Drives the BFS below.
(define (fsm-successors fsm state)
  (remove-duplicates
    (map caddr
         (filter (lambda (t) (equal? (car t) state))
                 (fsm-transitions fsm)))))

;; ── Structural properties ───────────────────────────────────────────────
;; Deterministic: no (from,event) pair maps to two distinct `to`.
(define (fsm-deterministic? fsm)
  (all? (lambda (t)
          (all? (lambda (u)
                  (or (not (and (equal? (car u) (car t))
                                (equal? (cadr u) (cadr t))))
                      (equal? (caddr u) (caddr t))))
                (fsm-transitions fsm)))
        (fsm-transitions fsm)))

;; Complete: every (state,event) in the declared domain has a transition.
(define (fsm-complete? fsm)
  (all? (lambda (s)
          (all? (lambda (e) (not (equal? (fsm-step fsm s e) 'fsm-stuck)))
                (fsm-events fsm)))
        (fsm-states fsm)))

;; ── Reachability: complete BFS from the start over the finite graph ──────
(define (fsm-reachable fsm)
  (let loop ((frontier (list (fsm-start fsm))) (visited '()))
    (if (null? frontier)
        (reverse visited)
        (let ((s (car frontier)))
          (if (member s visited)                    ; #f (only false) or tail
              (loop (cdr frontier) visited)
              (loop (append (cdr frontier) (fsm-successors fsm s))
                    (cons s visited)))))))

(define (fsm-reaches? fsm target)
  (if (member target (fsm-reachable fsm)) #t #f))

;; ── Verification ─────────────────────────────────────────────────────────
;; (1) The inductive step, exhaustively checked over states×events.
;; A stuck (state,event) takes no transition, so it can't violate anything
;; — vacuously #t. inv? must be a boolean predicate (check-exhaustive is
;; boolean-strict since 0.62.1: a non-boolean return is a named
;; counterexample, never a silent pass).
(define (fsm-verify-invariant fsm inv?)
  (check-exhaustive
    (lambda (state event)
      (let ((next (fsm-step fsm state event)))
        (if (equal? next 'fsm-stuck)
            #t
            (implies (inv? state) (inv? next)))))
    (list (fsm-states fsm) (fsm-events fsm))))

;; (2) Bad-state unreachability, exact via the complete BFS. 'verified if
;; no reachable state is bad?, else the bad reachable states as witnesses.
(define (fsm-verify-unreachable fsm bad?)
  (let ((bad-reachable (filter bad? (fsm-reachable fsm))))
    (if (null? bad-reachable) 'verified bad-reachable)))

;; A safety verdict as DATA (mirrors shouzhong's certify-report): both
;; methods' verdicts, the reachable-state count, and the domain size that
;; makes the bounded claim countable.
(define (fsm-safety-report fsm inv? bad?)
  (list 'fsm-safety-report
        'inductive       (fsm-verify-invariant fsm inv?)
        'bad-unreachable (fsm-verify-unreachable fsm bad?)
        'reachable-count (length (fsm-reachable fsm))
        'domain-size     (* (length (fsm-states fsm))
                            (length (fsm-events fsm)))))
