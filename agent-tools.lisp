;;; agent-tools.lisp — the agent tool library (filesystem/shell/LLM tools
;;; + the ReAct entry point). Loaded automatically by std.lisp at startup.
;;; Registration is silent — call (agent-help) for the tool reference.

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
  "Show the registered tool reference."
  (show-tools))

(define (agent goal)
  "Run a ReAct agent loop (max 10 steps) with all registered tools."
  (react-loop goal 10))

;; Registration complete — no output. Call (agent-help) for the reference.
