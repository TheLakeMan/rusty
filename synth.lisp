;; synth.lisp — sketch-based program synthesis, CEGIS-style (Phase 4.2).
;;
;; A SKETCH is a quoted program containing holes — (?? id) markers.
;; HOLES maps each id to a finite list of candidate expressions:
;;   ((id (expr expr ...)) ...)
;; SPEC is the 2.1 format verify-candidate already understands:
;;   ((pure #t) (domains (d1 d2 ...)) (invariant (lambda (f args...) ...)))
;;
;; (synth-fill sketch holes spec) enumerates fillings in deterministic
;; order (first hole cycles fastest) and gates each candidate the 2.1 way —
;; static checks first, exhaustive checking only after — with a CEGIS
;; twist: every counterexample the exhaustive oracle finds is added to a
;; cheap up-front filter, so later candidates die on a handful of concrete
;; inputs instead of a full exhaustive run.
;;
;;   => (ok filled-expr bindings tried N cexs M)   on success
;;      (no-solution tried N)                       domains exhausted
;;      (search-capped tried N)                     hit *synth-max-tries*

;; ── Sketch surgery ────────────────────────────────────────────────────────
(define (sketch-hole? t) (and (pair? t) (equal? (car t) '??)))

(define (sketch-holes t)               ; hole ids, left-to-right, no dups
  (cond ((sketch-hole? t) (list (cadr t)))
        ((pair? t) (remove-duplicates (flatten1 (map sketch-holes t))))
        (else '())))

(define (sketch-fill t bind)           ; substitute (?? id) per bindings
  (cond ((sketch-hole? t)
         (let ((hit (assoc (cadr t) bind)))
           (if hit (cadr hit) t)))
        ((pair? t) (map (lambda (s) (sketch-fill s bind)) t))
        (else t)))

;; ── Deterministic enumeration (odometer over hole domains) ───────────────
(define (synth-bind holes idx)
  (if (null? holes) '()
      (cons (list (car (car holes)) (nth (cadr (car holes)) (car idx)))
            (synth-bind (cdr holes) (cdr idx)))))

(define (synth-next-idx holes idx)     ; increment; #f when exhausted
  (cond ((null? idx) #f)
        ((< (+ (car idx) 1) (length (cadr (car holes))))
         (cons (+ (car idx) 1) (cdr idx)))
        (else (let ((rest (synth-next-idx (cdr holes) (cdr idx))))
                (if rest (cons 0 rest) #f)))))

;; ── CEGIS helpers ─────────────────────────────────────────────────────────
(define (synth-cex rejection)          ; first counterexample's args, or #f
  ;; rejection: ((counterexamples (((args...) reason) ...)) ...)
  (let ((hit (assoc 'counterexamples rejection)))
    (if hit (car (car (cadr hit))) #f)))

(define (synth-member? x lst)
  (cond ((null? lst) #f)
        ((equal? (car lst) x) #t)
        (else (synth-member? x (cdr lst)))))

(define (synth-passes-cexs? f invariant cexs)
  (all? (lambda (args)
          (try-catch (apply invariant (cons f args)) (e) #f))
        cexs))

;; ── The solver ────────────────────────────────────────────────────────────
(define *synth-max-tries* 100000)

(define (synth-fill sketch holes spec)
  (if (null? holes)
      (let ((f (eval sketch)))
        (if (equal? (verify-candidate f spec) 'verified)
            (list 'ok sketch '() 'tried 1 'cexs 0)
            (list 'no-solution 'tried 1)))
      (let ((invariant (spec-get spec 'invariant #f)))
        (let loop ((idx (map (lambda (h) 0) holes))
                   (cexs '())
                   (tried 0))
          (cond ((>= tried *synth-max-tries*) (list 'search-capped 'tried tried))
                ((equal? idx #f) (list 'no-solution 'tried tried))
                (else
                 (let ((bind (synth-bind holes idx)))
                   (let ((cand (sketch-fill sketch bind)))
                     (let ((f (try-catch (eval cand) (e) #f)))
                       (if (or (not (procedure? f))
                               (not (synth-passes-cexs? f invariant cexs)))
                           (loop (synth-next-idx holes idx) cexs (+ tried 1))
                           (let ((r (verify-candidate f spec)))
                             (if (equal? r 'verified)
                                 (list 'ok cand bind 'tried (+ tried 1) 'cexs (length cexs))
                                 (let ((cex (synth-cex r)))
                                   (loop (synth-next-idx holes idx)
                                         (if (and cex (not (synth-member? cex cexs)))
                                             (cons cex cexs)
                                             cexs)
                                         (+ tried 1)))))))))))))))

;; ── Proposer-driven synthesis: the LLM + constraint-solver loop ──────────
;; A PROPOSER (attempt feedback) → bindings ((id expr)...). The constraint
;; side is unchanged — verify-candidate accepts or the reason loops back as
;; feedback. Any deterministic function works (the golden test scripts
;; one); llm-hole-proposer below asks a live local model.
(define (synth-with-proposer sketch holes spec proposer max-attempts)
  (let loop ((attempt 1) (feedback '()))
    (if (> attempt max-attempts)
        (list 'failed (reverse feedback))
        (let ((outcome
                (try-catch
                  (let ((bind (proposer attempt feedback)))
                    (let ((cand (sketch-fill sketch bind)))
                      (let ((r (verify-candidate (eval cand) spec)))
                        (if (equal? r 'verified)
                            (list 'ok cand bind)
                            (list 'rejected (list bind r))))))
                  (e) (list 'rejected (list 'error e)))))
          (if (equal? (car outcome) 'ok)
              outcome
              (loop (+ attempt 1) (cons (cadr outcome) feedback)))))))

;; ── Robust bindings extraction from prose replies ────────────────────────
;; std.lisp's extract-sexp (first "(" to last ")") is useless on a reply
;; that reasons out loud — it spans the whole essay. Instead: scan for
;; every balanced top-level sexp, parse each as DATA, and keep the LAST
;; one that validates as a bindings alist over the sketch's hole ids
;; (models put the answer at the end).
(define (synth-sexp-spans text)
  (let ((n (string-length text)))
    (let loop ((i 0) (depth 0) (start 0) (spans '()))
      (if (>= i n) (reverse spans)
          (let ((c (string-ref text i)))
            (cond ((equal? c "(")
                   (loop (+ i 1) (+ depth 1) (if (= depth 0) i start) spans))
                  ((equal? c ")")
                   (if (= depth 1)
                       (loop (+ i 1) 0 start (cons (list start (+ i 1)) spans))
                       (loop (+ i 1) (max 0 (- depth 1)) start spans)))
                  (else (loop (+ i 1) depth start spans))))))))

(define (synth-parse-bindings s hole-ids)
  (try-catch
    (let ((v (eval-string (string-append "(quote " s ")"))))
      (if (and (pair? v)
               (all? (lambda (row)
                       (and (pair? row) (= (length row) 2)
                            (synth-member? (car row) hole-ids)))
                     v))
          v #f))
    (e) #f))

(define (synth-extract-bindings text hole-ids)
  (let loop ((spans (synth-sexp-spans text)) (found #f))
    (if (null? spans) found
        (let ((b (synth-parse-bindings
                   (substring text (car (car spans)) (cadr (car spans)))
                   hole-ids)))
          (loop (cdr spans) (if b b found))))))

;; Ask a local model to fill the holes. The reply is parsed as DATA and
;; never executed before verification gates it — same discipline as 2.1's
;; llm-proposer. A reply with no valid bindings costs one attempt (the
;; raise is caught by synth-with-proposer's try-catch).
(define (llm-hole-proposer sketch holes task)
  (let ((hole-ids (map car holes)))
    (lambda (attempt feedback)
      (let ((reply
              (llm (string-append
                     "Fill the holes in this Lisp program sketch.\n"
                     "Task: " task
                     (format "\nSketch: ~a" sketch)
                     (format "\nHoles and allowed choices: ~a" holes)
                     (if (null? feedback) ""
                         (format "\nEarlier attempts failed: ~a" feedback))
                     "\nEnd your reply with the chosen bindings list"
                     " ((hole-id chosen-expr) ...) on its own final line.")
                   0.2 700)))
        (let ((b (synth-extract-bindings reply hole-ids)))
          (if b b (error "proposer reply contained no valid bindings")))))))
