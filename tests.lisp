;tests.lisp
; Regression tests for SimpleLisp.
; If a test fails, it intentionally raises: Division by zero.

(def assert-equal (expected actual label)
  (if (eq expected actual)
      (print label)
      (begin
        (print "FAIL: expected/actual mismatch")
        (print label)
        (print expected)
        (print actual)
        (div 1 0))))

(def assert-true (value label)
  (if value
      (print label)
      (begin
        (print "FAIL: expected true")
        (print label)
        (div 1 0))))

(def assert-false (value label)
  (if (not value)
      (print label)
      (begin
        (print "FAIL: expected false")
        (print label)
        (div 1 0))))


; -----------------------------
; Arithmetic tests
; -----------------------------

(def test-arith ()
  (begin
    (assert-equal 10 (add 3 7) "add")
    (assert-equal -3 (sub 2 5) "sub negative")
    (assert-equal 12 (mul 3 4) "mul")
    (assert-equal 2 (div 8 4) "div")

    (assert-true (eq 5 5) "eq true")
    (assert-false (eq 5 6) "eq false")

    (assert-true (gt 5 3) "gt")
    (assert-true (lt 3 5) "lt")
    (assert-true (ge 5 5) "ge")
    (assert-true (le 5 5) "le")
    (assert-true (neq 5 6) "neq")
    (assert-true (not (eq 1 2)) "not")

    "arith-ok"))


; -----------------------------
; String tests
; -----------------------------

(def test-strings ()
  (begin
    (assert-equal "hello" "hello" "string equality")
    (assert-equal "a\nb" "a\nb" "string escape")
    "strings-ok"))


; -----------------------------
; List tests
; -----------------------------

(def sum-list (xs)
  (if (eq xs (quote ()))
      0
      (add (car xs) (sum-list (cdr xs)))))

(def test-lists ()
  (begin
    (assert-equal (quote (1 2 3)) (list 1 2 3) "list")
    (assert-equal 1 (car (quote (1 2 3))) "car")
    (assert-equal (quote (2 3)) (cdr (quote (1 2 3))) "cdr")
    (assert-equal (quote (0 1 2)) (cons 0 (quote (1 2))) "cons")
    (assert-equal 3 (length (quote (1 2 3))) "length")
    (assert-equal (quote (1 2 3 4)) (append (quote (1 2)) (quote (3 4))) "append")
    (assert-equal 10 (sum-list (quote (1 2 3 4))) "recursive list sum")
    "lists-ok"))


; -----------------------------
; Closure tests
; -----------------------------

(def make-counter ()
  (begin
    (set x 0)
    (def counter-step () (set x (add x 1)))
    (def counter-value () x)
    (list counter-step counter-value)))

(def test-counter ()
  (begin
    (set counter-pair (make-counter))
    (set counter-step-fn (car counter-pair))
    (set counter-value-fn (car (cdr counter-pair)))

    (counter-step-fn)
    (assert-equal 1 (counter-value-fn) "counter first")

    (counter-step-fn)
    (assert-equal 2 (counter-value-fn) "counter second")

    "counter-ok"))


; -----------------------------
; Adder closure test
; -----------------------------

(def make-adder (n)
  (lambda (x) (add x n)))

(def test-adder ()
  (assert-equal 15 ((make-adder 5) 10) "adder closure"))


; -----------------------------
; Local recursive factorial test
; -----------------------------

(def make-fact ()
  (begin
    (def fact (n)
      (if (eq n 0)
          1
          (mul n (fact (sub n 1)))))
    fact))

(def test-factorial ()
  (assert-equal 120 ((make-fact) 5) "local recursive factorial"))


; -----------------------------
; Map/filter tests
; -----------------------------

(def test-map-filter ()
  (begin
    (assert-equal
      (quote (2 4 6))
      (map (lambda (x) (mul x 2)) (quote (1 2 3)))
      "map")

    (assert-equal
      (quote (3))
      (filter (lambda (x) (gt x 2)) (quote (1 2 3)))
      "filter")

    "map-filter-ok"))


; -----------------------------
; Lexical scoping shadowing test
; -----------------------------

(def make-shadow (y)
  (begin
    (set x 0)

    (def outer (z)
      (begin
        (set x (add x 1))
        (add x y z)))

    outer))

(def test-shadow ()
  (begin
    (set shadow-fn (make-shadow 10))

    (assert-equal 11 (shadow-fn 0) "shadow first")
    (assert-equal 12 (shadow-fn 0) "shadow second")

    "shadow-ok"))


; -----------------------------
; Higher-order function test
; -----------------------------

(def compose (f g)
  (lambda (x) (f (g x))))

(def double (x)
  (add x x))

(def add-one (x)
  (add x 1))

(def test-compose ()
  (assert-equal 12 ((compose double add-one) 5) "compose"))


; -----------------------------
; Recursion test
; -----------------------------

(def fib (n)
  (if (lt n 2)
      n
      (add (fib (sub n 1)) (fib (sub n 2)))))

(def test-recursion ()
  (assert-equal 55 (fib 10) "fibonacci"))


; -----------------------------
; Run everything
; -----------------------------

(def run-tests ()
  (begin
    (test-arith)
    (test-strings)
    (test-lists)
    (test-counter)
    (test-adder)
    (test-factorial)
    (test-map-filter)
    (test-shadow)
    (test-compose)
    (test-recursion)
    (print "ALL TESTS PASSED")))

(run-tests)
