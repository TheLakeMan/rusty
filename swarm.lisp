;; swarm.lisp — Phase 3.2 deliverable: a multi-agent system where agents
;; coordinate SYMBOLIC REASONING through message passing alone.
;;
;;   proposer  --(verify name source)-->  verifier  --(certified ...)--> certifier
;;      ^                                    |
;;      +------(propose name feedback)-------+   rejected: feedback loops back
;;
;; The verifier's brain is the Phase 2 proof machinery: static gates first
;; (check-effects, check-types — the candidate is REJECTED WITHOUT EVER
;; RUNNING if it has side effects), then check-exhaustive over the spec's
;; finite domains. The proposer here is scripted (deterministic — this file
;; is a golden test, see run_tests.sh); swap `pop-candidate` for a call to
;; `llm-proposer` (std.lisp) to drive the same swarm from a live local
;; model. Every hop is observable via (trace-on), and the whole system
;; checkpoints mid-flight like any other actor state ((checkpoint "f.lisp"),
;; since handlers keep their state in globals).

;; ── Specs: what the swarm must synthesize ────────────────────────────────
(define abs-spec
  (list (list 'pure #t)
        (list 'domains (list (list -3 -1 0 2 5)))
        (list 'invariant
              (lambda (f x) (and (>= (f x) 0)
                                 (or (= (f x) x) (= (f x) (- 0 x))))))))

(define max-spec
  (list (list 'pure #t)
        (list 'domains (list (list -2 0 3) (list -1 1 4)))
        (list 'invariant
              (lambda (f a b) (and (>= (f a b) a) (>= (f a b) b)
                                   (or (= (f a b) a) (= (f a b) b)))))))

(define *swarm-specs*
  (list (list 'abs-fn abs-spec)
        (list 'max-fn max-spec)))

;; ── Scripted proposer state: candidate queues, flawed attempts first ────
;; abs-fn attempt 1 prints (impure → static reject, never executed),
;; attempt 2 is wrong on negatives (counterexample), attempt 3 is right.
(define *candidates*
  (list (list 'abs-fn (list "(lambda (x) (begin (print x) x))"
                            "(lambda (x) x)"
                            "(lambda (x) (if (< x 0) (- 0 x) x))"))
        (list 'max-fn (list "(lambda (a b) (+ a b))"
                            "(lambda (a b) (if (> a b) a b))"))))

(define *attempts*  '())   ; (name count)
(define *certified* '())   ; (name source fn attempts)

(define (alist-update alist name v)
  (map (lambda (p) (if (equal? (car p) name) (list name v) p)) alist))

(define (attempts-of name)
  (let ((e (assoc name *attempts*))) (if e (cadr e) 0)))

(define (bump-attempts name)
  (if (assoc name *attempts*)
      (set! *attempts* (alist-update *attempts* name (+ (attempts-of name) 1)))
      (set! *attempts* (cons (list name 1) *attempts*))))

(define (pop-candidate name)
  (let ((e (assoc name *candidates*)))
    (if (and e (not (null? (cadr e))))
        (let ((next (car (cadr e))))
          (set! *candidates* (alist-update *candidates* name (cdr (cadr e))))
          next)
        #f)))

;; ── The agents ───────────────────────────────────────────────────────────
(agent-spawn 'proposer
  (lambda (msg)                       ; (propose spec-name feedback)
    (let ((name (cadr msg)))
      (let ((src (pop-candidate name)))
        (if src
            (begin
              (bump-attempts name)
              (print (list 'proposer name 'attempt (attempts-of name)))
              (send! 'verifier (list 'verify name src)))
            (begin
              (print (list 'proposer name 'out-of-candidates))
              (send! 'certifier (list 'failed name (caddr msg)))))))))

(agent-spawn 'verifier
  (lambda (msg)                       ; (verify spec-name source)
    (let ((name (cadr msg)) (src (caddr msg)))
      (let ((spec (cadr (assoc name *swarm-specs*)))
            (f (try-catch (eval-string src) (e) e)))
        (let ((result (verify-candidate f spec)))
          (if (equal? result 'verified)
              (begin
                (print (list 'verifier name 'accepted))
                (send! 'certifier (list 'certified name src f)))
              (begin
                (print (list 'verifier name 'rejected (car (car result))))
                (send! 'proposer (list 'propose name result)))))))))

(agent-spawn 'certifier
  (lambda (msg)                       ; (certified name src fn) | (failed name fb)
    (if (equal? (car msg) 'certified)
        (let ((name (cadr msg)))
          (set! *certified*
                (cons (list name (caddr msg) (cadddr msg) (attempts-of name))
                      *certified*))
          (print (list 'certifier name 'recorded 'attempts (attempts-of name))))
        (print (list 'certifier (cadr msg) 'FAILED)))))

;; ── Run the swarm, fully traced ──────────────────────────────────────────
(trace-on)
(send! 'proposer (list 'propose 'abs-fn '()))
(send! 'proposer (list 'propose 'max-fn '()))
(print (run-agents))
(trace-off)

;; ── The synthesized functions actually work ─────────────────────────────
(define (certified-fn name) (caddr (assoc name *certified*)))
(print (list 'abs-of -7 '= ((certified-fn 'abs-fn) -7)))
(print (list 'abs-of 4 '= ((certified-fn 'abs-fn) 4)))
(print (list 'max-of 3 9 '= ((certified-fn 'max-fn) 3 9)))
(print (list 'max-of -1 -5 '= ((certified-fn 'max-fn) -1 -5)))

;; ── Coordination was observable end to end ──────────────────────────────
(define tr (trace-report))
(define (count-kind k)
  (length (filter (lambda (e) (equal? (nth e 2) k)) tr)))
(print (list 'trace 'sends (count-kind 'send) 'handled (count-kind 'agent-handle)))
(print "SWARM COMPLETE")
