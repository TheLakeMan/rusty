;;; std.lisp — Rusty Standard Library v1.1
;;; Auto-loaded on startup.

;; ── List accessors ─────────────────────────────────────────────────────────
(define (caar x)   (car (car x)))
(define (cadr x)   (car (cdr x)))
(define (cdar x)   (cdr (car x)))
(define (cddr x)   (cdr (cdr x)))
(define (caddr x)  (car (cdr (cdr x))))
(define (cadddr x) (car (cdr (cdr (cdr x)))))

;; ── Record / alist access ──────────────────────────────────────────────────
(define (get-field key rec)
  (let ((pair (assoc key rec)))
    (if pair (cadr pair) ())))

(defmacro field (key rec)
  `(get-field ,(symbol->string key) ,rec))

(define (record-set rec key val)
  (cons (list key val)
        (filter (lambda (p) (not (equal? (car p) key))) rec)))

(define (make-record . pairs)
  (let loop ((ps pairs) (acc '()))
    (if (null? ps) (reverse acc)
        (loop (cddr ps)
              (cons (list (car ps) (cadr ps)) acc)))))

;; ── Threading macros ───────────────────────────────────────────────────────
(defmacro -> (x . forms)
  (if (null? forms) x
      (let ((form (car forms)) (rest (cdr forms)))
        (if (pair? form)
            `(-> (,(car form) ,x ,@(cdr form)) ,@rest)
            `(-> (,form ,x) ,@rest)))))

(defmacro ->> (x . forms)
  (if (null? forms) x
      (let ((form (car forms)) (rest (cdr forms)))
        (if (pair? form)
            `(->> (,(car form) ,@(cdr form) ,x) ,@rest)
            `(->> (,form ,x) ,@rest)))))

;; ── Loop macros ────────────────────────────────────────────────────────────
(defmacro while (test . body)
  `(let loop ()
     (when ,test ,@body (loop))))

(defmacro dotimes (spec . body)
  `(let loop ((,(car spec) 0))
     (when (< ,(car spec) ,(cadr spec))
       ,@body
       (loop (+ ,(car spec) 1)))))

(defmacro dolist (spec . body)
  `(for-each (lambda (,(car spec)) ,@body) ,(cadr spec)))

(defmacro repeat (n . body)
  (let ((i (gensym "i")))
    `(dotimes (,i ,n) ,@body)))

(defmacro swap! (a b)
  (let ((tmp (gensym "tmp")))
    `(let ((,tmp ,a))
       (set! ,a ,b)
       (set! ,b ,tmp))))

;; ── Macro profiler ─────────────────────────────────────────────────────────
;; (macro-profile-on) / (macro-profile-off) toggle instrumentation (off by
;; default — zero overhead when unused). (macro-profile-report) returns raw
;; (name call-count total-microseconds) rows, sorted by total time
;; descending; (show-macro-profile) pretty-prints them.
(define (show-macro-profile)
  (println "Macro expansion profile (name  calls  total-us):")
  (for-each
    (lambda (row)
      (println (format "  ~a  ~a  ~a" (car row) (cadr row) (caddr row))))
    (macro-profile-report)))

;; ── Math ───────────────────────────────────────────────────────────────────
(define (square x)      (* x x))
(define (cube x)        (* x x x))
(define (inc x)         (+ x 1))
(define (dec x)         (- x 1))
(define (average a b)   (/ (+ a b) 2))
(define (clamp v lo hi) (max lo (min hi v)))
(define (sign x)        (cond ((> x 0) 1) ((< x 0) -1) (else 0)))

;; ── List utilities ─────────────────────────────────────────────────────────
(define (last lst)
  (if (null? (cdr lst)) (car lst) (last (cdr lst))))

