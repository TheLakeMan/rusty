# LLM / agent stress harnesses

Manual reproduction harnesses for Rusty's LLM-driven paths — the `llm` special
form, the verify-gated proposer loop (`synthesize-verified` + `llm-proposer`),
and the `agent` / `react-loop` ReAct loop.

**These are NOT golden or CI tests.** They need a live, OpenAI-compatible
endpoint (a local `llama-server` on `:8080` by default), and the model's replies
are nondeterministic — so there's nothing to diff. They exist to *reproduce* the
robustness checks by hand and to catch interop regressions against a real server
(the `max_tokens: null` bug in v0.62.0 was found this way).

## Running

Start a server (e.g. `llama-server -m <model>.gguf --port 8080`), then:

```bash
cargo build --release
./target/release/rusty benchmarks/llm/llm_volume.lisp     # volume + latency, no leak/hang
./target/release/rusty benchmarks/llm/llm_proposer.lisp   # verify-gated synthesis converges
./target/release/rusty benchmarks/llm/agent_react.lisp    # ReAct loop: reasoning + tool use
```

Override the target with the same env vars the `llm` builtin reads:
`RUSTY_LLM_URL`, `RUSTY_MODEL`, `RUSTY_SYSTEM`, `RUSTY_LLM_TIMEOUT_SECS`.

## What each checks

| File | Checks |
|------|--------|
| `llm_volume.lisp` | many sequential `llm` calls on the shared runtime — success rate, latency stability, no leak/hang |
| `llm_proposer.lisp` | the **verify-gate holds under a real model**: wrong proposals are rejected (static gate / counterexample) and fed back, correct ones verified — never rubber-stamped, never a crash |
| `agent_react.lisp` | the ReAct loop drives tools client-side, feeds observations back, and **terminates** within `max_steps` |

## Safety note (read before running `agent_react.lisp`)

`(agent goal)` runs **ungated** tools — Rusty parses the model's `ACTION:`/`INPUT:`
text and executes the named tool itself, including `write-file` / `delete-file` /
`shell-run`. This is client-side and independent of whether the *server* has any
tool/function-calling feature. The harness uses read-only goals, but a different
goal (or a model that improvises) could take real action. Gated execution is what
[wuwei](https://github.com/TheLakeMan/wuwei) exists to provide; the raw `agent`
here trusts the model's text.
