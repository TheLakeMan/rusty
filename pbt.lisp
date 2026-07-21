;;; Copyright (c) 2026 Nicholas Vermeulen
;;; SPDX-License-Identifier: AGPL-3.0-or-later

;; pbt.lisp — property-based testing with shrinking, and a dual
;; sample -> exhaust mode. Pure Lisp, zero interpreter changes, same
;; library pattern as fsm.lisp / testkit.lisp / symreg.lisp.
;;
;; A PROPERTY is a 1-argument boolean predicate over generated inputs.
;; A GENERATOR is a 0-argument function that draws one value from the
;; shared seeded PRNG (reseed with (pbt-seed! n) for reproducible runs).
;;
;; TWO modes, with DELIBERATELY different verdicts so the claim can't be
;; overstated:
;;
;;   (pbt-check prop gen n)   — SAMPLE mode. Draw n seeded cases; on the
;;   first failure, delta-debug SHRINK it to a minimal counterexample and
;;   return it as data. Verdict on success is 'passed — the honest claim
;;   is "no counterexample in n seeded draws", NEVER 'verified. Absence in
;;   a sample is not absence.
;;
;;   (pbt-verify prop domain)  — EXHAUST mode. Hand the property to
;;   check-exhaustive over an EXPLICIT finite input set: it runs the
;;   property on every element, so success is 'verified (a real proof over
;;   the declared domain, per the bounded-verification rule) and failure
;;   still shrinks the first counterexample to minimal. This is the Rusty
;;   angle — on a small finite domain a property test UPGRADES from a
;;   sample into a proof, reusing the same shrinker for the witness.
;;
;; Shrinking is type-directed and generic (numbers toward 0, lists by
;; deleting elements then shrinking them), greedy first-failing, so the
;; minimal counterexample is a deterministic function of the failing input
;; — same seed => same original => same minimal (pinned in the golden).
;; "Minimal" is minimal under the declared size metric (pbt-size): it is a
;; local minimum of the greedy search, not a global one.
;;
;; Claim discipline: 'verified means "ran everywhere on the DECLARED finite
;; domain", 'passed means "no counterexample sampled" — never "correct" or
;; "safe". A raise from a property counts as NOT holding (boolean-strict,
;; like check-exhaustive since 0.62.1: only #t holds).

;; ── Seeded PRNG (same LCG as symreg.lisp) ────────────────────────────────
(define *pbt-seed* 2463534242)
(define (pbt-seed! n) (set! *pbt-seed* n))
(define (pbt-rand)                          ; float in [0,1)
  (set! *pbt-seed* (mod (+ (* *pbt-seed* 1103515245) 12345) 2147483648))
  (/ *pbt-seed* 2147483648))
(define (pbt-rand-int n) (floor (* (pbt-rand) n)))   ; int in 0..n-1

;; ── Generators: each is a thunk drawing one value from the PRNG ──────────
(define (gen-int lo hi)                      ; int in [lo,hi] inclusive
  (lambda () (+ lo (pbt-rand-int (+ 1 (- hi lo))))))
(define (gen-oneof lst)                      ; a uniformly chosen element
  (lambda () (nth lst (pbt-rand-int (length lst)))))
(define (gen-bool)
  (lambda () (< (pbt-rand) 0.5)))
(define (gen-const x)
  (lambda () x))
(define (gen-list elem-gen max-len)          ; list of length 0..max-len
  (lambda ()
    (let loop ((k (pbt-rand-int (+ 1 max-len))) (acc '()))
      (if (= k 0) acc (loop (- k 1) (cons (elem-gen) acc))))))

;; ── Does the property hold on v? Boolean-strict: only #t holds; a #f,
;; a non-boolean, or a raise all count as a FAILURE (a counterexample). ───
(define (pbt-holds? prop v)
  (equal? (try-catch (prop v) (e) 'pbt-raised) #t))

;; ── Size metric — what "minimal" is minimised against ────────────────────
(define (pbt-size v)
  (cond ((number? v) (abs v))
        ((list? v)   (foldl (lambda (x acc) (+ acc 1 (pbt-size x))) 0 v))
        (else 1)))

;; ── Shrink candidates: strictly-smaller values, most-aggressive first ────
(define (pbt-half n)                          ; halve toward zero (truncating)
  (* (sign n) (floor (/ (abs n) 2))))
(define (pbt-num-shrinks n)
  (if (= n 0) '()
      (remove-duplicates
        (filter (lambda (c) (< (abs c) (abs n)))
                (list 0 (pbt-half n) (- n (sign n)))))))

;; All lists obtained by deleting exactly one element (each is shorter).
(define (pbt-removals lst)
  (if (null? lst) '()
      (cons (cdr lst)
            (map (lambda (rest) (cons (car lst) rest))
                 (pbt-removals (cdr lst))))))

;; All lists obtained by shrinking exactly one element in place (recurses
;; into nested structure via pbt-shrinks).
(define (pbt-elem-shrinks lst)
  (let loop ((rest lst) (prefix '()))
    (if (null? rest) '()
        (let ((x (car rest)) (tail (cdr rest)))
          (append
            (map (lambda (s) (append (reverse prefix) (cons s tail)))
                 (pbt-shrinks x))
            (loop tail (cons x prefix)))))))

(define (pbt-shrinks v)
  (cond ((number? v) (pbt-num-shrinks v))
        ((list? v)   (append (pbt-removals v) (pbt-elem-shrinks v)))
        (else '())))

;; ── Greedy delta-debugging shrink. Precondition: (prop v) fails. Take the
;; first still-failing candidate, adopt it, restart — until none fail. ────
(define (pbt-first-failing prop cands)
  (cond ((null? cands) 'pbt-none)
        ((not (pbt-holds? prop (car cands))) (car cands))
        (else (pbt-first-failing prop (cdr cands)))))

(define (pbt-shrink prop v)                   ; => (list minimal steps)
  (let loop ((cur v) (steps 0))
    (let ((next (pbt-first-failing prop (pbt-shrinks cur))))
      (if (equal? next 'pbt-none)
          (list cur steps)
          (loop next (+ steps 1))))))

;; ── SAMPLE mode: draw n cases; first failure shrinks to a minimal CE ─────
(define (pbt-check prop gen n)
  (let loop ((i 0))
    (if (>= i n)
        (list 'pbt-result 'status 'passed 'tests n)   ; no CE in n draws (weak)
        (let ((v (gen)))
          (if (pbt-holds? prop v)
              (loop (+ i 1))
              (let ((shr (pbt-shrink prop v)))
                (list 'pbt-result 'status 'failed
                      'original v
                      'minimal  (car shr)
                      'shrinks  (cadr shr))))))))

;; ── EXHAUST mode: prove over an explicit finite input set ────────────────
;; check-exhaustive runs prop on every element of `domain`; success is a
;; real proof over that declared set. On failure the first counterexample
;; is shrunk to minimal, reusing the sampler's shrinker.
(define (pbt-verify prop domain)
  (let ((r (check-exhaustive prop (list domain))))
    (if (equal? r 'verified)
        (list 'pbt-result 'status 'verified 'domain-size (length domain))
        (let* ((first-ce (car (car (car r))))        ; (((input) reason)...) -> input
               (shr (pbt-shrink prop first-ce)))
          (list 'pbt-result 'status 'refuted
                'counterexamples (length r)
                'first    first-ce
                'minimal  (car shr))))))

;; Multi-argument exhaust passthrough: prop takes k args, `domains` is a
;; list of k finite domains — the raw cartesian-product proof/counterexamples.
(define (pbt-verify* prop domains) (check-exhaustive prop domains))

;; ── Domain builder: every list over `alphabet` of length 0..max-len ──────
(define (pbt-append-all lsts)
  (foldl (lambda (x acc) (append acc x)) '() lsts))
(define (pbt-lists-exact alphabet k)
  (if (= k 0) (list '())
      (let ((shorter (pbt-lists-exact alphabet (- k 1))))
        (pbt-append-all
          (map (lambda (a) (map (lambda (rest) (cons a rest)) shorter))
               alphabet)))))
(define (pbt-lists alphabet max-len)
  (pbt-append-all
    (map (lambda (k) (pbt-lists-exact alphabet k))
         (range 0 (+ max-len 1)))))
