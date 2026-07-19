;;; Copyright (c) 2026 Nicholas Vermeulen
;;; SPDX-License-Identifier: AGPL-3.0-or-later

;; kg-test.lisp — golden test for the knowledge graph (src/kg.rs + kg.lisp).
;; Deterministic: insertion-ordered store, fixed data, tmp-file round-trip.

(load "kg.lisp")
(kg-clear!)
(kg-rules-clear!)

;; ── Facts ─────────────────────────────────────────────────────────────────
(kg-add! 'alice 'parent 'bob)
(kg-add! 'bob 'parent 'carol)
(kg-add! 'carol 'parent 'dan)
(kg-add! 'alice 'age 62)
(kg-add! 'bob 'name "Robert")
(print (list 'count (kg-count)))
(print (list 'dedupe (kg-add! 'alice 'parent 'bob)))   ; #f — already known
(print (list 'count-still (kg-count)))

;; ── Queries: single pattern, join, multiple vars, no match ───────────────
(print (list 'children-of-alice (kg-query '((alice parent ?c)))))
(print (list 'grandparent-join
             (kg-query '((?g parent ?p) (?p parent ?c)))))
(print (list 'who-has-age (kg-query '((?who age ?n)))))
(print (list 'no-match (kg-query '((dan parent ?x)))))

;; ── Rules: forward chaining to fixpoint ──────────────────────────────────
(kg-rule! '((?x parent ?y) (?y parent ?z)) '(?x grandparent ?z))
(kg-rule! '((?x parent ?y)) '(?x ancestor ?y))
(kg-rule! '((?x parent ?y) (?y ancestor ?z)) '(?x ancestor ?z))
(print (list 'derived (kg-infer!)))
(print (list 'grandparents (kg-query '((?g grandparent ?c)))))
(print (list 'alice-reaches (kg-query '((alice ancestor ?d)))))
(print (list 'inference-is-fixpoint (kg-infer!)))       ; 0 — nothing new

;; ── N-Triples round trip (symbols, strings, numbers) ─────────────────────
(define n-saved (kg-save-ntriples "/tmp/rusty-kg-test.nt"))
(kg-clear!)
(print (list 'cleared (kg-count)))
(define n-loaded (kg-load-ntriples "/tmp/rusty-kg-test.nt"))
(print (list 'roundtrip (equal? n-saved n-loaded)
             'age-survived (kg-query '((alice age ?n)))
             'name-survived (kg-query '((bob name ?s)))))
(file-delete "/tmp/rusty-kg-test.nt")

;; ── The verification layers see the graph honestly ───────────────────────
(print (check-effects (lambda (s) (kg-add! s 'known #t))))

;; ── ...and the prover can prove over graph-derived data ─────────────────
(load "prover.lisp")
(define ages (map (lambda (b) (cadr (cadr b))) (kg-query '((?w age ?n)))))
(print (defproof kg-ages-plausible
         (forall ((a (62))) (and (>= a 0) (< a 150)))
         (auto)))
(print (list 'ages-match-proof-domain (equal? ages '(62))))

(print "KG TESTS DONE")
