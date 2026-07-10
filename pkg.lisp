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
                (for-each (lambda (dep) (pkg-install dep))
                          (pkg-get m 'deps '()))
                (list 'installed (pkg-get m 'name name)
                      (pkg-get m 'version "?"))))))))

(define (pkg-load name)
  (if (not (pkg-installed? name))
      (error (format "pkg-load: ~a is not installed" name))
      (let ((m (pkg-read-manifest (pkg-dir name))))
        (load (string-append (pkg-dir name) "/"
                             (pkg-get m 'main (string-append name ".lisp"))))
        (list 'loaded (pkg-get m 'name name) (pkg-get m 'version "?")))))

(define (require-package url . opt)
  (let ((name (pkg-url-name url)))
    (when (not (pkg-installed? name))
      (apply pkg-install (cons url opt)))
    (pkg-load name)))

(define (pkg-list)
  (if (file-exists? (pkg-root))
      (map (lambda (n)
             (let ((m (pkg-read-manifest (pkg-dir n))))
               (list (pkg-get m 'name n) (pkg-get m 'version "?"))))
           (dir-list (pkg-root)))
      '()))

(define (pkg-remove name)
  (if (pkg-installed? name)
      (begin (shell (format "rm -rf ~a" (pkg-dir name)))
             (list 'removed name))
      (list 'not-installed name)))
