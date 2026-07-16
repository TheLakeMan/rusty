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
;;; JIT marshalling, cut in two passes. Each A/B'd on one machine state with
;;; this file, medians of 3; every step verified bit-identical to graph-grad
;;; across 5 shapes / 37,353 values.
;;;
;;; v0.43.0 — the generated kernel stopped copying: it borrows its input tensors
;;;   (was `.to_vec()` per input, ~295 KB/call at 64x256->64) and borrows on the
;;;   SumTo same-shape identity (was a clone, ~164 KB/call).
;;;     64x256->64 x100   JIT 143.3 ms -> 130.6 ms  (-8.9%)
;;;     8x16->8   x1000   JIT   6.18 ms ->   5.78 ms (-6.5%)
;;;   Narrowed the gap to the interpreter but did NOT flip it (~5% slower still).
;;;
;;; v0.44.0 — per-argument-pointer ABI: the caller stopped copying too (was one
;;;   flat buffer in + one out, ~885 KB/call at 64x256->64).
;;;     64x256->64 x100   JIT 127.5 ms -> 114.6 ms  (-10.1%)
;;;     8x16->8   x1000   JIT ~5.78 ms -> ~5.75 ms  (flat — little to marshal)
;;;   THIS FLIPPED IT: at 64x256->64 the JIT now BEATS graph-grad (~1.14x), where
;;;   it had been ~1.12x slower. Cumulative 143.3 -> 114.6 ms (-20%).
;;;
;;; graph-grad (interpreted) is untouched by both — the medium interpreted row
;;; is noisy (~117-134 ms run to run), so compare JIT numbers, which are stable.
;;;
;;; v0.50.0 — AVX2 without touching a single accumulation: the JIT rustc gets
;;;   -C target-feature=+avx,+avx2 when the running CPU has AVX2 (folded into
;;;   the cache hash; never target-cpu=native, so the flag says exactly what
;;;   the .so contains), and the interpreter's two matmuls share one
;;;   runtime-dispatched kernel (graph_ir::matmul_ikj, #[target_feature] AVX2
;;;   version of the same body). Rust never FMA-contracts or reassociates, so
;;;   wider vectors change speed only — proven by both final-loss values below
;;;   landing bit-identical to v0.44, through 100/1000 SGD steps on both paths.
;;;     64x256->64 x100   JIT ~110.8 ms -> ~98.7 ms  (-10.9%, medians of 3 runs)
;;;     8x16->8   x1000   JIT  ~5.69 ms -> ~5.47 ms  (-3.9%)
;;;   Cumulative JIT medium: 143.3 -> ~98.7 ms (-31%).
;;;   MEASURED CEILING NOTE (Intel N95): Gracemont E-cores double-pump 256-bit
;;;   ops, so AVX2 alone is worth only 1.07-1.24x on the matmul kernel here;
;;;   the rest of PyTorch's remaining lead is FMA, which fuses rounding and is
;;;   BANNED by the bit-for-bit claim. Blocked/tiled matmul at these shapes
;;;   was REFUTED as a ~2x lane on this machine (kernel already at ~67% of
;;;   non-FMA peak). Next bit-preserving lever: threading rows.
;;;
;;; v0.51.0 — row-parallel interpreter matmul: graph_ir::matmul_ikj splits
;;;   output rows across a persistent fixed-assignment pool (worker w owns
;;;   band w+1, dispatcher owns band 0; no work-stealing, so no cross-job
;;;   straggler hazard) above the measured ~64k mul-add crossover;
;;;   RUSTY_MM_THREADS overrides (<=1 = serial). Every band runs the same
;;;   kernel body -> per-element op order untouched; verified bit-identical
;;;   serial-vs-pooled via save-model diff on 6 shapes (incl. 67 rows,
;;;   non-divisible) AND both final losses below unchanged.
;;;     64x256->64 x100  graph-grad (interp) ~106 -> ~88 ms median of 3 runs
;;;       (-17%; best run 76 ms; spread widened 76-96 — 4 shared E-cores)
;;;     8x16->8 x1000    unchanged ~33 ms (below crossover, stays serial)
;;;     JIT rows unchanged (~99 ms medium) — the FUSED KERNEL IS STILL
;;;     SINGLE-THREADED, so the interpreter re-took the medium lead. Pool
;;;     micro-bench: 2.07-2.25x at the three training shapes, ~2.3x plateau
;;;     at 512^3 (4 E-cores, shared L2). Threading the JIT matmul codegen is
;;;     the open follow-up.
;;;   PyTorch note: tensor_torch_bench.py pins 1 thread BY DESIGN (kernel
;;;   quality comparison). Report threaded-Rusty numbers as their own row,
;;;   never against the 1-thread torch row.
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
