;;; Copyright (c) 2026 Nicholas Vermeulen
;;; SPDX-License-Identifier: AGPL-3.0-or-later

;; pkg.lisp — a registry-less package manager (Phase 5.2, pure Lisp).
;;
;; A PACKAGE is any git repository with a `package.lisp` manifest at its
;; root — one alist:
;;   ((name "mylib") (version "0.1.0") (main "mylib.lisp")
;;    (deps ("https://github.com/user/otherlib" ...)))   ; deps optional
;;
;; Install = `git clone` into ~/.rusty/packages/<name>. Any URL git
;; understands works — https, ssh, file:// — so there is no central
;; registry to stand up or trust (the Go-modules lesson); a hosted index
;; can layer on later without changing this format.
;;
;;   (pkg-install url [tag])   clone (optionally at a tag) + install deps
;;   (pkg-load name)           load an installed package's main file
;;   (require-package url [tag])  install-if-missing, then load
;;   (pkg-list) / (pkg-remove name)

(define (pkg-root)
  (string-append (shell "printf $HOME") "/.rusty/packages"))

(define (pkg-dir name) (string-append (pkg-root) "/" name))
(define (pkg-manifest-path dir) (string-append dir "/package.lisp"))
(define (pkg-installed? name) (file-exists? (pkg-dir name)))

(define (pkg-read-manifest dir)
  (eval-string (string-append "(quote " (file-read (pkg-manifest-path dir)) ")")))

(define (pkg-get m key default)
  (let ((hit (assoc key m))) (if hit (cadr hit) default)))

(define (pkg-strip-git s)
  (let ((n (string-length s)))
    (if (and (>= n 4) (equal? (substring s (- n 4) n) ".git"))
        (substring s 0 (- n 4))
        s)))

(define (pkg-url-name url)
  (let ((parts (string-split url "/")))
    (pkg-strip-git (nth parts (- (length parts) 1)))))

