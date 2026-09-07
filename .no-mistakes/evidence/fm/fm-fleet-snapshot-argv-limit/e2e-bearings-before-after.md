# Fleet status with an oversized backlog: before vs after

Demo home built like a real one: 1 in-flight ship task, 160 queued backlog rows.
data/backlog.md = 158413 bytes; serialized backlog JSON = 402107 bytes,
far past Linux MAX_ARG_STRLEN (131072 bytes), the per-argv-entry cap that broke jq exec.
Long titles below are truncated to 150 columns for readability.

## BEFORE - base commit 3a4a733

```
$ FM_HOME=<demo> bin/fm-bearings-snapshot.sh
/tmp/fm-e2big-repro.51lI8p/bin/fm-fleet-snapshot.sh: line 621: /home/ubuntu/.nix-profile/bin/jq: Argument list too long
fm-fleet-snapshot: main inventory summary failed
exit=1

$ FM_HOME=<demo> bin/fm-fleet-view.sh
/tmp/fm-e2big-repro.51lI8p/bin/fm-fleet-snapshot.sh: line 621: /home/ubuntu/.nix-profile/bin/jq: Argument list too long
fm-fleet-snapshot: main inventory summary failed
exit=1
```

## AFTER - HEAD be82c98

```
$ FM_HOME=<demo> bin/fm-bearings-snapshot.sh
schema: fm-bearings.v1
home: tmp/fm-e2e-demo.gXguku
generated: "2026-09-07T21:18:29Z"
prs: "not_requested (run: /bearings include PRs)"
in_flight[1]{id,kind,state,doing}:
  ship-task,ship,unknown,"backend target gone: firstmate:fm-ship-task"
secondmates: []
decisions_open: []
landed: []
gates[20]{id,title,blocked_by,reason,owner}:
  backlog-item-001,Backlog item 001 yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy…,"-","-",(main)
  backlog-item-002,Backlog item 002 yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy…,"-","-",(main)
  backlog-item-003,Backlog item 003 yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy…,"-","-",(main)
  ... 20 of 160 gates shown, bounded as designed
exit=0

$ FM_HOME=<demo> bin/fm-fleet-view.sh
# Fleet View

Schema: fm-fleet-snapshot.v1
Home: /tmp/fm-e2e-demo.gXguku

## Under Way
| ID | Current | Kind | Repo/Project | Backend | Endpoint | Artifact | Path | Watch / return channel |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| ship-task | unknown / none | ship | alpha | tmux | absent | - | /tmp/fm-e2e-demo.gXguku/projects/alpha-worktree | bin/fm-peek.sh fm-ship-task |

## Queued
| ID | Title | Repo | Kind | Blocked By | Artifact |
| --- | --- | --- | --- | --- | --- |
| backlog-item-001 | Backlog item 001 yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy
  ...
exit=0

$ FM_HOME=<demo> bin/fm-fleet-snapshot.sh --json | jq -c "{schema, main_inventory_valid: .main_inventory.valid, queued: ..., backlog_json_bytes: ...}"
{"schema":"fm-fleet-snapshot.v1","main_inventory_valid":true,"queued":160,"backlog_json_bytes":402107}
```
