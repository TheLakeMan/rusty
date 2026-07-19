;;; coverage-check.lisp — the ratchet. Reads the accumulated exercised-names
;;; file ($RUSTY_COVERAGE_FILE), the registry, and the allowlist; prints
;;; "COVERAGE OK" or the violations. Deterministic (sorted) output.
;;;
;;; There is no getenv builtin; path comes from the env via shell (printf, no
;;; newline). This script must NOT run with RUSTY_COVERAGE set (would record itself).
;;;
;;; Capture the registry BEFORE defining any helper functions — (command-registry)
;;; walks every callable binding in the global env, so top-level helpers would
;;; otherwise appear as "untested commands".
(load "tests/coverage-allowlist.lisp")

(define all-names (map car (command-registry)))

(define exercised
  (string-split (file-read (shell "printf %s \"$RUSTY_COVERAGE_FILE\"")) "\n"))

(define (exercised? name) (member name exercised))
(define (allowed? sym) (member sym *coverage-allow*))

;; uncovered commands not on the allowlist = FAILURE (new untested command)
(define offenders
  (filter (lambda (n)
            (and (not (exercised? n))
                 (not (allowed? (string->symbol n)))))
          all-names))

;; allowlisted commands that WERE exercised = stale exemption
(define stale
  (filter (lambda (s) (exercised? (symbol->string s))) *coverage-allow*))

(cond ((and (null? offenders) (null? stale)) (println "COVERAGE OK"))
      (else
        (if (not (null? offenders))
            (println (format "UNTESTED (add a test or allowlist w/ reason): ~a"
                             (sort-strings offenders))) ())
        (if (not (null? stale))
            (println (format "STALE ALLOWLIST (now exercised, remove): ~a"
                             (sort-strings (map symbol->string stale)))) ())))
