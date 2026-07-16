;;; Copyright (c) 2026 Nicholas Vermeulen
;;; SPDX-License-Identifier: AGPL-3.0-or-later

;; pkg-test.lisp — golden test for pkg.lisp. No network: the fixture
;; packages are local git repositories under /tmp, installed via file://
;; URLs. Deterministic (fixed paths, no timestamps/hashes in output).

(load "pkg.lisp")

;; ── Build two fixture packages: rusty-pkg-fix depends on rusty-pkg-dep ──
(define (make-fixture dir manifest libfile libsrc)
  (shell (format "rm -rf ~a" dir))
  (dir-create dir)
  (file-write (string-append dir "/package.lisp") manifest)
  (file-write (string-append dir "/" libfile) libsrc)
  (shell (format "cd ~a && git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -qm fixture" dir)))

(make-fixture "/tmp/rusty-pkg-dep"
  "((name \"rusty-pkg-dep\") (version \"0.1.0\") (main \"dep.lisp\"))"
  "dep.lisp"
  "(define (dep-triple x) (* 3 x))")

(make-fixture "/tmp/rusty-pkg-fix"
  "((name \"rusty-pkg-fix\") (version \"1.2.0\") (main \"fix.lisp\") (deps (\"file:///tmp/rusty-pkg-dep\")))"
  "fix.lisp"
  "(define (fix-answer x) (+ (dep-triple x) 1))")

;; start clean (idempotent re-runs)
(pkg-remove "rusty-pkg-fix")
(pkg-remove "rusty-pkg-dep")

;; ── Install: pulls the dependency transitively ───────────────────────────
(print (pkg-install "file:///tmp/rusty-pkg-fix"))
(print (list 'dep-arrived-too (pkg-installed? "rusty-pkg-dep")))
(print (pkg-install "file:///tmp/rusty-pkg-fix"))   ; second time: no-op

;; ── Load and actually use it (dep loads first) ───────────────────────────
(print (pkg-load "rusty-pkg-dep"))
(print (pkg-load "rusty-pkg-fix"))
(print (list 'fix-answer-of-5 (fix-answer 5)))      ; 3*5+1 = 16

;; require-package on something already present: just loads
(print (require-package "file:///tmp/rusty-pkg-dep"))

;; ── Errors are informative, not crashes ──────────────────────────────────
(print (try-catch (pkg-load "no-such-package") (e) (list 'rejected e)))
(shell "rm -rf /tmp/rusty-not-a-pkg && mkdir -p /tmp/rusty-not-a-pkg && cd /tmp/rusty-not-a-pkg && git init -q && git -c user.email=t@t -c user.name=t commit -qm empty --allow-empty")
(print (try-catch (pkg-install "file:///tmp/rusty-not-a-pkg") (e) (list 'rejected e)))

;; ── Integrity: is this still what I installed? ───────────────────────────
;; Hashes themselves stay out of the golden (they'd be noise); what's pinned is
;; the SHAPE: which files are covered, that .git is not, and that every kind of
;; change is NAMED rather than merely counted.
(define FP (pkg-fingerprint "rusty-pkg-dep"))
(print (list 'fingerprint-covers (map car FP)))     ; sorted; no .git
(print (list 'every-file-hashed (all? (lambda (r) (string? (cadr r))) FP)))
(print (list 'fresh-install-has-no-drift (pkg-drift "rusty-pkg-dep")))

;; Edit an installed file — the tamper a lock exists to catch.
(file-append (string-append (pkg-dir "rusty-pkg-dep") "/dep.lisp") "\n(define sneaky 1)\n")
(print (list 'edited-file-named (pkg-drift "rusty-pkg-dep")))
;; ...and an out-of-band fingerprint (the honest kind) catches it too
(print (list 'verify-vs-out-of-band-fp (pkg-verify "rusty-pkg-dep" FP)))

;; A file that appeared, and one that vanished, are different words.
(file-write (string-append (pkg-dir "rusty-pkg-dep") "/extra.lisp") "(define x 1)")
(print (list 'added-file-named (pkg-verify "rusty-pkg-dep" FP)))
(file-delete (string-append (pkg-dir "rusty-pkg-dep") "/extra.lisp"))
(file-delete (string-append (pkg-dir "rusty-pkg-dep") "/dep.lisp"))
(print (list 'missing-file-named (pkg-verify "rusty-pkg-dep" FP)))

;; Absence of a lock is its own answer — never a clean bill of health.
(file-delete (pkg-lock-path "rusty-pkg-dep"))
(print (list 'no-lock-is-not-verified (pkg-drift "rusty-pkg-dep")))
(print (list 'not-installed-is-not-verified (pkg-drift "no-such-package")))

;; ── Uninstall, leave the machine clean ───────────────────────────────────
(print (pkg-remove "rusty-pkg-fix"))
(print (list 'lock-removed-with-package (pkg-locked? "rusty-pkg-fix")))
(print (pkg-remove "rusty-pkg-dep"))
(print (pkg-remove "rusty-pkg-fix"))                ; already gone
(shell "rm -rf /tmp/rusty-pkg-fix /tmp/rusty-pkg-dep /tmp/rusty-not-a-pkg")

(print "PKG TESTS DONE")
