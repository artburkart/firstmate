#!/usr/bin/env bash
# Regression tests for Treehouse pool-slot recognition and the per-slot owner
# claim under a templated worktree_path, for example
# ("/srv/slots/{repo}-{slot}", with the pool state under ~/.treehouse).
#
# Before this fix fm_treehouse_pool_slot read pool membership from the default
# <pool>/<slot>/<repo> path shape, so a templated slot was never recognised:
# spawn wrote no claim, and teardown skipped the project lock, the record scan,
# and the owner check while `treehouse return --force` still ran. Every
# templated slot would also have shared one claim file, <root>/.fm-slot-owner,
# in a directory Firstmate cannot write; claims now live in the
# Firstmate root home's state, keyed by slot.
#
# A fake treehouse lists the pool; nothing here touches a real pool,
# ~/.treehouse, or /srv/slots.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-treehouse-templated-slot)

# <case>/project with a commit, its fakebin, and a Firstmate home. Every fake
# call except a status query is logged to <case>/runtime.log.
make_case() {  # <name>
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config" "$dir/fakebin"
  git init -q "$dir/project"
  git -C "$dir/project" -c user.name=test -c user.email=test@example.invalid \
    commit --allow-empty -qm init
  : > "$dir/runtime.log"
  cat > "$dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf 'tmux' >> "${FM_RUNTIME_LOG:?}"
printf ' <%s>' "$@" >> "${FM_RUNTIME_LOG:?}"
printf '\n' >> "${FM_RUNTIME_LOG:?}"
exit 0
SH
  cat > "$dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf 'treehouse' >> "${FM_RUNTIME_LOG:?}"
printf ' <%s>' "$@" >> "${FM_RUNTIME_LOG:?}"
printf '\n' >> "${FM_RUNTIME_LOG:?}"
exit 0
SH
  chmod +x "$dir/fakebin/tmux" "$dir/fakebin/treehouse"
  printf '%s\n' "$dir"
}

add_slot() {  # <case> <path>
  git -C "$1/project" worktree add -q --detach "$2"
}

# Run one wake-library call against a case, under bash and the case's PATH.
# shellcheck disable=SC2016 # Positional parameters expand in the child shell.
lib() {  # <case> <function> [args...]
  local dir=$1
  shift
  FM_HOME="$dir/home" PATH="$dir/fakebin:$PATH" \
    bash -c '. "$1"; shift; "$@"' _ "$ROOT/bin/fm-wake-lib.sh" "$@"
}

pool_rc() {  # <case> <worktree>
  local rc=0
  lib "$1" fm_treehouse_pool_slot "$1/project" "$2" || rc=$?
  printf '%s\n' "$rc"
}

marker() {  # <case> <worktree>
  lib "$1" fm_treehouse_slot_owner_marker "$2"
}

# shellcheck disable=SC2016 # Positional parameters expand in the child shell.
owner_state() {  # <case> <worktree> <task-id>
  FM_HOME="$1/home" PATH="$1/fakebin:$PATH" \
    bash -c '. "$1"; fm_treehouse_slot_owner_state "$2" "$3"; printf %s "$FM_TREEHOUSE_SLOT_OWNER"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$2" "$3"
}

run_teardown() {  # <case> <id> [--force]
  local dir=$1 id=$2
  shift 2
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
  FM_RUNTIME_LOG="$dir/runtime.log" PATH="$dir/fakebin:$PATH" \
    "$TEARDOWN" "$id" "$@"
}

write_record() {  # <case> <id> <worktree>
  fm_write_meta "$1/home/state/$2.meta" \
    "window=firstmate:fm-$2" "endpoint_task_id=$2" \
    "worktree=$3" "project=$1/project" "kind=scout"
}

