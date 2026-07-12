;;; Copyright (c) 2026 Nicholas Vermeulen
;;; SPDX-License-Identifier: AGPL-3.0-or-later

;; ─────────────────────────────────────────────────────────────────────────────
;; loop-test.lisp — Hermetic, deterministic golden test for the Loop engine.
;;
;; HERMETIC BY CONSTRUCTION: after loading the real engine we REDEFINE every
;; impure/nondeterministic function it can reach (clock, LLM advisor,
;; remember/recall, save-response, dir helpers) with pure in-memory stubs.
;; The committed test touches NO real files, NO shell, NO LLM. The engine's own
;; functions call our stubs because Lisp resolves free identifiers at call time.
;; ─────────────────────────────────────────────────────────────────────────────

(load "loop-core.lisp")
(load "loop-questions.lisp")


;; ── Stubs: replace every impurity source the test can reach ─────────────────────

;; Fixed clock → deterministic session IDs / started-at.
(define (current-unix-time) 1000000)

;; In-memory key/value store replacing remember/recall (which hit ~/.rusty/memory.lisp).
;; Contract preserved exactly: recall returns Nil on a miss, the stored string on a hit.
(define *mem* (list))
(define (remember key val)
  (set! *mem* (cons (list key val) *mem*))
  val)
(define (recall key)
  ;; newest write wins (cons-to-front), Nil on miss — matches the real builtin
  (let ((hit (filter (lambda (p) (equal? (nth p 0) key)) *mem*)))
    (if (null? hit) (nil) (nth (nth hit 0) 1))))

;; Scripted LLM advisor: pop one decision per call; default "continue" when empty.
(define *advice-script* (list))
(define (llm-advise session transcript)
  (if (null? *advice-script*)
    "continue"
    (let ((a (nth *advice-script* 0)))
      (set! *advice-script* (cdr *advice-script*))
      a)))

