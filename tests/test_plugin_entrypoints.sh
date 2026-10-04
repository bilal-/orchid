#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/lib/manifest.sh"
source "$REPO_ROOT/lib/resolver.sh"
export ORCHID_ROOT="$REPO_ROOT" HOME="$MACHINE_HOME"
unset ORCHID_ENGINES_DIR ORCHID_PLUGIN_PATH

# RED: trust and execution must refuse a different, symlinked or escaped entrypoint.
# GREEN: the fixed engine run and owned nested non-engine entrypoints still execute.
cd_scratch "$WORK" || exit 1
git init -q .
git commit -q --allow-empty -m root
mkdir -p .orchid/tasks
export ORCHID_REPO="$WORK"
ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"; export ORCHID_EPOCH
printf 'notify.channel=test\nnotify.plugin=entrypath\nsend_retry_max=5\n' > orchid.config
printf -- '---\nrun_status: running\nrun_id: r-entrypoints\n---\n# Roadmap\n' > .orchid/roadmap.md
"$ORCHID_BIN" trust unattended "$WORK" --reason 'entrypoint ownership fixture' || fail 'fixture unattended acknowledgement'

write_manifest() {
  printf 'manifest_version=1\nid=review/%s\nversion=0.1.0\nkind=%s\napi_version=1\ncapabilities=structured_text\nentrypoint=%s\n' "$2" "$3" "$4" > "$1/plugin.conf"
}
write_marker() {
  local target="$1" marker="$2" marker_q
  printf -v marker_q '%q' "$marker"
  printf '#!/bin/bash\nprintf "called\\n" >> %s\n' "$marker_q" > "$target"
  chmod +x "$target"
}
expect_refusal() {
  local label="$1"; shift
  local rc=0 output
  output="$("$@" 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || fail "$label must refuse (output: $output)"
}

engine="$WORK/.orchid/plugins/engines/entrypath-engine"; mkdir -p "$engine"
write_manifest "$engine" entrypath-engine engine declared-entry
write_marker "$engine/declared-entry" "$WORK/declared-marker"
write_marker "$WORK/external-engine" "$WORK/external-engine-marker"
ln -s "$WORK/external-engine" "$engine/run"
expect_refusal 'engine declaration different from run' manifest_validate "$engine"
expect_refusal 'trust of different declared engine executable' "$ORCHID_BIN" plugins trust "$engine"
# A pre-fix malformed pin must not escape through the resolver after upgrading.
engine_abs="$(_trust_canon_path "$engine")"
trust_store_set "$engine_abs" "$(plugin_digest "$engine")" || fail 'fixture old pin'
engine_rc=0
engine_exe="$(resolve_engine_exe entrypath-engine)" || engine_rc=$?
[ "$engine_rc" -ne 0 ] || fail 'resolver must refuse an old pin naming a different executable'
if [ "$engine_rc" -eq 0 ]; then "$engine_exe"; fi
[ ! -e "$WORK/external-engine-marker" ] || fail 'old pin must not execute external symlink target'
red_case 'engine trust and old-pin resolution reject declaration/run disagreement'

rm "$engine/run"
write_marker "$engine/run" "$WORK/regular-engine-marker"
write_manifest "$engine" entrypath-engine engine run
"$ORCHID_BIN" plugins trust --update "$engine" || fail 'regular engine trust'
engine_exe="$(resolve_engine_exe entrypath-engine)" || fail 'regular engine resolve'
"$engine_exe" || fail 'regular engine execute'
[ -s "$WORK/regular-engine-marker" ] || fail 'regular engine executed'
green_case 'regular declared engine run remains trusted and resolvable'

# A legacy pin for a declared run symlink is also denied at resolve time.
rm "$engine/run"; ln -s "$WORK/external-engine" "$engine/run"
trust_store_set "$engine_abs" "$(plugin_digest "$engine")" || fail 'fixture old symlink pin'
expect_refusal 'resolver of old symlink run pin' resolve_engine_exe entrypath-engine
red_case 'old symlinked-run pin cannot be adopted after upgrade'
rm "$engine/run"
write_marker "$engine/run" "$WORK/regular-engine-marker"
"$ORCHID_BIN" plugins trust --update "$engine" || fail 'repaired regular engine trust'
resolve_engine_exe entrypath-engine || fail 'repaired engine resolve'
green_case 'repairing run to a regular file restores explicit trust and resolution'

plugins="$WORK/channel-plugins"; notify="$plugins/notify/entrypath"
mkdir -p "$notify" "$WORK/external-channel"
export ORCHID_PLUGIN_PATH="$plugins"
write_marker "$plugins/notify/outside" "$WORK/outside-notify-marker"
write_manifest "$notify" entrypath notify ../outside
expect_refusal 'notify parent escape validation' manifest_validate "$notify"
expect_refusal 'notify parent escape trust' "$ORCHID_BIN" plugins trust "$notify"
expect_refusal 'notify parent escape conformance' "$ORCHID_BIN" plugins conform "$notify"
expect_refusal 'notify parent escape resolve' resolve_notify_dir entrypath
mkdir -p .orchid/runtime/outbox
printf 'queued message\n' > .orchid/runtime/outbox/q-escape
"$REPO_ROOT/runners/orchid-pump" > "$WORK/pump-escape.log" 2>&1 || { fail 'fresh-lease pump should retain refused notify attempt'; cat "$WORK/pump-escape.log"; }
[ ! -e "$WORK/outside-notify-marker" ] || fail 'pump must not execute escaped notify entrypoint'
[ -f .orchid/runtime/outbox/q-escape ] || fail 'refused send remains queued for repair'
red_case 'notify validation trust conformance resolution and actual pump refuse parent escape'

