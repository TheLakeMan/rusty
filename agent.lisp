;;; agent.lisp — Rusty AI Agent demo
;;; Shows the ReAct pattern, prompt building, state machines, and JSON I/O.
;;; Run: cargo run -- agent.lisp

;; ── Tool registry ──────────────────────────────────────────────────────────

(define tools
  (list
    (list "add"     (lambda (a b) (+ a b)))
    (list "mul"     (lambda (a b) (* a b)))
    (list "reverse" (lambda (lst) (reverse lst)))
    (list "length"  (lambda (lst) (length lst)))))

(define (call-tool name args)
  (let ((entry (assoc name tools)))
    (if entry
        (apply (cadr entry) args)
        (error (format "Unknown tool: ~a" name)))))

;; ── State helpers ──────────────────────────────────────────────────────────

(define (make-state task)
  (make-record "task" task "step" 0 "history" '() "done" #f "result" ()))

(define (state-add-history state entry)
  (record-set state "history"
    (append (get-field "history" state) (list entry))))

(define (state-done state result)
  (record-set (record-set state "done" #t) "result" result))

;; ── Prompt builder (uses format + quasiquote) ──────────────────────────────

(define (build-prompt state action)
  (format "Task: ~a~%Step: ~a~%Action: ~a~%Available tools: ~a"
    (get-field "task" state)
    (get-field "step" state)
    action
    (map car tools)))

;; ── Pattern-matching action dispatcher ─────────────────────────────────────

(define (dispatch action)
  (match action
    (("tool" name args)
     (try-catch
       (list "ok" (call-tool name args))
       (e) (list "error" e)))
    (("done" result)
     (list "done" result))
    (("think" thought)
     (list "thought" thought))
    (_ (list "error" "unknown action"))))

;; ── Agent loop ─────────────────────────────────────────────────────────────

(define (agent-step state actions)
  (if (null? actions)
      state
      (let* ((action  (car actions))
             (rest    (cdr actions))
             (outcome (dispatch action))
             (state   (state-add-history state
                        (list "action" action "result" outcome))))
        (if (equal? (car outcome) "done")
            (state-done state (cadr outcome))
            (agent-step (record-set state "step"
                          (+ (get-field "step" state) 1))
                        rest)))))

;; ── Run a demo task ────────────────────────────────────────────────────────

(define (run-demo)
  (println "=== Rusty Agent Demo ===")
  (println "")

  ;; Task 1: arithmetic pipeline
  (let* ((state (make-state "Compute (3 + 4) * 2"))
         (actions (list
           (list "think" "First I'll add 3 and 4")
           (list "tool" "add" (list 3 4))
           (list "think" "Now multiply by 2")
           (list "tool" "mul" 7 2)    ; will error — wrong arity, shows try-catch
           (list "tool" "mul" (list 7 2))
           (list "done" 14)))
         (final (agent-step state actions)))

    (println (format "Task:   ~a" (get-field "task" final)))
    (println (format "Done:   ~a" (get-field "done" final)))
    (println (format "Result: ~a" (get-field "result" final)))
    (println (format "Steps:  ~a" (get-field "step" final)))
    (println ""))

  ;; Task 2: list processing pipeline
  (let* ((data '(5 3 1 4 2))
         (result (->> data
                      (filter odd?)
                      (map square)
                      sum)))
    (println (format "Pipeline: filter odd? -> square -> sum of ~a" data))
    (println (format "Result: ~a" result))
    (println ""))

  ;; Task 3: JSON state serialization
  (let* ((state (make-state "Research AI trends"))
         (state (record-set state "step" 3))
         (state (record-set state "done" #t))
         (state (record-set state "result" "LLMs are dominant"))
         (json  (json-encode state)))
    (println "State as JSON:")
    (println json)
    (println "")
    (let ((decoded (json-decode json)))
      (println (format "Decoded task: ~a" (get-field "task" decoded)))))

  ;; Task 4: pattern matching on LLM-style output
  (println "")
  (println "Pattern matching on structured data:")
  (for-each
    (lambda (msg)
      (let ((label (match msg
        (("error" reason) (format "ERROR: ~a" reason))
        (("ok"    value)  (format "OK: ~a" value))
        (("list" . items) (format "LIST of ~a items" (length items)))
        ((_ _)            "two-element pair")
        ((_ _ _ . _)      "three-or-more element list")
        (_                "unknown"))))
        (println (format "  ~a => ~a" msg label))))
    (list
      (list "ok" 42)
      (list "error" "not found")
      (list "list" 1 2 3)
      (list "x" "y")
      "bare-string")))

(run-demo)
