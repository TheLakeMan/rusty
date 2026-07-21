;;; Copyright (c) 2026 Nicholas Vermeulen
;;; SPDX-License-Identifier: AGPL-3.0-or-later

;; parse.lisp — pure parser combinators with exhaustive language checks.
;; Pure Lisp, zero interpreter changes.
;;
;; Combinators (`parse-seq`, `parse-alt`, `parse-many`, `parse-map`,
;; `parse-lit`, `parse-sat`) consume a list of tokens and return a RESULT as
;; data: either `(ok value rest)` or `(err pos reason)`. Trees and error
;; positions are ordinary lists — never raises for ordinary parse failure.
;; Ambiguity is detected by collecting ALL successful parses of a string
;; under an alt-heavy grammar (two ok results ⇒ ambiguous on that input).
;;
;; LEFT-RECURSION POLICY: combinators do NOT detect left recursion. A
;; left-recursive grammar diverges (no fuel). Callers must write right-
;; recursive or iterative forms (`parse-many`). Documented, not refused at
;; runtime — there is no static grammar analysis here.
;;
;; CLAIM DISCIPLINE:
;;   "language-equivalent to the reference table on A^≤k"
;; NEVER "correct parser for the language" in general, and NEVER that an
;; ambiguous grammar is "resolved". Exhaustive checks classify every string
;; in a finite A^≤k against a hand table.

;; ── Result helpers ────────────────────────────────────────────────────────
(define (parse-ok? r)  (equal? (car r) 'ok))
(define (parse-err? r) (equal? (car r) 'err))
(define (parse-val r)  (cadr r))
(define (parse-rest r) (caddr r))
(define (parse-pos r)  (cadr r))
(define (parse-reason r) (caddr r))
(define (ok v rest) (list 'ok v rest))
(define (err pos reason) (list 'err pos reason))

;; ── Primitive combinators ─────────────────────────────────────────────────
;; Token stream is a list; position is how many tokens already consumed
;; (tracked only in err results — ok results carry the remaining stream).

(define (parse-lit tok)
  (lambda (input pos)
    (if (and (not (null? input)) (equal? (car input) tok))
        (ok tok (cdr input))
        (err pos (list 'expected tok)))))

(define (parse-sat pred)
  (lambda (input pos)
    (if (and (not (null? input)) (pred (car input)))
        (ok (car input) (cdr input))
        (err pos 'sat-failed))))

(define (parse-eps v)
  (lambda (input pos) (ok v input)))

;; Sequence: run p then q on the rest; value is (list vp vq).
;; Position advances by tokens actually consumed (from rest length).
(define (parse-seq p q)
  (lambda (input pos)
    (let ((r1 (p input pos)))
      (if (parse-err? r1) r1
          (let* ((rest1 (parse-rest r1))
                 (consumed (- (length input) (length rest1)))
                 (r2 (q rest1 (+ pos consumed))))
            (if (parse-err? r2) r2
                (ok (list (parse-val r1) (parse-val r2)) (parse-rest r2))))))))

;; Alternation: try p, on err try q (same input/pos). First success wins
;; for ordinary parse; use parse-all-alt for ambiguity detection.
(define (parse-alt p q)
  (lambda (input pos)
    (let ((r1 (p input pos)))
      (if (parse-ok? r1) r1 (q input pos)))))

;; Map a pure function over a successful value.
(define (parse-map f p)
  (lambda (input pos)
    (let ((r (p input pos)))
      (if (parse-err? r) r
          (ok (f (parse-val r)) (parse-rest r))))))

;; Zero-or-more greedy: always succeeds (possibly with empty list).
(define (parse-many p)
  (lambda (input pos)
    (define (go in po acc)
      (let ((r (p in po)))
        (if (parse-err? r)
            (ok (reverse acc) in)
            (let* ((rest (parse-rest r))
                   (consumed (- (length in) (length rest))))
              (go rest (+ po consumed) (cons (parse-val r) acc))))))
    (go input pos '())))

;; One-or-more.
(define (parse-some p)
  (parse-map (lambda (pair) (cons (car pair) (cadr pair)))
             (parse-seq p (parse-many p))))

;; Run a parser; require full consumption for accept.
(define (parse-run p input)
  (let ((r (p input 0)))
    (if (parse-err? r) r
        (if (null? (parse-rest r))
            r
            (err (- (length input) (length (parse-rest r)))
                 'unconsumed)))))

;; ── Ambiguity: collect every successful full parse under a list of alts ──
;; `alts` is a list of parsers; each is tried independently on the same
;; input. Returns the list of ok values (trees). Length ≥ 2 ⇒ ambiguous.
(define (parse-all-accepting alts input)
  (foldl (lambda (p acc)
           (let ((r (parse-run p input)))
             (if (parse-ok? r) (cons (parse-val r) acc) acc)))
         '() alts))

(define (parse-ambiguous? alts input)
  (>= (length (parse-all-accepting alts input)) 2))

;; ── Exhaustive language classification on A^≤k ────────────────────────────
;; Generate all strings over alphabet A of length 0..k (lists of tokens).
(define (parse-strings-of-len A n)
  (if (= n 0) (list '())
      (foldl (lambda (s acc)
               (append acc (map (lambda (a) (cons a s)) A)))
             '()
             (parse-strings-of-len A (- n 1)))))

(define (parse-strings-upto A k)
  (define (go n acc)
    (if (> n k) acc
        (go (+ n 1) (append acc (parse-strings-of-len A n)))))
  (go 0 '()))

;; accept?: string -> boolean. reference: same shape. Exhaustive agreement.
(define (verify-lang-equiv accept? reference? A k)
  (let ((universe (parse-strings-upto A k)))
    (check-exhaustive
      (lambda (s) (equal? (accept? s) (reference? s)))
      (list universe))))

;; Wrong reference must be refused with a witness string.
(define (verify-lang-equiv-wrong accept? bad-ref? A k)
  (verify-lang-equiv accept? bad-ref? A k))
