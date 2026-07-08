---
name: run
description: Launch and drive the Rusty Lisp interpreter (this repo) — REPL, a .lisp script, or the agent demo — to see a change working.
---

# Running Rusty

Build first, then run against a script or drop into the REPL:

```bash
cargo build --release
./target/release/rusty                      # REPL
./target/release/rusty path/to/script.lisp  # run a .lisp file, prints the last value
./target/release/rusty agent.lisp           # tool/agent demo (needs a local LLM — see below)
```

`cargo run --release -- <file>` works too but re-checks/compiles every time; prefer the built binary for repeated runs.

For a quick one-off expression, write it to a scratch `.lisp` file and run that — there's no `-e`/eval-string flag.

## Agent/LLM-dependent code

`(llm ...)`, `(react-loop ...)`, and `agent.lisp` need an OpenAI-chat-compatible server reachable at `RUSTY_LLM_URL` (default `http://localhost:8080/v1/chat/completions`), e.g. `llama-server -m <model.gguf> --port 8080`. Without one, those calls fail with a connection error — that's expected in a sandbox with no local model server, not a bug in the interpreter.

## Confirming a change works

For most changes (evaluator, builtins, macros, stdlib) "driving the app" means running a `.lisp` snippet that exercises the changed behavior and reading stdout — there's no browser/UI to click through. See the `verify` skill for the fuller before/after workflow used to confirm bug fixes.