test_default_and_templated_layouts_are_recognised() {
  local dir slot_a slot_b

  dir=$(make_case default-layout)
  mkdir -p "$dir/pool/1" "$dir/pool/2"
  add_slot "$dir" "$dir/pool/1/project"
  add_slot "$dir" "$dir/pool/2/project"
  fm_fake_treehouse_pool "$dir/fakebin" "$dir/pool/1/project" "$dir/pool/2/project"
  assert_equals 0 "$(pool_rc "$dir" "$dir/pool/1/project")" \
    "a default-layout slot was not recognised as a pool slot"
  assert_not_equals "$(marker "$dir" "$dir/pool/1/project")" "$(marker "$dir" "$dir/pool/2/project")" \
    "two default-layout slots share one slot-owner claim"
  # Treehouse may name the <pool>/<slot> directory instead of the checkout.
  fm_fake_treehouse_pool "$dir/fakebin" "$dir/pool/1" "$dir/pool/2"
  assert_equals 0 "$(pool_rc "$dir" "$dir/pool/1/project")" \
    "a default-layout slot listed by its slot directory was not recognised"

  dir=$(make_case templated-layout)
  slot_a="$dir/slots/project-1"
  slot_b="$dir/slots/project-2"
  mkdir -p "$dir/slots"
  add_slot "$dir" "$slot_a"
  add_slot "$dir" "$slot_b"
  fm_fake_treehouse_pool "$dir/fakebin" "$slot_a" "$slot_b"
  # The old path-shape check looked for the pool state two levels up; keep it
  # absent so recognition can only come from Treehouse's own listing.
  assert_absent "$dir/treehouse-state.json" "the templated fixture grew a pool state file beside its slots"
  assert_equals 0 "$(pool_rc "$dir" "$slot_a")" \
    "a templated-layout slot was not recognised as a pool slot"
  assert_equals 0 "$(pool_rc "$dir" "$slot_b")" \
    "the second templated-layout slot was not recognised as a pool slot"
  assert_not_equals "$(marker "$dir" "$slot_a")" "$(marker "$dir" "$slot_b")" \
    "two templated slots share one slot-owner claim"
  case "$(marker "$dir" "$slot_a")" in
    "$dir/home/state/"*) ;;
    *) fail "a templated slot's claim is not kept in the Firstmate home's state: $(marker "$dir" "$slot_a")" ;;
  esac

  # A listing that reaches the slot through a symlinked root still names it.
  ln -s "$dir/slots" "$dir/slots-link"
  fm_fake_treehouse_pool "$dir/fakebin" "$dir/slots-link/project-1"
  assert_equals 0 "$(pool_rc "$dir" "$slot_a")" \
    "a slot Treehouse lists through a symlinked root was not recognised"
  pass "default and templated Treehouse slots are recognised from Treehouse's listing, each with its own claim"
}

test_claims_on_sibling_templated_slots_stay_separate() {
  local dir slot_a slot_b
  dir=$(make_case templated-claims)
  slot_a="$dir/slots/project-1"
  slot_b="$dir/slots/project-2"
  mkdir -p "$dir/slots"
  add_slot "$dir" "$slot_a"
  add_slot "$dir" "$slot_b"
  fm_fake_treehouse_pool "$dir/fakebin" "$slot_a" "$slot_b"
  # The shared slot root is not writable; claiming must not need to write it.
  chmod 555 "$dir/slots"

  lib "$dir" fm_treehouse_slot_owner_claim "$slot_a" task-a "$dir/home" \
    || fail "claiming the first templated slot failed"
  lib "$dir" fm_treehouse_slot_owner_claim "$slot_b" task-b "$dir/home" \
    || fail "claiming the second templated slot failed"
  assert_equals mine "$(owner_state "$dir" "$slot_a" task-a)" \
    "the second slot's claim overwrote the first slot's"
  assert_equals mine "$(owner_state "$dir" "$slot_b" task-b)" \
    "the second slot's claim does not name its own task"
  lib "$dir" fm_treehouse_slot_owner_release "$slot_a" task-a
  assert_absent "$(marker "$dir" "$slot_a")" "releasing the first slot left its claim"
  assert_contains "$(cat "$(marker "$dir" "$slot_b")")" "task=task-b" \
    "releasing the first slot disturbed the second slot's claim"
  [ -z "$(find "$dir/home/state" -maxdepth 1 -name '.treehouse-slot-owner-*.tmp.*')" ] \
    || fail "a claim left its temporary file behind"
  chmod 755 "$dir/slots"
  pass "claims on sibling templated slots are written, read, and released independently"
}

