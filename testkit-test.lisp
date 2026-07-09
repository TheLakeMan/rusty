;; testkit-test.lisp — golden test for testkit.lisp. Deterministic:
;; benchmark timings are asserted sane, never printed.

(load "testkit.lisp")

(deftest arithmetic
  (assert-eq (+ 1 2) 3)
  (assert-close (sqrt 2) 1.41421356 0.0001))

(deftest lists-and-truth
  (assert-eq (map (lambda (x) (* x x)) '(1 2 3)) '(1 4 9))
  (assert-true (if '() #t #f))          ; () is true — SPEC §3
  (assert-false (= 1 2)))

(deftest raising
  (assert-raises (lambda () (/ 1 0)))
  (assert-raises (lambda () (error "boom"))))

(deftest deliberately-failing            ; the runner must survive and report
  (assert-eq (* 2 2) 5))

(deftest deliberately-erroring
  (undefined-function 42))

(define all-green (test-run))
(print (list 'suite-green all-green))    ; #f — two tests fail by design

;; a fresh registry runs clean
(test-reset!)
(deftest only-good (assert-eq 1 1))
(print (list 'clean-suite (test-run)))

;; benchmarking utilities return sane numbers (values never golden-printed)
(define med (bench-median (lambda () (foldl + 0 '(1 2 3 4 5))) 5))
(print (list 'bench-median-sane (and (number? med) (>= med 0))))

(print "TESTKIT TESTS DONE")
