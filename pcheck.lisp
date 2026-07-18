;;; Copyright (c) 2026 Nicholas Vermeulen
;;; SPDX-License-Identifier: AGPL-3.0-or-later

;; pcheck.lisp — Phase D: PARALLEL check-exhaustive over the proc-pmap builtin.
;;
;; check-exhaustive proves a property on EVERY point of a finite domain product
;; — real proof, not sampling. It is also embarrassingly parallel: the points
;; are independent. The Rusty core is Rc-based single-threaded on purpose, so
;; the ONE honest way to reach many cores is many PROCESSES. pcheck-exhaustive
;; shards the sweep across child `rusty` processes (proc-pmap) and merges their
;; verdicts.
;;
;; DETERMINISM (the whole point): check-exhaustive iterates the FIRST domain
;; OUTERMOST (slowest-varying). Split that first domain into CONTIGUOUS chunks
;; and give shard i chunk i x the other domains; concatenating the shards'
;; counterexamples in shard order reproduces the serial odometer order EXACTLY.
;; So the result is bit-identical regardless of shard count or worker count —
;; workers change the SPEED, never the ANSWER. That equivalence is the claim,
;; and pcheck-test.lisp pins it: (equal? (pcheck-exhaustive ...) serial-result).
;;
;; HONEST SCOPE (the caveat is the crack):
;;  - A child that errors / times out / crashes is NOT "verified". It surfaces
;;    as (pcheck-incomplete shard proc-result). Absence of a counterexample from
;;    a shard that never finished is not evidence of its absence — never a false
;;    'verified.
;;  - The property must be a BOOLEAN predicate. check-exhaustive's counterexample
;;    reason is then uniformly "false", which is exactly what lets the merge
;;    rebuild the serial result bit-for-bit. A property that RAISES on some input
;;    is outside that contract: the shard child detects the non-"false" reason
;;    and fails loudly (its proc-result becomes an error → pcheck-incomplete),
;;    rather than mislabel a raised input as an ordinary counterexample.
;;  - Per-child interpreter STARTUP is real overhead, so shards must be COARSE
;;    enough that compute >> startup. Below that crossover serial check-exhaustive
;;    wins — use it. See benchmarks/pcheck_bench.lisp for the measured crossover.
;;  - The property and its helpers cross to a fresh child, so anything the
;;    property references beyond builtins/std must be supplied as the `preamble`
;;    source string. Domain values must be numbers/symbols (they round-trip
;;    through the child's printed output; strings/quotes would not).
;;  - proc-pmap drains a child's stdout AFTER it exits (like proc-eval). A shard
;;    that emits enough counterexamples to fill the OS pipe buffer (~64 KB)
;;    before it exits would block and be reported (timeout) -> pcheck-incomplete
;;    rather than returning them. It fails SAFE (never a false 'verified), and
;;    the target use — a mostly-PASSING safety property — never approaches it;
;;    concurrent pipe draining is deferred.

;; ── datum -> source text ────────────────────────────────────────────────────
;; A property crosses to a child as TEXT, so render a datum back to source.
;; Strings are re-quoted so the round-trip is lossless (unlike print/display,
;; which drop the quotes).
(define (datum->source d)
  (cond ((null? d)    "()")
        ((string? d)  (string-append "\"" d "\""))
        ((symbol? d)  (symbol->string d))
        ((number? d)  (number->string d))
        ((boolean? d) (if d "#t" "#f"))
        ((pair? d)    (string-append "("
                        (string-join (map datum->source d) " ") ")"))
        (else (error "datum->source: unrenderable datum"))))

;; ── sharding ────────────────────────────────────────────────────────────────
;; Split a list into at most n CONTIGUOUS chunks (ceil-sized; the last chunk
;; takes the remainder). Order-preserving and gap-free, which is what makes the
;; merge reproduce the serial sweep. n larger than the list just yields fewer,
;; smaller shards; never an empty one. One TAIL-RECURSIVE pass — std's `take`
;; is not tail-recursive and overflows the stack on the large domains this is
;; meant for, so we accumulate by hand instead.
(define (pcheck-ceil-div a b) (floor (/ (+ a b -1) b)))

(define (pcheck-chunks lst n)
  (let ((len (length lst)))
    (if (or (<= n 1) (<= len 1))
        (list lst)
        (let ((size (pcheck-ceil-div len n)))
          (let loop ((rest lst) (cur (list)) (cnt 0) (chunks (list)))
            (cond ((null? rest)
                   (reverse (if (null? cur) chunks (cons (reverse cur) chunks))))
                  ((>= cnt size)
                   (loop rest (list) 0 (cons (reverse cur) chunks)))
                  (else
                   (loop (cdr rest) (cons (car rest) cur) (+ cnt 1) chunks))))))))

;; ── child code ──────────────────────────────────────────────────────────────
;; Each shard child runs check-exhaustive on its sub-domain and prints a
;; PARSE-FREE protocol the parent can reconstruct losslessly:
;;   "V"           -> this shard verified (no counterexamples)
;;   "C(args)\n"   -> one counterexample; (args) is the printed argument list
;; A counterexample whose reason is not "false" (the property RAISED) is out of
;; contract: the child raises, so the shard reports incomplete rather than lie.
(define (pcheck-child-code preamble prop-src doms)
  (string-append
    preamble "\n"
    "(let ((r (check-exhaustive " (datum->source prop-src)
    " (quote " (datum->source doms) "))))\n"
    "  (if (equal? r (quote verified))\n"
    "      (display \"V\")\n"
    "      (for-each (lambda (ce)\n"
    "        (if (equal? (cadr ce) \"false\")\n"
    "            (begin (display \"C\") (display (car ce)) (newline))\n"
    "            (error \"pcheck: property is not a boolean predicate (it raised):\"\n"
    "                   (car ce) (cadr ce))))\n"
    "        r)))"))

;; ── parsing one shard's result ──────────────────────────────────────────────
;; Reconstruct a counterexample line "C(1 -4 4)" back to data ((1 -4 4) "false").
;; The args round-trip via the quote trick; the reason is reattached as the
;; literal string "false" so the result is `equal?` to serial check-exhaustive's.
(define (pcheck-line->ce line)
  (let ((argstr (substring line 1 (string-length line))))
    (list (eval-string (string-append "(quote " argstr ")")) "false")))

;; proc-result (one element of proc-pmap's output) -> 'verified | (ce...) |
;; (pcheck-incomplete proc-result). Anything but a clean (ok ...) is incomplete.
(define (pcheck-parse-shard proc-result)
  (if (and (pair? proc-result) (equal? (car proc-result) 'ok))
      (let ((out (cadr proc-result)))
        (if (equal? out "V")
            'verified
            (map pcheck-line->ce (string-split out "\n"))))
      (list 'pcheck-incomplete proc-result)))

(define (pcheck-incomplete? p) (and (pair? p) (equal? (car p) 'pcheck-incomplete)))
(define (pcheck-shard-ces  p) (if (equal? p 'verified) (list) p))

;; ── merge ───────────────────────────────────────────────────────────────────
;; parsed shards IN ORDER -> the SAME value serial check-exhaustive returns:
;;   'verified iff every shard verified,
;;   else the shards' counterexamples concatenated in shard order.
;; An incomplete shard poisons the whole verdict (honest: we did not prove it).
(define (pcheck-merge parsed)
  (let ((bad (filter pcheck-incomplete? parsed)))
    (cond ((not (null? bad)) (car bad))
          ((all? (lambda (p) (equal? p 'verified)) parsed) 'verified)
          (else (apply append (map pcheck-shard-ces parsed))))))

;; ── the driver ──────────────────────────────────────────────────────────────
;; (pcheck-exhaustive prop-src domains n-shards [timeout [preamble]])
;;   prop-src : a QUOTED lambda expression, e.g. '(lambda (x) (< x 100))
;;   domains  : list of finite domain lists, like check-exhaustive's 2nd arg
;;   n-shards : how many child processes to split the FIRST domain across
;;   timeout  : per-child wall-clock seconds (default 30)
;;   preamble : extra source the property needs in the child (default "")
;; Returns exactly what (check-exhaustive <prop> domains) returns.
(define (pcheck-exhaustive prop-src domains n-shards . opt)
  (let ((timeout  (if (>= (length opt) 1) (nth opt 0) 30))
        (preamble (if (>= (length opt) 2) (nth opt 1) "")))
    (let* ((first-dom  (car domains))
           (rest-doms  (cdr domains))
           (shard-doms (pcheck-chunks first-dom n-shards))
           (codes      (map (lambda (chunk)
                              (pcheck-child-code preamble prop-src (cons chunk rest-doms)))
                            shard-doms))
           (results    (proc-pmap codes timeout (length codes))))
      (pcheck-merge (map pcheck-parse-shard results)))))
