;;; std.lisp — Rusty Standard Library v1.0
;;; Auto-loaded on startup. Place a custom std.lisp next to your binary to override.

;; ── List accessors (cXXr) ──────────────────────────────────────────────────
(define (caar x)   (car (car x)))
(define (cadr x)   (car (cdr x)))
(define (cdar x)   (cdr (car x)))
(define (cddr x)   (cdr (cdr x)))
(define (caaar x)  (car (car (car x))))
(define (caadr x)  (car (car (cdr x))))
(define (caddr x)  (car (cdr (cdr x))))
(define (cdddr x)  (cdr (cdr (cdr x))))
(define (cadddr x) (car (cdr (cdr (cdr x)))))

;; ── Keyword-style alist accessor: (:key alist) ────────────────────────────
;; Lets you write (:task state) instead of (assoc "task" state)
;; (get-field key alist) — get value from association list by string key
;; Use as: (get-field "task" state)  or define your own accessors
(define (get-field key rec)
  (let ((pair (assoc key rec)))
    (if pair (cadr pair) ())))

;; Keyword accessor — (field 'task state) — quotes the key
(defmacro field (key rec)
  `(get-field ,(symbol->string key) ,rec))

;; ── Threading macros ──────────────────────────────────────────────────────
;; (-> val (f a) (g b)) => (g (f val a) b)   — thread first
(defmacro -> (x . forms)
  (if (null? forms)
      x
      (let ((form (car forms))
            (rest (cdr forms)))
        (if (pair? form)
            `(-> (,(car form) ,x ,@(cdr form)) ,@rest)
            `(-> (,form ,x) ,@rest)))))

;; (->> val (f a) (g b)) => (g b (f a val))  — thread last
(defmacro ->> (x . forms)
  (if (null? forms)
      x
      (let ((form (car forms))
            (rest (cdr forms)))
        (if (pair? form)
            `(->> (,(car form) ,@(cdr form) ,x) ,@rest)
            `(->> (,form ,x) ,@rest)))))

;; ── Loop macros ───────────────────────────────────────────────────────────
;; (while test body...)
(defmacro while (test . body)
  `(let loop ()
     (when ,test ,@body (loop))))

;; (dotimes (i n) body...) — i from 0 to n-1
(defmacro dotimes (spec . body)
  `(let loop ((,(car spec) 0))
     (when (< ,(car spec) ,(cadr spec))
       ,@body
       (loop (+ ,(car spec) 1)))))

;; (dolist (x lst) body...) — iterate list
(defmacro dolist (spec . body)
  `(for-each (lambda (,(car spec)) ,@body) ,(cadr spec)))

;; (repeat n body...) — run body n times, ignoring index
(defmacro repeat (n . body)
  (let ((i (gensym "i")))
    `(dotimes (,i ,n) ,@body)))

;; (swap! a b) — swap two bindings
(defmacro swap! (a b)
  (let ((tmp (gensym "tmp")))
    `(let ((,tmp ,a))
       (set! ,a ,b)
       (set! ,b ,tmp))))

;; ── Boolean shorthands ────────────────────────────────────────────────────
(defmacro and2 (a b) `(if ,a ,b #f))
(defmacro or2  (a b) `(if ,a ,a ,b))

;; ── Math utilities ────────────────────────────────────────────────────────
(define (square x)     (* x x))
(define (cube x)       (* x x x))
(define (inc x)        (+ x 1))
(define (dec x)        (- x 1))
(define (average a b)  (/ (+ a b) 2))
(define (clamp v lo hi) (max lo (min hi v)))
(define (sign x)
  (cond ((> x 0) 1) ((< x 0) -1) (else 0)))

;; ── List utilities ────────────────────────────────────────────────────────
(define (last lst)
  (if (null? (cdr lst)) (car lst) (last (cdr lst))))

(define (init lst)
  (if (null? (cdr lst)) '() (cons (car lst) (init (cdr lst)))))

(define (flatten lst)
  (cond
    ((null? lst) '())
    ((pair? (car lst)) (append (flatten (car lst)) (flatten (cdr lst))))
    (else (cons (car lst) (flatten (cdr lst))))))

(define (zip lst1 lst2)
  (if (or (null? lst1) (null? lst2)) '()
      (cons (list (car lst1) (car lst2))
            (zip (cdr lst1) (cdr lst2)))))

(define (zip-with f lst1 lst2)
  (if (or (null? lst1) (null? lst2)) '()
      (cons (f (car lst1) (car lst2))
            (zip-with f (cdr lst1) (cdr lst2)))))

(define (take n lst)
  (if (or (= n 0) (null? lst)) '()
      (cons (car lst) (take (- n 1) (cdr lst)))))

(define (drop n lst)
  (if (or (= n 0) (null? lst)) lst
      (drop (- n 1) (cdr lst))))

(define (take-while pred lst)
  (if (or (null? lst) (not (pred (car lst)))) '()
      (cons (car lst) (take-while pred (cdr lst)))))

(define (drop-while pred lst)
  (if (or (null? lst) (not (pred (car lst)))) lst
      (drop-while pred (cdr lst))))

(define (range start end)
  (if (>= start end) '()
      (cons start (range (+ start 1) end))))

(define (iota n)        (range 0 n))
(define (iota-from s n) (range s (+ s n)))

(define (sum lst)      (foldl + 0 lst))
(define (product lst)  (foldl * 1 lst))

(define (any? pred lst)
  (cond ((null? lst) #f)
        ((pred (car lst)) #t)
        (else (any? pred (cdr lst)))))

(define (all? pred lst)
  (cond ((null? lst) #t)
        ((not (pred (car lst))) #f)
        (else (all? pred (cdr lst)))))

(define (none? pred lst)
  (not (any? pred lst)))

(define (count pred lst)
  (foldl (lambda (x acc) (if (pred x) (+ acc 1) acc)) 0 lst))

(define (find pred lst)
  (cond ((null? lst) #f)
        ((pred (car lst)) (car lst))
        (else (find pred (cdr lst)))))

(define (find-index pred lst)
  (let loop ((l lst) (i 0))
    (cond ((null? l) -1)
          ((pred (car l)) i)
          (else (loop (cdr l) (+ i 1))))))

(define (flatten1 lst)  (apply append lst))

(define (partition pred lst)
  (let loop ((l lst) (yes '()) (no '()))
    (cond ((null? l) (list (reverse yes) (reverse no)))
          ((pred (car l)) (loop (cdr l) (cons (car l) yes) no))
          (else           (loop (cdr l) yes (cons (car l) no))))))

(define (remove-duplicates lst)
  (let loop ((l lst) (seen '()))
    (cond ((null? l) (reverse seen))
          ((member (car l) seen) (loop (cdr l) seen))
          (else (loop (cdr l) (cons (car l) seen))))))

(define (list-copy lst)
  (if (null? lst) '() (cons (car lst) (list-copy (cdr lst)))))

(define (interleave x lst)
  (if (null? lst) '()
      (if (null? (cdr lst)) lst
          (cons (car lst) (cons x (interleave x (cdr lst)))))))

;; ── Association lists ─────────────────────────────────────────────────────
(define (assoc key alist)
  (cond ((null? alist) #f)
        ((equal? key (car (car alist))) (car alist))
        (else (assoc key (cdr alist)))))

(define (assq key alist)
  (cond ((null? alist) #f)
        ((eq? key (car (car alist))) (car alist))
        (else (assq key (cdr alist)))))

(define (alist-set key val alist)
  (cons (list key val)
        (filter (lambda (pair) (not (equal? (car pair) key))) alist)))

(define (alist-get key alist default)
  (let ((pair (assoc key alist)))
    (if pair (cadr pair) default)))

;; ── String utilities ──────────────────────────────────────────────────────
(define (string-join lst sep)
  (if (null? lst) ""
      (foldl (lambda (s acc) (string-append acc sep s))
             (car lst) (cdr lst))))

(define (string-repeat s n)
  (let loop ((i 0) (acc ""))
    (if (= i n) acc (loop (+ i 1) (string-append acc s)))))

(define (string-contains? str sub)
  (let* ((slen (string-length str))
         (sublen (string-length sub)))
    (let loop ((i 0))
      (cond ((> (+ i sublen) slen) #f)
            ((string=? (substring str i (+ i sublen)) sub) #t)
            (else (loop (+ i 1)))))))

(define (string-starts-with? str prefix)
  (and (>= (string-length str) (string-length prefix))
       (string=? (substring str 0 (string-length prefix)) prefix)))

(define (string-trim s)
  ; Trim leading and trailing whitespace
  (let* ((chars (string->list s))
         (trimmed (drop-while (lambda (c) (string=? c " ")) chars)))
    (string-join (reverse (drop-while (lambda (c) (string=? c " "))
                                      (reverse trimmed))) "")))

;; ── Functional utilities ──────────────────────────────────────────────────
(define (compose . fns)
  (if (null? fns)
      (lambda (x) x)
      (let ((fn (car fns))
            (rest (apply compose (cdr fns))))
        (lambda (x) (fn (rest x))))))

(define (curry f . args)
  (lambda rest (apply f (append args rest))))

(define (identity x) x)
(define (const x)    (lambda args x))
(define (flip f)     (lambda (a b) (f b a)))

(define (negate pred)
  (lambda (x) (not (pred x))))

(define (juxtapose . fns)
  (lambda (x) (map (lambda (f) (f x)) fns)))

(define (memoize f)
  (let ((cache '()))
    (lambda args
      (let ((cached (assoc args cache)))
        (if cached
            (cadr cached)
            (let ((result (apply f args)))
              (set! cache (cons (list args result) cache))
              result))))))

;; ── I/O ───────────────────────────────────────────────────────────────────
(define (print-list lst)
  (for-each (lambda (x) (display x) (newline)) lst))

;; ── Assertion helpers ─────────────────────────────────────────────────────
(define (assert condition msg)
  (when (not condition)
    (error (string-append "Assertion failed: " msg))))

;; ── Agent/state utilities ─────────────────────────────────────────────────
;; Immutable record update: (record-set alist key val)
(define (record-set rec key val)
  (alist-set key val rec))

;; Make a simple record
(define (make-record . pairs)
  (let loop ((ps pairs) (acc '()))
    (if (null? ps) (reverse acc)
        (loop (cddr ps)
              (cons (list (car ps) (cadr ps)) acc)))))


;; ── Pipeline-friendly list aliases (value-first, for use with ->) ─────────
;; These put the list first so -> threading works naturally
(define (map* lst f)    (map f lst))
(define (filter* lst f) (filter f lst))
(define (for-each* lst f) (for-each f lst))
(define (foldl* lst f init) (foldl f init lst))
