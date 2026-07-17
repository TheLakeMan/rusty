;; supervisor.lisp — certifiable supervision + isolation honesty for the
;; actor scheduler (pure Lisp library, zero interpreter changes).
;;
;; Erlang supervises on trust; here the two trust points become checkable:
;;   1. The restart POLICY is data, and its decision core is a pure
;;      function — certify-policy pins it in both directions with
;;      check-exhaustive ("never restart at/over budget, always under").
;;   2. A handler can be spawned from SOURCE through a static isolation
;;      check that runs BEFORE anything evaluates (2.1 gate ordering — a
;;      trojan never runs): set! only on declared owned names, calls only
;;      to declared names / a pure whitelist / send! (messages are the
;;      sanctioned interaction). Computed calls — ((car msg)) invoking a
;;      function smuggled in a message — are refused outright and cannot
;;      be declared away: every named piece can be whitelisted; only the
;;      call shape betrays it.
;;
;; Claim discipline: "policy proven budget-honest on the declared domain",
;; "handler source sets only its declared names" — never "safe".
;;
;; Supervision semantics (deliberate, receipted):
;;   - A child is (name init-thunk); init-thunk returns a FRESH handler,
;;     so restart re-initializes state (Erlang child semantics).
;;   - The in-flight message that crashed a handler is LOST (dequeued
;;     before handling, exactly like the plain scheduler and like Erlang's
;;     in-flight loss) — the crash receipt records it.
;;   - The budget is a per-child LIFETIME restart count, not Erlang's
;;     per-time-window rate: a time window would break determinism, and
;;     the lifetime count is the honest deterministic analog.
;;   - A failed child's queued mail drains to dead letters one message per
;;     step, so run-supervised still quiesces.
;;   - An init-thunk that crashes during restart becomes an init-crash
;;     receipt + give-up (it throws inside supervised-step's catch
;;     handler, so it needs its own try-catch), never a dead supervisor.
;; Missing vs Erlang, stated plainly: flat supervisor (no supervisor of
;; supervisors yet), no one-for-all / rest-for-one strategies.

;; ── Supervision ─────────────────────────────────────────────────────────

