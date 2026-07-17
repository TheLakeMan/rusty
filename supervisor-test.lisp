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
