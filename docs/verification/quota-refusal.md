# Provider quota refusal verification

Audience: maintainer verification.

This record contains reusable version-scoped evidence for the provider quota-refusal detection and resume path.
[`bin/fm-quota-lib.sh`](../../bin/fm-quota-lib.sh) owns the contract itself, and [`bin/fm-quota-watch.sh`](../../bin/fm-quota-watch.sh) owns the scan and resume mechanics.
Exact task chronology, branch names, temporary homes, and local paths remain in private reports or PR evidence.

`FM_QUOTA_LIVE=1 tests/fm-quota-banner-live-e2e.test.sh` is the command that refreshes everything below against the installed harnesses and the installed `quota-axi`.
Run it after every harness or `quota-axi` upgrade.
`tests/fm-quota-wait.test.sh` is the portable regression that pins the same logic against stubs wherever CI runs tmux.

## The structural field the exhaustion verdict reads

Verified 2026-09-08 against quota-axi 0.1.29, schema 5.

The verdict is `quotaSemantics.effectiveAvailability[]` with `scope == "all_models"` reporting `runway.status == "exhausted_now"`, and the reset time is the latest `resetsAt` among that scope's `limitingWindowIds`.
Only the `all_models` scope is consulted, because a named-model window bounds only that model while provider-level and all-model evidence applies to every model in the family.
The reset is the latest rather than the earliest limiting window, because headroom returns only once every currently limiting window has turned over.

```sh
quota-axi --json | jq -r '
  .providers[]? as $p
  | ($p.quotaSemantics.effectiveAvailability[]? | select(.scope == "all_models")) as $scope
  | [ $p.provider, ($scope.runway.status // "unknown"),
      ([$p.windows[]? | select(.id as $id | ($scope.limitingWindowIds // []) | index($id)) | .resetsAt]
        | map(select(. != null)) | sort | last // "unknown") ] | @tsv'
```

Observed shape on a healthy account, with account-specific values normalized:

```text
claude	through_reset	2026-09-11T16:59:59.953967+00:00
codex	through_reset	2026-09-11T16:59:59.953967+00:00
```

`usableRunwaySeconds`, `projectedExhaustedAt`, and `limitingWindowId` remain in default `--json` when `runway.status` is `projected_exhaustion` or `exhausted_now`; see [dispatch-auth.md](dispatch-auth.md) for the fuller effective-availability shape, which this check reuses rather than restates.
A provider with no row, or a row whose scope status is not `known`, reads `unknown` and never `available`, so missing evidence can never be mistaken for headroom.

## Provider attribution

Verified 2026-09-08 against quota-axi 0.1.29.

`quota-axi models --json` publishes a deterministic provider/model join, which is what lets a recorded model id name its provider without inferring anything from a name prefix:

```sh
quota-axi models --json | jq -r '.models[] | "\(.provider)\t\(.id)"' | sort
```

```text
claude	claude-haiku-4-5
claude	claude-opus-4-5
claude	claude-sonnet-4-5
codex	gpt-5-codex-mini
codex	gpt-5.1-codex
codex	gpt-5.3-codex
grok	grok-3-mini
grok	grok-4
grok	grok-4-fast
kimi	kimi-k1.5
kimi	kimi-k2
kimi	kimi-k2.5
```

The catalog covers only the vendors that publish model-level windows, so it is one of two attribution sources rather than the only one.
The other is the single-vendor harness table in `bin/fm-quota-lib.sh`: `claude`, `codex`, `grok`, `kimi`, and `cursor` each authenticate to exactly one vendor, while `opencode`, `pi`, `pi-signed`, and `muse` are multi-provider surfaces and are deliberately absent from it.
A worker on a multi-provider harness with no catalogued model has no structural verdict, which is disclosed uncertainty rather than a fault.
When both sources answer and disagree, the provider is not established at all.

Attribution verified live on 2026-09-08 for the harnesses installed on that machine:

```text
claude 2.1.263 (Claude Code)   -> claude
codex-cli 0.148.0              -> codex
opencode 1.15.10               -> deliberately unattributed
pi 0.84.2                      -> deliberately unattributed
```

`grok`, `kimi`, `cursor`, and `muse` were not installed on that machine, so their live attribution is unverified in this record; the live guard reports each absent harness explicitly rather than passing over it.

## The rendered limit notice

The notice is a harness-dependent signal, so it is never the whole verdict: it is consulted only when the structural read is unavailable, it must be corroborated by an alive endpoint reading and an exactly-idle semantic busy verdict, and the wait it produces expires within `FM_QUOTA_BANNER_WAIT_MAX_SECS` rather than running to a vendor reset time.

Observed wording, reported from the incident of 2026-09-05 on Claude Code:

```text
You have hit your session limit, resets 8:50am
```

The pattern set in `bin/fm-quota-lib.sh` deliberately carries several independent phrasings, any one of which produces a match, so a single vendor wording change cannot silently disable the check.
No automated guard can prove that a CURRENT vendor limit notice still matches, because provoking one would mean exhausting a real account.
What the live guard proves instead is the more damaging direction: on 2026-09-08 the ordinary `--help` and `--version` output of every installed harness above was fed to the production matcher and produced no match, so the patterns do not park healthy workers.
