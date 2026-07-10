;;; Copyright (c) 2026 Nicholas Vermeulen
;;; SPDX-License-Identifier: AGPL-3.0-or-later

;; testkit.lisp — testing & benchmarking utilities (Phase 5.2).
;;
;;   (deftest name body...)      register a test (order preserved)
;;   (test-run)                  run all: per-test line + summary, => #t/#f
;;   (test-reset!)               clear the registry
;;
;; Assertions raise informative errors (the runner catches and reports):
;;   (assert-eq got want)        structural equality
;;   (assert-close got want eps) float comparison with tolerance
;;   (assert-true v) (assert-false v)
;;   (assert-raises thunk)       passes iff thunk raises
;;
;; Benchmarking (timings are wall-clock — never put them in golden files):
;;   (bench-median thunk n)      median microseconds over n runs
;;   (bench-report label thunk n)  print label + median, return median

;; ── Registry ──────────────────────────────────────────────────────────────
(define *tests* '())
(define (test-reset!) (set! *tests* '()))

(defmacro deftest (name . body)
  `(set! *tests* (cons (list (quote ,name) (lambda () ,@body #t)) *tests*)))

;; ── Assertions ────────────────────────────────────────────────────────────
(define (assert-eq got want)
  (if (equal? got want) #t
      (error (format "assert-eq: expected ~a, got ~a" want got))))

(define (assert-close got want eps)
  (if (<= (abs (- got want)) eps) #t
      (error (format "assert-close: expected ~a within ~a, got ~a" want eps got))))

(define (assert-true v)
  (if (equal? v #f) (error "assert-true: got #f") #t))

(define (assert-false v)
  (if (equal? v #f) #t (error (format "assert-false: got ~a" v))))

(define (assert-raises thunk)
  (let ((r (try-catch (begin (thunk) 'no-raise) (e) 'raised)))
    (if (equal? r 'raised) #t
        (error "assert-raises: no error was raised"))))

;; ── Runner ────────────────────────────────────────────────────────────────
(define (test-run)
  (let loop ((ts (reverse *tests*)) (pass 0) (fail 0))
    (if (null? ts)
        (begin
          (print (list 'tests 'passed pass 'failed fail))
          (= fail 0))
        (let ((name (car (car ts))) (thunk (cadr (car ts))))
          (let ((r (try-catch (begin (thunk) 'pass) (e) (list 'FAIL e))))
            (if (equal? r 'pass)
                (begin (print (list 'test name 'pass))
                       (loop (cdr ts) (+ pass 1) fail))
                (begin (print (list 'test name 'FAIL (cadr r)))
                       (loop (cdr ts) pass (+ fail 1)))))))))

;; ── Benchmarking ──────────────────────────────────────────────────────────
(define (bench-median thunk n)
  (define (sort-nums lst)                       ; insertion sort, small n
    (define (ins x s)
      (cond ((null? s) (list x))
            ((< x (car s)) (cons x s))
            (else (cons (car s) (ins x (cdr s))))))
    (foldl ins '() lst))
  (let loop ((i 0) (times '()))
    (if (>= i n)
        (nth (sort-nums times) (floor (/ n 2)))
        (let ((t0 (now-micros)))
          (begin (thunk)
                 (loop (+ i 1) (cons (- (now-micros) t0) times)))))))

(define (bench-report label thunk n)
  (let ((med (bench-median thunk n)))
    (println (format "~a: median ~a us over ~a runs" label med n))
    med))
