#!/usr/bin/env bash
# Tests gh-bouncer against a stub gh (test/gh). Usage: test/run.sh [part of a test name]
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="$HERE/../gh-bouncer"
ONLY="${1:-}"
command -v jq >/dev/null || { echo "test/run.sh needs jq: the stub applies the script's --jq filters with it"; exit 1; }
pass=0 fail=0

URL=https://github.com/up/repo/pull/7
DONE="The bouncer is checking the signed review now."

# run <name> <expected exit> <expected text> [stub flags...] -- [gh bouncer args...]
# Also: NOT=<text that must not appear>, KEY=<ANTHROPIC_API_KEY>, ENVS="VAR=value ...",
# and the stub's S_STATE, S_VERDICT, S_LABELS, S_ANNOTATION, HEAD_REF.
run() {
  local name="$1" want_code="$2" want_text="$3"; shift 3
  [ -z "$ONLY" ] || [[ "$name" == *"$ONLY"* ]] || return 0
  setup "$@"; shift "$SHIFT"
  # shellcheck disable=SC2086  # ENVS is a list of assignments
  out="$(env -u NO_COLOR -u CLICOLOR -u CLICOLOR_FORCE -u GH_FORCE_TTY ${ENVS:-} PATH="$HERE:$PATH" \
    GH_BOUNCER_POLL_SECONDS=0 GH_BOUNCER_VERDICT_SECONDS=0 GH_BOUNCER_VERDICT_TRIES=3 ANTHROPIC_API_KEY="${KEY:-}" \
    "$BIN" "$@" </dev/null 2>&1)"
  verdict "$name" "$want_code" "$want_text" $?
}
setup() {  # flag files for the stub, up to --
  STUB="$(mktemp -d)"; export STUB
  : >"$STUB/calls.log"
  SHIFT=0
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do touch "$STUB/$1"; shift; SHIFT=$((SHIFT + 1)); done
  [ $# -eq 0 ] || SHIFT=$((SHIFT + 1))
}
verdict() {
  local name="$1" want_code="$2" want_text="$3" code="$4" why=""
  [ "$code" = "$want_code" ] || why="exit $code, want $want_code"
  grep -qF -- "$want_text" <<<"$out" || why="${why:+$why; }missing: $want_text"
  if [ -n "${NOT:-}" ] && grep -qF -- "$NOT" <<<"$out"; then why="${why:+$why; }has: $NOT"; fi
  if grep -q '^UNEXPECTED\|^LEAK' "$STUB/calls.log"; then why="${why:+$why; }bad gh call"; fi
  [ -n "$why" ] || check "$name" || why="check failed"
  if [ -z "$why" ]; then
    pass=$((pass + 1)); echo "ok   $name"
  else
    fail=$((fail + 1)); echo "FAIL $name ($why)"; printf '%s\n' "$out" | sed 's/^/     /'
    echo "     gh calls:"; sed 's/^/       /' "$STUB/calls.log"
  fi
  rm -rf "$STUB"
}
called() { grep -q -- "$1" "$STUB/calls.log"; }
has() { grep -qF -- "$1" <<<"$out"; }
dispatches() { grep -c 'dispatches' "$STUB/calls.log"; }

check() {  # extra assertions per test
  case "$1" in
    pass) called "dispatches -f ref=main -f inputs\[pr\]=7 " && called '^pr comment 7 -R up/repo --body /bouncer check$' ;;
    number-repo-flag) ! called '^repo view' ;;
    key-from-env|key-trimmed) [ "$(cat "$STUB/secret_value")" = "sk-ant-test" ] && ! called 'sk-ant' ;;
    key-not-a-key|no-key-no-tty|set-key-no-tty) [ ! -f "$STUB/secret_value" ] && [ "$(dispatches)" = 0 ] ;;
    set-key-env) [ "$(cat "$STUB/secret_value")" = "sk-ant-new" ] ;;
    enable) [ -f "$STUB/wf_enabled" ] ;;
    sync) [ -f "$STUB/synced" ] && has "$DONE" ;;
    fork-of-fork-no-workflow|sync-own-branch) ! called 'merge-upstream' ;;
    dispatch-204) called '^run watch 555 ' ;;
    no-watch) ! called '^run watch' && ! called '^pr comment' ;;
    merged|closed*|already-passed|skip-label|not-waiting|override|open-*|fail-label-stale|from-upstream|fork-deleted)
      [ "$(dispatches)" = 0 ] && ! called 'secret' ;;
    no-color|no-color-env|no-color-clicolor) ! grep -q $'\e' <<<"$out" ;;
    color-forced|color-force-tty) grep -q $'\e\\[32m✓' <<<"$out" ;;
    help) has "LEARN MORE" && has "EXIT CODES" ;;
    init) [ -f "$STUB/put_workflow" ] && [ -f "$STUB/put_config" ] &&
          called 'content=bmFtZTogQm91bmNlcgo=' &&
          grep -qx 'Add bouncer' "$STUB/pr_create" &&
          grep -qF -- "- \`.bouncer.yml\`: the Repo Config (review agent" "$STUB/pr_create" &&
          grep -qF "Past contributors are not" "$STUB/pr_create" &&
          ! grep -qi "prior contributors.* are exempt\|past contributors and" "$STUB/pr_create" &&
          has "Next:" && has "2. Merge the pull request to turn bouncer on" ;;
    init-explicit) ! called '^repo view' ;;
    init-keep-config) [ -f "$STUB/put_workflow" ] && [ ! -f "$STUB/put_config" ] && grep -qF ".bouncer.yml\`: kept" "$STUB/pr_create" ;;
    init-no-scope) [ -f "$STUB/branch_deleted" ] ;;
    init-installed|init-setup-pr|init-setup-branch|init-fork|init-no-write) [ ! -f "$STUB/branch_created" ] ;;
    init-update) grep -qx 'Update bouncer workflow' "$STUB/pr_create" && called 'sha=wfsha' ;;
    *) true ;;
  esac
}

