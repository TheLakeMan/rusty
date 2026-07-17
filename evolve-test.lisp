;; evolve-test.lisp — golden test for evolve.lisp (self-optimization with
;; receipts). Deterministic: scripted proposers, stubbed bench seam (real
;; timings are never golden data), kg cleared up front.

(load "evolve.lisp")
(kg-clear!)

(display "== EVOLVE: gates + receipts ==") (newline)

;; ── 1. A slow implementation evolves into a fast equivalent ─────────────
(define (slow-double n)
  (if (= n 0) 0 (+ 2 (slow-double (- n 1)))))

(display (list 'before (slow-double 21))) (newline)

(define dom-0-24 (list (range 0 25)))

(display (evolve! 'slow-double '(lambda (n) (* n 2)) dom-0-24)) (newline)
(display (list 'after (slow-double 21))) (newline)

;; ── 2. A wrong candidate is rejected with the counterexample ────────────
;; (off by one at exactly n=7; the binding must stay untouched)
(display (evolve! 'slow-double
                  '(lambda (n) (if (= n 7) 15 (* n 2)))
                  dom-0-24)) (newline)
(display (list 'still-correct (slow-double 7))) (newline)

;; ── 3. A trojan is rejected STATICALLY — it never runs ──────────────────
;; The candidate would write a file; the effect gate rejects before any
;; execution, so the file must not exist afterwards.
(display (evolve! 'slow-double
                  '(lambda (n) (begin (file-write "evolve-trojan-proof.txt" "pwned") (* n 2)))
                  dom-0-24)) (newline)
(display (list 'trojan-ran (file-exists? "evolve-trojan-proof.txt"))) (newline)

;; ── 4. The speed gate: correct but slower is refused ────────────────────
;; Stub the bench seam (called OLD first, then NEW per the contract).
(define bench-calls 0)
(evolve-bench! (lambda (thunk reps)
  (set! bench-calls (+ bench-calls 1))
  (if (= bench-calls 1) 100 300)))   ; old 100, new 300 -> not faster
(display (evolve! 'slow-double '(lambda (n) (+ n n)) dom-0-24 (list 3 (list 12)))) (newline)

(set! bench-calls 0)
(evolve-bench! (lambda (thunk reps)
  (set! bench-calls (+ bench-calls 1))
  (if (= bench-calls 1) 300 100)))   ; old 300, new 100 -> faster
(display (evolve! 'slow-double '(lambda (n) (+ n n)) dom-0-24 (list 3 (list 12)))) (newline)
(display (list 'after-speed-gate (slow-double 21))) (newline)

;; ── 5. Proposer seat: bad proposals cost attempts, then one lands ───────
(define (scripted-proposer attempt feedback)
  (cond ((= attempt 1) '(lambda (n) (* n 3)))          ; wrong
        ((= attempt 2) '(lambda (n) (undefined-fn n))) ; raises at vet
        (else          '(lambda (n) (* 2 n)))))        ; right
(display (evolve-with-proposer 'slow-double scripted-proposer dom-0-24 5)) (newline)

;; A proposer that never lands: failure is a verdict, not a crash.
(display (evolve-with-proposer 'slow-double
                               (lambda (a f) '(lambda (n) (* n 5)))
                               dom-0-24 2)) (newline)

;; ── 6. Raise-tolerance: equivalence includes agreeing on raises ─────────
(define (checked-recip n) (/ 100 n))                   ; raises at n=0
(display (evolve! 'checked-recip
                  '(lambda (n) (/ 100 n))
                  (list (range 0 5)))) (newline)       ; both raise at 0 -> ok
(display (evolve! 'checked-recip
                  '(lambda (n) (if (= n 0) 0 (/ 100 n)))
                  (list (range 0 5)))) (newline)       ; hides the raise -> rejected

;; ── 7. Receipts: the audit trail is queryable data ───────────────────────
(display (list 'verdicts (kg-query '((slow-double evolve-verdict ?v))))) (newline)
(display (list 'became (kg-query '((slow-double evolved-to ?src))))) (newline)
(display (list 'domain-size (kg-query '((slow-double evolve-domain-size ?n))))) (newline)

(display "EVOLVE TESTS DONE") (newline)