test_membership_is_only_what_treehouse_answers() {
  local dir slot other

  dir=$(make_case membership)
  slot="$dir/slots/project-1"
  mkdir -p "$dir/slots"
  add_slot "$dir" "$slot"
  add_slot "$dir" "$dir/slots/project-unlisted"
  fm_fake_treehouse_pool "$dir/fakebin" "$slot"
  assert_equals 1 "$(pool_rc "$dir" "$dir/slots/project-unlisted")" \
    "a linked worktree Treehouse does not list was taken for a pool slot"

  # A listed path that belongs to another repository is not this project's slot.
  other="$dir/other"
  git init -q "$other"
  git -C "$other" -c user.name=test -c user.email=test@example.invalid commit --allow-empty -qm init
  mkdir -p "$dir/foreign"
  git -C "$other" worktree add -q --detach "$dir/foreign/other-1"
  fm_fake_treehouse_pool "$dir/fakebin" "$slot" "$dir/foreign/other-1"
  assert_equals 1 "$(pool_rc "$dir" "$dir/foreign/other-1")" \
    "another repository's worktree was taken for this project's pool slot"

  # A status that succeeds with no output lists no slots.
  : > "$dir/fakebin/.treehouse-pool-status.json"
  assert_equals 1 "$(pool_rc "$dir" "$slot")" "an empty Treehouse answer did not read as an empty pool"

  # Anything Treehouse cannot answer readably is unknown, never "not a slot".
  printf 'all worktrees are busy\n' > "$dir/fakebin/.treehouse-pool-status.json"
  assert_equals 2 "$(pool_rc "$dir" "$slot")" "a non-JSON Treehouse answer was not reported as unknown"
  printf '{"worktrees":[{"name":"1","path":"%s"}]}\n' "$slot" > "$dir/fakebin/.treehouse-pool-status.json"
  assert_equals 2 "$(pool_rc "$dir" "$slot")" "a Treehouse answer that is not a list was not reported as unknown"
  # An entry that cannot name a slot makes the whole listing unreadable, even
  # beside a well-formed entry, rather than silently shrinking the pool.
  printf '[{"name":"1","worktree":"%s"}]\n' "$slot" > "$dir/fakebin/.treehouse-pool-status.json"
  assert_equals 2 "$(pool_rc "$dir" "$slot")" "an entry without a path was not reported as unknown"
  printf '[{"name":"1","path":"slots/project-1"}]\n' > "$dir/fakebin/.treehouse-pool-status.json"
  assert_equals 2 "$(pool_rc "$dir" "$slot")" "a relative listed path was not reported as unknown"
  printf '[{"name":"2","path":"%s"},"project-1"]\n' "$dir/slots/project-unlisted" \
    > "$dir/fakebin/.treehouse-pool-status.json"
  assert_equals 2 "$(pool_rc "$dir" "$slot")" "a listing with a non-object entry was not reported as unknown"
  cat > "$dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
echo "treehouse: cannot read pool state" >&2
exit 1
SH
  assert_equals 2 "$(pool_rc "$dir" "$slot")" "a failed Treehouse status was not reported as unknown"
  # A listing jq cannot read is unknown even when Treehouse would answer.
  fm_fake_treehouse_pool "$dir/fakebin" "$slot"
  # shellcheck disable=SC2016 # Positional parameters expand in the child shell.
  assert_equals 2 "$(FM_HOME="$dir/home" PATH="$dir/fakebin:$(fm_test_base_path_sans "$PATH" jq treehouse)" \
    bash -c '. "$1"; rc=0; fm_treehouse_pool_slot "$2" "$3" || rc=$?; printf %s "$rc"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$dir/project" "$slot")" \
    "a missing jq was not reported as unknown"
  # With no treehouse at all nothing can return the copy through it, so an
  # ordinary linked worktree stays one, as on a host that never installed it.
  rm -f "$dir/fakebin/treehouse"
  # shellcheck disable=SC2016 # Positional parameters expand in the child shell.
  assert_equals 1 "$(FM_HOME="$dir/home" PATH="$dir/fakebin:$(fm_test_base_path_sans "$PATH" treehouse)" \
    bash -c '. "$1"; rc=0; fm_treehouse_pool_slot "$2" "$3" || rc=$?; printf %s "$rc"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$dir/project" "$slot")" \
    "a host without treehouse took an ordinary linked worktree for a pool slot"
  pass "pool membership is exactly what Treehouse lists, an unreadable answer is unknown, and no Treehouse means no slot"
}

