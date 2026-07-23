;; sandbox-test.lisp — one-way filesystem/subprocess confinement.
;; Security-review fix: the file builtins follow symlinks and take a raw path,
;; so a Lisp-level path-prefix guard was defeated by a symlink (or `..`, or an
;; absolute path) escaping the box. (sandbox-enable! root) closes that at the
;; builtin funnel for every file/subprocess builtin at once.
;;
;; Output is deliberately BOOLEAN-ONLY so the golden is portable — the refusal
;; messages carry machine-specific absolute paths, so we assert on the OUTCOME
;; (was it refused?), never on the message text. The absolute-path and `..`
;; escapes exercise the same canonicalize-under-root check as a symlink escape.

(define box "/tmp/rusty-sbx-test-box")
(dir-create box)
(file-write (string-append box "/ok.txt") "in-box")

(define (refused? thunk)
  (try-catch (begin (thunk) #f) (e) (string-contains? e "refused")))

;; Nothing is confined until enabled.
(display (list 'active-before (sandbox-active?))) (newline)
(sandbox-enable! box)
(display (list 'active-after (sandbox-active?))) (newline)
;; sandbox-root now reports a non-Nil root (assert non-Nil, not the path — portable).
(display (list 'root-set (not (equal? (sandbox-root) ())))) (newline)

;; A legitimate in-box read still works under the sandbox.
(display (list 'in-box-read (file-read (string-append box "/ok.txt")))) (newline)

;; Escapes are refused (absolute + `..`), and a write is refused.
(display (list 'abs-read     (refused? (lambda () (file-read "/etc/hostname")))
               'dotdot-read  (refused? (lambda () (file-read (string-append box "/../../etc/hostname"))))
               'abs-write    (refused? (lambda () (file-write "/tmp/rusty-sbx-outside.txt" "x")))
               'dotdot-list  (refused? (lambda () (dir-list "/"))))) (newline)

;; Subprocess / native-compile vectors are refused outright.
(display (list 'shell     (refused? (lambda () (shell "echo x")))
               'proc-eval (refused? (lambda () (proc-eval "(+ 1 2)")))
               'proc-pmap (refused? (lambda () (proc-pmap (list "(+ 1 2)")))))) (newline)

;; Model + persistent-memory builtins take a fixed or user path and used to write
;; OUTSIDE the box unguarded — the userspace floor now refuses them too (Landlock
;; catches them at the kernel on top, but the floor must hold with no kernel help).
;; An in-box save-model still works, so this is confinement, not a blanket ban.
(display (list 'save-out (refused? (lambda () (save-model "/tmp/rusty-sbx-outside.json" 1)))
               'load-out (refused? (lambda () (load-model "/etc/hostname")))
               'remember (refused? (lambda () (remember "k" "v")))
               'forget   (refused? (lambda () (forget "k")))
               'mem-list (refused? (lambda () (memory-list)))
               'save-in  (try-catch (begin (save-model (string-append box "/m.json") 9)
                                           (file-delete (string-append box "/m.json")) 'ok)
                                    (e) 'FAIL))) (newline)

;; One-way latch: the sandbox can only narrow, never widen or clear.
(display (list 'cannot-widen
  (try-catch (begin (sandbox-enable! "/tmp") #f)
             (e) (string-contains? e "can only narrow")))) (newline)

;; Cleanup (parent is the root, so an in-box delete is allowed).
(file-delete (string-append box "/ok.txt"))
