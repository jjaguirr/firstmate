#!/usr/bin/env bash
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
eval "$(python3 - "$ROOT/bin/fm-spawn.sh" <<'PY'
import pathlib,re,sys
print(re.search(r'^launch_template\(\) \{\n.*?^\}',pathlib.Path(sys.argv[1]).read_text(),re.M|re.S)[0])
PY
)"
for harness in pi pi-signed; do
 for kind in scout ship secondmate; do
  actual=$(FM_PI_NO_TOOLS=1 launch_template "$harness" "$kind")
  case "$actual" in *'--no-tools --no-mcp --no-extensions --no-skills --no-context-files'*) ;; *) echo 'not ok: no-tools launch missing' >&2; exit 1;; esac
  actual=$(FM_PI_NO_TOOLS=0 launch_template "$harness" "$kind")
  case "$actual" in *--no-tools*) exit 1;; esac
 done
done
if FM_PI_NO_TOOLS=invalid launch_template pi scout >/dev/null; then echo 'invalid policy accepted' >&2; exit 1; fi
echo 'ok: Pi no-tools policy and default compatibility'
