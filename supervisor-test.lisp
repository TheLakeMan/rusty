;; supervisor-test.lisp — golden test for supervisor.lisp (certifiable
;; supervision + isolation honesty + proven hot reload of a live agent).
;; Deterministic by design: no timings, no randomness, no LLM, no real
;; filesystem writes (the one file-write in here belongs to a TROJAN that
;; the static gate must refuse before it ever runs — the test then proves
;; the file does not exist).

(load "supervisor.lisp")
(load "evolve.lisp")

(display "── certify-policy: budget honesty by exhaustion ──") (newline)
(display (certify-policy '(one-for-one 3) (range 0 50))) (newline)
(display (certify-policy '(one-for-one 0) (range 0 50))) (newline)

(display "── crash → restart → budget exhaustion (one-for-one) ──") (newline)
;; worker: counts ticks, crashes on 'boom. sibling: pure accumulator that
;; must never notice the worker's lifecycle.
(define *sibling-log* '())
(define (make-worker)
  (let ((count 0))
    (lambda (msg)
      (if (equal? msg 'boom)
          (error "worker exploded")
          (set! count (+ count 1))))))
(define (make-sibling)
  (lambda (msg)
    (set! *sibling-log* (append *sibling-log* (list msg)))))

(supervise! (list (list 'worker make-worker)
                  (list 'sibling make-sibling))
            '(one-for-one 2))
(send! 'worker 'tick)
(send! 'worker 'boom)        ; crash 1 → restart (0 < 2)
(send! 'sibling 'alive-1)
(send! 'worker 'boom)        ; crash 2 → restart (1 < 2)
(send! 'worker 'boom)        ; crash 3 → give-up (2 >= 2)
(send! 'worker 'after-death) ; → dead letter
(send! 'sibling 'alive-2)
(display (run-supervised)) (newline)
(display (sup-report)) (newline)
(display (list 'receipts *sup-receipts*)) (newline)
(display (list 'sibling-saw *sibling-log*)) (newline)

(display "── restart resets state (fresh handler from init) ──") (newline)
;; 2 ticks, crash, 1 tick, report → sibling must see (count 1), not (count 3):
;; the two pre-crash ticks died with the old handler's state.
(define (make-counting-worker)
  (let ((count 0))
    (lambda (msg)
      (cond ((equal? msg 'boom) (error "kaboom"))
            ((equal? msg 'report) (send! 'sibling (list 'count count)))
            (else (set! count (+ count 1)))))))
(set! *sibling-log* '())
(supervise! (list (list 'worker make-counting-worker)
                  (list 'sibling make-sibling))
            '(one-for-one 2))
(send! 'worker 'tick)
(send! 'worker 'tick)
(send! 'worker 'boom)
(send! 'worker 'tick)
(send! 'worker 'report)
(display (run-supervised)) (newline)
(display (list 'sibling-saw *sibling-log*)) (newline)

(display "── init crash on restart → receipt + give-up, run survives ──") (newline)
;; init works once, then throws on every re-init: the restart itself fails.
;; Must become an init-crash receipt, never a dead supervisor.
(define *init-uses* 0)
(define (make-fragile)
  (begin
    (set! *init-uses* (+ *init-uses* 1))
    (if (> *init-uses* 1) (error "init exploded") #f)
    (lambda (msg) (if (equal? msg 'boom) (error "fragile crashed") #f))))
(supervise! (list (list 'fragile make-fragile)) '(one-for-one 5))
(send! 'fragile 'boom)
(send! 'fragile 'after)
(display (run-supervised)) (newline)
(display (sup-report)) (newline)
(display (list 'receipts *sup-receipts*)) (newline)

(display "── isolation honesty: refuse-by-default spawn from source ──") (newline)
(agent-reset!)
;; honest handler: sets only its owned name
(define *my-count* 0)
(display (agent-spawn-isolated 'honest
           '(lambda (msg) (set! *my-count* (+ *my-count* 1)))
           '(*my-count*) '()))
(newline)
;; trojan 1: set!s the scheduler's own mailboxes
(display (agent-spawn-isolated 'trojan-a
           '(lambda (msg) (set! *mailboxes* '()))
           '() '()))
(newline)
;; trojan 2: calls an undeclared effectful builtin
(display (agent-spawn-isolated 'trojan-b
           '(lambda (msg) (file-write "sup-evil-artifact.tmp" "gotcha"))
           '() '()))
(newline)
;; trojan 3: computed call — invokes a function smuggled inside the message;
;; every named piece (car) is whitelisted, only the call shape betrays it
(display (agent-spawn-isolated 'trojan-c
           '(lambda (msg) ((car msg)))
           '() '()))
(newline)
;; the honest handler actually runs; no trojan ever evaluated
(send! 'honest 'go)
(send! 'honest 'go)
(display (run-agents)) (newline)
(display (list 'my-count *my-count*)) (newline)

(display "── proven hot reload of a live supervised agent ──") (newline)
;; the handler goes through a NAMED global, so evolve! swaps behavior live:
;; no respawn, mailbox and restart budget intact, receipts in the kg.
(define (worker-math n)
  (if (= n 0) 0 (+ 2 (worker-math (- n 1)))))
(define (make-math-worker)
  (lambda (msg)
    (cond ((equal? msg 'boom) (error "math worker crashed"))
          ((equal? (car msg) 'compute)
           (send! 'collector (list 'result (worker-math (cadr msg))))))))
(define *collected* '())
(define (make-collector)
  (lambda (msg) (set! *collected* (append *collected* (list msg)))))

(supervise! (list (list 'mathw make-math-worker)
                  (list 'collector make-collector))
            '(one-for-one 1))
(send! 'mathw (list 'compute 3))
(display (run-supervised)) (newline)
(display (list 'before-evolve *collected*)) (newline)

;; reload 1: proven-equivalent replacement — accepted
(display (evolve! 'worker-math '(lambda (n) (* 2 n)) (list (range 0 21))))
(newline)
;; reload 2: trojan hiding a file write — refused STATICALLY, never runs
(display (evolve! 'worker-math
                  '(lambda (n) (begin (file-write "sup-evil-artifact.tmp" "gotcha")
                                      (* 2 n)))
                  (list (range 0 21))))
(newline)
(display (list 'trojan-ran (file-exists? "sup-evil-artifact.tmp"))) (newline)
;; reload 3: wrong at exactly one domain point — refused with the witness
(display (evolve! 'worker-math
                  '(lambda (n) (if (= n 13) 999 (* 2 n)))
                  (list (range 0 21))))
(newline)

;; the live agent now runs the evolved implementation — same mailbox,
;; same supervisor, no respawn
(send! 'mathw (list 'compute 4))
(display (run-supervised)) (newline)
(display (list 'after-evolve *collected*)) (newline)

;; supervision still works on the evolved agent: crash → restart → carry on
(send! 'mathw 'boom)
(send! 'mathw (list 'compute 5))
(display (run-supervised)) (newline)
(display (list 'after-crash *collected*)) (newline)
(display (sup-report)) (newline)

;; the name's full evolution history, queryable from the kg
(display (list 'kg-receipts (evolve-receipts 'worker-math))) (newline)

(display "── certify-strategy: restart-set semantics by exhaustion ──") (newline)
(display (certify-strategy 'one-for-one)) (newline)
(display (certify-strategy 'one-for-all)) (newline)
(display (certify-strategy 'rest-for-one)) (newline)

;; shared fixtures for the tree demos: named counters that report to a
;; collector living OUTSIDE the strategy's blast radius
(define *tree-collected* '())
(define (make-tree-collector)
  (lambda (msg) (set! *tree-collected* (append *tree-collected* (list msg)))))
(define (make-named-counter name)
  (lambda ()
    (let ((count 0))
      (lambda (msg)
        (cond ((equal? msg 'boom) (error "counter crashed"))
              ((equal? msg 'report) (send! 'collector (list name count)))
              (else (set! count (+ count 1))))))))

(display "── one-for-all: a crash re-inits every sibling under that sup ──") (newline)
(set! *tree-collected* '())
(supervise-tree!
  (list 'sup 'root '(one-for-one 1)
        (list 'worker 'collector make-tree-collector)
        (list 'sup 'pair '(one-for-all 2)
              (list 'worker 'a (make-named-counter 'a))
              (list 'worker 'b (make-named-counter 'b)))))
;; Phase boundaries make the proof exact: run-tree quiesces before the
;; crash, so every pre-crash tick is HANDLED, and any count seen after the
;; crash can only come from post-restart state. Without the boundary, a
;; still-queued tick would be processed by the fresh handler and the
;; post-crash count could not distinguish reset state from leftover queue
;; — that ambiguity is itself pinned as a negative control further down
;; ("mailboxes survive, state does not").
(send! 'a 'tick) (send! 'a 'tick) (send! 'b 'tick)
(send! 'a 'report) (send! 'b 'report)
(display (run-tree)) (newline)
(send! 'a 'boom)                 ; one-for-all → BOTH a and b reset
(display (run-tree)) (newline)
(send! 'a 'tick)
(send! 'a 'report) (send! 'b 'report)
(display (run-tree)) (newline)
(display (list 'collector-saw *tree-collected*)) (newline)  ; (a 2)(b 1) then (a 1)(b 0)
(display (tree-report)) (newline)

(display "── rest-for-one: crash resets the crashed child and later siblings ──") (newline)
(set! *tree-collected* '())
(supervise-tree!
  (list 'sup 'root '(one-for-one 1)
        (list 'worker 'collector make-tree-collector)
        (list 'sup 'row '(rest-for-one 2)
              (list 'worker 'a (make-named-counter 'a))
              (list 'worker 'b (make-named-counter 'b))
              (list 'worker 'c (make-named-counter 'c)))))
(send! 'a 'tick) (send! 'b 'tick) (send! 'c 'tick)
(display (run-tree)) (newline)
(send! 'b 'boom)                 ; b crashes → b and c reset, a KEEPS state
(display (run-tree)) (newline)
(send! 'a 'report) (send! 'b 'report) (send! 'c 'report)
(display (run-tree)) (newline)
(display (list 'collector-saw *tree-collected*)) (newline)  ; (a 1)(b 0)(c 0)

(display "── negative control: mailboxes survive a restart, state does not ──") (newline)
;; The stated divergence from Erlang, PROVEN so it can't hide in a comment:
;; b banks 2 ticks (handled — state 2), then 3 more ticks are queued but NOT
;; run when a crashes. one-for-all resets b's state; b's queue survives the
;; restart and the fresh handler processes it. Final report: (b 3) — exactly
;; the 3 surviving QUEUED ticks, not 5 (state did not survive), not 0 (queue
;; did). One number separates the two claims.
(set! *tree-collected* '())
(supervise-tree!
  (list 'sup 'root '(one-for-one 1)
        (list 'worker 'collector make-tree-collector)
        (list 'sup 'pair '(one-for-all 2)
              (list 'worker 'a (make-named-counter 'a))
              (list 'worker 'b (make-named-counter 'b)))))
(send! 'b 'tick) (send! 'b 'tick)
(display (run-tree)) (newline)          ; b's state is now 2, queue empty
(send! 'b 'tick) (send! 'b 'tick) (send! 'b 'tick)  ; queued, NOT run
(send! 'a 'boom)
(display (run-tree)) (newline)          ; crash resets state; queue survives
(send! 'b 'report)
(display (run-tree)) (newline)
(display (list 'collector-saw *tree-collected*)) (newline)  ; (b 3)

(display "── escalation: budget exhaustion fails the sup as a unit, parent decides ──") (newline)
;; pair's budget is 1: crash 1 → pair restarts w; crash 2 → pair exhausted
;; → escalate → root restarts the WHOLE subtree (pair's counter resets —
;; proven because crash 3 is again handled by pair); crash 4 → pair
;; exhausted again → escalate → root exhausted → tree-failed; later mail
;; drains to dead letters.
(supervise-tree!
  (list 'sup 'root '(one-for-one 1)
        (list 'sup 'pair '(one-for-one 1)
              (list 'worker 'w (make-named-counter 'w)))))
(send! 'w 'boom) (send! 'w 'boom) (send! 'w 'boom) (send! 'w 'boom)
(send! 'w 'after-death)
(display (run-tree)) (newline)
(display (tree-report)) (newline)
(display (list 'receipts *tree-receipts*)) (newline)

(display "── re-init crash during tree restart → escalates, never a dead run ──") (newline)
;; init works once, then throws forever: pair's restart fails → escalate;
;; root's subtree re-init hits the same throw → root escalates → tree-failed.
(define *tree-init-uses* 0)
(define (make-tree-fragile)
  (begin
    (set! *tree-init-uses* (+ *tree-init-uses* 1))
    (if (> *tree-init-uses* 1) (error "init exploded") #f)
    (lambda (msg) (if (equal? msg 'boom) (error "fragile crashed") #f))))
(supervise-tree!
  (list 'sup 'root '(one-for-one 3)
        (list 'sup 'pair '(one-for-one 3)
              (list 'worker 'f make-tree-fragile))))
(send! 'f 'boom)
(display (run-tree)) (newline)
(display (tree-report)) (newline)
(display (list 'receipts *tree-receipts*)) (newline)
