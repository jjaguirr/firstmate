# Open-decision agreement: captain-facing before/after transcript

One firstmate home, one durable status log, four real captain surfaces driven end to end:

| surface | executable |
| --- | --- |
| A - fleet-wide OPEN DECISIONS fold | `bin/fm-wake-drain.sh` |
| B - the answer path | `bin/fm-send.sh <task> --resolve-key <key> "<answer>"` |
| C - triage the captain reads | `bin/fm-fleet-snapshot.sh --json` |
| D - away catch-up gate | `bin/fm-afk-return.sh begin` |

Harness: `decision-agreement-harness.sh` (real executables, stubbed tmux/no-mistakes transports only).
Full transcripts: `before.txt` (base `7a31984`) and `after.txt` (target `29905ae`).

## 1. Busy pane: triage said nothing was waiting while the other two held the key open

Durable log for `pane-task`, unchanged in both runs:

```
needs-decision [key=rollout]: choose the deployment path
```

The task's harness is reporting activity, so its current state is `working - source: pane`.

BEFORE (base):

```
--- captain surface C - bin/fm-fleet-snapshot.sh --json (triage hints)
  "current_state": { "state": "working", "source": "pane", ... },
  "pending_decision": false,
  "open_decisions": []

--- captain surface A - OPEN DECISIONS for the same task
  pane-task [key=rollout] needs-decision: choose the deployment path

--- captain surface B - --resolve-key rollout on the same task
  exit=0
  delivered to worker: go with the blue path
  closing line appended: resolved [key=rollout]: answered: go with the blue path
```

The captain reading the fleet snapshot saw nothing waiting for a key the drain listed and `--resolve-key` accepted.

AFTER (target):

```
--- captain surface C - bin/fm-fleet-snapshot.sh --json (triage hints)
  "current_state": { "state": "working", "source": "pane", ... },
  "pending_decision": true,
  "open_decisions": [ { "key": "rollout", "verb": "needs-decision", "summary": "choose the deployment path" } ]

--- captain surface A - OPEN DECISIONS for the same task
  pane-task [key=rollout] needs-decision: choose the deployment path

--- captain surface B - --resolve-key rollout on the same task
  exit=0
  delivered to worker: go with the blue path
  closing line appended: resolved [key=rollout]: answered: go with the blue path
```

All three surfaces now answer the same question the same way.

## 2. Active run supersession: presented, answerable, and refused consistently

Durable log for `resumed`, identical across every check (no `resolved` line anywhere):

```
needs-decision [key=rollout]: choose the deployment path
needs-decision [key=schema]: pick the schema
working [key=rollout]: resumed validation after the rollout answer
working: keyless routine note
blocked [key=creds]: need the staging secret
```

AFTER, while `fm-crew-state` reports `state: working - source: run-step`:

```
--- captain surface A - bin/fm-wake-drain.sh OPEN DECISIONS
  resumed [key=schema] needs-decision: pick the schema
  resumed [key=creds] blocked: need the staging secret        <- rollout is NOT listed

--- captain surface B - --resolve-key rollout
  exit=1
  error: --resolve-key 'rollout': that decision is still recorded as open in .../resumed.status,
  but it is not answerable now: the crew later reported progress under that same key and its task
  is working on an active run (state: working - source: run-step - ci running), so the run
  superseded it. Wait for that run to park or finish and resend if the decision is still needed;
  nothing was sent.
  delivered to worker: (nothing)
  closing line appended: (none)

--- captain surface B - --resolve-key creds (blocker raised mid-run)
  exit=0
  delivered to worker: use the vault secret
  closing line appended: resolved [key=creds]: answered: use the vault secret
```

Same bytes, run parked:

```
--- captain surface A - OPEN DECISIONS
  resumed [key=rollout] needs-decision: choose the deployment path   <- back, no synthetic event needed

--- captain surface B - --resolve-key rollout is answerable again
  exit=0
  closing line appended: resolved [key=rollout]: answered: phase it

--- captain surface B - answering the same key twice
  exit=1
  error: ... no open decision or blocker with that key ... (already closed or mistyped)
```

The superseded refusal and the already-closed refusal are distinct messages, so a captain can tell "wait for the run" from "you mistyped it".

BEFORE, the same run-superseded key was both listed by the drain and answered: the answer was typed into an actively working run and a `resolved` line was appended over it (`before.txt`, section 1, `exit=0 / delivered to worker: phase it`).

## 3. Away catch-up list follows the same verdict

Durable log for `repair-task`, identical in both checks:

```
blocked [key=creds]: firstmate can refresh the synthetic token
working [key=creds]: retrying with the cached token
```

BEFORE: `fm-afk-return.sh begin` gated the captain with `firstmate-actionable blocker: repair-task [key=creds] ...` while the run was actively working, and `--resolve-key creds` then typed the answer straight into that working run and appended the closing line (`exit=0`).
Both surfaces ignored the run lifecycle entirely.

AFTER:

```
--- run ACTIVELY WORKING - catch-up list
  fm-afk-return: catch-up clear; ordinary captain work may proceed        (exit=0)
--- run ACTIVELY WORKING - --resolve-key creds
  exit=1  ... the run superseded it ...

--- same bytes, run PARKED - catch-up list
  firstmate-actionable blocker: repair-task [key=creds] firstmate can refresh the synthetic token   (exit=3)
--- same bytes, run PARKED - --resolve-key creds
  exit=0
  resulting log: resolved [key=creds]: answered: use the vault secret
```

The list presents exactly the blockers the answer path accepts, in both directions.
