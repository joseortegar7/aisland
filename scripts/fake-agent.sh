#!/bin/bash
# Fake Claude Code session for verifying the notch end to end without any API
# spend. Run from a real terminal (iTerm2/Terminal.app) so TerminalRef capture
# and click-to-jump are exercised for real.
#
# Flow: SessionStart → prompt → gated PreToolUse (approve/deny it from the
# notch!) → Stop → SessionEnd.
set -euo pipefail
cd "$(dirname "$0")/.."

CTL=".build/debug/islandctl"
if [[ ! -x "$CTL" ]]; then
    echo "building islandctl…"
    swift build --product islandctl >/dev/null
fi

ID="fake-$$"
echo "== fake agent session $ID (terminal: ${TERM_PROGRAM:-unknown}, tty: $(tty)) =="

"$CTL" session-start --id "$ID"
"$CTL" prompt --id "$ID" --text "fix the auth bug in middleware"

echo
echo ">> A permission card should now appear in the notch. Decide there. <<"
"$CTL" permission --id "$ID" --tool Bash --arg "rm -rf /tmp/scratch-dir"

"$CTL" stop --id "$ID"
sleep 2
"$CTL" session-end --id "$ID"
echo "== done =="
