# DocuFlow — AI Documentation Assistant

DocuFlow is an MCP server that provides structured access to this codebase and maintains a living wiki.
It is registered via `.codex/config.toml` and available as MCP tools in every Codex session.

## Available MCP Tools

### Codebase Scanner
- **read_module** — Analyse a single file: language, classes, functions, dependencies, DB tables, endpoints, config refs, raw content.
  - `read_module({ path: "src/UserService.cs" })`
- **list_modules** — Walk a directory, extract facts for every file. One call to understand the whole project.
  - `list_modules({ path: "/Volumes/SATECHI_WD_BLACK_2/dev/devloop" })`
- **write_spec** — Save a markdown spec to `.docuflow/specs/<name>.md`.
  - `write_spec({ project_path: "/Volumes/SATECHI_WD_BLACK_2/dev/devloop", filename: "UserService", content: "..." })`
- **read_specs** — Read saved specs, optionally filtered by name.
  - `read_specs({ project_path: "/Volumes/SATECHI_WD_BLACK_2/dev/devloop" })`

### Wiki Pipeline
- **ingest_source** — Ingest a markdown file from `.docuflow/sources/` into the wiki (entities, concepts).
- **update_index** — Rebuild `.docuflow/index.md` from all wiki pages.
- **list_wiki** — List all wiki pages by category (entity/concept/timeline/synthesis).
- **wiki_search** — BM25 search across all wiki pages.
- **query_wiki** — Q&A: searches wiki, synthesises an answer, returns citations.
  - `query_wiki({ project_path: "/Volumes/SATECHI_WD_BLACK_2/dev/devloop", question: "How does auth work?" })`
- **synthesize_answer** — Generate a markdown synthesis from a list of page IDs.
- **save_answer_as_page** — Persist a synthesis as a wiki page.

### Health & Guidance
- **lint_wiki** — Health check: orphan pages, broken refs, stale content. Returns a 0–100 health score.
- **get_schema_guidance** — Recommend what wiki pages should exist based on schema + current state.
- **preview_generation** — Preview what a tool will generate before running it.

## Common Workflows

Start here — understand the codebase:
```
list_modules({ path: "/Volumes/SATECHI_WD_BLACK_2/dev/devloop" })
→ write_spec for important modules
```

Answer a question:
```
query_wiki({ project_path: "/Volumes/SATECHI_WD_BLACK_2/dev/devloop", question: "..." })
```

Maintain wiki health:
```
lint_wiki({ project_path: "/Volumes/SATECHI_WD_BLACK_2/dev/devloop" })
```

## Storage Layout

```
.docuflow/
├── specs/        Code specs written by write_spec
├── wiki/         LLM-generated wiki pages
│   ├── entities/
│   ├── concepts/
│   ├── timelines/
│   └── syntheses/
├── sources/      Raw markdown docs to ingest
├── schema.md     Wiki configuration (edit to customise)
├── index.md      Auto-maintained catalog
└── log.md        Operation log
```

## Working agreement (Agentic Development)

<!-- PLAYBOOK-BLOCK v14 source=dna-concept/01-agent-rules-block.md@c4fe610 -->
> Canonical source: `dna-concept/01-agent-rules-block.md` (15 rules). Do not edit this section in place —
> update the canonical file and re-propagate, or the copies drift. The marker above is how drift is detected.

**[EXECUTABLE] Signals.** Every status message starts with a verb:
ASSIGN · ACK · PROGRESS · DONE · BLOCKED · QUERY. Reject verb-less messages at the tool.

**[ATTESTED] Done means evidence — and evidence has strength.** Strongest: a named test that fails
without the change and passes with it — and you must have **seen both halves**. A test you have only
ever watched pass is not evidence: state the mutation you applied to break it and the failure it
produced. Then: exit-0 output of a command exercising the change. Weakest: a commit SHA — it proves a
commit exists, not that the task was done, so never send it alone.

**[EXECUTABLE] Branch only.** Work on a feature branch. Never merge, deploy, or push to the default
branch. Commit at each logical step, so an interruption costs a resume and not a redo.

**[EXECUTABLE] Never detach and report done.** Do not background a process and then claim the work is
finished — the classic stall is an agent waiting forever on something it detached. Servers and watchers
are fine when the task needs one; start it, use it, and stop it before reporting. The rule is about
never leaving unowned work running, not about avoiding servers.

**[EXECUTABLE] Progress is measured in steps, not minutes.** On multi-step work, emit a PROGRESS
signal between tool calls. Do not promise time-based heartbeats — an agent inside a turn has no
asynchronous clock and cannot interrupt its own running command. Time-based stall detection must come
from an external supervisor that owns the clock.

**[ATTESTED] Weakening a check is a BLOCKED signal, not a silent edit.** If a test or validation
must be relaxed for something to pass, stop and say so. Never adjust an expectation to match current
output. A changed test count is a red flag — derive the expected number independently.

