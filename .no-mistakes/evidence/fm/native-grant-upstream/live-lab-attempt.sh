#!/usr/bin/env bash
# Live grant-recovery scenarios against a real Herdr lab + real fm-spawn.sh.
set -u
ROOT={run-worktree}
cd "$ROOT"
. "$ROOT/tests/herdr-test-safety.sh"
. "$ROOT/tests/lib.sh"
herdr_forget_inherited_pane
SESSION="fm-lab-grant-$$"
LAB=$(mktemp -d /tmp/fmg.XXXX)
SHIM="$LAB/shim"; mkdir -p "$SHIM"
cat > "$SHIM/claude" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = auth ] && exit 0
echo "STUB-CLAUDE launched: $*" >> "$FM_LAB_LAUNCH_LOG"
exec sleep 3000
SH
chmod +x "$SHIM/claude"
export FM_LAB_LAUNCH_LOG="$LAB/launch.log"
cleanup() { herdr_safe_stop_and_delete "$SESSION"; herdr session stop fleetstub >/dev/null 2>&1; herdr session delete fleetstub >/dev/null 2>&1; kill $FLEETPID 2>/dev/null; }
trap cleanup EXIT
export PATH="$SHIM:$PATH"; export XDG_CONFIG_HOME="$LAB/x"; mkdir -p "$XDG_CONFIG_HOME/herdr"; [ -f ~/.config/herdr/config.toml ] && cp ~/.config/herdr/config.toml "$XDG_CONFIG_HOME/herdr/"
export HERDR_SESSION="$SESSION"
HERDR_SESSION=fleetstub herdr server --session fleetstub >/tmp/fmlive/fleet.log 2>&1 & FLEETPID=$!; sleep 3; export FM_HERDR_LAB_FLEET_SESSION=fleetstub; herdr session list; fm_herdr_lab_provision "$SESSION" || exit 91
. "$ROOT/bin/fm-backend.sh"; fm_backend_source herdr
HOME_D="$LAB/home"; mkdir -p "$HOME_D/state" "$HOME_D/data" "$HOME_D/config" "$LAB/user-home" "$LAB/grants"
PROJ="$LAB/proj"; WT="$LAB/wt"; ID=ng1
fm_git_worktree "$PROJ" "$WT" "task-$ID"
mkdir -p "$HOME_D/data/$ID"
printf '# Task\n## Captain'"'"'s intent\nlive grant\n\n## Firstmate spec\nrecover\n' > "$HOME_D/data/$ID/brief.md"
RAW=$(fm_backend_herdr_container_ensure "$PROJ") || exit 92
CONTAINER=${RAW%%$'\t'*}; SEED=${RAW#*$'\t'}
IDS=$(fm_backend_herdr_create_task "$CONTAINER" "fm-$ID" "$WT" "$SEED") || exit 93
read -r TAB PANE <<<"$IDS"
WS=${CONTAINER#*:}
{
echo "window=$SESSION:$PANE"; echo "endpoint_task_id=$ID"; echo "worktree=$WT"; echo "project=$PROJ"
echo harness=claude; echo kind=ship; echo mode=no-mistakes; echo yolo=off; echo "tasktmp=$LAB/tmp-$ID"
echo model=opus; echo effort=high; echo backend=herdr; echo "herdr_session=$SESSION"
echo "herdr_workspace_id=$WS"; echo "herdr_tab_id=$TAB"; echo "herdr_pane_id=$PANE"
} > "$HOME_D/state/$ID.meta"
F="$HOME_D/data/backlog.md"
printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$F"
tasks-axi add $ID "live fixture" --kind ship --file "$F" >/dev/null
tasks-axi start $ID --file "$F" >/dev/null
tasks-axi hold $ID --reason "waiting on external dependency" --kind external --file "$F" >/dev/null
echo "== fixture: pane=$PANE session=$SESSION"
# real host restart: stop session and bring server back; pane survives with no agent
fm_herdr_lab_stop "$SESSION" >/dev/null 2>&1 || exit 94
sleep 0.5
fm_backend_herdr_server_ensure "$SESSION" || exit 95
herdr pane get "$PANE" --session "$SESSION" >/dev/null 2>&1 && echo "pane survived restart"
herdr agent get "$PANE" --session "$SESSION" >/dev/null 2>&1 && echo "UNEXPECTED agent registered" || echo "no agent registered (husk)"
spawn() { env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SOCKET_PATH -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
  FM_HOME="$HOME_D" HOME="$LAB/user-home" CLAUDE_CONFIG_DIR='' FM_SPAWN_NO_GUARD=1 HERDR_SESSION="$SESSION" \
  timeout 90 "$ROOT/bin/fm-spawn.sh" "$@" 2>&1; }
mkgrant() { # name json
  printf '%s' "$2" > "$LAB/grants/$1"; }
now=$(date +%s); SES=0123abcd-0000-4000-8000-0000000000aa
good() { printf '{"task":"%s","pane":"%s","agent":"claude","session":"%s","written":%s}' "$ID" "$PANE" "$SES" "$1"; }
before=$(cat "$F"); LED="$HOME_D/state/$ID.native-grant-spent"
echo "---- (b1) missing grant"
spawn $ID --relaunch --native-grant "$LAB/grants/$ID.json" ; echo "rc=$?"
ls "$LED" 2>&1 | head -1; [ -s "$LAUNCH_LOG" ] 2>/dev/null; ls "$FM_LAB_LAUNCH_LOG" 2>&1|head -1
echo "---- (b2) expired grant"
mkgrant $ID.json "$(good $((now-43201)))"
spawn $ID --relaunch --native-grant "$LAB/grants/$ID.json"; echo "rc=$?"
ls "$LED" 2>&1 | head -1; ls "$FM_LAB_LAUNCH_LOG" 2>&1|head -1
echo "---- (b3) mismatched grant (wrong pane)"
mkgrant $ID.json "$(printf '{"task":"%s","pane":"%%99","agent":"claude","session":"%s","written":%s}' "$ID" "$SES" "$now")"
spawn $ID --relaunch --native-grant "$LAB/grants/$ID.json"; echo "rc=$?"
ls "$LED" 2>&1 | head -1; ls "$FM_LAB_LAUNCH_LOG" 2>&1|head -1
echo "backlog unchanged after refusals: $([ "$before" = "$(cat "$F")" ] && echo yes || echo NO)"
echo "---- (a) matching grant"
mkgrant $ID.json "$(good $now)"
spawn $ID --relaunch --native-grant "$LAB/grants/$ID.json"; echo "rc=$?"
echo "ledger:"; cat "$LED" 2>&1
sleep 2
echo "launch log:"; cat "$FM_LAB_LAUNCH_LOG" 2>&1
echo "meta model/effort/pane:"; grep -E '^(model|effort|herdr_pane_id)=' "$HOME_D/state/$ID.meta"
echo "backlog unchanged: $([ "$before" = "$(cat "$F")" ] && echo yes || echo NO)"
tasks-axi show $ID --file "$F" | grep -E 'state|held'
herdr pane read "$PANE" --session "$SESSION" 2>&1 | tail -5
echo "---- (a2) replay same grant after agent gone"
herdr pane run "$PANE" 'pkill -f "sleep 3000"' --session "$SESSION" >/dev/null 2>&1; sleep 2
rm -f "$FM_LAB_LAUNCH_LOG"
spawn $ID --relaunch --native-grant "$LAB/grants/$ID.json"; echo "rc=$?"
ls "$FM_LAB_LAUNCH_LOG" 2>&1|head -1
echo done
