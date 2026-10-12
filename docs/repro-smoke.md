# Reproducible Firstmate smoke

Canonical source: `jjaguirr/firstmate`. Check out the exact reviewed full commit SHA on each host; do not share runtime state or credentials. No main-branch switch is required.

```
python3 tests/test_repro_smoke.py
python3 bin/fm-repro-smoke.py --expected-revision FULL_40_HEX_SHA --runtime-root "$HOME/.local/state/firstmate-smoke"
python3 bin/fm-repro-smoke.py --expected-revision FULL_40_HEX_SHA --runtime-root "$HOME/.local/state/firstmate-smoke" --live
```

`tests/fixtures/repro-smoke.json` is the versioned sample configuration. Copy it outside the checkout and use `--config` to override models or timeout. Pi is pinned to 1.1.0 because this version's `--no-tools` disables built-in and extension tools. Other tools are presence checked; Git/source revision is strictly pinned. Each operation has a timeout. There is one Luna scout at most per run.

Offline policy assertions are deterministic and do not launch models. Live inference is stochastic: the protocol/fixture and assertions are deterministic, not model token output. The live runner uses real `fm-spawn.sh`, a private tmux socket, a tiny Git fixture and a lab-local Treehouse pool. Sol readiness and Sol return are separate no-tools calls; this is script-driven Firstmate dispatch, **not proof of autonomous Sol delegation or full interactive Firstmate supervision**. No unrestricted worker fallback exists. The scout report is harness-owned because the worker cannot write files.

`FM_PI_NO_TOOLS=1` is an opt-in launch policy for Pi/Pi-signed workers, preserving normal defaults when unset/0 and rejecting other values. Explicit Firstmate lifecycle extensions still load, but Pi disables all their tools. This is a tool capability restriction, not an OS sandbox. Codex retains workspace-write/on-request. Trusted execution is confined to the disposable smoke.

Host-local `receipt.json` records pass/blocker and cleanup. Missing host tools/auth is a blocker, not a skipped success. No auth values are logged or copied. Runtime directories are disposable and removed; receipts remain outside source. No projects, merges, deploys or publishing are involved.
