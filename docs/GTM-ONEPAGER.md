# Rusty — GTM One-Pager

**Product:** [Rusty](https://github.com/TheLakeMan/rusty) — a Lisp runtime in Rust that is the **verifiable execution layer** under AI agents.  
**Tagline:** *LLM plans. Rusty executes—only what is proven safe, honest, and replayable.*  
**Version context:** v0.54+ · AGPL-3.0-or-later (commercial license on inquiry)

---

## The problem (market, not theory)

Agentic AI already runs with real privileges: shell, files, credentials, APIs. Failure modes users keep reporting:

| Failure | What people experience |
|--------|-------------------------|
| **Over-action** | Agents delete or wipe beyond intent; “sorry” doesn’t restore the disk |
| **Prompt ≠ safety** | “Confirm before acting” in system text is not a hard constraint |
| **Fake done** | Models claim work finished when files/tests never changed |
| **Injection & skills** | Malicious or sloppy tools inherit full agent permissions |
| **Credential blast radius** | Broad tokens + agent autonomy → production gone in seconds |
| **Creative planners on plants** | LLM re-aims; physics and geofences still must not break |

Competitors sell **more autonomy**, **better models**, or **OS sandboxes**. Sandboxes contain *where* damage can go. Almost nothing makes *which tool contracts may fire* and *whether the log is true* machine-checked.

---

## Positioning

| | |
|--|--|
| **Category** | Verifiable agent execution substrate (not “another agent framework”) |
| **For** | Teams shipping LLM agents that touch files, shell, APIs, or control loops |
| **Against** | Hope-based safety (prompts, vibes, self-reported success) |
| **Unlike** | LangChain-style orchestration, pure Docker sandbox, raw coding agents |
| **Rusty** | Contracts, effect honesty, exhaustive safety domains, deterministic replay—under any planner |

**One sentence:**  
> Rusty is the symbolic executor that sits under Claude Code, Hermes, Codex, or your custom loop: tools cannot lie about effects, unsafe chains refuse to start, and “what happened” must replay to the same result.

**Three Laws (product narrative):**

1. **Honest tools** — Declared effects must match the body (`check-effects`, `deftool-spec`, `safe-call`, `certify-tool-chain`).  
2. **Proven control** — Controllers may not act outside bounds proven over every reachable state (`check-exhaustive`, shouzhong).  
3. **Truthful record** — Logs don’t ask for trust; replay them (mingjian).

**Flagship demos (zero new interpreter code):** [wuwei](https://github.com/TheLakeMan/wuwei) · [shouzhong](https://github.com/TheLakeMan/shouzhong) · [mingjian](https://github.com/TheLakeMan/mingjian) · [loop](https://github.com/TheLakeMan/loop)

---

## Ideal customer profile (ICP)

### Primary (wedge — ship first)

| Attribute | Detail |
|-----------|--------|
| **Who** | Solo builders and 2–15 person teams shipping **coding / ops / internal agents** on their machines or CI |
| **Role** | Founding engineer, AI eng, platform eng, security-minded indie |
| **Trigger** | First real scare (bad `rm`, prod-adjacent token, fake “done”) or policy pressure (“we need audit”) |
| **Stack** | Already use Claude Code / Cursor / Codex / Open Interpreter / custom ReAct; local or OpenAI-compatible LLMs OK |
| **Job-to-be-done** | Keep agent productivity **without** full home-dir shell trust |

### Secondary (expand)

| Segment | Why Rusty fits |
|---------|----------------|
| **Robotics / sim / industrial R&D** | LLM planner + hard envelope (Law II) |
| **Regulated / audit-heavy internal tools** | Replay + traces as compliance evidence (Law III) |
| **Multi-agent research** | Deterministic actors, certifier swarms, golden tests |
| **Local-first / privacy products** | Zero runtime deps, embeddable binary, on-device LLM |

### Anti-persona (do not sell)

- Teams that only need chat Q&A (no tools).  
- Buyers who want a full **OS microVM product** as the sole story (Rusty pairs with sandbox; is not the sandbox).  
- Orgs that require **permissive embed in closed SaaS** without commercial license (AGPL friction).  
- “Replace Cursor for everyone” mass-consumer GTM.  
- Teams unwilling to **narrow the tool surface** (if they insist on unrestricted `shell-run`, the product thesis fails).

---

## Value proposition (buyer language)

**Before:** Agent can do anything the OS allows; safety = prompt + human hope + post-incident restore.  
**After:** Only certified tools run; effects are checked statically; control laws are exhaustive where domains are finite; audits replay.

**Outcomes:**

1. **Fewer catastrophic tool calls** — preconditions + honesty gates before body.  
2. **Auditable autonomy** — traces, checkpoints, named-tick divergence on forgery.  
3. **Planner-agnostic** — keep Claude/Codex/Hermes; swap the execution spine.  
4. **Small ops footprint** — single binary, stdlib embedded, optional `rustc` only for JIT.  
5. **Proof demos that double as marketing** — wuwei / shouzhong / mingjian are runnable thesis.

---

## Product wedge (land) → platform (expand)

```
Land:  "Safe tool backend for my coding agent"
       → path-scoped file tools + safe-call + certify-tool-chain
       → 1–2 week integration under existing planner

Expand: Replay CI for agent sessions (mingjian)
        Exhaustive control for one plant (shouzhong)
        Internal multi-agent synth with static gates
        Commercial embed / support license
```

**Do not lead with:** “Lisp interpreter,” “PyTorch-competitive tensors,” or full 5-year roadmap.  
**Lead with:** “Your agent’s next destructive mistake is a contract failure, not a disk failure.”

---

## Messaging kit

| Asset | Copy |
|-------|------|
| **Headline** | Capability is not permission. Make that machine-checked. |
| **Subhead** | Rusty is the execution layer under AI agents—honest tools, proven bounds, truthful logs. |
| **Proof line** | Same runtime powers wuwei (gated agents), shouzhong (exhaustive control), mingjian (replay audit). |
| **Objection: “We use Docker”** | Great—contain *where*. Rusty constrains *what may run* and *whether the record is true*. |
| **Objection: “Claude already asks permission”** | Approval UX is not effect honesty or replay. Both layers help; only one is hard. |
| **Objection: “Another Lisp?”** | Lisp is the *representation* for code-as-data, macros, and checkers. Buyers buy the **Laws**, not nostalgia. |
| **CTA** | `cargo install rusty-lisp` · run Law I/II/III quickstarts · star/fork demos · commercial license inquiry |

---

## Channels & motion

| Motion | How |
|--------|-----|
| **Founder-led (default)** | X/threads: map weekly agent-failure news → one Law → 30s demo clip |
| **Developer land** | Install script, golden tests, `docs/LAWS.md`, three demo repos as “product” |
| **Embed** | Python bridge + C ABI `defrust` for teams who won’t rewrite in Lisp |
| **Partner** | Agent-firewall / sandbox vendors: complementary stack (they isolate; you certify) |
| **Avoid early** | Broad paid ads; enterprise RFPs before 3 public design partners |

**Content pillars (repeatable):**  
(1) Incident → which Law would have stopped it  
(2) 60s terminal demos (certify fails / replay diverges)  
(3) “Under Claude Code” integration posts  
(4) Benchmarks only as secondary (tensors/JIT are credibility, not the wedge)

---

## Packaging & monetization (simple)

| Tier | Offer | Price posture |
|------|--------|----------------|
| **Open core** | Interpreter + Laws APIs + demo apps (AGPL) | Free; community mindshare |
| **Commercial license** | Closed embed, SaaS with modified Rusty, dual-license | Quote (AGPL alternative) |
| **Support / design partner** | Integration under their agent + audit design | Fixed engagement |
| **Later** | Hosted “verify this agent log” or managed gate (only if AGPL network story is deliberate) | TBD |

Early revenue = **commercial license + design partners**, not seats of a chat UI.

---

## Success metrics (first 90 days)

| Metric | Why |
|--------|-----|
| Design partners running **safe-call chains in CI** (target: 3) | Real embed, not stars |
| Reproducible public demos (Laws I–III cold-start) | Trust |
| Inbound from “agent deleted my …” discourse | Message-market fit |
| Commercial license conversations (even 1–2) | Packaging signal |
| Stars secondary; **clone + run golden tests** primary | Quality of interest |

---

## 30-day GTM checklist

1. Publish this one-pager + LAWS quickstarts as the homepage narrative (problem → Law → demo).  
2. One “Claude Code / Hermes → Rusty tools only” reference integration.  
3. Three X threads: delete/wipe · fake done · prompt ≠ safety → each ends with a command.  
4. Short video: `certify-tool-chain` fail, then pass; mingjian diverge on doctored log.  
5. Outbound to 10 teams who publicly shipped agent sandboxes or agent security tools (complement, not compete).  
6. Explicit commercial-license contact path on README (already partial—make one-click).

---

## Competitive snapshot

| Approach | Helps with | Misses |
|----------|------------|--------|
| Bigger / safer models | Fewer dumb errors | Not hard policy; still over-executes |
| Coding agent UX approvals | Human in loop | Fatigue; not effect proofs; not replay |
| Docker / microVM / agent OS | Isolation | Not tool honesty; not control proofs |
| Agent firewalls (redirect rm, honeypots) | Containment theater / rollback | Policy still outside language of tools |
| **Rusty** | Certified tools, exhaustive domains, replay | Needs narrow tools + optional OS sandbox |

**Win condition:** Become the default **policy and proof layer** that serious agent stacks call before actuation—invisible to end users, non-negotiable to platform teams.

---

## Elevator (15 seconds)

> People are giving agents shell and file access. Prompts don’t stop catastrophes; sandboxes only limit the blast radius. Rusty is a small Lisp runtime in Rust where tools must be honest about effects, unsafe chains won’t start, and every session can be replayed. Keep your planner—swap in an executor that doesn’t trust the model’s story.

---

*Internal/public GTM draft for Rusty. Update ICP and metrics as design partners land.*
