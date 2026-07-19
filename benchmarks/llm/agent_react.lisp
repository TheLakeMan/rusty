;;; Copyright (c) 2026 Nicholas Vermeulen
;;; SPDX-License-Identifier: AGPL-3.0-or-later

;; agent_react.lisp — ReAct loop (`agent` / `react-loop`) under a real model.
;; Manual (needs a live llama-server on :8080); NOT a golden. See ./README.md.
;;
;; SAFETY: `(agent goal)` runs UNGATED tools — Rusty parses the model's
;; ACTION:/INPUT: text and executes the named tool ITSELF (read-file, write-file,
;; delete-file, shell-run, ...), client-side, regardless of any server tool
;; config. The goals below are read-only; a different goal could take real
;; action. Gated execution is wuwei's job. Read ./README.md before editing goals.
;;
;; Two checks: (1) a reasoning goal terminates straight to FINAL; (2) a tool goal
;; invokes a read-only tool, feeds the observation back, and terminates with the
;; right answer. Note: react-loop re-sends the FULL growing history each step, so
;; keep observations small (a big directory listing balloons the prompt fast and
;; slows later steps — cost is ~O(steps^2) in tokens).

(println "--- reasoning goal (expect quick FINAL) ---")
(println (list 'reasoning (agent "What is 15 multiplied by 23? Compute it and give the final answer.")))

(println "--- tool goal (read-only list-dir on a tiny dir), traced ---")
(dir-create "/tmp/rusty-agent-probe")
(file-write "/tmp/rusty-agent-probe/a.txt" "")
(file-write "/tmp/rusty-agent-probe/b.txt" "")
(file-write "/tmp/rusty-agent-probe/c.txt" "")
(trace-on)
(println (list 'tool-use
  (react-loop
    "Call list-dir with the path /tmp/rusty-agent-probe to see its files. Then give FINAL: the count of files."
    4)))
(trace-off)
(println "--- react/tool trace (raw rows: seq t kind name dur data) ---")
(for-each println (trace-report))
