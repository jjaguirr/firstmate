# Regression tests: fail on old code, pass on new

Each new test in tests/fm-fleet-snapshot-view.test.sh was run in isolation against a copy
of the repo with bin/fm-fleet-snapshot.sh reverted to an earlier commit.

## Against base commit 3a4a733 (no fix)
```
=== PRE-FIX: test_oversized_backlog_survives_argv_limit_json ===
not ok - snapshot must survive a backlog JSON larger than MAX_ARG_STRLEN: /tmp/fm-e2big-repro.51lI8p/bin/fm-fleet-snapshot.sh: line 621: /home/ubuntu/.nix-profile/bin/jq: Argument list too long
fm-fleet-snapshot: main inventory summary failed
=== PRE-FIX: test_oversized_backlog_survives_argv_limit_secondmate_summary ===
not ok - secondmate home summary must survive a backlog JSON larger than MAX_ARG_STRLEN: /tmp/fm-e2big-repro.51lI8p/bin/fm-fleet-snapshot.sh: line 649: /home/ubuntu/.nix-profile/bin/jq: Argument list too long
fm-fleet-snapshot: secondmate home summary failed
=== PRE-FIX: test_oversized_secondmate_summary_survives_argv_limit ===
not ok - secondmate home summary fixture must succeed: /tmp/fm-e2big-repro.51lI8p/bin/fm-fleet-snapshot.sh: line 649: /home/ubuntu/.nix-profile/bin/jq: Argument list too long
fm-fleet-snapshot: secondmate home summary failed
=== PRE-FIX: test_oversized_scout_reports_survive_argv_limit ===
not ok - snapshot must survive a scout report list larger than MAX_ARG_STRLEN: /tmp/fm-e2big-repro.51lI8p/bin/fm-fleet-snapshot.sh: line 1379: /home/ubuntu/.nix-profile/bin/jq: Argument list too long
```

## Against e65f7e6 (backlog/tasks converted, secondmate summary and scout reports still argv)
```
=== e65f7e6 (backlog/tasks fixed, secondmate summary still argv): secondmate test ===
not ok - snapshot must survive a secondmate summary larger than MAX_ARG_STRLEN: /tmp/fm-e2big-repro.51lI8p/bin/fm-fleet-snapshot.sh: line 1084: /home/ubuntu/.nix-profile/bin/jq: Argument list too long
/tmp/fm-e2big-repro.51lI8p/bin/fm-fleet-snapshot.sh: line 1304: /home/ubuntu/.nix-profile/bin/jq: Argument list too long
jq: invalid JSON text passed to --argjson
Use jq --help for help with command-line options,
=== e65f7e6: scout reports test ===
not ok - snapshot must survive a scout report list larger than MAX_ARG_STRLEN: /tmp/fm-e2big-repro.51lI8p/bin/fm-fleet-snapshot.sh: line 1404: /home/ubuntu/.nix-profile/bin/jq: Argument list too long
```

## Against HEAD be82c98
```
$ /bin/bash tests/fm-fleet-snapshot-view.test.sh
ok - an oversized backlog crosses the argv limit and the JSON snapshot still succeeds
ok - an oversized backlog crosses the argv limit and the secondmate home summary still succeeds
ok - an oversized secondmate summary crosses the argv limit and the fleet snapshot still succeeds
ok - an oversized scout report list crosses the argv limit and the JSON snapshot still succeeds
(20 of 20 tests in the file pass; the four new ones shown)
```

## Temp payload directory is removed on normal exit and on signal death

The fix writes the backlog/tasks/secondmate payloads (task titles, PR URLs) to files under
$TMPDIR instead of argv, so leaking them would be a new problem. Probe with a private TMPDIR:
```
$ FM_HOME=<demo> TMPDIR=<probe> bin/fm-fleet-snapshot.sh --json >/dev/null; ls -A <probe> | wc -l
exit=0 leftover_entries=0
kill -INT during run: exit=130 leftover_entries=0
kill -TERM during run: exit=143 leftover_entries=0
kill -HUP during run: exit=129 leftover_entries=0
```