templated_case() {  # <name> -> case with slots/project-1 and slots/project-2 listed
  local dir
  dir=$(make_case "$1")
  mkdir -p "$dir/slots"
  add_slot "$dir" "$dir/slots/project-1"
  add_slot "$dir" "$dir/slots/project-2"
  : > "$dir/slots/project-1/sentinel"
  fm_fake_treehouse_pool "$dir/fakebin" "$dir/slots/project-1" "$dir/slots/project-2"
  printf '%s\n' "$dir"
}

# The lab hazard: a stale record names a templated slot Treehouse has since
# handed to another task, which claimed it. Teardown of the stale record must
# finish its own cleanup and leave the slot - its copy, its claim, its
# processes - untouched.
test_stale_record_never_returns_a_reassigned_templated_slot() {
  local dir id=stale-task other=new-holder rc claim
  dir=$(templated_case stale-templated)
  write_record "$dir" "$id" "$dir/slots/project-1"
  lib "$dir" fm_treehouse_slot_owner_claim "$dir/slots/project-1" "$other" "$dir/other-home" \
    || fail "the new holder could not claim its templated slot"
  claim=$(marker "$dir" "$dir/slots/project-1")

  set +e
  run_teardown "$dir" "$id" --force > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "teardown of a stale record on a reassigned templated slot failed: $(cat "$dir/stderr")"
  assert_absent "$dir/home/state/$id.meta" "the stale record was not cleaned up"
  ! grep -Fq "treehouse <return>" "$dir/runtime.log" \
    || fail "the stale record returned a templated slot another task holds: $(cat "$dir/runtime.log")"
  assert_present "$dir/slots/project-1/sentinel" "the stale record reset the new holder's copy"
  assert_contains "$(cat "$claim")" "task=$other" "the stale record rewrote the new holder's claim"
  assert_contains "$(cat "$dir/stderr")" "reassigned" "teardown did not name the reassignment"
  pass "a stale record never returns a templated slot another task has claimed"
}