rm -rf .orchid/runtime/outbox
mkdir -p "$notify/helpers" .orchid/runtime/outbox
write_marker "$notify/helpers/send" "$WORK/nested-notify-marker"
write_manifest "$notify" entrypath notify helpers/send
manifest_validate "$notify" || fail 'owned nested notify manifest'
"$ORCHID_BIN" plugins trust --update "$notify" || fail 'owned nested notify trust'
"$ORCHID_BIN" plugins conform "$notify" || fail 'owned nested notify conformance'
resolve_notify_dir entrypath || fail 'owned nested notify resolve'
printf 'queued message\n' > .orchid/runtime/outbox/q-owned
"$REPO_ROOT/runners/orchid-pump" > "$WORK/pump-owned.log" 2>&1 || { fail 'fresh-lease owned notify pump'; cat "$WORK/pump-owned.log"; }
[ -s "$WORK/nested-notify-marker" ] || fail 'pump executes owned nested notify entrypoint'
[ ! -e .orchid/runtime/outbox/q-owned ] || fail 'successful owned send drains queue'
green_case 'owned nested notify regular file remains valid trusted conformant and executable'

write_marker "$WORK/external-channel/send" "$WORK/linked-notify-marker"
ln -s "$WORK/external-channel" "$notify/linked"
write_manifest "$notify" entrypath notify linked/send
expect_refusal 'notify external parent symlink validation' manifest_validate "$notify"
expect_refusal 'notify external parent symlink resolve' resolve_notify_dir entrypath
red_case 'nested external parent cannot redirect an otherwise regular entrypoint'
write_manifest "$notify" entrypath notify helpers/send
manifest_validate "$notify" || fail 'owned nested notify repair'
resolve_notify_dir entrypath || fail 'owned nested notify repaired resolve'
green_case 'returning entrypoint to its owned regular nested file restores validity'

# Conformance must not invoke an escaped hook even after reporting invalid manifest.
hook="$WORK/hook"; mkdir -p "$hook"
write_marker "$WORK/outside-hook" "$WORK/outside-hook-marker"
write_manifest "$hook" entrypath-hook hook ../outside-hook
expect_refusal 'hook escaped conformance' "$ORCHID_BIN" plugins conform "$hook"
[ ! -e "$WORK/outside-hook-marker" ] || fail 'conformance never invokes an escaped hook executable'
red_case 'conformance skips all executable probes for escaped hook entrypoint'

mk_good_stub() {  # dir
  mkdir -p "$1"
  printf 'manifest_version=1\nid=test/stub\nversion=0.1.0\nkind=engine\napi_version=1\ncapabilities=structured_text,workspace_read,workspace_write,shell,git\nentrypoint=run\n' \
    > "$1/plugin.conf"
  cat > "$1/run" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
req="${1:?usage: run <request.json>}"
operation="$(jq -r .operation "$req")"
output="$(jq -r .output "$req")"
job_id="$(jq -r .job_id "$req")"
task="$(jq -r .task "$req")"

write() {  # status extra-json
  local extra="${2:-}"; [ -n "$extra" ] || extra='{}'
  jq -n --arg job_id "$job_id" --arg task "$task" --arg operation "$operation" \
        --arg status "$1" --argjson extra "$extra" \
    '{contract:1, job_id:$job_id, task:$task, operation:$operation, status:$status} + $extra' \
    > "$output"
}

if [ "${ORCHID_DRYRUN:-0}" != "1" ]; then
  write failed '{}'
  exit 1
fi

case "$operation" in
  implement)       write ok '{"summary":"dryrun"}' ;;
  review|critique) write ok '{"verdict":"approve","scope_complete":true}' ;;
  orchestrate)     write ok '{"actions":[],"summary":"dryrun"}' ;;
  hook)            write ok '{"artifact":{},"summary":"dryrun"}' ;;
  *)
    write failed '{}'
    exit 1 ;;
esac
exit 0
EOF
  chmod +x "$1/run"
}


mk_good_stub "$WORK/owned-hook"
mkdir -p "$WORK/owned-hook/helpers"
mv "$WORK/owned-hook/run" "$WORK/owned-hook/helpers/run"
write_manifest "$WORK/owned-hook" entrypath-owned-hook hook helpers/run
"$ORCHID_BIN" plugins conform "$WORK/owned-hook" || fail 'owned nested hook conformance'
green_case 'owned nested regular hook executes and passes the full conformance battery'

[ "$FAILS" -eq 0 ]
