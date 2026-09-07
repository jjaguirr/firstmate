# Wedge deep-inspection marker: before / after

Both columns are the literal `stale: ...` wake reason a supervisor reads, produced by running the real `bin/fm-watch.sh` over the same fixture. "Before" runs the watcher at the base commit `3a4a733`; "after" runs the branch head.

## A killed agent behind a run-step that still reads "validating (running)"

- Before: `stale: test:fm-dead-agent (idle 501s, possible wedge, escalation 1)` - no marker; the supervisor reaches deep inspection only after three of these.
- After: `stale: test:fm-dead-agent (idle 501s, possible wedge, escalation 1, demand-deep-inspection: no agent is alive at the recorded endpoint - inspect now, do not re-absorb on the run-step/pane state alone)`

## A healthy pane whose agent is alive, with the counter already at the threshold of 3

- Before: `stale: test:fm-alive-agent (idle 501s, possible wedge, escalation 4, demand-deep-inspection: same pane has wedge-escalated 4 times in a row - do not re-absorb on the run-step/pane state alone)` - counter advances 3 to 4 and the marker fires on an affirmative reading.
- After: `stale: test:fm-alive-agent (idle 501s, possible wedge, escalation 3 unexplained so far, agent alive at the recorded endpoint so this escalation is not counted; confirm what the worker is waiting on)` - the wake still fires and still reports an unresolved possible wedge, carries no marker, and the stored counter stays 3 across repeated rounds.

## Unchanged paths

- Unreadable endpoint (unknown verdict): counts 1, 2, 3 and the marker fires at 3, exactly as before.
- Secondmate: endpoint never probed, keeps the repetition schedule, first escalation carries no marker even with a bare shell in the pane foreground.
- Pane past the busy-turn bound with a live agent: counts 1, 2, 3 and the marker fires at 3, because that path refuses the affirmative reading.
- Pane past the busy-turn bound with a dead agent: marker on escalation 1, so the dead path is strengthened there too.
- Away-mode daemon: the alive-arm reason still routes to the captain escalation feed under a `paused:` status line, so no pane that surfaced before is absorbed now.

Full transcripts: `wedge-escalation-wake-reasons.txt`, `baseline-3a4a733-wake-reasons.txt`, `alive-wedge-daemon-routing.txt`.
