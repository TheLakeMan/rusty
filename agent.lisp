;;; agent.lisp — Rusty Agent Tools + ReAct Loop
;;; Load with: cargo run -- agent.lisp

;; ── Filesystem tools ───────────────────────────────────────────────────────

(deftool read-file (path)
  "Read the contents of a file at the given path"
  (try-catch
    (let ((content (load path)))
      content)
    (e) (format "Error reading file: ~a" e)))

(deftool write-file (path content)
  "Write content to a file at the given path"
  (try-catch
    (begin
      ; Use system shell to write — bridges to OS
      (shell (format "cat > ~a << 'RUSTY_EOF'~%~a~%RUSTY_EOF" path content))
      (format "Written: ~a" path))
    (e) (format "Error writing file: ~a" e)))

(deftool create-dir (path)
  "Create a directory at the given path"
  (try-catch
    (begin
      (shell (format "mkdir -p ~a" path))
      (format "Created directory: ~a" path))
    (e) (format "Error creating directory: ~a" e)))

(deftool list-dir (path)
  "List files and directories at the given path"
  (try-catch
    (shell (format "ls -la ~a" path))
    (e) (format "Error listing directory: ~a" e)))

(deftool delete-file (path)
  "Delete a file at the given path"
  (try-catch
    (begin
      (shell (format "rm -f ~a" path))
      (format "Deleted: ~a" path))
    (e) (format "Error deleting file: ~a" e)))

;; ── Shell tool ─────────────────────────────────────────────────────────────

(deftool shell-run (command)
  "Run a shell command and return its output"
  (shell command))

;; ── LLM tool ───────────────────────────────────────────────────────────────

(deftool ask-llm (prompt)
  "Ask the LLM a question and get a response"
  (llm prompt 0.7 500))

;; ── Search tool (uses ripgrep if available) ────────────────────────────────

(deftool search-files (pattern)
  "Search for a pattern across files in current directory"
  (try-catch
    (shell (format "grep -r ~s . 2>/dev/null | head -20" pattern))
    (e) (format "Search error: ~a" e)))

;; ── Agent utilities ────────────────────────────────────────────────────────

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

(define (agent goal)
  "Run a ReAct agent loop with all registered tools"
  (println (format "🤖 Agent starting: ~a" goal))
  (let ((result (react-loop goal 10)))
    (println (format "✅ Result: ~a" result))
    result))

;; ── Demo ───────────────────────────────────────────────────────────────────

(show-tools)
(println "")
(println "Tools registered. Try:")
(println "  (agent \"Create a file called hello.txt with the content 'Hello from Rusty!'\")")
(println "  (tool-call \"list-dir\" \".\")")
(println "  (tool-call \"ask-llm\" \"What is 2+2?\")")
