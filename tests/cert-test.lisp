;;; Copyright (c) 2026 Nicholas Vermeulen
;;; SPDX-License-Identifier: AGPL-3.0-or-later

;; cert-test.lisp — golden for cert.lisp. Deterministic: fixed Ed25519 seeds
;; (signing is deterministic), no timings, no network. Proves the two layers
;; are independent — provenance (signature) and honesty (re-run) — the
;; injective encoding (embedded quotes are safe; old collisions are gone), and
;; that malformed/tampered bundles are refused before any source is eval'd.

(load "cert.lisp")

;; Two fixed test identities (64-hex seeds = 32-byte Ed25519 private keys).
(define trusted-secret   "0000000000000000000000000000000000000000000000000000000000000001")
(define untrusted-secret "0000000000000000000000000000000000000000000000000000000000000002")
(define trusted-pub   (cert-issuer-pub trusted-secret))
(define untrusted-pub (cert-issuer-pub untrusted-secret))
(define trust (list trusted-pub))          ; the receiver's trusted-issuer set

;; The claim: abs is non-negative and equals ±x, over a small integer domain.
(define abs-fn  "(lambda (x) (if (< x 0) (- 0 x) x))")
(define abs-inv "(lambda (f x) (and (>= (f x) 0) (or (= (f x) x) (= (f x) (- 0 x)))))")
(define dom     (list (list -3 -1 0 2 5)))

;; helpers: forge a validly-signed bundle WITHOUT gating (a lying/buggy issuer
;; — signs the REAL claim message), and tamper one field of an honest bundle
;; without re-signing.
(define (forge secret subject fn-src inv-src domains)
  (list 'cert (list 'subject subject) (list 'fn-src fn-src)
        (list 'invariant-src inv-src) (list 'domains domains)
        (list 'issuer (cert-issuer-pub secret))
        (list 'sig (ed25519-sign secret
                     (cert--claim-message subject fn-src inv-src domains)))))
(define (tamper-field bundle key new)
  (cons 'cert (map (lambda (e) (if (equal? (car e) key) (list key new) e))
                   (cdr bundle))))

(display "== an honest cert, issued and independently re-verified ==") (newline)
(define good (cert-make trusted-secret 'abs abs-fn abs-inv dom))
(display (list 'is-cert (cert? good) 'subject (cert-subject good))) (newline)
(display (list 'verify (cert-verify good trust))) (newline)
(newline)

(display "== the encoding is injective: embedded quotes are safe now ==") (newline)
;; a real claim whose SOURCE contains string literals (a doc string) — pure,
;; still computes abs. Under the old renderer its quotes could forge a field
;; boundary; now it certifies cleanly.
(define absdoc-fn "(lambda (x) (begin \"doc\" (if (< x 0) (- 0 x) x)))")
(display (list 'embedded-quote
               (cert-verify (cert-make trusted-secret 'absdoc absdoc-fn abs-inv dom) trust)))
(newline)
;; the classic cross-field collision pair now encodes to DIFFERENT bytes.
(display (list 'no-collision
               (not (equal? (cert-serialize (list "a\" \"b" "c"))
                            (cert-serialize (list "a" "b\" \"c"))))))
(newline)
(newline)

(display "== tamper the claim (no re-sign): signature fails ==") (newline)
(display (list 'fn-tamper
               (cert-verify (tamper-field good 'fn-src "(lambda (x) x)") trust))) (newline)
;; subject is bound into the signed message too — tampering only it fails.
(display (list 'subject-tamper
               (cert-verify (tamper-field good 'subject 'evil) trust))) (newline)
(newline)

(display "== signed by an untrusted issuer: refused before any re-run ==") (newline)
(define outside (cert-make untrusted-secret 'abs abs-fn abs-inv dom))
(let ((v (cert-verify outside trust)))
  (display (list (car v) (cadr v)))) (newline)          ; (refused untrusted-issuer)
(newline)

(display "== NEGATIVE CONTROL: valid signature, trusted issuer, WRONG claim ==") (newline)
(display "   (the re-run refuses what the signature would have waved through)") (newline)
;; a trusted key signs a bundle whose fn does NOT satisfy the invariant.
(display (list 'wrong-but-signed
               (cert-verify (forge trusted-secret 'abs "(lambda (x) x)" abs-inv dom) trust)))
(newline)
;; a trusted key signs an IMPURE fn — the static gate catches it, and the
;; smuggled (print x) never runs (no stray output below).
(display (list 'impure-but-signed
               (cert-verify (forge trusted-secret 'abs
                              "(lambda (x) (begin (print x) x))" abs-inv dom) trust)))
(newline)
(newline)

(display "== malformed bundles are refused, never crash the receiver ==") (newline)
(display (list 'missing-fields (cert-verify (list 'cert (list 'subject 'x)) trust))) (newline)
;; a trusted, validly-signed bundle whose source is unparseable garbage:
;; refused (error ...), not a raise.
(display (list 'garbage-source (car (cdr (cert-verify
               (forge trusted-secret 'abs "(this is not )( valid" abs-inv dom) trust))))) (newline)
(newline)

(display "== an issuer will not sign what fails its OWN gates ==") (newline)
(display (list 'make-junk (cert-make trusted-secret 'abs "(lambda (x) x)" abs-inv dom)))
(newline)
(display "CERT OK") (newline)
