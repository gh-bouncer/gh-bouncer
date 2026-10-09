#!/usr/bin/env bash
# Tests gh-bouncer against a stub gh (test/gh). Usage: test/run.sh [part of a test name]
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="$HERE/../gh-bouncer"
ONLY="${1:-}"
command -v jq >/dev/null || { echo "test/run.sh needs jq: the stub applies the script's --jq filters with it"; exit 1; }
pass=0 fail=0

URL=https://github.com/up/repo/pull/7
SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
OLD=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
REPORT="$URL#issuecomment-2002"
# shellcheck disable=SC2016  # the backticks are Markdown
REASONS='"reasons":["`not-duplicate` (Required, 92% confidence): Retry with backoff already landed in #377 (src/http.py:40).","`correct` (Required, 88% confidence): Calls http.retry(), which doesn'"'"'t exist in this codebase."]'
# st <status> [<more JSON fields>]: the bouncer's state for the current commit
st() { printf '{"v":1,"sha":"%s","status":"%s","left":2,"report":"%s","model":"claude-opus-5-5","effort":"high"%s}' "$SHA" "$1" "$REPORT" "${2:+,$2}"; }
BOUNCED="$(st fail "$REASONS")"

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
# ctrl_c <name> <gh call to wait for> <expected text> [stub flags...] -- [args...]: press Ctrl-C
# (SIGINT to the whole process group, as a terminal does) once that call has started.
ctrl_c() {
  local name="$1" when="$2" want_text="$3" pid code; shift 3
  [ -z "$ONLY" ] || [[ "$name" == *"$ONLY"* ]] || return 0
  setup "$@"; shift "$SHIFT"
  set -m
  env -u NO_COLOR -u CLICOLOR -u CLICOLOR_FORCE -u GH_FORCE_TTY PATH="$HERE:$PATH" GH_BOUNCER_POLL_SECONDS=0 \
    GH_BOUNCER_VERDICT_SECONDS=30 ANTHROPIC_API_KEY= "$BIN" "$@" </dev/null >"$STUB/out" 2>&1 &
  pid=$!
  set +m
  for _ in $(seq 100); do grep -q -- "^$when" "$STUB/calls.log" 2>/dev/null && break; sleep 0.05; done
  sleep 0.3
  kill -INT -- "-$pid"
  wait "$pid"; code=$?
  out="$(cat "$STUB/out")"
  verdict "$name" 2 "$want_text" "$code"
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
    pass) called "dispatches -f ref=main -f inputs\[pr\]=7 -f inputs\[upstream\]=up/repo" &&
          called '^pr comment 7 -R up/repo --body /bouncer check$' &&
          has "Review: $REPORT" && has "usually reviewed automatically, on your key" &&
          has "Deadline 2026-10-11 12:00 UTC · 3 review attempts left" ;;
    number-repo-flag) ! called '^repo view' ;;
    key-from-env|key-trimmed) [ "$(cat "$STUB/secret_value")" = "sk-ant-test" ] && ! called 'sk-ant' ;;
    key-not-a-key|no-key-no-tty|set-key-no-tty) [ ! -f "$STUB/secret_value" ] && [ "$(dispatches)" = 0 ] ;;
    set-key-env) [ "$(cat "$STUB/secret_value")" = "sk-ant-new" ] ;;
    secret-list-fails) ! called '^secret set' && has "Passed." ;;
    enable) [ -f "$STUB/wf_enabled" ] ;;
    sync) [ -f "$STUB/synced" ] && has "Passed." ;;
    sync-lag) [ -f "$STUB/synced" ] ;;
    fork-of-fork) called 'inputs\[upstream\]=up/repo' ;;
    fork-of-fork-no-workflow|sync-own-branch) ! called 'merge-upstream' ;;
    dispatch-old-workflow) [ "$(dispatches)" = 2 ] && [ "$(grep dispatches "$STUB/calls.log" | tail -n 1 | grep -c upstream)" = 0 ] ;;
    dispatch-204) called '^run watch 555 ' ;;
    no-watch) ! called '^run watch' && ! called '^pr comment' ;;
    branch-no-workflow) called 'contents/.github/workflows/bouncer.yml -f ref=feature' &&
                        has "run gh bouncer again after each push" ;;
    follow-push-run) [ "$(dispatches)" = 0 ] && called '^run watch 3131 ' && has "Passed." ;;
    follow-manual-run) [ "$(dispatches)" = 0 ] && called '^run watch 3232 ' ;;
    other-pr-run|skipped-push-run|config-changed-rerun) [ "$(dispatches)" = 1 ] && called '^run watch 4242 ' ;;
    reuse-signed-run) [ "$(dispatches)" = 0 ] && ! called '^run watch' && called '^pr comment' && has "Passed." ;;
    followed-run-skipped) called '^run watch 3131 ' && called '^run watch 4242 ' && [ "$(dispatches)" = 1 ] && has "Passed." ;;
    outdated-syncs) called 'merge-upstream' && [ "$(dispatches)" = 1 ] ;;
    run-out-of-credits) has "Nothing was signed, so this doesn't use up a review attempt." &&
                        has "gh run view 4242 -R fork/repo --log-failed" && ! called '^pr comment' ;;
    run-fails-after-signing) has "but the review was signed, so it counts" ;;
    bounce) has "  • \`not-duplicate\` (Required, 92% confidence)" && has "To try again (2 review attempts left):" &&
            has "Don't force-push" && has "2. Reopen the pull request." && has "3. Run gh bouncer $URL" && has "Full review: $REPORT" ;;
    bounce-open) has "A new review usually starts on your key" && has "still asks for one, run gh bouncer again." ;;
    verdict-timeout|comment-fails) has "The result will appear on $URL" ;;
    closed-bounced) has "Don't force-push" && has "  • \`correct\`" && [ "$(dispatches)" = 0 ] ;;
    merged|closed*|already-passed|skip-label|not-waiting|override|open-*|fail-label-stale|from-upstream|fork-deleted|draft-pr)
      [ "$(dispatches)" = 0 ] && ! called 'secret' ;;
    forged-state) [ "$(dispatches)" = 1 ] ;;
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
run pass                0 "Passed. up/repo#7 is ready for a maintainer."     has_secret -- "$URL"
run short-ref           0 "Passed."                                           has_secret -- up/repo#7
run number-only         0 "Passed."                                           has_secret -- 7
run number-repo-flag    0 "Passed."                                           has_secret -- 7 -R up/repo
run current-branch      0 "Passed."                                           has_secret --
run bad-url             1 "Not a pull request URL"                            -- https://github.com/up/repo/issues/7
run bad-number          1 "isn't a pull request number"                       -- abc
run two-prs             1 "one pull request at a time"                        -- 1 2
run no-pr-branch        1 "No pull request found for the current branch."     no_branch_pr --