(define (pkg-install url . opt)
  (let ((name (pkg-url-name url)))
    (if (pkg-installed? name)
        (list 'already-installed name)
        (begin
          (dir-create (pkg-root))
          (shell (format "git clone --quiet --depth 1 ~a ~a ~a"
                         (if (null? opt) "" (format "--branch ~a" (car opt)))
                         url (pkg-dir name)))
          (if (not (file-exists? (pkg-manifest-path (pkg-dir name))))
              (begin
                (shell (format "rm -rf ~a" (pkg-dir name)))
                (error (format "pkg-install: ~a is not a Rusty package (no package.lisp manifest)" url)))
              (let ((m (pkg-read-manifest (pkg-dir name))))
                ;; Record what arrived, before anything else runs: this is the
                ;; only moment we can honestly say "this is what was installed".
                (pkg-lock! name)
                (for-each (lambda (dep) (pkg-install dep))
                          (pkg-get m 'deps '()))
                (list 'installed (pkg-get m 'name name)
                      (pkg-get m 'version "?"))))))))

;; The file `pkg-load` runs: the manifest's `main`, defaulting to <name>.lisp.
;; pkg-load and pkg-effects both go through this, so "the file that runs" and
;; "the file we inspect" can never drift apart.
(define (pkg-main-path name)
  (let ((m (pkg-read-manifest (pkg-dir name))))
    (string-append (pkg-dir name) "/"
                   (pkg-get m 'main (string-append name ".lisp")))))

(define (pkg-load name)
  (if (not (pkg-installed? name))
      (error (format "pkg-load: ~a is not installed" name))
      (let ((m (pkg-read-manifest (pkg-dir name))))
        (load (pkg-main-path name))
        (list 'loaded (pkg-get m 'name name) (pkg-get m 'version "?")))))

(define (require-package url . opt)
  (let ((name (pkg-url-name url)))
    (when (not (pkg-installed? name))
      (apply pkg-install (cons url opt)))
    (pkg-load name)))

;; ── Effect disclosure (what a package ADMITS to doing) ─────────────────────
;; Integrity (below) proves SAMENESS. This asks an orthogonal question: what
;; does this package's code admit it does? check-effects walks a body WITHOUT
;; running it; here we point it at the very file pkg-load would execute. The
;; file's top-level forms are wrapped in one (lambda () ...) — building the
;; closure runs nothing — and the real Rust effect walker reports every
;; effectful operation it finds (shell, file I/O, load, ...).
;;
;; HONEST SCOPE — this is DISCLOSURE, never a sandbox:
;;   1. It inspects the MAIN file only. A (load "other.lisp") inside it is
;;      itself surfaced as an effect ("there is more code here I did not read"),
;;      but that other file's contents are not walked.
;;   2. It surfaces every effect NAMED anywhere in the main file — including
;;      inside a helper this file defines (that body is walked too). The blind
;;      spot is an effect reachable only through code NOT in this file: a
;;      DEPENDENCY's function, or a file this one `load`s. check-effects is
;;      conservative — an unrecognized/user-defined call is never flagged — so
;;      it reports what the file ADMITS, and can never prove what it CANNOT do.
;;   3. A pass from pkg-load-checked means "admits nothing beyond what you
;;      allowed", never "safe to run".
(define (pkg-effects name)
  (if (not (pkg-installed? name))
      #f
      (let ((forms (eval-string
                     (string-append "(quote (" (file-read (pkg-main-path name)) "))"))))
        (if (null? forms)
            'pure
            (check-effects (eval (cons 'lambda (cons '() forms))))))))

;; The deduped effect OPERATION symbols (the same shape undeclared-effects /
;; safe-call use): #f if not installed, '() if pure, else e.g. (shell load).
(define (pkg-effect-ops name)
  (let ((e (pkg-effects name)))
    (cond ((not e) #f)
          ((equal? e 'pure) '())
          (else (remove-duplicates (map finding-op e))))))

;; Effect-gated load: load only if every operation the package admits is in
;; `allowed` (a list of op symbols). Otherwise refuse WITHOUT loading and name
;; the operations you did not allow. Refuse-by-disclosure, not a sandbox.
(define (pkg-load-checked name allowed)
  (let ((ops (pkg-effect-ops name)))
    (if (not ops)
        (list 'not-installed name)
        (let ((undeclared (filter (lambda (op) (not (member op allowed))) ops)))
          (if (null? undeclared)
              (pkg-load name)
              (list 'refused name (cons 'undeclared undeclared)))))))

(define (pkg-list)
  (if (file-exists? (pkg-root))
      (map (lambda (n)
             (let ((m (pkg-read-manifest (pkg-dir n))))
               (list (pkg-get m 'name n) (pkg-get m 'version "?"))))
           (dir-list (pkg-root)))
      '()))

;; ── Integrity ────────────────────────────────────────────────────────────
;; What you install from a git URL is whatever that URL served you. A
;; fingerprint gives an installed package a comparable identity: every file
;; under it with its SHA-256, sorted by path (dir-list sorts, so two machines
;; that installed the same bytes agree exactly).
;;
;; HONEST SCOPE, twice over:
;;   1. A fingerprint proves SAMENESS, not safety. Identical bytes to a
;;      malicious package are still malicious. It answers "is this what I
;;      installed / what the publisher meant?" — never "is this good?".
;;   2. A fingerprint is only worth WHERE IT CAME FROM. One the package hands
;;      you itself — in its own manifest, in its own repo — proves nothing:
;;      whoever changes the files changes the manifest in the same commit.
;;      That is why there is no (files ...) hash key in the manifest format;
;;      it would look like a guarantee and be none. An expected fingerprint has
;;      to reach you another way: the publisher's site, a release note, a
;;      counterparty, or your own record from install day (that last one is
;;      what pkg-lock! keeps, and it detects local drift only — an attacker on
;;      your machine can rewrite the lock as easily as the package).
;;
;; .git is skipped: two clones of the same commit are not byte-identical there,
;; so including it would make every fingerprint disagree with every other.
;; Symlinks are followed (file-hash follows them), so a package that symlinks
;; outside its own tree fingerprints its target's bytes, not the link.

;; No is-a-directory? builtin exists; dir-list raises on a regular file, and
;; that raise is the test.
(define (pkg-dir? path)
  (try-catch (begin (dir-list path) #t) (e) #f))

(define (pkg-files dir prefix)
  (foldl
    (lambda (name acc)
      (let ((full (string-append dir "/" name))
            (rel  (string-append prefix name)))
        (cond ((equal? name ".git") acc)
              ((pkg-dir? full) (append acc (pkg-files full (string-append rel "/"))))
              (else (append acc (list (list rel (file-hash full))))))))
    '()
    (dir-list dir)))

;; -> ((relpath sha256) ...) sorted, or #f if not installed
(define (pkg-fingerprint name)
  (if (pkg-installed? name) (pkg-files (pkg-dir name) "") #f))

(define (pkg-fp-lookup fp path)
  (let ((hit (assoc path fp))) (if hit (cadr hit) #f)))

;; Name what moved, per file: changed / missing / added. A verdict of "this
;; package differs" without saying WHERE is not worth printing.
(define (pkg-fp-diff expected got)
  (append
    (foldl (lambda (row acc)
             (let ((g (pkg-fp-lookup got (car row))))
               (cond ((not g) (append acc (list (list (car row) 'missing))))
                     ((not (equal? g (cadr row))) (append acc (list (list (car row) 'changed))))
                     (else acc))))
           '() expected)
    (foldl (lambda (row acc)
             (if (pkg-fp-lookup expected (car row))
                 acc
                 (append acc (list (list (car row) 'added)))))
           '() got)))

;; 'verified | (changed ((path what) ...)) | (not-installed name)
(define (pkg-verify name expected)
  (let ((got (pkg-fingerprint name)))
    (cond ((not got) (list 'not-installed name))
          ((equal? got expected) 'verified)
          (else (list 'changed (pkg-fp-diff expected got))))))

;; Locks live OUTSIDE the package directory on purpose: a lock inside the tree
;; it vouches for would be rewritten by the same `git pull` (or hand-edit) it
;; is supposed to notice, and would change its own fingerprint besides.
(define (pkg-lock-root) (string-append (shell "printf $HOME") "/.rusty/pkg-locks"))
(define (pkg-lock-path name) (string-append (pkg-lock-root) "/" name ".json"))
(define (pkg-locked? name) (file-exists? (pkg-lock-path name)))

(define (pkg-lock! name)
  (let ((fp (pkg-fingerprint name)))
    (if (not fp)
        (list 'not-installed name)
        (begin (dir-create (pkg-lock-root))
               (save-model (pkg-lock-path name) fp)
               (list 'locked name (length fp))))))

;; Has anything under an installed package changed since it was installed?
;; 'verified | (changed ...) | (no-lock name) | (not-installed name)
(define (pkg-drift name)
  (cond ((not (pkg-installed? name)) (list 'not-installed name))
        ((not (pkg-locked? name))    (list 'no-lock name))
        (else (pkg-verify name (load-model (pkg-lock-path name))))))

(define (pkg-remove name)
  (if (pkg-installed? name)
      (begin (shell (format "rm -rf ~a" (pkg-dir name)))
             (if (pkg-locked? name) (file-delete (pkg-lock-path name)))
             (list 'removed name))
      (list 'not-installed name)))

;; Give the package manager its own help category (embedded + auto-loaded into
;; every env, so these appear in (help)/(apropos)/(command-registry) unprefixed).
;; Without this the pkg-* names all fall into "other".
(categorize! 'pkg '(pkg-root pkg-dir pkg-manifest-path pkg-installed? pkg-read-manifest
  pkg-get pkg-strip-git pkg-url-name pkg-install pkg-main-path pkg-load require-package
  pkg-effects pkg-effect-ops pkg-load-checked pkg-list
  pkg-dir? pkg-files pkg-fingerprint pkg-fp-lookup pkg-fp-diff pkg-verify
  pkg-lock-root pkg-lock-path pkg-locked? pkg-lock! pkg-drift pkg-remove))
