;;; agent.lisp — Rusty Agent Tools + ReAct Loop
;;; Loaded automatically by std.lisp at startup.
;;; Tool registration is silent — call (agent-help) to see available tools.

;; ── Filesystem tools ────────────────────────────────────────────────────────

(deftool read-file (path)
  "Read the contents of a file at the given path"
  (file-read path))

(deftool write-file (path content)
  "Write content to a file at the given path"
  (file-write path content))

(deftool append-file (path content)
  "Append content to a file"
  (file-append path content))

(deftool create-dir (path)
  "Create a directory (and any parents) at the given path"
  (dir-create path))

(deftool list-dir (path)
  "List files and directories at the given path"
  (let ((entries (dir-list path)))
    (if (null? entries)
        "(empty)"
        (string-join entries "\n"))))

(deftool delete-file (path)
  "Delete a file at the given path"
  (shell (format "rm -f ~a" path)))

(deftool file-exists (path)
  "Check if a file or directory exists"
  (file-exists? path))

;; ── Shell tool ──────────────────────────────────────────────────────────────

(deftool shell-run (command)
  "Run a shell command and return its output"
  (shell command))

;; ── LLM tool ────────────────────────────────────────────────────────────────

(deftool ask-llm (prompt)
  "Ask the local LLM a question and get a response"
  (llm prompt 0.7 500))

;; ── Search tool ─────────────────────────────────────────────────────────────

(deftool search-files (pattern)
  "Search for a pattern across files in current directory"
  (shell (format "grep -r ~s . 2>/dev/null | head -20" pattern)))

;; ── Agent utilities ─────────────────────────────────────────────────────────

(define (show-tools)
  (println "Registered tools:")
  (for-each
    (lambda (t)
      (println (format "  ~a~a — ~a"
        (car t)
        (if (null? (caddr t)) "()"
            (format "(~a)" (string-join (map symbol->string (caddr t)) ", ")))
        (cadr t))))
    (list-tools)))

(define (agent-help)
  "Show registered tools and usage examples."
  (show-tools)
  (println "")
  (println "Examples:")
  (println "  (tool-call \"create-dir\" \"my-project\")")
  (println "  (tool-call \"write-file\" \"my-project/README.md\" \"# My Project\")")
  (println "  (tool-call \"read-file\" \"my-project/README.md\")")
  (println "  (tool-call \"list-dir\" \"my-project\")")
  (println "  (agent \"Create a folder called test-project with a README.md\")"))

(define (agent goal)
  "Run a ReAct agent loop with all registered tools."
  (println (format "🤖 Agent: ~a" goal))
  (let ((result (react-loop goal 10)))
    (println (format "✅ Result: ~a" result))
    result))

;; Registration complete — no output. Call (agent-help) to see tools.