# --- gh conventions: help, version, flags, errors, exit codes, colors
run help                0 "USAGE"                                             -- --help
run version             0 "gh bouncer version 0.3.0"                          -- --version
run unknown-flag        1 "Unknown flag: --frobnicate"                        -- --frobnicate "$URL"
run not-logged-in       4 "Run gh auth login, then try again."                no_auth -- "$URL"
run not-logged-in-branch 4 "You're not logged in to GitHub CLI."              no_auth --
run offline             1 "Couldn't connect to GitHub."                       offline -- "$URL"
run pr-404              1 "Pull request up/repo#7 doesn't exist, or you can't see it." pr_404 -- "$URL"
run G25-fork-api-fails  1 "GitHub returned an error: Bad Gateway (HTTP 502)"  head_api_fails -- "$URL"
run no-color            0 "Passed."                                           has_secret -- "$URL"
ENVS="CLICOLOR_FORCE=1" run color-forced 0 "Passed."                          has_secret -- "$URL"
ENVS="GH_FORCE_TTY=1" run color-force-tty 0 "Passed."                         has_secret -- "$URL"
ENVS="GH_FORCE_TTY=1 NO_COLOR=1" run no-color-env 0 "Passed."                 has_secret -- "$URL"
ENVS="GH_FORCE_TTY=1 CLICOLOR=0" run no-color-clicolor 0 "Passed."            has_secret -- "$URL"

