#!/usr/bin/env bash
# Exercise the real template function without sourcing spawn's fleet mutations.
# This revision has no CODEX_NATIVE switch: secondmate is the no-notify seam.
set -eu
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Extract only the real function definition; never execute a generated launch.
TEMPLATE_FUNCTION=$(python3 - "$ROOT/bin/fm-spawn.sh" <<'PY'
import pathlib
import re
import sys
source = pathlib.Path(sys.argv[1]).read_text()
match = re.search(r'^launch_template\(\) \{\n.*?^\}', source, re.M | re.S)
if match is None:
    sys.exit('launch_template definition not found')
print(match.group(0))
PY
)
eval "$TEMPLATE_FUNCTION"

failures=0
for kind in secondmate ship scout; do
  actual=$(launch_template codex "$kind")
  expected='codex __MODELFLAG____EFFORTFLAG__--sandbox workspace-write --ask-for-approval on-request '
  if [ "$kind" != secondmate ]; then
    expected+='-c "notify=[\"bash\",\"-c\",\"touch __TURNEND__\"]" '
  fi
  expected+='"$(__OPINPUT__ encode launch-brief < __BRIEF__)"'
  if [ "$actual" = "$expected" ]; then
    printf 'ok - Codex %s template: workspace-write sandbox and on-request approvals\n' "$kind"
  else
    printf 'not ok - Codex %s template\nexpected: %s\nactual:   %s\n' "$kind" "$expected" "$actual" >&2
    failures=1
  fi
done
exit "$failures"
