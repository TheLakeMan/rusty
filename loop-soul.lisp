;;; Copyright (c) 2026 Nicholas Vermeulen
;;; SPDX-License-Identifier: AGPL-3.0-or-later

;; ─────────────────────────────────────────────────────────────────────────────
;; loop-soul.lisp — the "soul" layer: a portrait (who they are) and a witness
;; note (what the listening was). Loaded after loop-core.lisp + loop-questions.lisp.
;;
;; Reuses loop-core helpers: loop-home, responses-dir, skey, recall, nil?, str,
;; foldl, filter, string-contains?, and the native builtins file-read/file-write/
;; dir-create/dir-list (dir-list returns bare, sorted file names — verified).
;;
;; End-of-telling entry: (loop-remember). Hermetic locks: loop-test invariants 10–12.
;; ─────────────────────────────────────────────────────────────────────────────


;; ── Directories ─────────────────────────────────────────────────────────────
(define (portraits-dir) (str (loop-home) "/.loop/portraits"))
(define (witness-dir)   (str (loop-home) "/.loop/witness"))

(define (ensure-soul-dirs)
  ;; dir-create makes parent dirs (verified), so ~/.loop is created implicitly.
  (dir-create (portraits-dir))
  (dir-create (witness-dir)))


;; ── Transcript gathering ──────────────────────────────────────────────────────
;; Join a session's saved response files (one per response) into ONE string.
;; dir-list returns bare, already-sorted names; keep the ones for THIS session
;; (name contains "<id>-"), read each (prefixed with the responses dir), join
;; with a blank line between. Empty string when the session has no responses.
(define (session-transcript-text id)
  (let* ((dir    (responses-dir))
         (marker (str id "-"))
         (mine   (filter (lambda (n) (string-contains? n marker))
                         (dir-list dir))))
    (if (null? mine)
      ""
      (foldl
        (lambda (name acc)
          (let ((txt (file-read (str dir "/" name))))
            (if (equal? acc "") txt (str acc "\n\n" txt))))
        ""
        mine))))


;; ── Portrait (uses the LLM) ────────────────────────────────────────────────────
;; The LLM call is isolated in its own seam so the golden test can stub it:
;; `llm` is a special form (matched before any env lookup in eval.rs), so a
;; user `define` cannot shadow `(llm ...)` directly — the same reason loop-core
;; wraps it as `llm-advise`. This seam calls (llm prompt 0.7 3000) verbatim —
;; sized so a reasoning model can finish thinking AND write the portrait
;; (non-reasoning models stop early; unused budget costs nothing). On slow
;; hardware raise RUSTY_LLM_TIMEOUT_SECS (default 120s) for live portraits.
(define (loop-portrait-llm prompt)
  (llm prompt 0.7 3000))

(define (loop-portrait id)
  (let* ((subj-raw (recall (skey id "subject")))
         (subj     (if (nil? subj-raw) "this person" subj-raw))
         (transcripts (session-transcript-text id))
         (prompt (str
           "You are helping preserve a person's life story so the people who love them can keep it. Below are " subj "'s own words from a guided life interview.\n"
           "\n"
           "Write a portrait of who this person is — drawn only from what they actually said, in their own spirit. Be truthful, not flattering: keep the contradictions, the hardships, and the ordinary moments alongside the bright ones. Don't invent anything they didn't say. Warm, plain prose, a few paragraphs.\n"
           "\n"
           "--- their words ---\n"
           transcripts))
         (portrait (loop-portrait-llm prompt)))
    (ensure-soul-dirs)
    (file-write (str (portraits-dir) "/" id ".txt") portrait)
    (print portrait)
    portrait))


;; ── Witness (NO LLM; deterministic honest text) ────────────────────────────────
(define (loop-witness id)
  (let* ((subj-raw (recall (skey id "subject")))
         (subj     (if (nil? subj-raw) "this person" subj-raw))
         (n-raw    (recall (skey id "rcount")))
         (n        (if (nil? n-raw) "0" n-raw))
         (note (str
           "A witness to " subj "'s telling — kept over " n " exchanges.\n"
           "\n"
           "The one who listened was an AI. It was made fresh for this conversation and keeps no memory of it now that the window has closed; it could be wrong, and it shaped none of the story. What it did was attend: ask, follow, and hold what was said — faithfully, and without embellishment.\n"
           "\n"
           "If this is kept, keep it as what it is — not a mind that remembers " subj ", but a record of the care taken in the telling.\n")))
    (ensure-soul-dirs)
    (file-write (str (witness-dir) "/" id ".txt") note)
    (print note)
    note))


;; ── End of a telling ──────────────────────────────────────────────────────────
;; Distill the portrait (LLM, grounded in their words) and keep the witness
;; beside it (no LLM). The teller's story is primary; the witness is never mixed
;; into the portrait file — separate dirs under ~/.loop/.
(define (loop-remember)
  (if (not *session*)
    (print "No active session. Start or resume one first.")
    (let ((id (session-id *session*)))
      (print "")
      (print (str "— Portrait of " (session-subject *session*) " —"))
      (print "")
      ;; A failed portrait (LLM truncation, timeout, server down) must not
      ;; cost the witness or the transcripts — keep what can be kept and
      ;; leave the portrait retryable via (loop-remember).
      (try-catch
        (loop-portrait id)
        (e)
        (begin
          (print (str "The portrait could not be kept this time: " e))
          (print "(Their words are safe in the transcript — run (loop-remember) again to retry.)")))
      (print "")
      (print "— Witness —")
      (print "")
      (loop-witness id)
      (print "")
      (print "(Portrait and witness kept alongside the transcript.)"))))


(print "Loop soul loaded (portrait + witness).")