;; Capture responses in memory (in order) instead of writing files via python3/shell.
(define *responses* (list))
(define (save-response session-id question-id depth transcript)
  (set! *responses*
    (append *responses* (list (list question-id depth transcript))))
  #t)

;; Directory helpers: no shell, ever.
(define (ensure-dirs) #t)
(define (responses-dir) "/fake/loop/responses")

(define (reset-all)
  (set! *mem* (list))
  (set! *responses* (list))
  (set! *advice-script* (list)))


;; ── Assertion helpers (print label on pass, divide-by-zero abort on fail) ───────

(define (assert-equal expected actual label)
  (if (equal? expected actual)
    (print label)
    (begin (print (str "FAIL " label)) (/ 1 0))))

(define (assert-true value label)
  (if value
    (print label)
    (begin (print (str "FAIL " label)) (/ 1 0))))

(define (all-unique? lst)
  (cond
    ((null? lst) #t)
    ((list-contains? (cdr lst) (nth lst 0)) #f)
    (else (all-unique? (cdr lst)))))

;; Run n turns (default/scripted advisor), asserting asked-ids stays duplicate-free.
(define (drive-check session n)
  (if (= n 0)
    session
    (let* ((r (loop-turn session "resp"))
           (s (nth r 0)))
      (if (not (all-unique? (session-asked-ids s))) (/ 1 0) #t)
      (drive-check s (- n 1)))))


;; ── Invariant 1: Start ──────────────────────────────────────────────────────────
(reset-all)
(let* ((r  (start-session "TestName"))
       (s  (nth r 0))
       (q  (nth r 1)))
  (assert-equal "childhood" (session-current-category s) "1a start category is childhood")
  ;; first question is the first childhood question in the bank
  (assert-equal (question-id (nth (get-category-questions "childhood") 0))
                (session-current-qid s) "1b start qid is first childhood question")
  (assert-equal (question-text q-childhood-001) q "1c start prompt is that question's text")
  (assert-equal "loop-TestName-1000000" (session-id s) "1d start session id is deterministic"))


;; ── Invariant 2: Follow-up depth (script "follow-up") ───────────────────────────
(reset-all)
(set! *advice-script* (list "follow-up" "follow-up" "follow-up" "follow-up"))
(let* ((r0 (start-session "Depth"))
       (s0 (nth r0 0))
       (r1 (loop-turn s0 "a")) (s1 (nth r1 0))
       (r2 (loop-turn s1 "b")) (s2 (nth r2 0))
       (r3 (loop-turn s2 "c")) (s3 (nth r3 0))
       (r4 (loop-turn s3 "d")) (s4 (nth r4 0)))
  (assert-equal 1 (session-follow-up-depth s1) "2a depth 1 after first follow-up")
  (assert-equal 2 (session-follow-up-depth s2) "2b depth 2")
  (assert-equal 3 (session-follow-up-depth s3) "2c depth 3 (at cap)")
  (assert-equal "childhood-001" (session-current-qid s3) "2d qid unchanged through follow-ups")
  (assert-true (not (list-contains? (session-asked-ids s3) "childhood-001"))
               "2e question not marked asked during follow-ups")
  ;; at the cap, next turn moves on AND marks the question asked
  (assert-equal 0 (session-follow-up-depth s4) "2f depth resets after cap")
  (assert-equal "childhood-002" (session-current-qid s4) "2g moves to next question at cap")
  (assert-true (list-contains? (session-asked-ids s4) "childhood-001")
               "2h question now marked asked"))


;; ── Invariant 3: No repeats ─────────────────────────────────────────────────────
(reset-all)
(let* ((r0 (start-session "NoRepeat"))
       (s0 (nth r0 0))
       (final (drive-check s0 10)))
  (assert-true (all-unique? (session-asked-ids final)) "3a asked-ids never contains a duplicate"))
;; next-question directly skips an already-asked question
(reset-all)
(let* ((r0 (start-session "Skip"))
       (s0 (nth r0 0))
       (s1 (session-set s0 "asked" (list "childhood-001")))
       (nq (next-question s1 "childhood")))
  (assert-equal "childhood-002" (question-id nq) "3b next-question skips an asked question"))


;; ── Invariant 4: Response capture (exactly one per turn, in order) ──────────────
(reset-all)
(set! *advice-script* (list "follow-up" "follow-up" "follow-up" "follow-up"))
(let* ((r0 (start-session "Capture"))
       (s0 (nth r0 0))
       (s1 (nth (loop-turn s0 "resp-1") 0))
       (s2 (nth (loop-turn s1 "resp-2") 0))
       (s3 (nth (loop-turn s2 "resp-3") 0))
       (s4 (nth (loop-turn s3 "resp-4") 0)))
  (assert-equal 4 (length *responses*) "4a one response captured per turn")
  (assert-equal
    (list (list "childhood-001" 0 "resp-1")
          (list "childhood-001" 1 "resp-2")
          (list "childhood-001" 2 "resp-3")
          (list "childhood-001" 3 "resp-4"))
    *responses*
    "4b responses captured in order with qid+depth"))


;; ── Invariant 5: Category advance ───────────────────────────────────────────────
;; Exhaust the whole childhood category (default "continue"); the turn that crosses
;; into family-and-roots returns text beginning with "Let's move on.".
(reset-all)
(let* ((r0 (start-session "Advance"))
       (s0 (nth r0 0)))
  ;; With the advisor saying "continue" (the default), follow-ups are skipped,
  ;; so childhood's 3 questions take one turn each — the 3rd turn crosses.
  (let* ((s2 (drive-check s0 2))
         (r3 (loop-turn s2 "resp"))
         (s10 (nth r3 0))
         (text (nth r3 1)))
    (assert-equal "family-and-roots" (session-current-category s10)
                  "5a advanced to next category in CATEGORY-ORDER")
    (assert-equal "Let's move on." (substring text 0 14)
                  "5b boundary text begins with \"Let's move on.\"")))


;; ── Invariant 6: Pause/resume round-trip (depth 0 AND depth>0) ──────────────────
;; Case A: depth 0
(reset-all)
(let* ((r0 (start-session "PauseA"))
       (s0 (nth r0 0)))
  (pause-session s0)                         ; saves status=paused to *mem*
  (let ((ld (load-session (session-id s0))))
    (assert-equal (session-subject s0)          (session-subject ld)          "6a-1 subject round-trips")
    (assert-equal "paused"                       (session-status ld)          "6a-2 status is paused")
    (assert-equal (session-current-category s0)  (session-current-category ld) "6a-3 category round-trips")
    (assert-equal (session-current-qid s0)       (session-current-qid ld)      "6a-4 qid round-trips")
    (assert-equal 0                              (session-follow-up-depth ld)  "6a-5 depth round-trips (0)")
    (assert-equal (session-asked-ids s0)         (session-asked-ids ld)        "6a-6 asked list round-trips")
    (assert-equal (question-text q-childhood-001) (pending-question ld)
                  "6a-7 pending-question at depth 0 is the core question")))

;; Case B: depth > 0 (mid follow-up)
(reset-all)
(set! *advice-script* (list "follow-up" "follow-up"))
(let* ((r0 (start-session "PauseB"))
       (s0 (nth r0 0))
       (s1 (nth (loop-turn s0 "x") 0))
       (s2 (nth (loop-turn s1 "y") 0)))     ; depth 2, still on childhood-001
  (pause-session s2)
  (let ((ld (load-session (session-id s2))))
    (assert-equal "paused"                  (session-status ld)           "6b-1 status is paused")
    (assert-equal "childhood-001"           (session-current-qid ld)      "6b-2 qid round-trips")
    (assert-equal "childhood"               (session-current-category ld) "6b-3 category round-trips")
    (assert-equal 2                         (session-follow-up-depth ld)  "6b-4 depth round-trips (2)")
    (assert-equal (session-asked-ids s2)    (session-asked-ids ld)        "6b-5 asked list round-trips")
    (assert-equal (nth (question-follow-ups q-childhood-001) 1) (pending-question ld)
                  "6b-6 pending-question at depth 2 is the mid follow-up")))


;; ── Invariant 7: Complete ───────────────────────────────────────────────────────
(reset-all)
(set! *advice-script* (list "complete"))
(let* ((r0 (start-session "Done"))
       (s0 (nth r0 0))
       (r1 (loop-turn s0 "I'm tired now"))
       (s1 (nth r1 0))
       (msg (nth r1 1)))
  (assert-equal "complete" (session-status s1) "7a status is complete")
  (assert-equal (loop-closing s1) msg "7b message equals loop-closing output"))


;; ── Invariant 8: save/load fidelity (field-by-field) ────────────────────────────
;; Build a session with a multi-element asked list, save it, load it, compare.
(reset-all)
(let* ((r0 (start-session "Fidelity"))
       (s0 (nth r0 0))
       (src (drive-check s0 7)))            ; "continue" (default): 7 questions asked across categories
  (save-session src)
  (let ((ld (load-session (session-id src))))
    (assert-equal (session-id src)               (session-id ld)               "8a id")
    (assert-equal (session-subject src)          (session-subject ld)          "8b subject")
    (assert-equal (session-started-at src)       (session-started-at ld)       "8c started-at")
    (assert-equal (session-status src)           (session-status ld)           "8d status")
    (assert-equal (session-current-category src) (session-current-category ld) "8e category")
    (assert-equal (session-current-qid src)      (session-current-qid ld)      "8f qid")
    (assert-equal (session-follow-up-depth src)  (session-follow-up-depth ld)  "8g depth")
    (assert-equal (session-asked-ids src)        (session-asked-ids ld)        "8h asked list")
    (assert-true  (> (length (session-asked-ids ld)) 1) "8i asked list is multi-element (delimiter round-trips)")))


;; ── Invariant 9: the advisor actually gates follow-ups ─────────────────────────
;; childhood-001 HAS follow-ups, but a "continue" verdict must SKIP them and move
;; straight on — this is the whole point of wiring the advisor into advance-session.
;; (Contrast invariant 2, where "follow-up" drills into those same follow-ups.)
(reset-all)
(set! *advice-script* (list "continue"))
(let* ((r0 (start-session "Advisor"))
       (s0 (nth r0 0))
       (r1 (loop-turn s0 "done with this one"))
       (s1 (nth r1 0)))
  (assert-true (> (length (question-follow-ups q-childhood-001)) 0)
               "9a childhood-001 has follow-ups available")
  (assert-equal 0 (session-follow-up-depth s1)
                "9b continue does NOT drill a follow-up")
  (assert-equal "childhood-002" (session-current-qid s1)
                "9c continue moves straight to the next question")
  (assert-true (list-contains? (session-asked-ids s1) "childhood-001")
               "9d question marked asked without drilling"))


(print "LOOP TESTS PASSED")
