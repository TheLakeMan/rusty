;; evolve.lisp — self-optimization with receipts (pure Lisp library).
;;
;; An agent (or you) proposes REPLACEMENT SOURCE for a named global
;; function; evolve! vets it through the Phase-2 gates and rebinds the
;; name only on a full pass. Gate order is the 2.1 invariant — static
;; first: (1) effect honesty — the candidate is rejected WITHOUT EVER
;; RUNNING if it has effects its predecessor didn't have; (2) exhaustive
;; input/output equivalence on a declared finite domain (raise-tolerant:
;; equal values, or both raise); (3) optional measured-speed gate.
;; Every verdict leaves a queryable receipt in the knowledge graph.
;;
;; The claim, exactly: the replacement is PROVEN EQUIVALENT ON THE
;; DECLARED DOMAIN (check-exhaustive runs every point) and adds no
;; visible effects. Never "safe", and nothing beyond the domain.
;;
;; Candidates are SOURCE (s-expressions — pure data), not closures: that
;; is what lets the receipt record exactly what the name became, and
;; makes apply a real top-level (define ...). Call evolve! at top level;
;; candidates close over the global env like any define. A proposer seat
;; (evolve-with-proposer) mirrors synthesize-verified: a misbehaving
;; proposal costs one attempt with feedback, never a crash.

(define (evolve--subset? xs ys)
  (if (null? xs) #t
      (if (member (car xs) ys) (evolve--subset? (cdr xs) ys) #f)))

;; Gate 1 (static — runs nothing): new effects must be a subset of old.
;; Pure stays pure; an impure predecessor admits the same effects only.
(define (evolve-effects-ok? old-f new-f)
  (let ((neweff (check-effects new-f)))
    (if (equal? neweff 'pure) #t
        (let ((oldeff (check-effects old-f)))
          (if (equal? oldeff 'pure) #f
              (evolve--subset? neweff oldeff))))))

;; Raise-tolerant outcome: equivalence means equal values, or both raise.
(define (evolve--outcome f args)
  (try-catch (list 'val (apply f args)) (e) (list 'raised)))

;; Gate 2: exhaustive agreement on every domain point.
(define (evolve-equivalent old-f new-f domains)
  (check-exhaustive
    (lambda args (equal? (evolve--outcome old-f args)
                         (evolve--outcome new-f args)))
    domains))

(define (evolve--domain-size domains)
  (foldl (lambda (d acc) (* acc (length d))) 1 domains))

;; Bench seam — timings are never golden data, so tests stub this.
;; Contract: a vet that reaches gate 3 calls it exactly twice, OLD first.
(define evolve-bench (lambda (thunk reps) (bench-median thunk reps)))
(define (evolve-bench! f) (set! evolve-bench f))

;; Vet without applying. 'ok, or (rejected <why> <detail>).
;; bench: #f to skip gate 3, or (reps args) — times (apply f args) and
;; requires the new median to beat the old.
(define (evolve-vet old-f new-f domains bench)
  (if (not (evolve-effects-ok? old-f new-f))
      (list 'rejected 'adds-effects (check-effects new-f))
      (let ((eq (evolve-equivalent old-f new-f domains)))
        (if (not (equal? eq 'verified))
            (list 'rejected 'not-equivalent-on-domain (car eq))
            (if (not bench)
                'ok
                (let ((told (evolve-bench (lambda () (apply old-f (cadr bench))) (car bench))))
                  (let ((tnew (evolve-bench (lambda () (apply new-f (cadr bench))) (car bench))))
                    (if (< tnew told)
                        'ok
                        (list 'rejected 'not-faster 'median-not-below-old)))))))))

;; Apply + receipt. The receipt is the point: what the name became, the
;; verdict, and the bounded claim made countable (domain size).
(define (evolve--apply! name src domains)
  (eval (list 'define name src))
  (kg-add! name 'evolve-verdict 'ok)
  (kg-add! name 'evolved-to src)
  (kg-add! name 'evolve-domain-size (evolve--domain-size domains))
  (list 'ok name))

(define (evolve--refuse! name verdict)
  (kg-add! name 'evolve-verdict 'rejected)
  (kg-add! name 'evolve-rejected-because (cadr verdict))
  verdict)

;; (evolve! 'name src domains)              — correctness gates only
;; (evolve! 'name src domains (list reps args)) — plus the speed gate
(define (evolve! name src domains . opt)
  (let ((bench (if (null? opt) #f (car opt))))
    (let ((verdict (evolve-vet (eval name) (eval src) domains bench)))
      (if (equal? verdict 'ok)
          (evolve--apply! name src domains)
          (evolve--refuse! name verdict)))))

;; Proposer seat: (proposer attempt feedback) -> candidate source (data).
;; Rejections loop back as feedback; a raise costs one attempt.
(define (evolve-with-proposer name proposer domains max-attempts)
  (let ((old-f (eval name)))
    (let loop ((attempt 1) (feedback '()))
      (if (> attempt max-attempts)
          (begin
            (kg-add! name 'evolve-verdict 'failed)
            (list 'failed (reverse feedback)))
          (let ((outcome
                  (try-catch
                    (let ((src (proposer attempt feedback)))
                      (let ((verdict (evolve-vet old-f (eval src) domains #f)))
                        (if (equal? verdict 'ok)
                            (list 'accepted src)
                            (list 'no verdict))))
                    (e) (list 'no (list 'rejected 'proposal-error e)))))
            (if (equal? (car outcome) 'accepted)
                (begin
                  (evolve--apply! name (cadr outcome) domains)
                  (list 'ok name attempt))
                (loop (+ attempt 1) (cons (cadr outcome) feedback))))))))

;; Queryable history of a name's evolution.
(define (evolve-receipts name)
  (kg-query (list (list name '?p '?o))))
