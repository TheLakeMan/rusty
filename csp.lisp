;;; Copyright (c) 2026 Nicholas Vermeulen
;;; SPDX-License-Identifier: AGPL-3.0-or-later

;; csp.lisp — finite-domain constraint solving. Pure Lisp, zero interpreter
;; changes, same library pattern as fsm.lisp / prover.lisp / synth.lisp.
;;
;; A CSP is DATA:
;;   (csp-make vars domains constraints)
;;     vars        — a list of variable names (any equal?-comparable value)
;;     domains     — an alist, one entry (var val1 val2 …) per variable
;;     constraints — a list of (scope pred) where scope is a list of vars and
;;                   pred is a function of those vars' values, in scope order,
;;                   returning a boolean.
;;
;; Solving is complete BACKTRACKING search in the DECLARED variable order,
;; trying each variable's domain in DECLARED order, checking every constraint
;; whose scope has just become fully assigned. Because the search explores
;; the entire tree (pruning only branches PROVEN inconsistent), the results
;; are exact over the declared domains:
;;
;;   * `csp-solutions` returns EVERY solution, in a stable lexicographic order.
;;   * `csp-unsat?` #t means the whole tree was exhausted with no solution —
;;     a PROOF of unsatisfiability on the declared domains, not a sample.
;;
;; Two independent checks pin that the smart solver is honest:
;;   * `csp-verify` cross-checks backtracking against the BRUTE cartesian
;;     enumeration (the dumb exhaustive solver) — same solutions, same order.
;;   * `csp-prove-unsat` hands the negated constraints to `check-exhaustive`
;;     over the domains: 'verified is a real proof of unsatisfiability; on a
;;     satisfiable instance the counterexamples ARE the solutions.
;;
;; Claim discipline: "solved / proven unsatisfiable over the DECLARED finite
;; domains", per the bounded-verification rule — never "no solution exists"
;; in some larger space, and never "optimal".

;; ── Construction + accessors ─────────────────────────────────────────────
(define (csp-make vars domains constraints) (list 'csp vars domains constraints))
(define (csp-vars csp)        (cadr csp))
(define (csp-domains csp)     (caddr csp))
(define (csp-constraints csp) (cadddr csp))
(define (csp-domain-of csp v) (cdr (assoc v (csp-domains csp))))  ; (var v0 v1 …) -> (v0 v1 …)

;; ── Assignments are alists of (var value) pairs ──────────────────────────
(define (csp-zip vars vals)                       ; ((v0 val0) (v1 val1) …)
  (if (or (null? vars) (null? vals)) '()
      (cons (list (car vars) (car vals))
            (csp-zip (cdr vars) (cdr vals)))))
(define (csp-assigned? assign v) (if (assoc v assign) #t #f))
(define (csp-lookup    assign v) (cadr (assoc v assign)))

;; A constraint is satisfied by a (possibly partial) assignment when its
;; scope isn't fully assigned yet (nothing to check), or it is and the
;; predicate holds. Boolean-strict: only #t counts as holding.
(define (csp-constraint-ok? assign con)
  (let ((scope (car con)) (pred (cadr con)))
    (if (all? (lambda (v) (csp-assigned? assign v)) scope)
        (equal? (apply pred (map (lambda (v) (csp-lookup assign v)) scope)) #t)
        #t)))

(define (csp-consistent? csp assign)
  (all? (lambda (con) (csp-constraint-ok? assign con)) (csp-constraints csp)))

;; ── append-all (flatten one level, order-preserving) ─────────────────────
(define (csp-append-all lsts) (foldl (lambda (x acc) (append acc x)) '() lsts))

;; ── Complete backtracking search: EVERY solution, stable order ───────────
(define (csp-solutions csp)
  (let search ((vars (csp-vars csp)) (assign '()))
    (if (null? vars)
        (list (reverse assign))                     ; complete assignment = a solution
        (let ((v (car vars)))
          (csp-append-all
            (map (lambda (val)
                   (let ((a2 (cons (list v val) assign)))
                     (if (csp-consistent? csp a2)
                         (search (cdr vars) a2)
                         '())))
                 (csp-domain-of csp v)))))))

(define (csp-solve  csp) (let ((s (csp-solutions csp))) (if (null? s) 'unsat (car s))))
(define (csp-count  csp) (length (csp-solutions csp)))
(define (csp-unsat? csp) (null? (csp-solutions csp)))

;; ── Brute cartesian baseline: the dumb exhaustive solver ─────────────────
(define (csp-cartesian lsts)
  (if (null? lsts) (list '())
      (let ((rest (csp-cartesian (cdr lsts))))
        (csp-append-all
          (map (lambda (x) (map (lambda (r) (cons x r)) rest)) (car lsts))))))

(define (csp-brute-solutions csp)
  (let* ((vars (csp-vars csp))
         (doms (map (lambda (v) (csp-domain-of csp v)) vars)))
    (map (lambda (tuple) (csp-zip vars tuple))
         (filter (lambda (tuple) (csp-consistent? csp (csp-zip vars tuple)))
                 (csp-cartesian doms)))))

;; Cross-check: backtracking agrees with brute enumeration, count and order.
(define (csp-verify csp)
  (let ((smart (csp-solutions csp)) (brute (csp-brute-solutions csp)))
    (list 'csp-verify 'agree (equal? smart brute) 'solutions (length smart))))

;; ── Prove unsatisfiability with check-exhaustive ─────────────────────────
;; Property over the domains' cartesian product: "this tuple is NOT a
;; solution". 'verified => proven unsatisfiable on the declared domains
;; (exhausted, never sampled). Otherwise the counterexamples are exactly
;; the satisfying assignments (as ((tuple) "false") entries).
(define (csp-prove-unsat csp)
  (let* ((vars (csp-vars csp))
         (doms (map (lambda (v) (csp-domain-of csp v)) vars)))
    (check-exhaustive
      (lambda args (not (csp-consistent? csp (csp-zip vars args))))
      doms)))
