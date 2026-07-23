;;; Copyright (c) 2026 Nicholas Vermeulen
;;; SPDX-License-Identifier: AGPL-3.0-or-later

;; cert.lisp — verifiable certificate exchange (pure Lisp library).
;;
;; mingjian proves a log by REPLAYING it; cert.lisp generalizes that to
;; proof EXCHANGE across hosts. An issuer bundles a claim — a function's
;; SOURCE, a property's SOURCE, and the finite DOMAINS it was checked over —
;; runs the gates locally, and SIGNS the bundle (Ed25519). A receiver on
;; another machine does TWO independent things:
;;   1. verifies the signature — the bundle came UNCHANGED from a trusted
;;      issuer (mutate one byte of the claim and the signature fails);
;;   2. RE-RUNS the gates itself — check-effects (pure?) then check-exhaustive
;;      over the declared domains — trusting the issuer's word for NOTHING.
;;
;; THE LOAD-BEARING DISTINCTION: a validly-signed bundle from a trusted issuer
;; is STILL refused if the receiver's own re-run finds a counterexample or an
;; effect. The signature proves PROVENANCE; the re-run proves HONESTY; they
;; are separate, and honesty is not delegated. (Proven as a negative control
;; in the golden: a hand-forged, correctly-signed, WRONG bundle is refused.)
;;
;; CLAIM DISCIPLINE: `certified` = "the receiver independently re-verified the
;; gates on THIS signed bundle over the DECLARED finite domain, and the
;; signature proves it arrived unchanged from a trusted issuer." Never
;; "trusted"/"safe"/"correct in general". The mingjian anchor limit still
;; holds: a holder of the private key can sign a false claim, and only the
;; receiver's re-run — not the signature — catches it.
;;
;; No new interpreter code: check-effects + check-exhaustive are the gates,
;; ed25519-keygen/sign/verify are the anchor, eval turns SOURCE into a callable.

;; ── Canonical serialization (the exact bytes that get signed) ──────────────
;; Same lossless renderer pcheck uses; strings are re-quoted so the round-trip
;; is faithful. DOCUMENTED SUBSET (as in pcheck's datum->source): string
;; escaping is minimal, so keep signed claims to source strings without
;; embedded double-quotes — every claim built here is exactly that.
(define (cert-serialize d)
  (cond ((null? d)    "()")
        ((string? d)  (string-append "\"" d "\""))
        ((symbol? d)  (symbol->string d))
        ((number? d)  (number->string d))
        ((boolean? d) (if d "#t" "#f"))
        ((pair? d)    (string-append "(" (string-join (map cert-serialize d) " ") ")"))
        (else (error "cert-serialize: unrenderable datum"))))

(define (cert--domain-size domains)
  (foldl (lambda (d acc) (* acc (length d))) 1 domains))

;; The signed message is the canonical claim — subject + both sources + domains.
;; Nothing about the issuer or signature is inside it (a signature can't cover
;; itself), so tampering with ANY claim field breaks verification.
(define (cert--claim-message subject fn-src invariant-src domains)
  (cert-serialize (list subject fn-src invariant-src domains)))

;; ── The gates (run by BOTH issuer and receiver — identical, so they can't
;; drift): the candidate must be pure, then satisfy the invariant on every
;; declared domain point. 'ok, or (refused <tag> <detail>). ─────────────────
;; fn-src / invariant-src are SOURCE STRINGS (a bundle crosses hosts as text),
;; so eval-string (parse + eval in a fresh env) — not eval, which runs a datum.
(define (cert-gates fn-src invariant-src domains)
  (let ((f (eval-string fn-src)))
    (if (not (procedure? f))
        (list 'refused 'not-a-function fn-src)
        (let ((eff (check-effects f)))
          (if (not (equal? eff 'pure))
              (list 'refused 'impure eff)
              (let ((inv (eval-string invariant-src)))
                (let ((r (check-exhaustive
                           (lambda args (apply inv (cons f args))) domains)))
                  (if (equal? r 'verified)
                      'ok
                      (list 'refused 'counterexamples r)))))))))

;; ── Issue: gate locally, then sign. The issuer VOUCHES ONLY for what passed
;; its own gates — cert-make refuses to sign a bundle that doesn't verify. ───
;; secret-hex is the Ed25519 private seed (32 bytes hex); it never leaves the
;; issuer. Returns a bundle (data) or the gate refusal.
(define (cert-issuer-pub secret) (cadr (ed25519-keygen secret)))

(define (cert-make secret subject fn-src invariant-src domains)
  (let ((g (cert-gates fn-src invariant-src domains)))
    (if (not (equal? g 'ok))
        g
        (let ((msg (cert--claim-message subject fn-src invariant-src domains)))
          (list 'cert
                (list 'subject subject)
                (list 'fn-src fn-src)
                (list 'invariant-src invariant-src)
                (list 'domains domains)
                (list 'issuer (cert-issuer-pub secret))
                (list 'sig (ed25519-sign secret msg)))))))

;; ── Bundle accessors ───────────────────────────────────────────────────────
(define (cert? b) (and (pair? b) (equal? (car b) 'cert)))
(define (cert-field b k) (let ((e (assoc k (cdr b)))) (if e (cadr e) #f)))
(define (cert-subject b)       (cert-field b 'subject))
(define (cert-fn-src b)        (cert-field b 'fn-src))
(define (cert-invariant-src b) (cert-field b 'invariant-src))
(define (cert-domains b)       (cert-field b 'domains))
(define (cert-issuer b)        (cert-field b 'issuer))
(define (cert-sig b)           (cert-field b 'sig))

;; ── Verify: the receiver's job. `trusted` is a list of issuer public keys
;; (they arrive out-of-band, over a channel you already trust). Returns
;; (certified subject domain-size N) or (refused <tag> ...). ─────────────────
;; Order matters: a malformed/untrusted/forged bundle is refused BEFORE its
;; source is ever eval'd by the re-run — the same static-first discipline the
;; gates themselves use.
(define (cert-verify bundle trusted)
  (if (not (cert? bundle))
      (list 'refused 'not-a-cert)
      (let ((subject (cert-subject bundle))
            (fn-src  (cert-fn-src bundle))
            (inv-src (cert-invariant-src bundle))
            (domains (cert-domains bundle))
            (issuer  (cert-issuer bundle))
            (sig     (cert-sig bundle)))
        (if (not (member issuer trusted))
            (list 'refused 'untrusted-issuer issuer)
            (let ((msg (cert--claim-message subject fn-src inv-src domains)))
              (if (not (ed25519-verify issuer msg sig))
                  (list 'refused 'bad-signature)
                  ;; provenance ok — now re-run the gates, trusting nothing.
                  (let ((g (cert-gates fn-src inv-src domains)))
                    (if (equal? g 'ok)
                        (list 'certified subject 'domain-size (cert--domain-size domains))
                        g))))))))          ; a valid signature does NOT save a bundle
                                           ; whose re-run fails — g is the refusal.
