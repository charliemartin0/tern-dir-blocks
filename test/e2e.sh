#!/usr/bin/env bash
# End-to-end check in a real Tern window: cd into a configured directory, the
# blocks open exactly once; cd around inside, nothing reopens; the number of
# Tern windows (hyprctl clients) never changes.
#
# Needs: tern, jq, hyprctl (a running Hyprland session), a display.
# Everything runs in a private Tern config dir, daemon, control socket and
# window; your own windows, plugin links and daemon are never touched.
#
#   bash test/e2e.sh          two fixture blocks (test/fixtures/stub-a, stub-b) in temporary directories
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/dir-blocks-e2e.XXXXXX")
export TERN_CONFIG_DIR="$tmp/cfg" TERN_DAEMON_SOCKET="$tmp/daemon.sock" XDG_STATE_HOME="$tmp/state"
mkdir -p "$TERN_CONFIG_DIR" "$XDG_STATE_HOME"
ctl_sock="$tmp/ctl.sock"
daemon_pid=""; win_pid=""
fails=0

for tool in tern jq hyprctl; do
	command -v "$tool" >/dev/null || { echo "FAIL: $tool not found"; exit 1; }
done
if [ -z "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
	sig=$(ls -t "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/hypr" 2>/dev/null | head -1)
	[ -n "$sig" ] && export HYPRLAND_INSTANCE_SIGNATURE="$sig"
fi

cleanup() {
	if [ -n "$win_pid" ] && kill -0 "$win_pid" 2>/dev/null; then
		tern ctl --control "$ctl_sock" quit >/dev/null 2>&1
		for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$win_pid" 2>/dev/null || break; sleep 0.3; done
		kill -0 "$win_pid" 2>/dev/null && kill "$win_pid" 2>/dev/null
		wait "$win_pid" 2>/dev/null
	fi
	if [ -n "$daemon_pid" ] && kill -0 "$daemon_pid" 2>/dev/null; then
		kill "$daemon_pid" 2>/dev/null
		for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$daemon_pid" 2>/dev/null || break; sleep 0.3; done
		kill -0 "$daemon_pid" 2>/dev/null && kill -9 "$daemon_pid" 2>/dev/null
		wait "$daemon_pid" 2>/dev/null
	fi
	rm -rf "$tmp"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

ctl() { tern ctl --control "$ctl_sock" "$@" 2>&1 | grep -v stencil_trace; }
say() { ctl run "\"$1\"" >/dev/null; }                       # type a command line into the focused pane
cd_to() { say "cd $1"; ctl ready >/dev/null; sleep 1.2; }    # let the cwd event and any opens settle
# blocks of a program (e.g. stub-a.panel) in the private session; optional second arg: tab number
count() {
	tern ls --json 2>/dev/null | jq --arg p "$1" --arg t "${2:-}" \
		'[.sessions[].tabs[] | select($t == "" or (.number | tostring) == $t) | .blocks[] | select(.program == $p)] | length'
}
tern_windows() { hyprctl clients -j | jq '[.[] | select(.class == "so.stencil.tern")] | length'; }
expect() { # name got want
	if [ "$2" = "$3" ]; then echo "  ok   $1 ($2)"; else echo "  FAIL $1: got $2, want $3"; fails=$((fails + 1)); fi
}

work="$tmp/work"
mkdir -p "$work/repo/sub/one" "$work/repo/sub/two" "$work/repo2" "$work/outside"
plugins=("$root/test/fixtures/stub-a" "$root/test/fixtures/stub-b")
a=stub-a.panel; b=stub-b.panel
rule_path="$work/repo"; rule_a=stub-a; rule_b=stub-b; ratio_a=', "ratio": 0.35'
outside="$work/outside"
repo="$work/repo"
inside=("$repo" "$repo/sub" "$repo/sub/one" "$repo/sub/two" "$repo/sub/../sub/one" "$repo")

echo "== starting a private daemon"
tern daemon --socket "$TERN_DAEMON_SOCKET" >"$tmp/daemon.log" 2>&1 &
daemon_pid=$!
for _ in $(seq 1 30); do [ -S "$TERN_DAEMON_SOCKET" ] && break; sleep 0.3; done
[ -S "$TERN_DAEMON_SOCKET" ] || { echo "FAIL: daemon did not start"; cat "$tmp/daemon.log"; exit 1; }
for p in "$root" "${plugins[@]}"; do
	tern plugin link "$p" 2>&1 | grep -v stencil_trace | grep -v "^$" | tail -1
done
mkdir -p "$TERN_CONFIG_DIR/plugin-data/dir-blocks"
config_json() { # extra rules (a leading comma and JSON), appended after the main rule
	cat <<EOF
{
  "rules": [
    { "path": "$rule_path",
      "blocks": [ { "block": "$rule_a", "place": "right"$ratio_a }, { "block": "$rule_b", "place": "down" } ] }$1
  ]
}
EOF
}
config_json "" >"$TERN_CONFIG_DIR/plugin-data/dir-blocks/config.json"
tern plugin reload 2>&1 | grep -v stencil_trace | grep -E "dir-blocks|failed"
status=$(tern plugin list --json 2>/dev/null | jq -r '.plugins[] | select(.id == "dir-blocks") | .status | if type == "string" then . else tojson end')
expect "plugin list status" "$status" "ready"

echo "== opening a private window"
(cd "$outside" && exec tern --control "$ctl_sock" "$outside") >"$tmp/window.log" 2>&1 &
win_pid=$!
for _ in $(seq 1 60); do
	kill -0 "$win_pid" 2>/dev/null || { echo "FAIL: window exited"; cat "$tmp/window.log"; exit 1; }
	ctl ready 2>/dev/null | grep -q '"ok":true' && break
	sleep 0.5
done
sleep 1
windows_before=$(tern_windows)
clients_before=$(tern inspect --json | jq '[.clients[] | select(.kind == "window")] | length')
echo "  Tern windows (hyprctl): $windows_before; windows on the private daemon: $clients_before"

echo "== outside the rule"
cd_to "$outside"
expect "no $a outside" "$(count "$a")" 0
expect "no $b outside" "$(count "$b")" 0

echo "== cd into the configured directory"
cd_to "$repo"
expect "$a opened once" "$(count "$a")" 1
expect "$b opened once" "$(count "$b")" 1
tab1=$(tern ls --json | jq -c '.sessions[].tabs[] | select(.number == 1) | .splits')
echo "  layout: $tab1"
shell_id=$(tern ls --json | jq -r '.sessions[].tabs[] | select(.number == 1) | .blocks[] | select(.program | test("sh$")) | .id')
expect "the shell keeps the top-left" "$(echo "$tab1" | jq --argjson s "$shell_id" '.Split.a.Split.a.Leaf == $s')" true
expect "the second block is split below the shell" "$(echo "$tab1" | jq '.Split.a.Split.b | has("Leaf")')" true
expect "the first block is the right-hand split" \
	"$(tern ls --json | jq --arg p "$a" --argjson l "$(echo "$tab1" | jq '.Split.b.Leaf')" '[.sessions[].tabs[].blocks[] | select(.program == $p)][0].id == $l')" true
ratio=$(echo "$tab1" | jq '.Split.ratio')
expect "ratio 0.35 for the right block leaves 0.65 to the shell (within 0.02)" "$(jq -n --argjson r "$ratio" '(($r - 0.65) | fabs) < 0.02')" true

echo "== cd around inside it"
for d in "${inside[@]}"; do cd_to "$d"; done
expect "$a still once" "$(count "$a")" 1
expect "$b still once" "$(count "$b")" 1

echo "== leave and come back"
cd_to "$outside"
cd_to "$repo"
expect "$a still once after re-entering" "$(count "$a")" 1
expect "$b still once after re-entering" "$(count "$b")" 1

echo "== manual command with both blocks already open"
ctl palette '"Open blocks for this directory"' >/dev/null; sleep 0.4; ctl key enter >/dev/null; sleep 1.2
expect "$a not duplicated by the manual command" "$(count "$a")" 1
expect "$b not duplicated by the manual command" "$(count "$b")" 1

echo "== manual command brings back a closed block"
block_id=$(tern ls --json | jq -r --arg p "$a" '[.sessions[].tabs[].blocks[] | select(.program == $p)][0].id')
tern close "$block_id" >/dev/null 2>&1; sleep 0.8
expect "$a closed" "$(count "$a")" 0
cd_to "$repo/.."; cd_to "$repo"
expect "auto-open does not reopen a block the user closed" "$(count "$a")" 0
ctl palette '"Open blocks for this directory"' >/dev/null; sleep 0.4; ctl key enter >/dev/null; sleep 1.5
expect "$a reopened by the manual command" "$(count "$a")" 1
expect "$b untouched by the manual command" "$(count "$b")" 1

echo "== toggle auto-open off: a fresh tab stays empty"
ctl palette '"Toggle directory auto-open"' >/dev/null; sleep 0.4; ctl key enter >/dev/null; sleep 1
expect "kv switch is off" "$(jq -r '.auto_open' "$TERN_CONFIG_DIR/plugin-data/dir-blocks/kv.json")" false
ctl tab new >/dev/null; ctl ready >/dev/null; sleep 1
cd_to "$repo"
expect "$a not opened in the new tab with auto-open off" "$(count "$a" 2)" 0
echo "== toggle auto-open on"
ctl palette '"Toggle directory auto-open"' >/dev/null; sleep 0.4; ctl key enter >/dev/null; sleep 1
cd_to "$repo/.."; cd_to "$repo"
expect "$a opened in the new tab with auto-open on" "$(count "$a" 2)" 1
expect "$b opened in the new tab with auto-open on" "$(count "$b" 2)" 1
expect "$a total across tabs" "$(count "$a")" 2

echo "== a config with bad rules: plugin list reports it, the valid rules still work"
config_json ",
    { \"path\": \"$work/repo2\", \"blocks\": [ { \"block\": \"$rule_a\", \"place\": \"tab\" } ] },
    { \"path\": \"relative/path\", \"blocks\": [ \"$rule_a\" ] },
    { \"path\": \"$work/ghost\", \"blocks\": [ \"no-such-plugin\" ] }" >"$TERN_CONFIG_DIR/plugin-data/dir-blocks/config.json"
if tern plugin reload >"$tmp/reload.out" 2>&1; then reload_rc=0; else reload_rc=$?; fi
expect "tern plugin reload exits 1" "$reload_rc" 1
listed=$(tern plugin list 2>/dev/null | grep "^dir-blocks")
echo "  $listed"
expect "tern plugin list shows failed with the bad rule" "$(echo "$listed" | grep -c 'failed:.*rules\[3\] (relative/path)')" 1
# a fresh tab that starts outside every rule (new tabs start in the directory of the pane they were
# opened from); the block the rule opens must not already be in the tab it is triggered from
cd_to "$outside"
ctl tab new >/dev/null; ctl ready >/dev/null; sleep 1
tabs_before=$(tern ls --json | jq '[.sessions[].tabs[]] | length')
shown_before=$(tern ls --json | jq '[.sessions[].tabs[] | select(.shown)] | .[0].number')
mkdir -p "$work/ghost"
cd_to "$work/ghost"
expect "a missing plugin opens nothing and breaks nothing" "$(tern ls --json | jq '[.sessions[].tabs[]] | length')" "$tabs_before"
cd_to "$work/repo2"
expect "tab placement opens one new tab" "$(tern ls --json | jq '[.sessions[].tabs[]] | length')" "$((tabs_before + 1))"
expect "$a is in it" "$(count "$a")" 3
expect "the new tab did not take focus from the tab being used" "$(tern ls --json | jq '[.sessions[].tabs[] | select(.shown)] | .[0].number')" "$shown_before"
cd_to "$work/repo2/.."
cd_to "$work/repo2"
expect "re-entering does not open another tab" "$(tern ls --json | jq '[.sessions[].tabs[]] | length')" "$((tabs_before + 1))"
config_json "" >"$TERN_CONFIG_DIR/plugin-data/dir-blocks/config.json"
tern plugin reload >/dev/null 2>&1
expect "plugin list is ready again after the config is fixed" \
	"$(tern plugin list --json | jq -r '.plugins[] | select(.id == "dir-blocks") | .status | if type == "string" then . else "failed" end')" ready

echo "== windows"
expect "Tern windows (hyprctl clients) unchanged" "$(tern_windows)" "$windows_before"
expect "windows on the private daemon unchanged" "$(tern inspect --json | jq '[.clients[] | select(.kind == "window")] | length')" "$clients_before"

if [ "$fails" -eq 0 ]; then echo "PASS"; else echo "FAIL: $fails check(s)"; echo "--- window log ---"; tail -30 "$tmp/window.log"; exit 1; fi
