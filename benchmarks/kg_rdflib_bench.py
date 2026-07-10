# Copyright (c) 2026 Nicholas Vermeulen
# SPDX-License-Identifier: AGPL-3.0-or-later
# kg_rdflib_bench.py — rdflib side of the knowledge-graph benchmark.
# Generates /tmp/rusty-kg-bench.nt (both sides load the identical file),
# then times: load, grandparent join (SPARQL), type+age join.
# rdflib is a benchmark yardstick only — never a Rusty dependency.
import time

N = 20000  # people; ~3 triples each

def gen():
    lines = []
    for i in range(N):
        s = f"<urn:rusty:person{i}>"
        lines.append(f"{s} <urn:rusty:type> <urn:rusty:person> .")
        lines.append(f'{s} <urn:rusty:age> "{float(20 + i % 60)}"'
                     f"^^<http://www.w3.org/2001/XMLSchema#double> .")
        if i + 1 < N:
            lines.append(f"{s} <urn:rusty:parent> <urn:rusty:person{i+1}> .")
    with open("/tmp/rusty-kg-bench.nt", "w") as f:
        f.write("\n".join(lines) + "\n")

gen()
print(("generated", 3 * N - 1, "triples"))

import rdflib
g = rdflib.Graph()
t0 = time.perf_counter()
g.parse("/tmp/rusty-kg-bench.nt", format="nt")
print(("loaded", len(g), "ms", round((time.perf_counter() - t0) * 1000, 1)))

t0 = time.perf_counter()
q = g.query("""SELECT ?g ?c WHERE {
  ?g <urn:rusty:parent> ?p . ?p <urn:rusty:parent> ?c . }""")
n = len(list(q))
print(("grandparent-solutions", n, "ms", round((time.perf_counter() - t0) * 1000, 1)))

t0 = time.perf_counter()
q = g.query("""SELECT ?x ?n WHERE {
  ?x <urn:rusty:type> <urn:rusty:person> . ?x <urn:rusty:age> ?n . }""")
n = len(list(q))
print(("type-age-join", n, "ms", round((time.perf_counter() - t0) * 1000, 1)))

print("RDFLIB BENCH DONE")
