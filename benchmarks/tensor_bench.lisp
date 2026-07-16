;;; tensor_bench.lisp — the Phase 3.1/3.3 tensor training benchmark.
;;; Timings, not golden output — do NOT add to run_tests.sh.
;;;
;;; Re-records the numbers ROADMAP 3.1 and 3.3 quote, all from ONE machine state:
;;;   8x16->8   x1000 SGD steps  — interpreted graph-grad vs compiled graph-compile-grad
;;;   64x256->64 x100 SGD steps  — same two paths
;;; Run benchmarks/tensor_torch_bench.py for the 1-thread float64 PyTorch side;
;;; it uses the same shapes, step counts, LR and inits, and the two sides should
;;; land on the SAME final loss (that agreement is what proves the loops match).
;;;
;;; Why absolutes drift: these are wall-clock on whatever machine/thermal state
;;; you run them on. The RATIO is the durable claim — see ROADMAP 3.1.
;;;
;;; v0.43.0 (2026-07-15) — JIT marshalling cut. A/B on one machine state, this
;;; file, medians of 3:
;;;   64x256->64 x100   JIT 143.3 ms -> 130.6 ms  (-8.9%)
;;;   8x16->8   x1000   JIT   6.18 ms ->   5.78 ms (-6.5%)
;;; graph-grad (interpreted) unchanged, as expected — the fix is codegen-only:
;;; the generated kernel borrowed its input tensors instead of copying them in
;;; (`.to_vec()` per input, ~295 KB/call at the medium shape) and stopped
;;; cloning on the SumTo same-shape identity (~164 KB/call). Verified
;;; bit-identical to graph-grad across 5 shapes / 37,353 values.
;;; NOTE the JIT is still ~5% SLOWER than the interpreter at 64x256->64 — the
;;; gap narrowed (~1.12x -> ~1.06x slower), it did not flip. Fusing still only
;;; pays at small shapes.
;;;
;;; Loss = mean((relu(xW+b) - t)^2). The graph IR has no capture, so everything
;;; the loss needs is a param or a literal; the mean divisor is passed as `nn`.
;;; Inputs are integer-derived /8 — exactly representable, so Rusty and torch
;;; start from bit-identical data.

(define (val i off) (/ (- (mod (+ (* i 7) off) 17) 8) 8.0))
(define (build-list n f) (let loop ((i 0) (acc '())) (if (= i n) (reverse acc) (loop (+ i 1) (cons (f i) acc)))))
(define (row-major m k off) (build-list m (lambda (i) (build-list k (lambda (j) (val (+ (* i k) j) off))))))

(define LR 0.01)

(define loss-fn
  (lambda (x W b t nn)
    (tensor-sum
      (tensor-div
        (tensor-mul (tensor-sub (relu (tensor-add (matmul x W) b)) t)
                    (tensor-sub (relu (tensor-add (matmul x W) b)) t))
        nn))))

;; One SGD run. `g` is whatever computes (loss gx gW gb gnn) — graph-grad itself
;; (interpreted: rebuilds+optimizes the graph every call) or a compiled
;; NativeGrad from graph-compile-grad. Identical loop either way.
(define (sgd g X W0 B0 T NN steps)
  (let loop ((i 0) (W W0) (b B0))
    (if (= i steps)
        (list W b)
        (let* ((r  (g X W b T NN))
               (gW (nth r 2))
               (gb (nth r 3)))
          (loop (+ i 1)
                (tensor-sub W (tensor-mul gW LR))
                (- b (* gb LR)))))))

(define REPS 3)

;; median of 3 without a general sort: total minus the extremes
(define (median3 xs)
  (let ((a (nth xs 0)) (b (nth xs 1)) (c (nth xs 2)))
    (- (+ a b c) (min a (min b c)) (max a (max b c)))))

;; median of REPS timed runs, so a single thermal blip can't set the record
(define (time-median g X W0 B0 T NN steps)
  (median3
    (build-list REPS
      (lambda (_)
        (let* ((t0 (now-micros))
               (r  (sgd g X W0 B0 T NN steps))
               (t1 (now-micros)))
          (/ (- t1 t0) 1000.0))))))

(define (bench label m k n steps)
  (let* ((X  (tensor (row-major m k 0)))
         (T  (tensor (row-major m n 5)))
         (W0 (tensor (row-major k n 3)))
         (B0 (val 1 0))
         (NN (* 1.0 (* m n)))
         (interp (lambda (x W b t nn) (graph-grad loss-fn x W b t nn)))
         (comp   (graph-compile-grad loss-fn X W0 B0 T NN)))
    ;; warm: .so cache, first-call dispatch, any lazy init
    (sgd interp X W0 B0 T NN 2)
    (sgd comp   X W0 B0 T NN 2)
    (let* ((ms-i (time-median interp X W0 B0 T NN steps))
           (ms-c (time-median comp   X W0 B0 T NN steps))
           (ri   (sgd interp X W0 B0 T NN steps))
           (rc   (sgd comp   X W0 B0 T NN steps)))
      (println (str label "  " m "x" k "->" n "  steps=" steps))
      (println (str "  graph-grad   (interpreted) " ms-i " ms   (median of " REPS ")"))
      (println (str "  graph-compile-grad (JIT)   " ms-c " ms   (median of " REPS ")   JIT/interp "
                    (/ ms-i ms-c) "x"))
      ;; the two paths must agree bit-for-bit, and with torch's final loss
      (println (str "  final-loss interp " (nth (graph-grad loss-fn X (nth 0 ri) (nth 1 ri) T NN) 0)))
      (println (str "  final-loss jit    " (nth (comp X (nth 0 rc) (nth 1 rc) T NN) 0))))))

(bench "SMALL " 8  16  8  1000)
(bench "MEDIUM" 64 256 64 100)
