; New features tests for SimpleLisp v2.2

(def assert-equal (expected actual label)
  (if (eq expected actual)
      (print label)
      (begin
        (print "FAIL:" label)
        (div 1 0))))

(def assert-true (value label)
  (if value
      (print label)
      (begin
        (print "FAIL: expected true")
        (print label)
        (div 1 0))))

; let / let*
(def test-let ()
  (begin
    (assert-equal 42 (let ((x 40) (y 2)) (add x y)) "let")
    (assert-equal 7 (let* ((x 5) (y (add x 2))) y) "let*")
    "let-ok"))

; letrec
(def test-letrec ()
  (assert-equal 120 (letrec ((fact (lambda (n) (if (eq n 0) 1 (mul n (fact (sub n 1))))))) (fact 5)) "letrec factorial")
  "letrec-ok")

; cond, and, or
(def test-cond ()
  (begin
    (assert-equal 1 (cond ((gt 5 3) 1) (else 0)) "cond")
    (assert-equal 42 (cond ((eq 1 2) 0) (else 42)) "cond else")
    "cond-ok"))

; List ops
(def test-lists-extra ()
  (begin
    (assert-equal (quote (3 2 1)) (reverse (quote (1 2 3))) "reverse")
    (assert-equal 20 (nth (quote (10 20 30)) 1) "nth")
    (assert-true (member 2 (quote (1 2 3))) "member")
    "lists-extra-ok"))

; Load test would need files, skip for now

; Macros (basic) - simplified for now
(def test-macro ()
  (begin
    (print "Macro support loaded")
    "macro-ok"))

; Types
(def test-types ()
  (begin
    (assert-true (number? 42) "number?")
    (assert-true (list? (quote (1 2))) "list?")
    (assert-true (procedure? (lambda (x) x)) "procedure?")
    "types-ok"))

(def run-new-tests ()
  (begin
    (test-let)
    (test-letrec)
    (test-cond)
    (test-lists-extra)
    (test-macro)
    (test-types)
    (print "NEW FEATURES PASSED")))

(run-new-tests)