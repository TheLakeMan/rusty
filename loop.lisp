;;; Copyright (c) 2026 Nicholas Vermeulen
;;; SPDX-License-Identifier: AGPL-3.0-or-later

;; ─────────────────────────────────────────────────────────────────────────────
;; loop.lisp — Entry point (loads everything once)
;; ─────────────────────────────────────────────────────────────────────────────

(load "loop-core.lisp")
(load "loop-questions.lisp")
(load "loop-soul.lisp")

(print "")
(print "╔════════════════════════════════════╗")
(print "║           L O O P  v0.3            ║")
(print "║   A memory vessel for the living.  ║")
(print "╚════════════════════════════════════╝")
(print "")
(print "  (loop-start \"Name\")     — begin new interview")
(print "  (loop-say \"...\")        — give a response")
(print "  (loop-pause)             — save and pause")
(print "  (loop-resume \"id\")      — resume a session")
(print "  (loop-status)            — current session info")
(print "  (loop-sessions)          — list all sessions")
(print "  (loop-remember)          — keep the portrait + witness")
(print "")