test_templated_slot_teardown_holds_the_project_lock() {
  local dir id=locked-task lock holder rc waited=0
  dir=$(templated_case locked-templated)
  write_record "$dir" "$id" "$dir/slots/project-1"
  lock=$(lib "$dir" fm_treehouse_project_lock_path "$dir/project") \
    || fail "could not resolve the Treehouse project lock"
  # shellcheck disable=SC2016 # Positional parameters expand in the child shell.
  FM_HOME="$dir/home" bash -c '. "$1"; fm_lock_try_acquire "$2" || exit 1; : > "$3"; exec sleep 30' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$lock" "$dir/lock-held" &
  holder=$!
  while [ ! -e "$dir/lock-held" ] && [ "$waited" -lt 100 ]; do
    sleep 0.05
    waited=$((waited + 1))
  done
  [ -e "$dir/lock-held" ] || fail "the stand-in allocation never took the project lock"

  set +e
  run_teardown "$dir" "$id" --force > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  [ "$rc" -ne 0 ] || fail "teardown returned a templated slot while an allocation held the project lock"
  assert_contains "$(cat "$dir/stderr")" "another Treehouse slot allocation or return is in progress" \
    "the refusal did not name the project lock"
  assert_present "$dir/home/state/$id.meta" "the contended teardown removed the record"
  [ ! -s "$dir/runtime.log" ] || fail "the contended teardown reached the runtime: $(cat "$dir/runtime.log")"
  pass "teardown of a templated slot is serialized by the Treehouse project lock"
}

# The record scan that refuses when two records name one slot also runs for a
# templated slot.
test_templated_slot_named_by_two_records_refuses() {
  local dir rc
  dir=$(templated_case duplicate-templated)
  write_record "$dir" first-task "$dir/slots/project-1"
  write_record "$dir" second-task "$dir/slots/project-1"

  set +e
  run_teardown "$dir" first-task --force > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "teardown returned a templated slot a second record still names"
  assert_contains "$(cat "$dir/stderr")" "second-task" "the refusal did not name the other record"
  assert_present "$dir/slots/project-1/sentinel" "the refused teardown reset the slot"
  [ ! -s "$dir/runtime.log" ] || fail "the refused teardown reached the runtime: $(cat "$dir/runtime.log")"
  pass "a templated slot named by two task records refuses teardown"
}

test_unreadable_treehouse_refuses_teardown() {
  local dir id=unknown-task rc
  dir=$(templated_case unreadable-templated)
  write_record "$dir" "$id" "$dir/slots/project-1"
  printf 'not json\n' > "$dir/fakebin/.treehouse-pool-status.json"

  set +e
  run_teardown "$dir" "$id" --force > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "teardown proceeded when Treehouse could not say whether the copy was a pool slot"
  assert_contains "$(cat "$dir/stderr")" "is a Treehouse pool slot" \
    "the refusal did not name the unreadable Treehouse status"
  assert_present "$dir/home/state/$id.meta" "the refused teardown removed the record"
  assert_present "$dir/slots/project-1/sentinel" "the refused teardown reset the copy"
  [ ! -s "$dir/runtime.log" ] || fail "the refused teardown reached the runtime: $(cat "$dir/runtime.log")"
  pass "teardown refuses, changing nothing, when Treehouse's status cannot be read"
}

test_own_templated_slot_returns_and_releases_only_its_claim() {
  local dir id=own-task
  dir=$(templated_case own-templated)
  write_record "$dir" "$id" "$dir/slots/project-1"
  lib "$dir" fm_treehouse_slot_owner_claim "$dir/slots/project-1" "$id" "$dir/home" \
    || fail "could not claim the task's own templated slot"
  lib "$dir" fm_treehouse_slot_owner_claim "$dir/slots/project-2" sibling-task "$dir/home" \
    || fail "could not claim the sibling templated slot"

  run_teardown "$dir" "$id" --force > "$dir/stdout" 2> "$dir/stderr" \
    || fail "teardown of a task holding its own templated slot failed: $(cat "$dir/stderr")"
  grep -Fq "treehouse <return>" "$dir/runtime.log" \
    || fail "teardown did not return its own templated slot: $(cat "$dir/runtime.log")"
  assert_absent "$(marker "$dir" "$dir/slots/project-1")" "teardown left its spent templated claim"
  assert_contains "$(cat "$(marker "$dir" "$dir/slots/project-2")")" "task=sibling-task" \
    "teardown disturbed the sibling slot's claim"
  pass "a task's own templated slot is returned and only its own claim is dropped"
}

