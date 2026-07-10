# Copyright (c) 2026 Nicholas Vermeulen
# SPDX-License-Identifier: AGPL-3.0-or-later
# symreg_gplearn_bench.py — gplearn side of the 4.1 deliverable benchmark.
# Same 3 problems, same budget (pop 120 x max 60 generations), same
# function set (+ - * protected-div), 10 seeds, single thread.
# Success = training MSE < 1e-10. Mirrors symreg_bench.lisp.
# gplearn is a benchmark yardstick only — never a Rusty dependency.

import time
import numpy as np
from gplearn.genetic import SymbolicRegressor

def frange(a, b, step):
    xs, x = [], a
    while x <= b:
        xs.append(x); x += step
    return xs

problems = {
    "quadratic": (np.array([[x] for x in frange(-2, 2, 0.25)]),
                  lambda X: X[:, 0]**2 + 2*X[:, 0] + 1),
    "koza-1":    (np.array([[x] for x in frange(-1, 1, 0.1)]),
                  lambda X: X[:, 0]**4 + X[:, 0]**3 + X[:, 0]**2 + X[:, 0]),
    "bivar":     (np.array([(-2,1),(-1,3),(0,2),(1,-1),(2,4),(3,-2),(-3,-1),(2,-3)], dtype=float),
                  lambda X: X[:, 0]*X[:, 1] + X[:, 0]),
}

for name, (X, f) in problems.items():
    y = f(X)
    wins, total_ms = 0, 0.0
    for seed in range(1, 11):
        est = SymbolicRegressor(
            population_size=120, generations=60,
            function_set=("add", "sub", "mul", "div"),
            metric="mse", stopping_criteria=1e-10,
            const_range=(-5.0, 5.0),
            n_jobs=1, random_state=seed, verbose=0,
        )
        t0 = time.perf_counter()
        est.fit(X, y)
        ms = (time.perf_counter() - t0) * 1000
        mse = float(np.mean((est.predict(X) - y) ** 2))
        gen = est.run_details_["generation"][-1]
        print((name, "seed", seed, "mse", mse, "gen", gen, "ms", round(ms, 1)))
        if mse < 1e-10:
            wins += 1
        total_ms += ms
    print((name, "success", wins, "/", 10, "total-ms", round(total_ms, 1)))
print("GPLEARN BENCH DONE")
