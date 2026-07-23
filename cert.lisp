;;; Copyright (c) 2026 Nicholas Vermeulen
;;; SPDX-License-Identifier: AGPL-3.0-or-later

;; cert.lisp — verifiable certificate exchange (pure Lisp library).
;;
;; mingjian proves a log by REPLAYING it; cert.lisp generalizes that to
;; proof EXCHANGE across hosts. An issuer bundles a claim — a function's
;; SOURCE, a property's SOURCE, and the finite DOMAINS it was checked over —
;; runs the gates locally, and SIGNS the canonical serialization (Ed25519). A
;; receiver on another machine does TWO independent things:
;;   1. verifies the signature — the bundle came UNCHANGED from a trusted
;;      issuer (the serialization is INJECTIVE, so mutating any claim field
;;      changes the signed bytes and the signature fails);
;;   2. RE-CHECKS the claim's HONESTY itself — check-effects (pure?) then
;;      check-exhaustive over the declared domains. The issuer's signature is
;;      NOT taken as evidence that the claim holds; the receiver re-runs it.
;;
;; THE LOAD-BEARING DISTINCTION: a validly-signed bundle from a trusted issuer
;; is STILL refused if the receiver's own re-run finds a counterexample or an
;; effect. The signature proves PROVENANCE (this exact claim came from this
;; key); the re-run proves HONESTY (the claim actually holds); they are
;; separate, and honesty is delegated to no one. (Negative control in the
;; golden: a correctly-signed WRONG bundle is refused by the re-run.)
;;
;; WHAT A CERT DOES *NOT* GIVE YOU: the receiver still accepts the issuer's
;; CHOICE of subject, sources, and DOMAINS. A trusted key can sign a true-but-
;; trivial claim (a tiny domain, a weak invariant); the re-run confirms only
;; that the stated claim holds on the stated domain, never that it is a strong
;; or meaningful claim. `certified` = "the receiver independently re-verified
;; THIS claim over THIS declared finite domain, and the signature proves it
;; arrived unchanged from a trusted issuer" — never "trusted"/"safe"/"correct".
;; The mingjian anchor limit holds: a private-key holder can sign a false
;; claim, and only the receiver's re-run — never the signature — catches it.
;;
;; No new interpreter code: check-effects + check-exhaustive are the gates,
;; ed25519-keygen/sign/verify are the anchor, eval-string turns SOURCE (text,
;; because a bundle crosses hosts as text) into a callable.

;; ── Canonical serialization = the exact bytes that get signed ──────────────
;; INJECTIVE by construction: every atom is TYPE-TAGGED and LENGTH-PREFIXED
;; (s/y/n = string/symbol/number then <char-count>:<chars>; L<count>: for a
;; list; bt/bf for a boolean). No content — embedded quotes, spaces, digits,
;; ":" — can forge a field boundary, and no two data of different type collide
;; (the tag separates them). Distinct data always encode to distinct strings,
;; so there is no fragile "subset" to remember. (We never parse this back;
;; injectivity of the ENCODER is all a signature preimage needs.)
(define (cert--len s) (number->string (string-length s)))
(define (cert-serialize d)
  (cond ((boolean? d) (if d "bt" "bf"))
        ((null? d)    "L0:")
        ((string? d)  (string-append "s" (cert--len d) ":" d))
        ((symbol? d)  (let ((s (symbol->string d)))
                        (string-append "y" (cert--len s) ":" s)))
        ((number? d)  (let ((s (number->string d)))
                        (string-append "n" (cert--len s) ":" s)))
        ((pair? d)    (string-append "L" (number->string (length d)) ":"
                                     (apply string-append (map cert-serialize d))))
        (else (error "cert-serialize: unrenderable datum"))))

(define (cert--domain-size domains)
  (foldl (lambda (d acc) (* acc (length d))) 1 domains))

;; The signed message = a DOMAIN-SEPARATION tag + the canonical claim. The tag
;; ("cert-v1") means a cert signature can never be replayed as an evolve
;; receipt (a different tag) even under the same key. Nothing about the issuer
;; or signature is inside it (a signature can't cover itself).
(define (cert--claim-message subject fn-src invariant-src domains)
  (string-append "cert-v1:"
                 (cert-serialize (list subject fn-src invariant-src domains))))

;; ── The gates (run by BOTH issuer and receiver — identical, so they can't
;; drift): the candidate must be pure, then satisfy the invariant on every
;; declared domain point. 'ok, or (refused <tag> <detail>). A malformed or
;; unparseable source RAISES inside eval-string / apply — caught here and
;; normalized to (refused error ...) so a garbage bundle can never crash the
;; receiver, only be refused. ───────────────────────────────────────────────
(define (cert-gates fn-src invariant-src domains)
  (try-catch
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
                        (list 'refused 'counterexamples r))))))))
    (e) (list 'refused 'error e)))

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
;; Static-first order: a malformed / untrusted / bad-signature bundle is
;; refused BEFORE its source is ever eval'd by the re-run. A missing field
;; (cert-field → #f) or empty domains is (refused malformed) — an empty domain
;; product is a vacuous claim, so it is rejected rather than "verified" over
;; nothing.
(define (cert-verify bundle trusted)
  (if (not (cert? bundle))
      (list 'refused 'not-a-cert)
      (let ((subject (cert-subject bundle))
            (fn-src  (cert-fn-src bundle))
            (inv-src (cert-invariant-src bundle))
            (domains (cert-domains bundle))
            (issuer  (cert-issuer bundle))
            (sig     (cert-sig bundle)))
        (if (or (not subject) (not fn-src) (not inv-src)
                (not domains) (not issuer) (not sig))
            (list 'refused 'malformed)
            (if (not (member issuer trusted))
                (list 'refused 'untrusted-issuer issuer)
                (let ((msg (cert--claim-message subject fn-src inv-src domains)))
                  (if (not (ed25519-verify issuer msg sig))
                      (list 'refused 'bad-signature)
                      ;; provenance ok — now re-run the gates, trusting nothing.
                      (let ((g (cert-gates fn-src inv-src domains)))
                        (if (equal? g 'ok)
                            (list 'certified subject
                                  'domain-size (cert--domain-size domains))
                            g)))))))))       ; a valid signature does NOT save a
                                             ; bundle whose re-run fails.