# --- the happy path, and how a pull request is named
run pass                0 "$DONE"                                             has_secret -- "$URL"
run short-ref           0 "$DONE"                                           has_secret -- up/repo#7
run number-only         0 "$DONE"                                           has_secret -- 7
run number-repo-flag    0 "$DONE"                                           has_secret -- 7 -R up/repo
run current-branch      0 "$DONE"                                           has_secret --
run bad-url             1 "Not a pull request URL"                            -- https://github.com/up/repo/issues/7
run bad-number          1 "isn't a pull request number"                       -- abc
run two-prs             1 "one pull request at a time"                        -- 1 2
run no-pr-branch        1 "No pull request found for the current branch."     no_branch_pr --

# --- gh conventions: help, version, flags, errors, exit codes, colors
run help                0 "USAGE"                                             -- --help
run version             0 "gh bouncer version 0.2.0"                          -- --version
run unknown-flag        1 "Unknown flag: --frobnicate"                        -- --frobnicate "$URL"
run not-logged-in       4 "Run gh auth login, then try again."                no_auth -- "$URL"
run not-logged-in-branch 4 "You're not logged in to GitHub CLI."              no_auth --
run offline             1 "Couldn't connect to GitHub."                       offline -- "$URL"
run pr-404              1 "Pull request up/repo#7 doesn't exist, or you can't see it." pr_404 -- "$URL"
run G25-fork-api-fails  1 "GitHub returned an error: Bad Gateway (HTTP 502)"  head_api_fails -- "$URL"
run no-color            0 "$DONE"                                           has_secret -- "$URL"
ENVS="CLICOLOR_FORCE=1" run color-forced 0 "$DONE"                          has_secret -- "$URL"
ENVS="GH_FORCE_TTY=1" run color-force-tty 0 "$DONE"                         has_secret -- "$URL"
ENVS="GH_FORCE_TTY=1 NO_COLOR=1" run no-color-env 0 "$DONE"                 has_secret -- "$URL"
ENVS="GH_FORCE_TTY=1 CLICOLOR=0" run no-color-clicolor 0 "$DONE"            has_secret -- "$URL"

# --- before spending anything: nothing to run, or nothing that can run
S_STATE=none run closed 1 "up/repo#7 is closed."                              pr_closed -- "$URL"
run from-upstream       1 "Bouncer reviews pull requests from forks"          pr_from_upstream -- "$URL"
run fork-deleted        1 "The fork behind up/repo#7 was deleted"             fork_deleted -- "$URL"
run not-fork-owner      1 "You need admin rights on fork/repo"                fork_not_admin -- "$URL"

# --- setting up the fork
run enable              0 "Turned on the review workflow in fork/repo"        has_secret wf_disabled -- "$URL"
run cannot-enable       1 "https://github.com/fork/repo/actions"              has_secret wf_disabled wf_cannot_enable -- "$URL"
run sync                0 "Synced fork/repo:main with up/repo"                has_secret no_workflow -- "$URL"
HEAD_REF=main run sync-own-branch 1 "it's your pull request's branch"         has_secret no_workflow -- "$URL"
run upstream-no-workflow 1 "up/repo has no .github/workflows/bouncer.yml"     has_secret no_workflow upstream_no_workflow -- "$URL"

# --- the key
KEY=sk-ant-test run key-from-env 0 "Saved ANTHROPIC_API_KEY as an Actions secret in fork/repo" -- "$URL"
run no-key-no-tty       1 "Your fork has no ANTHROPIC_API_KEY secret yet."    -- "$URL"
KEY=sk-ant-new run set-key-env 0 "Saved ANTHROPIC_API_KEY"                     has_secret -- --set-key "$URL"

# --- starting the review, or following one: never pay twice for a commit
run dispatch-204        0 "$DONE"                                           has_secret dispatch_204 -- "$URL"
NOT="/bouncer check" run no-watch 0 "within about 10 minutes of the review finishing" has_secret -- --no-watch "$URL"

# --- when the review run fails: say why, and that nothing was used up
run run-fails           1 "--log-failed"                                      has_secret run_fails -- "$URL"

# --- the result, from the bouncer's state once it has checked the signed review

# --- gh bouncer init (maintainers)
run init                0 "Opened https://github.com/me/proj/pull/1"          -- init
run init-explicit       0 "Opened"                                            -- init -R me/proj
run init-keep-config    0 "Kept your existing .bouncer.yml"                   has_config -- init
run init-no-scope       1 "gh auth refresh -s workflow"                       no_workflow_scope -- init
run init-no-write       1 "You need write access to me/proj"                  no_write -- init
run init-fork           1 "gh bouncer init -R up/proj"                        is_fork -- init
run init-installed      0 "Bouncer is already installed in me/proj"           installed_same -- init
run init-update         0 "Opened"                                            installed_old -- init
run init-setup-pr       1 "There's already a bouncer setup pull request: https://github.com/me/proj/pull/1" branch_exists setup_pr_open -- init
run init-setup-branch   1 "already exists in me/proj, with no open pull request" branch_exists -- init
run init-not-repo       1 "Not in a clone of a GitHub repository."            not_repo -- init
run init-not-logged-in  4 "gh auth login"                                     no_auth -- init
run init-unknown-arg    1 "Unknown argument: foo"                             -- init foo

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
