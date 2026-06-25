;;; std.lisp — Rusty Standard Library
;;; Loaded automatically on startup.

;; ── Boolean utilities ──────────────────────────────────────────────────────

(defmacro and2 (a b)
  `(if ,a ,b #f))

(defmacro or2 (a b)
  `(if ,a ,a ,b))

;; ── Control flow macros ────────────────────────────────────────────────────

;; (when test body...) — already a special form, but also available as macro
;; (unless test body...) — same

;; Clojure-style threading: (-> x (f a) (g b)) => (g (f x a) b)
(defmacro -> (x . forms)
  (if (null? forms)
      x
      (let ((form (car forms))
            (rest (cdr forms)))
        (if (pair? form)
            `(-> (,(car form) ,x ,@(cdr form)) ,@rest)
            `(-> (,form ,x) ,@rest)))))

;; Thread-last: (->> x (f a) (g b)) => (g b (f a x))
(defmacro ->> (x . forms)
  (if (null? forms)
      x
      (let ((form (car forms))
            (rest (cdr forms)))
        (if (pair? form)
            `(->> (,(car form) ,@(cdr form) ,x) ,@rest)
            `(->> (,form ,x) ,@rest)))))

;; (while test body...)
(defmacro while (test . body)
  `(let loop ()
     (when ,test
       ,@body
       (loop))))

;; (dotimes (i n) body...) — loop i from 0 to n-1
(defmacro dotimes (spec . body)
  (let ((var (car spec))
        (n   (car (cdr spec))))
    `(let loop (,var 0)
       (when (< ,var ,n)
         ,@body
         (loop (+ ,var 1))))))

;; (dolist (x lst) body...) — iterate over list
(defmacro dolist (spec . body)
  (let ((var (car spec))
        (lst (car (cdr spec))))
    `(for-each (lambda (,var) ,@body) ,lst)))

;; (swap! a b) — swap two bindings
(defmacro swap! (a b)
  (let ((tmp (gensym "tmp")))
    `(let ((,tmp ,a))
       (set! ,a ,b)
       (set! ,b ,tmp))))

;; ── List utilities ─────────────────────────────────────────────────────────

(define (caar x)   (car (car x)))
(define (cadr x)   (car (cdr x)))
(define (cdar x)   (cdr (car x)))
(define (cddr x)   (cdr (cdr x)))
(define (caaar x)  (car (car (car x))))
(define (caddr x)  (car (cdr (cdr x))))
(define (cadddr x) (car (cdr (cdr (cdr x)))))

(define (last lst)
  (if (null? (cdr lst))
      (car lst)
      (last (cdr lst))))

(define (flatten lst)
  (cond
    ((null? lst) '())
    ((pair? (car lst)) (append (flatten (car lst)) (flatten (cdr lst))))
    (else (cons (car lst) (flatten (cdr lst))))))

(define (zip lst1 lst2)
  (if (or (null? lst1) (null? lst2))
      '()
      (cons (list (car lst1) (car lst2))
            (zip (cdr lst1) (cdr lst2)))))

(define (take n lst)
  (if (or (= n 0) (null? lst))
      '()
      (cons (car lst) (take (- n 1) (cdr lst)))))

(define (drop n lst)
  (if (or (= n 0) (null? lst))
      lst
      (drop (- n 1) (cdr lst))))

(define (range start end)
  (if (>= start end)
      '()
      (cons start (range (+ start 1) end))))

(define (iota n)
  (range 0 n))

(define (sum lst)     (foldl + 0 lst))
(define (product lst) (foldl * 1 lst))

(define (any? pred lst)
  (cond
    ((null? lst) #f)
    ((pred (car lst)) #t)
    (else (any? pred (cdr lst)))))

(define (all? pred lst)
  (cond
    ((null? lst) #t)
    ((not (pred (car lst))) #f)
    (else (all? pred (cdr lst)))))

(define (count pred lst)
  (foldl (lambda (x acc) (if (pred x) (+ acc 1) acc)) 0 lst))

(define (find pred lst)
  (cond
    ((null? lst) #f)
    ((pred (car lst)) (car lst))
    (else (find pred (cdr lst)))))

(define (flatten1 lst)
  (apply append lst))

(define (list-copy lst)
  (if (null? lst) '() (cons (car lst) (list-copy (cdr lst)))))

(define (assoc key alist)
  (cond
    ((null? alist) #f)
    ((equal? key (caar alist)) (car alist))
    (else (assoc key (cdr alist)))))

(define (assq key alist)
  (cond
    ((null? alist) #f)
    ((eq? key (caar alist)) (car alist))
    (else (assq key (cdr alist)))))

;; ── Math utilities ─────────────────────────────────────────────────────────

(define (square x) (* x x))
(define (cube x)   (* x x x))
(define (inc x)    (+ x 1))
(define (dec x)    (- x 1))
(define (average a b) (/ (+ a b) 2))

(define (clamp val lo hi)
  (max lo (min hi val)))

;; ── String utilities ───────────────────────────────────────────────────────

(define (string-join lst sep)
  (if (null? lst)
      ""
      (foldl (lambda (s acc) (string-append acc sep s))
             (car lst)
             (cdr lst))))

(define (string-repeat s n)
  (let loop ((i 0) (acc ""))
    (if (= i n) acc
        (loop (+ i 1) (string-append acc s)))))

;; ── Functional utilities ───────────────────────────────────────────────────

(define (compose . fns)
  (if (null? fns)
      (lambda (x) x)
      (let ((fn  (car fns))
            (rest (apply compose (cdr fns))))
        (lambda (x) (fn (rest x))))))

(define (curry f . args)
  (lambda rest-args
    (apply f (append args rest-args))))

(define (identity x) x)
(define (const x)    (lambda args x))
(define (flip f)     (lambda (a b) (f b a)))

(define (negate pred)
  (lambda (x) (not (pred x))))

;; ── I/O utilities ──────────────────────────────────────────────────────────

(define (println x)
  (display x)
  (newline))

(define (print-list lst)
  (for-each (lambda (x) (display x) (newline)) lst))

;; ── Assertion (for tests) ──────────────────────────────────────────────────

(define (assert condition msg)
  (when (not condition)
    (error (string-append "Assertion failed: " msg))))

(define (assert-equal expected actual msg)
  (when (not (equal? expected actual))
    (error (string-append "Assert-equal failed [" msg "]: expected "
                          (number->string expected) " got "
                          (number->string actual)))))