# A claim the previous Firstmate wrote at <pool>/<slot>/.fm-slot-owner still
# protects a task in flight across the upgrade, but only where that version
# could have written it: the default layout with the pool state beside it.
test_legacy_default_layout_claims_are_still_honoured() {
  local dir id=stale-task rc legacy
  dir=$(make_case legacy-claim)
  mkdir -p "$dir/pool/1" "$dir/pool/2"
  add_slot "$dir" "$dir/pool/1/project"
  add_slot "$dir" "$dir/pool/2/project"
  : > "$dir/pool/1/project/sentinel"
  printf '{"worktrees":[]}\n' > "$dir/pool/treehouse-state.json"
  fm_fake_treehouse_pool "$dir/fakebin" "$dir/pool/1/project" "$dir/pool/2/project"
  legacy="$dir/pool/1/.fm-slot-owner"
  printf 'task=pre-upgrade-holder\nhome=%s\n' "$dir/other-home" > "$legacy"
  write_record "$dir" "$id" "$dir/pool/1/project"

  set +e
  run_teardown "$dir" "$id" --force > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "teardown of a stale record on a legacy-claimed slot failed: $(cat "$dir/stderr")"
  ! grep -Fq "treehouse <return>" "$dir/runtime.log" \
    || fail "a stale record returned a slot its legacy claim gives to another task: $(cat "$dir/runtime.log")"
  assert_present "$dir/pool/1/project/sentinel" "the stale record reset the legacy claimant's copy"
  assert_contains "$(cat "$legacy")" "task=pre-upgrade-holder" "the stale record rewrote the legacy claim"
  assert_contains "$(cat "$dir/stderr")" "pre-upgrade-holder" "teardown did not name the legacy claimant"

  # The legacy claimant's own teardown returns its slot and drops the claim.
  write_record "$dir" pre-upgrade-holder "$dir/pool/1/project"
  : > "$dir/runtime.log"
  run_teardown "$dir" pre-upgrade-holder --force > "$dir/stdout" 2> "$dir/stderr" \
    || fail "the legacy claimant's teardown failed: $(cat "$dir/stderr")"
  grep -Fq "treehouse <return>" "$dir/runtime.log" \
    || fail "the legacy claimant's teardown did not return its slot: $(cat "$dir/runtime.log")"
  assert_absent "$legacy" "the legacy claimant's teardown left its spent claim"

  # A new claim replaces a stale legacy one rather than leaving two answers.
  printf 'task=older-holder\nhome=%s\n' "$dir/other-home" > "$dir/pool/2/.fm-slot-owner"
  lib "$dir" fm_treehouse_slot_owner_claim "$dir/pool/2/project" new-holder "$dir/home" \
    || fail "claiming a slot that carries a legacy claim failed"
  assert_absent "$dir/pool/2/.fm-slot-owner" "a new claim left the stale legacy claim behind"
  assert_equals mine "$(owner_state "$dir" "$dir/pool/2/project" new-holder)" \
    "the new claim does not name its task"

  # Outside that shape a stray file of the legacy name is not a claim: under a
  # templated root it would be one file every slot shares.
  dir=$(templated_case legacy-name-templated)
  printf 'task=someone-else\n' > "$dir/slots/.fm-slot-owner"
  assert_equals absent "$(owner_state "$dir" "$dir/slots/project-1" any-task)" \
    "a shared legacy-named file under a templated root was read as a claim"
  pass "legacy default-layout claims still protect their slot and are released by their own task"
}

test_default_and_templated_layouts_are_recognised
test_claims_on_sibling_templated_slots_stay_separate
test_membership_is_only_what_treehouse_answers
test_stale_record_never_returns_a_reassigned_templated_slot
test_templated_slot_teardown_holds_the_project_lock
test_templated_slot_named_by_two_records_refuses
test_unreadable_treehouse_refuses_teardown
test_own_templated_slot_returns_and_releases_only_its_claim
test_legacy_default_layout_claims_are_still_honoured