(define (flatten lst)
  (cond ((null? lst) '())
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

;; Tail-recursive (builds back-to-front) so the evaluator's TCO applies —
;; the naive cons-position recursion overflowed the stack past ~200 elements.
(define (range start end)
  (let loop ((i (- end 1)) (acc '()))
    (if (< i start) acc
        (loop (- i 1) (cons i acc)))))

(define (iota n)   (range 0 n))
(define (sum lst)  (foldl + 0 lst))
(define (product lst) (foldl * 1 lst))

(define (any? pred lst)
  (cond ((null? lst) #f)
        ((pred (car lst)) #t)
        (else (any? pred (cdr lst)))))

(define (all? pred lst)
  (cond ((null? lst) #t)
        ((not (pred (car lst))) #f)
        (else (all? pred (cdr lst)))))

(define (none? pred lst) (not (any? pred lst)))

(define (count pred lst)
  (foldl (lambda (x acc) (if (pred x) (+ acc 1) acc)) 0 lst))

(define (find pred lst)
  (cond ((null? lst) #f)
        ((pred (car lst)) (car lst))
        (else (find pred (cdr lst)))))

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

(define (flatten1 lst) (apply append lst))

(define (interleave x lst)
  (if (or (null? lst) (null? (cdr lst))) lst
      (cons (car lst) (cons x (interleave x (cdr lst))))))

;; ── Association lists ──────────────────────────────────────────────────────
(define (assoc key alist)
  (cond ((null? alist) #f)
        ((equal? key (car (car alist))) (car alist))
        (else (assoc key (cdr alist)))))

(define (assq key alist)
  (cond ((null? alist) #f)
        ((eq? key (car (car alist))) (car alist))
        (else (assq key (cdr alist)))))

(define (alist-get key alist default)
  (let ((pair (assoc key alist)))
    (if pair (cadr pair) default)))

;; ── Strings ────────────────────────────────────────────────────────────────
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

;; ── Functional ─────────────────────────────────────────────────────────────
(define (compose . fns)
  (if (null? fns) (lambda (x) x)
      (let ((fn (car fns))
            (rest (apply compose (cdr fns))))
        (lambda (x) (fn (rest x))))))

(define (curry f . args)
  (lambda rest (apply f (append args rest))))

(define (identity x)  x)
(define (const x)     (lambda args x))
(define (flip f)      (lambda (a b) (f b a)))
(define (negate pred) (lambda (x) (not (pred x))))

(define (memoize f)
  (let ((cache '()))
    (lambda args
      (let ((hit (assoc args cache)))
        (if hit (cadr hit)
            (let ((result (apply f args)))
              (set! cache (cons (list args result) cache))
              result))))))

;; Pipeline-friendly aliases (list first, for use with ->)
(define (map* lst f)      (map f lst))
(define (filter* lst f)   (filter f lst))
(define (foldl* lst f i)  (foldl f i lst))

;; ── I/O ────────────────────────────────────────────────────────────────────
(define (print-list lst)
  (for-each (lambda (x) (display x) (newline)) lst))

;; ── Assertions ─────────────────────────────────────────────────────────────
;; A macro (not a plain function) so it can capture the literal condition
;; text for a useful default message when none is given.
(defmacro assert (condition . msg)
  (if (null? msg)
      `(when (not ,condition)
         (error (string-append "Assertion failed: " (format "~a" (quote ,condition)))))
      `(when (not ,condition) (error ,(car msg)))))

;; ── Constraint embedding ───────────────────────────────────────────────────
;; (defun-constrained (name params...) (assert cond [msg])... body...)
;; Like `define`, but any leading (assert ...) forms are checked against the
;; function's own arguments on every call, before body runs — the function
;; either satisfies its declared invariants or fails loudly, instead of
;; silently computing a wrong/undefined result.
(define (constrained-checks forms)
  (if (and (pair? forms) (pair? (car forms)) (equal? (car (car forms)) 'assert))
      (cons (car forms) (constrained-checks (cdr forms)))
      '()))

(define (constrained-body forms)
  (if (and (pair? forms) (pair? (car forms)) (equal? (car (car forms)) 'assert))
      (constrained-body (cdr forms))
      forms))

(defmacro defun-constrained (sig . forms)
  `(define ,sig ,@(constrained-checks forms) ,@(constrained-body forms)))

;; ── Logic-driven loss functions ────────────────────────────────────────────
;; Crisp propositional logic mapped to a fixed penalty — meant to be summed
;; or weighted into a larger loss alongside numeric terms. This is NOT
;; fuzzy/differentiable logic, so gradients don't flow through it; a
;; soft-relaxed version is future work, not this.
(defmacro implies (p q) `(or (not ,p) ,q))
(defmacro logic-loss (formula) `(if ,formula 0 1))

;; ── Gradual typing ───────────────────────────────────────────────────────
;; (define-typed (name (p1 : t1) (p2 : t2) untyped-p3 ...) : return-type
;;   body...)
;; plain `define`/`lambda` are completely untouched by this — define-typed
;; is an opt-in macro, so annotate only the functions (and only the
;; parameters) you want checked. Each ti/return-type must name an existing
;; `<type>?` predicate (number, string, boolean, symbol, list, procedure,
;; ...); checks run at call time (runtime contracts, not static analysis —
;; real flow-sensitive static typing is a much larger undertaking than a
;; library macro can give you). No rest-arg (`.`) support in v1.
(define (type-check-form val-expr type)
  (let ((pred (string->symbol (string-append (symbol->string type) "?"))))
    `(assert (,pred ,val-expr) ,(string-append "expected " (symbol->string type) ", got a different type"))))

(define (typed-param-name p) (if (pair? p) (car p) p))
(define (typed-param-type p) (if (pair? p) (caddr p) 'unknown))
(define (typed-param-check p)
  (if (pair? p) (type-check-form (typed-param-name p) (caddr p)) #f))

;; Expansion also calls register-signature so check-types (the static
;; checker) can see through calls to this function — declared types would
;; otherwise vanish after macro expansion. Unannotated positions register
;; as 'unknown (never flagged).
(defmacro define-typed (sig . rest)
  (let ((name (car sig)) (params (cdr sig)))
    (let ((checks (filter (lambda (x) x) (map typed-param-check params)))
          (names  (map typed-param-name params))
          (ptypes (map typed-param-type params)))
      (if (and (pair? rest) (equal? (car rest) ':))
          (let ((rtype (cadr rest)) (body (cddr rest)) (result (gensym "result")))
            `(begin
               (register-signature (quote ,name) (quote ,ptypes) (quote ,rtype))
               (define (,name ,@names)
                 ,@checks
                 (let ((,result (begin ,@body)))
                   ,(type-check-form result rtype)
                   ,result))))
          `(begin
             (register-signature (quote ,name) (quote ,ptypes) (quote unknown))
             (define (,name ,@names) ,@checks ,@rest))))))

;; ── Proof-by-checker loop ──────────────────────────────────────────────────
;; Synthesis with Rusty's own checkers as the verifier (ROADMAP 2.1): a
;; proposer suggests candidate functions, verify-candidate gates each one,
;; and only a candidate that passes every gate is accepted. The LLM is just
;; one possible proposer — the loop is proposer-agnostic, so it works (and
;; is tested) with a plain scripted proposer too.
;;
;; spec is an alist:
;;   (pure #t)              — candidate must pass check-effects
;;   (types ((p type)...))  — candidate must pass check-types with these
;;   (domains ((v...)...))  — finite domains for exhaustive checking
;;   (invariant f)          — (invariant candidate args...) must hold on
;;                            every domain combination
;; STATIC gates (pure/types) run first and never execute the candidate —
;; an LLM-proposed candidate with visible side effects is rejected without
;; ever being run. Only then does the exhaustive (executing) check fire.
(define (spec-get spec key default)
  (let ((hit (assoc key spec)))
    (if hit (cadr hit) default)))

(define (verify-candidate f spec)
  (if (not (procedure? f))
      (list (list 'not-a-function f))
      (verify-candidate-checks f spec)))

(define (verify-candidate-checks f spec)
  (let ((static-reasons '()))
    (when (spec-get spec 'pure #f)
      (let ((eff (check-effects f)))
        (when (not (equal? eff 'pure))
          (set! static-reasons (cons (list 'impure eff) static-reasons)))))
    (let ((types (spec-get spec 'types #f)))
      (when types
        (let ((t (check-types f types)))
          (when (not (equal? t 'ok))
            (set! static-reasons (cons (list 'type-errors t) static-reasons))))))
    (if (not (null? static-reasons))
        static-reasons
        (let ((domains   (spec-get spec 'domains #f))
              (invariant (spec-get spec 'invariant #f)))
          (if (and domains invariant)
              (let ((result (check-exhaustive
                              (lambda args (apply invariant (cons f args)))
                              domains)))
                (if (equal? result 'verified)
                    'verified
                    (list (list 'counterexamples result))))
              'verified)))))

;; A misbehaving proposer (LLM replying with prose, markdown fences, a
;; define instead of a lambda, unparseable text...) must cost one attempt
;; with feedback, never crash the loop — so both the proposal and its
;; verification run inside try-catch.
(define (synthesize-verified spec proposer max-attempts)
  (let loop ((attempt 1) (feedback '()))
    (if (> attempt max-attempts)
        (list 'failed (reverse feedback))
        (let ((outcome
                (try-catch
                  (let ((candidate (proposer attempt feedback)))
                    (let ((result (verify-candidate candidate spec)))
                      (if (equal? result 'verified)
                          (list 'ok candidate)
                          (list 'rejected result))))
                  (e) (list 'rejected (list (list 'error e))))))
          (if (equal? (car outcome) 'ok)
              ;; (verified <fn> <attempts-used>) — caddr tells you whether
              ;; the proposer nailed it first try or needed feedback rounds
              (list 'verified (cadr outcome) attempt)
              (loop (+ attempt 1)
                    (cons (list attempt (cadr outcome)) feedback)))))))

;; Pull the s-expression out of an LLM reply that may wrap it in markdown
;; fences or prose: everything from the first "(" through the last ")".
(define (string-first-index s ch)
  (let ((n (string-length s)))
    (let loop ((i 0))
      (cond ((>= i n) #f)
            ((equal? (string-ref s i) ch) i)
            (else (loop (+ i 1)))))))

(define (string-last-index s ch)
  (let loop ((i (- (string-length s) 1)))
    (cond ((< i 0) #f)
          ((equal? (string-ref s i) ch) i)
          (else (loop (- i 1))))))

(define (extract-sexp text)
  (let ((start (string-first-index text "("))
        (end   (string-last-index text ")")))
    (if (and start end (> end start))
        (substring text start (+ end 1))
        text)))

;; LLM-backed proposer (needs a llama-server-compatible endpoint running —
;; see the llm builtin). Generated text becomes a callable via eval-string;
;; verification failures are fed back into the next prompt.
(define (llm-proposer task)
  (lambda (attempt feedback)
    (eval-string
      (extract-sexp
        (llm (string-append
               "Write a single Rusty Lisp lambda for this task: " task
               (if (null? feedback) ""
                   (format "\nEarlier attempts failed verification: ~a" feedback))
               "\nReply with ONLY the lambda s-expression, nothing else.")
             0.2 300)))))

;; ── Tool specifications & chain certification ──────────────────────────────
;; ROADMAP 2.3: contracts for deftool tools, reusing the 2.1/2.2 checkers
;; rather than a second contract system. A spec declares param types, the
;; effect OPERATIONS the tool is allowed to perform (op names as known to
;; check-effects / effectful?, e.g. shell print write-file), an optional
;; precondition over the args, and dependencies on other tools.
(define *tool-specs* '())

(define (deftool-spec tool param-types effects precondition deps)
  (set! *tool-specs*
    (cons (list (tool-name tool) tool param-types effects precondition deps)
          (filter (lambda (s) (not (equal? (car s) (tool-name tool)))) *tool-specs*)))
  (tool-name tool))

(define (tool-spec name) (assoc name *tool-specs*))
(define (spec-tool-value s)  (cadr s))
(define (spec-param-types s) (caddr s))
(define (spec-effects s)     (cadddr s))
(define (spec-pre s)         (nth s 4))
(define (spec-deps s)        (nth s 5))

(define (type-pred ty)
  (cond ((equal? ty 'number)    number?)
        ((equal? ty 'string)    string?)
        ((equal? ty 'boolean)   boolean?)
        ((equal? ty 'symbol)    symbol?)
        ((equal? ty 'list)      list?)
        ((equal? ty 'procedure) procedure?)
        (else (lambda (v) #t))))          ; unknown/unannotated — never flagged

;; Contract-enforced invocation: arity, arg types, and precondition are all
;; checked BEFORE the tool body runs — a violated contract raises instead of
;; letting the tool fire on bad inputs (these tools touch the real system).
(define (safe-call tool . args)
  (let ((s (tool-spec (tool-name tool))))
    (assert s (format "safe-call: no spec registered for ~a" (tool-name tool)))
    (assert (= (length args) (length (spec-param-types s)))
            (format "safe-call: ~a expects ~a arg(s), got ~a"
                    (tool-name tool) (length (spec-param-types s)) (length args)))
    (for-each
      (lambda (pair)
        (let ((arg (car pair)) (pt (cadr pair)))
          (assert ((type-pred (cadr pt)) arg)
                  (format "safe-call: ~a: ~a must be ~a" (tool-name tool) (car pt) (cadr pt)))))
      (zip args (spec-param-types s)))
    (when (spec-pre s)
      (assert (apply (spec-pre s) args)
              (format "safe-call: ~a: precondition violated" (tool-name tool))))
    (apply tool args)))

;; Effect honesty: every operation check-effects finds in the tool's body
;; must be covered by its declared effects list — a tool can't claim less
;; than it does. (Static, never executes the tool.)
(define (finding-op f) (string->symbol (substring f 0 (string-first-index f ":"))))

(define (undeclared-effects tool declared)
  (let ((found (check-effects tool)))
    (if (equal? found 'pure) '()
        (filter (lambda (op) (not (member op declared)))
                (remove-duplicates (map finding-op found))))))

;; Chain certification: takes a list of tool VALUES in intended execution
;; order; every tool must have a spec, be honest about its effects, and
;; have its declared dependencies appear EARLIER in the chain.
;; Returns 'certified or a list of (tool-name reason...) findings.
(define (certify-tool-chain chain)
  (let loop ((rest chain) (seen '()) (problems '()))
    (if (null? rest)
        (if (null? problems) 'certified (reverse problems))
        (let ((tool (car rest)))
          (let ((name (tool-name tool)) (s (tool-spec (tool-name tool))))
            (cond
              ((not s)
               (loop (cdr rest) (cons name seen)
                     (cons (list name 'no-spec) problems)))
              (else
               (let ((lies (undeclared-effects tool (spec-effects s)))
                     (missing (filter (lambda (d) (not (member d seen))) (spec-deps s))))
                 (loop (cdr rest) (cons name seen)
                       (append
                         (if (null? missing) '()
                             (list (list name 'deps-not-satisfied missing)))
                         (if (null? lies) '()
                             (list (list name 'undeclared-effects lies)))
                         problems))))))))))

;; ── Actor-model message passing (Phase 3.2) ────────────────────────────────
;; Agents are named handler functions with a FIFO mailbox each. (send! to msg)
;; enqueues; (run-agents) pops one message at a time — agents visited in spawn
;; order, deterministic — and runs the recipient's handler to completion,
;; which may send! more messages. Runs until every mailbox is empty
;; ('quiescent) or the step cap is hit ('hit-max-steps — the guard against
;; infinite ping-pong). Handlers hold state by set!-ing an enclosing binding.
;; Single-threaded and cooperative by design: Rusty's runtime is Rc-based, so
;; concurrency here means interleaved message handling, not threads.

(define *agents* '())      ; ((name handler) ...) in spawn order
(define *mailboxes* '())   ; ((name (msg ...)) ...) FIFO queues

(define (agent-reset!)
  (set! *agents* '())
  (set! *mailboxes* '())
  'ok)

(define (agent-spawn name handler)
  (if (assoc name *agents*)
      (list 'error 'agent-exists name)
      (begin
        (set! *agents* (append *agents* (list (list name handler))))
        (set! *mailboxes* (append *mailboxes* (list (list name '()))))
        name)))

(define (agent-names) (map car *agents*))

(define (mailbox-count name)
  (let ((e (assoc name *mailboxes*)))
    (if e (length (cadr e)) (list 'error 'no-such-agent name))))

(define (mailbox-set! name q)
  (set! *mailboxes*
        (map (lambda (e) (if (equal? (car e) name) (list name q) e))
             *mailboxes*)))

(define (send! to msg)
  (let ((e (assoc to *mailboxes*)))
    (if e
        (begin (trace-event 'send to)             ; no-op unless (trace-on)
               (mailbox-set! to (append (cadr e) (list msg)))
               'sent)
        (list 'error 'no-such-agent to))))

;; Process exactly one pending message (first spawned agent with a non-empty
;; mailbox). Returns #t if a message was handled, #f if all mailboxes empty.
(define (agents-step)
  (let scan ((as *agents*))
    (if (null? as)
        #f
        (let* ((name (car (car as)))
               (handler (cadr (car as)))
               (q (cadr (assoc name *mailboxes*))))
          (if (null? q)
              (scan (cdr as))
              (begin
                (trace-event 'agent-handle name)  ; no-op unless (trace-on)
                (mailbox-set! name (cdr q))   ; dequeue BEFORE handling, so a
                (handler (car q))             ; handler send!-ing to itself works
                #t))))))

(define (agents-idle?)
  (null? (filter (lambda (e) (not (null? (cadr e)))) *mailboxes*)))

(define (run-agents . opt)
  (let ((max-steps (if (null? opt) 10000 (car opt))))
    (let loop ((n 0))
      (cond ((agents-idle?) (list 'quiescent n))
            ((>= n max-steps) (list 'hit-max-steps n))
            (else (begin (agents-step) (loop (+ n 1))))))))

;; ── Agent tools ────────────────────────────────────────────────────────────
(try-catch
  (load "agent.lisp")
  (e) ())   ; silently skip if not found
