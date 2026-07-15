# Three Laws, Machine-Checked

Asimov's Three Laws were fiction — natural language, interpreted by the robot
itself, and every story is about how that fails. These three are different on
both counts: they are executable predicates, checked exhaustively over finite
domains, enforced outside the model. The LLM can plan. It cannot overrule a law.

Each law is one small, public codebase built on [Rusty](../README.md) — a
zero-dependency Lisp interpreter in Rust whose verification checkers
(`check-effects`, `check-exhaustive`, `check-types`) are built in, not bolted on.
Every claim below is the narrow, reproducible one; nothing here says "safe AI."

## Law I — Honest Tools · [wuwei](https://github.com/TheLakeMan/wuwei)

**An agent may not call a tool whose declared effects don't match its body.**
At boot, `check-effects` statically certifies every tool in the registry is
effect-honest — the allowlist can't lie — and `safe-call` contract-checks each
call's preconditions before the body runs. Refuse-by-default.

```sh
# rusty on PATH (see ../README.md — Install), then:
git clone https://github.com/TheLakeMan/wuwei && cd wuwei
rusty demo-sandbox.lisp        # offline — no LLM
```

```
  write-file in the registry + read-only budget  (must refuse)
    => (refused effect-budget-exceeded ((write-file (file-write))))
  read /etc/passwd  (must reject — precondition)
    => (rejected "safe-call: read-file: precondition violated")
  write outside the sandbox  (must reject)
    => (rejected "safe-call: write-file: precondition violated")
```

## Law II — Proven Control · [shouzhong](https://github.com/TheLakeMan/shouzhong)

**A controller may not act outside bounds proven safe over every reachable state.**
`check-exhaustive` proves the safety property inductively over the full finite
state domain (120,351 states for the 3-D drone with gusts), and actuators are
gated: a command outside the proven envelope is refused before it actuates.

```sh
# rusty on PATH (see ../README.md — Install), then:
git clone https://github.com/TheLakeMan/shouzhong && cd shouzhong
rusty shouzhong-test.lisp      # offline — no LLM (or ./run_tests.sh for all three plants)
# needs rustc on PATH too: the proof-transfer step compiles the control law (defrust)
```

```
09 full-blast controller refused          => (refused inductive-step ((25) "false"))
10 overdrive refused at actuation bounds  => (refused actuation-bounds ((0) "false"))
15 past hardware limit: 9                 => (rejected "safe-call: heater!: precondition violated")
21 unproven overdrive, gated at runtime  => (halted gate-rejected 9 at-tick 0 trajectory ((30)))
```

## Law III — Truthful Record · [mingjian](https://github.com/TheLakeMan/mingjian)

**What the agent did must replay to the same result.**
For deterministic plants, replay IS the audit: an edited log names its own
divergence, tick by tick. Audits are data — queryable through Rusty's built-in
knowledge graph.

```sh
# rusty on PATH (see ../README.md — Install), then:
git clone https://github.com/TheLakeMan/mingjian && cd mingjian
rusty demo-receipt.lisp        # offline — no LLM
```

```
  mj-breaches (expect empty — honest run)
    => ()
  mj-breaches on forged audit (the only claim that counts)
    => ((4 write-file "/etc/shadow" ok))
  ↑ non-empty list = smoking gun. Screenshots of chat don't count.
```

---

These laws ride on the device, not in the cloud: one small static binary, no
external runtime dependencies, proofs re-checked in milliseconds when compiled.

Rusty also keeps one promise to people rather than robots:
[loop](https://github.com/TheLakeMan/loop), a memory vessel for the living.
