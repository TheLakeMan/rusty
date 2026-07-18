;;; Copyright (c) 2026 Nicholas Vermeulen
;;; SPDX-License-Identifier: AGPL-3.0-or-later

;; proc.lisp — Phase B: replay-verified process runs over the proc-eval builtin
;; (Phase A). A run RECORD is data: (proc-run <code> <timeout> <result>).
;;
;; The audit: because a child is a fresh, isolated, deterministic interpreter,
;; re-executing the recorded code MUST reproduce the recorded result. Replay IS
;; the audit — now across a process boundary (mingjian's thesis for deterministic
;; plants, applied to isolated computations). A record that does NOT reproduce
;; is the honest signal that the run was non-deterministic (it read the clock,
;; the network, a changing file) and so cannot be replay-audited — never a false
;; 'verified.
;;
;; HONEST SCOPE (the caveat is the crack): replay proves the recorded CODE
;; produces the recorded RESULT. It does NOT prove the code is the code you
;; meant to run — forge both code and result together and the forgery replays
;; clean (the same limit mingjian names: replay needs an out-of-band anchor to
;; say "this is the run I kept", it can only say "this run is self-consistent").

(define *proc-default-timeout* 30)

;; Run code in an isolated child and KEEP the record (input + output as data).
(define (proc-run code . opt)
  (let ((timeout (if (null? opt) *proc-default-timeout* (car opt))))
    (list 'proc-run code timeout (proc-eval code timeout))))

(define (proc-run-code r)    (cadr r))
(define (proc-run-timeout r) (caddr r))
(define (proc-run-result r)  (cadddr r))

;; Replay: re-execute the recorded code in a fresh child and compare.
;; 'verified | (diverged (claimed …) (got …))
(define (proc-replay r)
  (let ((fresh (proc-eval (proc-run-code r) (proc-run-timeout r))))
    (if (equal? fresh (proc-run-result r))
        'verified
        (list 'diverged (list 'claimed (proc-run-result r)) (list 'got fresh)))))

(define (proc-verified? r) (equal? (proc-replay r) 'verified))
