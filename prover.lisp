;; prover.lisp — a proof assistant for the invariants Rusty can express
;; (Phase 4.3). LCF-style: PROPOSITIONS are data, TACTICS are functions
;; that restructure goals, and the discharge oracle is 2.1's
;; check-exhaustive — so "proved" means *checked on every point of the
;; stated finite domains*, bounded verification by construction, never a
;; claim about unbounded mathematics (see docs/ROADMAP.md 4.3).
;;
;; Propositions:
;;   (forall ((var (v1 v2 ...)) ...) prop)    bounded quantification
;;   (implies p q) | (and p ...) | (or p ...) | (not p)
;;   <expr>                                    atomic: any Lisp expression
;;                                             over the bound variables
;;
;; A GOAL is (bindings hypotheses prop). Tactics return 'discharged,
;; (goals g...), or raise. Proof STATE is a list of open goals; a
;; STRATEGY is (lambda (state) state). Strategy combinators and defproof
;; are macros — proof patterns as syntax (roadmap item 2).

;; ── Goals ─────────────────────────────────────────────────────────────────
(define (new-goal prop) (list '() '() prop))
(define (goal-bindings g) (car g))
(define (goal-hyps g)     (cadr g))
(define (goal-prop g)     (caddr g))

;; ── Compiling a proposition to a checkable expression ────────────────────
(define (prop->expr p)
  (cond ((and (pair? p) (equal? (car p) 'forall))
         (error "prover: intro the forall first (intros)"))
        ((and (pair? p) (equal? (car p) 'implies))
         (list 'or (list 'not (prop->expr (cadr p))) (prop->expr (caddr p))))
        ((and (pair? p) (or (equal? (car p) 'and) (equal? (car p) 'or)))
         (cons (car p) (map prop->expr (cdr p))))
        ((and (pair? p) (equal? (car p) 'not))
         (list 'not (prop->expr (cadr p))))
        (else p)))

(define (goal->expr g)
  (let ((hyps (goal-hyps g)) (prop (goal-prop g)))
    (prop->expr (if (null? hyps) prop (list 'implies (cons 'and hyps) prop)))))

;; ── Core tactics (goal → 'discharged | (goals ...) | raise) ─────────────
(define (intros g)                     ; peel a leading forall into bindings
  (let ((p (goal-prop g)))
    (if (and (pair? p) (equal? (car p) 'forall))
        (list 'goals (list (append (goal-bindings g) (cadr p))
                           (goal-hyps g)
                           (caddr p)))
        (error "intros: goal is not a forall"))))

(define (intro g)                      ; move an implication's premise to hyps
  (let ((p (goal-prop g)))
    (if (and (pair? p) (equal? (car p) 'implies))
        (list 'goals (list (goal-bindings g)
                           (append (goal-hyps g) (list (cadr p)))
                           (caddr p)))
        (error "intro: goal is not an implication"))))

(define (split g)                      ; conjunction → one goal per conjunct
  (let ((p (goal-prop g)))
    (if (and (pair? p) (equal? (car p) 'and))
        (cons 'goals (map (lambda (c) (list (goal-bindings g) (goal-hyps g) c))
                          (cdr p)))
        (error "split: goal is not a conjunction"))))

(define (exhaust g)                    ; THE oracle: check every domain point
  (let ((bs (goal-bindings g)))
    (if (null? bs)
        (if (eval (goal->expr g)) 'discharged
            (error (format "exhaust: proposition is false: ~a" (goal->expr g))))
        (let ((f (eval (list 'lambda (map car bs) (goal->expr g)))))
          (let ((r (check-exhaustive f (map cadr bs))))
            (if (equal? r 'verified) 'discharged
                (error (format "exhaust: counterexamples ~a" r))))))))

;; ── Theorems: proved propositions, reusable as lemmas ───────────────────
(define *theorems* '())
(define (register-theorem name prop)
  (set! *theorems* (cons (list name prop) *theorems*)))
(define (theorem name)
  (let ((hit (assoc name *theorems*)))
    (if hit (cadr hit) (error (format "no theorem named ~a" name)))))

(define (lemma name)                   ; tactic: goal matches a proved theorem
  (lambda (g)
    (if (equal? (goal-prop g) (theorem name))
        'discharged
        (error (format "lemma ~a does not match the goal" name)))))

;; ── Refutation: the honest failure mode, counterexample as data ─────────
(define (find-counterexample prop)
  (let ((g (new-goal prop)))
    (let ((g2 (if (and (pair? prop) (equal? (car prop) 'forall))
                  (cadr (intros g)) g)))
      (let ((bs (goal-bindings g2)))
        (if (null? bs)
            (if (eval (goal->expr g2)) 'no-counterexample (list 'false prop))
            (let ((f (eval (list 'lambda (map car bs) (goal->expr g2)))))
              (let ((r (check-exhaustive f (map cadr bs))))
                (if (equal? r 'verified) 'no-counterexample
                    (list 'counterexamples r)))))))))

;; ── State level: strategies ──────────────────────────────────────────────
(define (apply-tactic tac state)       ; apply to the FIRST open goal
  (if (null? state)
      state
      (let ((r (tac (car state))))
        (cond ((equal? r 'discharged) (cdr state))
              ((and (pair? r) (equal? (car r) 'goals))
               (append (cdr r) (cdr state)))
              (else (error (format "tactic returned ~a" r)))))))

(define (step tac) (lambda (state) (apply-tactic tac state)))

;; ── Proof strategy MACROS (roadmap 4.3, item 2) ──────────────────────────
;; High-level proof patterns as syntax. tactic-seq runs strategies in
;; order; tactic-repeat runs one to fixpoint; tactic-or takes the first
;; that applies; auto is the pattern that proves most bounded goals:
;; keep structuring (intros/intro/split) until only exhaust remains.
(defmacro tactic-seq (s1 . more)
  `(lambda (st) (foldl (lambda (s acc) (s acc)) st (list ,s1 ,@more))))

(defmacro tactic-repeat (s)
  `(lambda (st)
     (let rep ((cur st))
       (let ((nxt (try-catch (,s cur) (e) cur)))
         (if (equal? nxt cur) cur (rep nxt))))))

(defmacro tactic-or (a b)
  `(lambda (st) (try-catch (,a st) (e) (,b st))))

(define (auto-step g)                  ; dispatch one structuring move
  (let ((p (goal-prop g)))
    (cond ((and (pair? p) (equal? (car p) 'forall))  (intros g))
          ((and (pair? p) (equal? (car p) 'implies)) (intro g))
          ((and (pair? p) (equal? (car p) 'and))     (split g))
          (else (exhaust g)))))

(defmacro auto ()
  `(tactic-repeat (step auto-step)))

;; defproof: run a proof script against a proposition; register the
;; theorem only if every goal is discharged. The proposition and name are
;; taken unevaluated — proofs read like statements, not calls.
(defmacro defproof (name prop . script)
  `(let ((final ((tactic-seq ,@script) (list (new-goal (quote ,prop))))))
     (if (null? final)
         (begin (register-theorem (quote ,name) (quote ,prop))
                (list 'proved (quote ,name)))
         (list 'unproved (quote ,name) 'open-goals (length final)))))

;; ── Interactive layer (state in a global — checkpointable, 3.2-style) ───
(define *proof-state* '())
(define *proof-goal-name* #f)
(define *proof-goal-prop* #f)
(define (prove name prop)
  (set! *proof-state* (list (new-goal prop)))
  (set! *proof-goal-name* name)
  (set! *proof-goal-prop* prop)
  (list 'proving name 'goals 1))
(define (tac! tac)
  (set! *proof-state* (apply-tactic tac *proof-state*))
  (list 'open-goals (length *proof-state*)))
(define (goals) *proof-state*)
(define (qed)
  (if (null? *proof-state*)
      (begin (register-theorem *proof-goal-name* *proof-goal-prop*)
             (list 'qed *proof-goal-name*))
      (error (format "qed: ~a goal(s) still open" (length *proof-state*)))))