# --- before spending anything: nothing to run, or nothing that can run
run merged              0 "up/repo#7 is already merged. Nothing to do."       pr_merged -- "$URL"
S_STATE=none run closed 1 "up/repo#7 is closed."                              pr_closed -- "$URL"
S_STATE="$BOUNCED" run closed-bounced 1 "up/repo#7 was bounced and closed."   pr_closed -- "$URL"
S_STATE="${BOUNCED/$SHA/$OLD}" run closed-bounced-pushed-since 1 "Reopen the pull request (you've already pushed new commits)." pr_closed -- "$URL"
S_STATE="$(st exhausted '"left":0')" run closed-exhausted 1 "used all its review attempts and was closed" pr_closed -- "$URL"
S_STATE="$(st expired)" run closed-expired 1 "no review arrived before the deadline" pr_closed -- "$URL"
S_STATE="$(st wrong_base '"base":"dev"')" run closed-wrong-base 1 "its base branch (dev) isn't one this project takes" pr_closed -- "$URL"
S_LABELS=bouncer:pass S_STATE="$(st pass)" run already-passed 0 "up/repo#7 already passed the bouncer review. Nothing to do." -- "$URL"
S_LABELS='' S_STATE="$(st draft)" run draft-pr 0 "up/repo#7 is a draft, so the bouncer isn't asking for a review yet." -- "$URL"
S_LABELS=bouncer:pass S_STATE="$(st pass | sed "s/$SHA/$OLD/")" run passed-earlier-commit 0 "That was for an earlier commit." -- "$URL"
S_LABELS=bouncer:skip run skip-label 0 "A maintainer labeled up/repo#7 bouncer:skip"  -- "$URL"
S_LABELS='' S_STATE=none run not-waiting 0 "isn't waiting for a bouncer review"  -- "$URL"
S_LABELS='' S_STATE="$(st override)" run override 0 "set the bouncer's verdict aside" -- "$URL"
S_LABELS=bouncer:fail S_STATE="$BOUNCED" run open-bounced 1 "up/repo#7 was bounced. It stays open" -- "$URL"
S_LABELS=bouncer:fail S_STATE="$(st wrong_base)" run open-wrong-base 1 "Change its base branch" -- "$URL"
S_LABELS=bouncer:fail S_STATE="${BOUNCED/$SHA/$OLD}" run fail-label-stale 0 "hasn't caught up" -- "$URL"
S_STATE="$(st quarantined)" run unknown-status 0 "doesn't know"              has_secret -- "$URL"
run forged-state        0 "Passed."                                           has_secret forged -- "$URL"
run state-on-later-pages 0 "Passed."                                          has_secret state_on_later_pages -- "$URL"
run from-upstream       0 "doesn't need a bouncer review"                     pr_from_upstream -- "$URL"
run fork-deleted        1 "The fork behind up/repo#7 was deleted"             fork_deleted -- "$URL"
run not-fork-owner      1 "You need admin rights on fork/repo"                fork_not_admin -- "$URL"

# --- setting up the fork
run enable              0 "Turned on GitHub Actions in fork/repo"             has_secret wf_disabled -- "$URL"
run cannot-enable       1 "https://github.com/fork/repo/actions"              has_secret wf_disabled wf_cannot_enable -- "$URL"
run sync                0 "Synced fork/repo:main with up/repo"                has_secret no_workflow -- "$URL"
NOT="turn on Actions" run sync-lag 0 "Passed."                                has_secret no_workflow sync_lag -- "$URL"
run sync-lag-forever    1 "GitHub hasn't picked up the bouncer workflow"      has_secret no_workflow sync_lag_forever -- "$URL"
run sync-no-scope       1 "gh auth refresh -s workflow"                       has_secret no_workflow sync_no_scope -- "$URL"
run sync-conflict       1 "commits that conflict with up/repo"                has_secret no_workflow sync_conflict -- "$URL"
HEAD_REF=main run sync-own-branch 1 "it's your pull request's branch"         has_secret no_workflow -- "$URL"
run upstream-no-workflow 1 "up/repo has no .github/workflows/bouncer.yml"     has_secret no_workflow upstream_no_workflow -- "$URL"
run fork-of-fork        0 "Passed."                                           has_secret fork_of_fork -- "$URL"
run fork-of-fork-no-workflow 1 "fork/repo is a fork of mid/repo, not of up/repo" has_secret fork_of_fork no_workflow -- "$URL"
NOT="reviewed automatically, on your key" run branch-no-workflow 0 "new commits aren't reviewed automatically" has_secret branch_no_workflow -- "$URL"

# --- the key
KEY=sk-ant-test run key-from-env 0 "Saved ANTHROPIC_API_KEY as an Actions secret in fork/repo" -- "$URL"
KEY="  sk-ant-test " run key-trimmed 0 "Saved ANTHROPIC_API_KEY"               -- "$URL"
KEY=hunter2 run key-not-a-key 1 "doesn't look like an Anthropic API key (they start with sk-ant-), so it wasn't saved" -- "$URL"
run no-key-no-tty       1 "Your fork has no ANTHROPIC_API_KEY secret yet."    -- "$URL"
run set-key-no-tty      1 "--set-key needs a terminal"                        has_secret -- --set-key "$URL"
KEY=sk-ant-new run set-key-env 0 "Saved ANTHROPIC_API_KEY"                     has_secret -- --set-key "$URL"
run secret-list-fails   0 "Couldn't check your fork's secrets"                has_secret secret_list_fails -- "$URL"

