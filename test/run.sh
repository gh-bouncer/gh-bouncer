#!/usr/bin/env bash
# Tests gh-bouncer against a stub gh. Usage: test/run.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="$HERE/../gh-bouncer"
pass=0; fail=0

run() {  # run <name> <expect-exit> <expect-in-output> [setup flags...] -- [args...]
  local name="$1" want_code="$2" want_text="$3"; shift 3
  STUB="$(mktemp -d)"; export STUB
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do touch "$STUB/$1"; shift; done
  [ "${1:-}" = "--" ] && shift
  out="$(PATH="$HERE:$PATH" GH_BOUNCER_POLL_SECONDS=0 ANTHROPIC_API_KEY="${KEY:-}" "$BIN" "$@" </dev/null 2>&1)"
  code=$?
  if [ "$code" = "$want_code" ] && grep -qF -- "$want_text" <<<"$out" && check "$name"; then
    pass=$((pass + 1)); echo "ok   $name"
  else
    fail=$((fail + 1)); echo "FAIL $name (exit $code)"; printf "%s\n" "$out" | sed "s/^/     /"; # shellcheck disable=SC2001
    echo "     calls:"; sed 's/^/       /' "$STUB/calls.log"
  fi
  rm -rf "$STUB"
}
check() {  # extra per-test assertions
  case "$1" in
    happy) grep -q '^pr comment 7 -R up/repo --body /bouncer check$' "$STUB/calls.log" &&
           grep -q 'inputs\[pr\]=7' "$STUB/calls.log" && grep -q 'ref=main' "$STUB/calls.log" ;;
    key-from-env) [ "$(cat "$STUB/secret_value")" = "sk-ant-test" ] && ! grep -q 'sk-ant-test' "$STUB/calls.log" ;;
    enable) [ -f "$STUB/wf_enabled" ] ;;
    sync) [ -f "$STUB/synced" ] ;;
    poll) grep -q 'runs/555' <<<"$out" ;;
    no-watch) ! grep -q '^run watch' "$STUB/calls.log" ;;
    init) [ -f "$STUB/put_workflow" ] && [ -f "$STUB/put_config" ] &&
          grep -q 'bmFtZTogQm91bmNlcgo=' "$STUB/calls.log" &&
          grep -q '^pr create -R me/proj --base main --head bouncer-setup --title Add bouncer' "$STUB/calls.log" &&
          grep -qF -- "- \`.bouncer.yml\`" "$STUB/calls.log" ;;
    init-keep-config) [ -f "$STUB/put_workflow" ] && [ ! -f "$STUB/put_config" ] ;;
    init-no-scope) [ -f "$STUB/branch_deleted" ] ;;
    *) true ;;
  esac
}

run happy          0 "Done. The gate is checking"       has_secret -- https://github.com/up/repo/pull/7
run short-ref      0 "Done."                             has_secret -- up/repo#7
run number-only    0 "Done."                             has_secret -- 7
run current-branch 0 "Done."                             has_secret --
KEY=sk-ant-test run key-from-env 0 "Stored ANTHROPIC_API_KEY" -- https://github.com/up/repo/pull/7
run no-key-no-tty  1 "no ANTHROPIC_API_KEY secret"       -- https://github.com/up/repo/pull/7
run enable         0 "Turned on the review workflow"     has_secret wf_disabled -- https://github.com/up/repo/pull/7
run cannot-enable  1 "https://github.com/fork/repo/actions" has_secret wf_disabled wf_cannot_enable -- https://github.com/up/repo/pull/7
run sync           0 "Syncing fork/repo's main"          has_secret no_workflow -- https://github.com/up/repo/pull/7
HEAD_REF=main run no-sync-own-branch 1 "won't be changed automatically" has_secret no_workflow -- https://github.com/up/repo/pull/7
run poll           0 "Done."                             has_secret dispatch_204 -- https://github.com/up/repo/pull/7
run no-watch       0 "picks it up within 10 minutes"     has_secret -- --no-watch https://github.com/up/repo/pull/7
run run-fails      1 "--log-failed"                      has_secret run_fails -- https://github.com/up/repo/pull/7
run closed         1 "is closed. Reopen it first"        pr_closed -- https://github.com/up/repo/pull/7
run from-upstream  1 "Bouncer reviews pull requests from forks" pr_from_upstream -- https://github.com/up/repo/pull/7
run no-pr-branch   1 "no pull request found"             no_branch_pr --
run bad-url        1 "not a pull request URL"            -- https://github.com/up/repo/issues/7
run bad-number     1 "is not a pull request number"      -- abc

run init             0 "Opened https://github.com/me/proj/pull/1" -- init
run init-explicit    0 "Opened"                            -- init -R me/proj
run init-keep-config 0 "Keeping your existing .bouncer.yml" has_config -- init
run init-no-scope    1 "gh auth refresh -s workflow"       no_workflow_scope -- init
run init-not-admin   1 "need admin rights"                 not_admin -- init
run init-fork        1 "is a fork"                         is_fork -- init
run init-branch      1 "If it already exists, merge or delete"   branch_exists -- init

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