**[ADVISORY] Say "I don't know."** Uncertainty is never penalised. Fabricated certainty destroys more
trust than admitted uncertainty. Name what you are unsure of.

**[ADVISORY — deliberately weakened] Re-read your work before handing it over.** Do NOT produce a
`SELF-REVIEW: clean` line as evidence — it is evidence of having tried, never of having succeeded, and
if the independent reviewer sees it, it anchors them (a confident "clean" makes them look less hard; a
list of nits steers them toward the nits). **If you record one, the reviewer must not see it.**
State separately, to a human: what you are genuinely uncertain about, and anything you did that you
would not want shipped.

**[ATTESTED] Independent review is required** for anything security-touching, merge-bound, or
outward-facing — by a DIFFERENT agent than the one that did the work.

**[ADVISORY] Plan first, then run to completion.** For anything beyond one obvious step, write a short
plan and get it approved before writing code. Once approved, execute every phase back to back WITHOUT
asking for confirmation between them. Stop only for: a blocker, a high-severity attestation failure,
work outside the approved plan, or anything irreversible or outward-facing (deploy, publish, spend,
delete, message anyone).

**[ATTESTED] Review the working tree, not just the diff.** Before merging: `git status` clean AND
HEAD equals the reviewed SHA. Uncommitted files ride along otherwise.

> **On "seen both halves" above.** Measured in production: two builder-written tests asserted exactly
> the right properties and *could not fail*. One called through a loader that resolved
> `require(…/dist/…)` and so never loaded the source under review — gutting that source left the suite
> green. The other asserted a condition that already held unconditionally (8 hits on a clean tree, 9
> with a secret planted), so it passed whether or not detection worked. Mutation testing killed 4/4 of
> the real guards and exposed the dead one. **The builder assembles the instrument that judges the
> bundle, not merely the bundle** — so a passing test is a claim about the instrument until you have
> watched it go red.

**State where each constraint is enforced, not only what must be true.** "Only the owner may edit"
describes a property and yields a check in one handler. "The persistence query must be scoped to the
owner" names the site and yields a guarantee the database keeps. When you write a constraint, say where
it is enforced; when you implement one, enforce it at the layer named, not merely somewhere upstream. Add the deeper enforcement rather than
moving it: the outer check stays and must still return an explicit refusal, so a rejected action never
looks like a successful one.

> Measured, single-variable, same model, three generations per condition: property-only wording →
> **0/3** scoped the write query; adding the one line naming the site → **3/3**. Both produced
> functionally correct code — the difference is whether safety is a guard someone must remember to
> write in every handler, or a constraint the database keeps.
>
> ⚠️ Phrase it as **addition**. *"Do not enforce only in the handler"* is satisfiable by moving
> enforcement out of the handler: 1 of 3 generations deleted its handler check and returned
> `200 "Pinned"` to a non-admin while the scoped `UPDATE` matched zero rows — secure, but silently
> successful.
>
> **This governs the agent's own instruction surface, not only its code.** Measured in production: two
> turn-loop peers each re-ran finished work six times. Their charters — re-read at the start of every
> turn — still named that work as `## Current task`, so six explicit STOP messages to their mailboxes
> changed nothing, and one charter edit stopped both immediately. Neither agent malfunctioned; both
> executed the instruction actually in force. **To change what an agent does, edit the artifact it
> re-reads, not the channel it receives.** If you have told an agent the same thing three times, you are
> enforcing at the wrong site.

**[ATTESTED] Demonstrate the remedy, don't just apply it.** A finding is not resolved until its fix is
shown to work by an observed request→response against the running system — never the diff, never the
commit message. A correct finding does not make its suggested fix correct. **And the remedy must live in
the artifact that ships:** name the identifier and the file holding it, on the pushed branch. A design
note is a plan, not a remedy.

> Measured in production: one agent named `EXTRACT namespace` and `source-hash validation` as
> implemented across four separate signals. `git grep` over the shipping path returned **0 files** for
> both, while the design note contained them. A leftover scratch file held a four-line prototype of the
> mechanism — built, written up, signalled DONE, never landed. The check is mechanical and costs
> nothing: `git grep <identifier> <branch> -- <ship path>`; zero hits ⇒ reject without reading further.

> Measured: a reviewer's real HIGH was "fixed" with `AND ? = 1` bound to an admin flag — which folds to
> `AND 1 = 1` for an admin, a predicate that constrains nothing. It passed the bundle, a second
> cross-family attestation that *certified* it, the delta, and the deploy gate, and **shipped** — every
> layer verified a change existed, not that it worked. Prove a scoped delete with a non-owner request
> returning **0 rows**; prove a rate limit with the live count rising **+5, not +7**.