# --- starting the review, or following one: never pay twice for a commit
run dispatch-204        0 "Passed."                                           has_secret dispatch_204 -- "$URL"
run dispatch-old-workflow 0 "Passed."                                         has_secret dispatch_old_workflow -- "$URL"
run dispatch-old-workflow-fork-of-fork 1 "too old to review a pull request from a fork of a fork" has_secret dispatch_old_workflow fork_of_fork -- "$URL"
run dispatch-no-trigger 1 "is out of date, so gh bouncer can't start it"      has_secret dispatch_no_trigger -- "$URL"
NOT="/bouncer check" run no-watch 0 "within about 10 minutes of the review finishing" has_secret -- --no-watch "$URL"
run follow-push-run     0 "already running in your fork. Following it"        has_secret run_push_running -- "$URL"
run follow-manual-run   0 "Following it instead of starting another"          has_secret run_dispatch_running -- "$URL"
run other-pr-run        0 "Started the review"                                has_secret run_other_pr_running -- "$URL"
run reuse-signed-run    0 "Your fork already reviewed this commit"            has_secret run_push_signed -- "$URL"
run skipped-push-run    0 "Started the review"                                has_secret run_push_skipped -- "$URL"
run followed-run-skipped 0 "That run didn't review your pull request"         has_secret run_push_running followed_run_skips -- "$URL"
S_STATE="$(st pending '"note":"config_changed"')" run config-changed-rerun 0 "doesn't count: the maintainers changed the bouncer settings" has_secret run_push_signed -- "$URL"
S_STATE="$(st pending '"note":"outdated"')" run outdated-syncs 0 "Your fork's bouncer workflow is out of date. Syncing" has_secret -- "$URL"
ctrl_c ctrl-c-watching "run watch" "Stopped watching. The review is still running: https://github.com/fork/repo/actions/runs/4242" has_secret slow_watch -- "$URL"

# --- when the review run fails: say why, and that nothing was used up
run run-out-of-credits  1 "The review didn't finish: Your Anthropic account is out of credits." has_secret run_fails -- "$URL"
NOT="Process completed" run run-fails-no-annotation 1 "The review didn't finish" has_secret run_fails no_annotation -- "$URL"
run run-cancelled       1 "cancelled before it was signed"                    has_secret run_cancelled -- "$URL"
run run-fails-after-signing 0 "Passed."                                       has_secret run_fails_after_signing -- "$URL"
run run-view-fails      1 "Couldn't connect to GitHub."                       has_secret run_view_fails -- "$URL"

# --- the result, from the bouncer's state once it has checked the signed review
S_VERDICT="$BOUNCED" run bounce 1 "Bounced. up/repo#7 was closed."            has_secret -- "$URL"
S_VERDICT="$BOUNCED" run bounce-open 1 "Bounced. up/repo#7 stays open for a maintainer to confirm." has_secret keep_open -- "$URL"
S_VERDICT="$(st fail '"left":0')" run bounce-last 1 "No review attempts left."  has_secret -- "$URL"
run verdict-timeout     0 "The bouncer hasn't posted the result yet."         has_secret verdict_pending -- "$URL"
S_VERDICT="$(st pass | sed "s/$SHA/$OLD/")" NOT="Passed" run verdict-other-commit 0 "The bouncer hasn't posted the result yet." has_secret -- "$URL"
S_VERDICT="$(st pending '"note":"config_changed"')" run verdict-config-changed 1 "Your review doesn't count: the maintainers changed" has_secret -- "$URL"
S_VERDICT="$(st pending '"note":"verify_error"')" run verdict-verify-error 0 "couldn't verify your signed review yet" has_secret -- "$URL"
S_VERDICT="$(st quarantined)" run verdict-unknown 0 "which this version of gh bouncer doesn't know" has_secret -- "$URL"
S_STATE='{"sha":"'$SHA'","status":"pending"}' S_VERDICT='{"sha":"'$SHA'","status":"pass"}' run verdict-old-bouncer 0 "Passed." has_secret -- "$URL"
run comment-fails       0 "Couldn't ask the bouncer to check right away"      has_secret comment_fails -- "$URL"
ctrl_c ctrl-c-waiting "pr comment" "Stopped waiting. The bouncer posts the result on $URL" has_secret verdict_pending -- "$URL"

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
