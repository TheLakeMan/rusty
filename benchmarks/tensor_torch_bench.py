#!/usr/bin/env python3
"""tensor_torch_bench.py — the PyTorch side of the Phase 3.1/3.3 comparison.

Companion to tensor_bench.lisp: same shapes, step counts, LR and inits, so the
two can be quoted as one measurement. PyTorch is NOT a dependency of Rusty — it
is the external yardstick Rusty is compared against after the fact (see
ROADMAP's "Design Constraint").

1-thread float64, to match the roadmap's stated conditions.

Both sides must land on the SAME final loss — that agreement is what proves the
two training loops are the same workload, not two different computations that
happen to take different times.

    pip install torch      # yardstick only
    python3 benchmarks/tensor_torch_bench.py
"""
import time

import torch

torch.set_num_threads(1)

LR = 0.01


def val(i, off):
    return ((i * 7 + off) % 17 - 8) / 8.0


def row_major(m, k, off):
    return [[val(i * k + j, off) for j in range(k)] for i in range(m)]


def bench(label, m, k, n, steps, reps=3):
    X = torch.tensor(row_major(m, k, 0), dtype=torch.float64)
    T = torch.tensor(row_major(m, n, 5), dtype=torch.float64)
    W0 = torch.tensor(row_major(k, n, 3), dtype=torch.float64)
    B0 = val(1, 0)

    def run():
        W = W0.clone().requires_grad_(True)
        b = torch.tensor(B0, dtype=torch.float64, requires_grad=True)
        for _ in range(steps):
            loss = ((torch.relu(X @ W + b) - T) ** 2).mean()
            loss.backward()
            with torch.no_grad():
                W -= LR * W.grad
                b -= LR * b.grad
                W.grad = None
                b.grad = None
        return W, b

    run()  # warm

    times = []
    for _ in range(reps):
        t0 = time.perf_counter()
        W, b = run()
        times.append((time.perf_counter() - t0) * 1000)
    times.sort()

    with torch.no_grad():
        final = ((torch.relu(X @ W + b) - T) ** 2).mean()

    print(f"{label}  {m}x{k}->{n}  steps={steps}")
    print(f"  torch (1 thread, float64)  {times[len(times) // 2]:.3f} ms  (median of {reps})")
    print(f"  final-loss {final.item():.17g}")


bench("SMALL ", 8, 16, 8, 1000)
bench("MEDIUM", 64, 256, 64, 100)
print(f"torch {torch.__version__}")