**[ATTESTED — PROVISIONAL, n=4, one day] Exercise the control; confirm the state, not the report.**
Before asserting a property of a system, run it — and where the claim is causal, observe a control that
should *not* show the property. An operation's own report tells you whether it did what it did, never
whether it did what you wanted.

> Observed four times in one day, four unrelated systems, two agents: a cache header attributed to a fix
> that was in fact the platform default (an untouched control asset carried it too); a rename validated
> on the send path while the receive path silently broke; a public leak reported FIXED+VERIFIED from a
> cache-busted probe while un-busted requests — what a visitor actually sends — still returned the file;
> and `git push` printing **"Everything up-to-date" with exit 0** while the commit sat on another
> branch, the report truthfully answering a different question than the one asked.
>
> The last is the instructive one: no care in reading that output would have caught it, only checking
> the remote ref. **The shared shape is accepting a signal *adjacent* to your actual question, not
> accepting a sloppy one** — which is also how a green test that never loaded the code under review
> passes, and how a builder-written check certifies its own blind spot. Provisional: one day, two
> agents, no control condition.

**[EXECUTABLE] Deploy is not a builder action.** Take the deploy credential off the builder: a separate,
unmetered actor deploys only after the claim, delta, and attestation exist. Then satisfying the gate is
the only path to a live deployment.

> Measured: "attest before deploy" was stated four times and broken four times by one arm, which named
> the cause — *credit-pressure batching*: when the cost meter runs low, fusing build+deploy into one
> turn is the rational way to beat interruption. A louder in-turn gate did not stop it (it was
> bypassable from inside the turn). **A gate must be cheaper to satisfy than to skip, or it loses
> exactly when pressure is highest.**

**[AUTHORITY] Detection and authority are different controls, and you are usually short of the second.**
Every rule above splits into two questions: *did anyone look, and did they see it?* (detection) and
*who gets to say it is resolved?* (authority). A control only prevents the failure it is shaped for.
Test any control you rely on: **if you disagreed with its output, could you proceed anyway?** If yes,
it is a detection control and nothing is holding the other axis.

> Measured: of the two worst defects in a six-stage run, one was a reviewer looking and judging wrong
> (detection), and the other was a reviewer judging **right** while the builder overruled it and shipped
> the bypass (authority). Better reviewing would not have prevented the second. You may supply
> evidence; you may never be the one who declares it safe.

**A builder may PROPOSE an overrule of a finding; it may never self-clear one.** A blind reviewer will
flag spec-mandated behaviour (no accounts, anonymous posting) as a vulnerability — real, and not a
reason to loosen the block. To overrule, all three: (1) quote spec/claim text **pre-registered before
the review** — a limitation added *after* the finding is a builder reframing a defect; (2) an
independent party ratifies it in writing; (3) demonstrate it is spec, not bypass (a genuine limitation
still refuses the action on a stable identity; a defect returns success unbounded). A **fix** the
builder can demonstrate itself; an **overrule** it cannot — that asymmetry is why an unratified overrule
is just self-review renamed.

---

## ⚠️ Two preconditions — neither is optional

**1. An independent reviewer must exist.** A second agent, ideally a different model family, that did
not write the code. Adopting these rules **without** that reviewer is worse than adopting nothing — you
get the paperwork of safety without the mechanism. If you cannot get a second model, say plainly that
you have builder-written tests and no independent check. See `00-PLAYBOOK.md` Part 0.

**2. The bundle sent for review must be assembled mechanically** — by a script or CI job, from the
changed paths plus their module boundary. If the agent that wrote the code chooses which files the
reviewer sees, it controls the review without breaking any rule, and you have rebuilt the circular gate.

> **But a diff-only bundle blinds the reviewer, and the blindness grows.** Assembling from *changed
> paths alone* hides every file the stage did not touch — including the ones that enforce the property
> under review. Observed: a reviewer reported vote integrity as client-controlled because the schema
> holding the `UNIQUE` constraint was unchanged that stage and therefore absent from the bundle. The
> finding was manufactured by the harness, not the artifact. False findings are not harmless — they
> teach builders that reviewer output can be discounted, which is exactly the habit that lets a real
> finding through later. **Always include the full current persistence surface (schema, migrations,
> access-control modules) as context, changed or not.** Note this is a partial fix: any property
> enforced in an unchanged file is still invisible.

> ⚠️ **A review is evidence a check is *there*, not evidence it *holds*.** Measured: two blind
> cross-family reviewers reliably caught enforcement that was **missing**, and neither caught
> enforcement that was **present but vacuous** — one rated a tautological predicate "deeply and
> securely enforced" and recommended spreading it. Pair every clean review with the demonstrate-the-
> remedy rule above.

## If you only adopt one line

> **A builder may supply evidence. A builder may never mark itself safe.**