(define *sup-children* '())     ; ((name init restarts status) ...)
(define *sup-policy* '())
(define *sup-receipts* '())     ; ((crash name msg err restarts decision) ...)
(define *sup-dead-letters* '()) ; ((name msg) ...) — drained after give-up

(define (sup-reset!)
  (set! *sup-children* '())
  (set! *sup-policy* '())
  (set! *sup-receipts* '())
  (set! *sup-dead-letters* '())
  'ok)

;; THE CERTIFIABLE CORE — pure, total on its domain. restart iff budget left.
(define (supervisor-decide policy restarts)
  (if (< restarts (cadr policy)) 'restart 'give-up))

;; Budget honesty, proven by exhaustion (both directions — pins the
;; function): never 'restart at/over budget, always 'restart under it.
(define (certify-policy policy restart-domain)
  (check-exhaustive
    (lambda (r)
      (if (equal? (supervisor-decide policy r) 'restart)
          (< r (cadr policy))
          (>= r (cadr policy))))
    (list restart-domain)))

(define (sup-child name)
  (assoc name *sup-children*))

(define (sup-child-update! name restarts status)
  (set! *sup-children*
        (map (lambda (c)
               (if (equal? (car c) name)
                   (list (car c) (cadr c) restarts status)
                   c))
             *sup-children*)))

(define (sup-agent-replace! name handler)
  (set! *agents*
        (map (lambda (e) (if (equal? (car e) name) (list name handler) e))
             *agents*)))

(define (supervise! children policy)
  (agent-reset!)
  (sup-reset!)
  (set! *sup-policy* policy)
  (set! *sup-children*
        (map (lambda (c) (list (car c) (cadr c) 0 'running)) children))
  (map (lambda (c) (agent-spawn (car c) ((cadr c)))) children)
  'supervised)

(define (sup-running? name)
  (let ((c (sup-child name)))
    (if c (equal? (cadddr c) 'running) #f)))

(define (sup-handle-crash! name msg err)
  (let* ((c (sup-child name))
         (restarts (caddr c))
         (decision (supervisor-decide *sup-policy* restarts)))
    (set! *sup-receipts*
          (append *sup-receipts*
                  (list (list 'crash name msg err restarts decision))))
    (if (equal? decision 'restart)
        ;; the init-thunk itself may crash on restart — that must become a
        ;; receipt + give-up, not kill the supervisor (we're already inside
        ;; supervised-step's catch handler, so a throw here escapes it)
        (try-catch
          (begin
            (sup-child-update! name (+ restarts 1) 'running)
            (sup-agent-replace! name ((cadr c)))  ; fresh handler = fresh state
            'restarted)
          (e2)
          (begin
            (set! *sup-receipts*
                  (append *sup-receipts*
                          (list (list 'init-crash name e2 'give-up))))
            (sup-child-update! name (+ restarts 1) 'failed)
            'gave-up))
        (begin
          (sup-child-update! name restarts 'failed)
          'gave-up))))

;; Like agents-step, but: a failed child's queued messages drain to dead
;; letters (one per step, so the loop still quiesces), and a handler crash
;; becomes a receipt + policy decision instead of killing the run.
(define (supervised-step)
  (let scan ((as *agents*))
    (if (null? as)
        #f
        (let* ((name (car (car as)))
               (q (cadr (assoc name *mailboxes*))))
          (cond ((null? q) (scan (cdr as)))
                ((not (sup-running? name))
                 (begin
                   (mailbox-set! name (cdr q))
                   (set! *sup-dead-letters*
                         (append *sup-dead-letters* (list (list name (car q)))))
                   #t))
                (else
                  (let ((handler (cadr (assoc name *agents*))))
                    (mailbox-set! name (cdr q))
                    (try-catch
                      (handler (car q))
                      (e) (sup-handle-crash! name (car q) e))
                    #t)))))))

(define (run-supervised . opt)
  (let ((max-steps (if (null? opt) 10000 (car opt))))
    (let loop ((n 0))
      (cond ((agents-idle?) (list 'quiescent n))
            ((>= n max-steps) (list 'hit-max-steps n))
            (else (begin (supervised-step) (loop (+ n 1))))))))

(define (sup-report)
  (list 'children (map (lambda (c) (list (car c) (caddr c) (cadddr c)))
                       *sup-children*)
        'receipts (length *sup-receipts*)
        'dead-letters *sup-dead-letters*))

;; ── Isolation honesty ───────────────────────────────────────────────────
;; A handler is spawned from SOURCE (s-expr data, evolve.lisp-style), and
;; the source is refused BEFORE evaluation unless every (set! x ...) target
;; is in the declared owned list and every called name is declared, a
;; whitelisted pure builtin, or send!. Conservative direction throughout:
;; over-collection can only cause false refusal (e.g. set! on a handler's
;; own let-bound name needs declaring). One-level check by design —
;; declared calls are trusted; certify helpers separately (or run this
;; checker on their source too). quote is skipped (inert data);
;; quasiquote is walked in FULL (over-approximation, same safe direction).

(define *iso-specials*
  '(if cond else let let* letrec lambda define begin when unless and or
    quote quasiquote unquote unquote-splicing set! do match try-catch))

(define *iso-pure-whitelist*
  '(+ - * / < > <= >= = equal? not null? car cdr cons list append length
    assoc member map filter reverse cadr caddr cadddr modulo mod min max abs))

(define (iso-collect expr acc)
  ;; acc = (set-targets called-names); returns updated acc
  (if (not (pair? expr))
      acc
      (let ((head (car expr)))
        (cond ((equal? head 'quote) acc)
              ((equal? head 'set!)
               (iso-collect (caddr expr)
                            (list (cons (cadr expr) (car acc)) (cadr acc))))
              ;; binder forms: skip the binder positions, walk inits + body —
              ;; a param list is names, not an application
              ((equal? head 'lambda)
               (iso-collect-list (cddr expr) acc))
              ((member head '(let let* letrec))
               (if (symbol? (cadr expr))   ; named let
                   (iso-collect-list (append (map cadr (caddr expr))
                                             (cdr (cddr expr)))
                                     acc)
                   (iso-collect-list (append (map cadr (cadr expr))
                                             (cddr expr))
                                     acc)))
              ((equal? head 'define)
               (if (pair? (cadr expr))
                   (iso-collect-list (cddr expr) acc)   ; (define (f a) body)
                   (iso-collect (caddr expr) acc)))     ; (define x init)
              ((member head *iso-specials*)
               (iso-collect-list (cdr expr) acc))
              ((symbol? head)
               (iso-collect-list (cdr expr)
                                 (list (car acc) (cons head (cadr acc)))))
              ;; computed call — ((car msg)), ((lambda ...) x): the callee is
              ;; not a name we can check, so it could be anything smuggled in
              ;; a message. Refused outright (false refusals accepted).
              (else (iso-collect-list expr
                                      (list (car acc)
                                            (cons 'computed-call (cadr acc)))))))))

(define (iso-collect-list exprs acc)
  (if (null? exprs)
      acc
      (iso-collect-list (cdr exprs) (iso-collect (car exprs) acc))))

(define (isolation-check source owned allowed-calls)
  (let* ((acc (iso-collect source (list '() '())))
         (bad-sets (filter (lambda (x) (not (member x owned))) (car acc)))
         (bad-calls (filter (lambda (f)
                              (if (equal? f 'computed-call)
                                  #t   ; never declarable — see iso-collect
                                  (and (not (member f allowed-calls))
                                       (not (member f *iso-pure-whitelist*))
                                       (not (equal? f 'send!)))))
                            (cadr acc))))
    (if (and (null? bad-sets) (null? bad-calls))
        'isolated
        (list 'refused
              (append (map (lambda (x) (list 'set!-outside x)) (reverse bad-sets))
                      (map (lambda (f) (list 'undeclared-call f)) (reverse bad-calls)))))))

;; Refuse-by-default spawn: static check FIRST, eval only after it passes
;; (same gate ordering as 2.1 — a trojan source is never evaluated).
(define (agent-spawn-isolated name source owned allowed-calls)
  (let ((verdict (isolation-check source owned allowed-calls)))
    (if (equal? verdict 'isolated)
        (begin (agent-spawn name (eval source)) (list 'spawned name))
        verdict)))
