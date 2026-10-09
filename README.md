# gh bouncer

Stop drowning in low-effort pull requests. With bouncer installed, a pull request from someone outside your team waits until its author runs a thorough AI review of it, **in their own fork, on their own Anthropic API key**, against your rules. Passing pull requests reach you with a review attached. The rest are closed with reasons. You pay nothing, and there is no server: everything runs in GitHub Actions.

```
gh extension install gh-bouncer/gh-bouncer
```

## Maintainers

```
gh bouncer init
```

Run it in a clone of your repository (or pass `-R owner/repo`). You need write access. It opens a pull request that adds:

- `.github/workflows/bouncer.yml`, which runs the gate (`gh-bouncer/action@v1`) in your repository and the review job in forks.
- `.bouncer.yml`, the Repo Config: review agent (model, effort), gate (deadlines, review attempts, exemptions), pre-checks, guidance and Agent Rules. Edit `guidance` and the rules before merging: guidance about scope and what you never accept matters most. A broken **Required** rule (`hard: true`) fails a pull request; a broken **Advisory** rule (`hard: false`) is only reported to you. You can build the file at [gh-bouncer.com](https://gh-bouncer.com/#config). An existing `.bouncer.yml` is kept.

If bouncer is already installed with the current workflow, `gh bouncer init` says so and changes nothing. If your workflow differs from the current template, it opens an "Update bouncer workflow" pull request instead. If a setup pull request or `bouncer-setup` branch is already there, it points you to it. Run it in a fork and it names the original project to run it in.

The repository's owners, members and collaborators are exempt, and so are the bots under `exempt_users` and any pull request labeled `bouncer:skip`. Past contributors are **not** exempt by default: one merged pull request would exempt everything its author opens afterwards. Set `exempt_prior_contributors: true` if you want that. Reopening a bounced pull request yourself overrides the verdict.

Adding workflow files needs the `workflow` scope on your `gh` login. If it's missing, `gh bouncer init` tells you to run `gh auth refresh -s workflow`.

## Contributors

The bouncer's comment on your pull request tells you to run:

```
gh bouncer https://github.com/OWNER/REPO/pull/123
```

1. It checks there's something to review. A pull request that already passed, is exempt, isn't waiting for the bouncer, or is merged doesn't start a paid review. A bounced or closed one gets the reasons and the steps to try again.
2. It makes sure your fork has the project's workflow, syncing your fork's default branch with the project if needed. It never touches your pull request's branch.
3. It turns on GitHub Actions in your fork (forks start with them off). If GitHub insists on a one-time click in the browser, it tells you where.
4. The first time, it asks for your Anthropic API key (or takes `ANTHROPIC_API_KEY` from your environment) and stores it as the `ANTHROPIC_API_KEY` Actions secret in your fork. It tells you which model and effort the project reviews with, since every review is billed to your key, and refuses anything that isn't an Anthropic key. The key never appears on a command line and never leaves your fork's secrets.
5. It starts the review and follows it. If a review of the same commit is already running in your fork, or one already finished and was signed, it uses that one instead of paying for another: only the first signed review of a commit counts anyway.
6. When the review is signed, it comments `/bouncer check` so the bouncer looks right away, waits for the result and shows it: passed, or bounced with the reasons, the review attempts you have left, and how to try again.

If the review run fails (an invalid key, no credits left, rate limits...), it says why. Nothing was signed, so it doesn't use up a review attempt.

Ctrl-C only stops watching. The review keeps running in your fork, and the bouncer still posts the result on the pull request.

If your pull request's branch has the bouncer workflow, every push to it starts a new review on your key automatically. A branch made before the project installed bouncer doesn't have it: merge the project's default branch into it, or run `gh bouncer` again after each push. `gh bouncer` tells you which applies.

```
gh bouncer [<pr-url> | <owner/repo#number> | <number>] [flags]
gh bouncer init [-R OWNER/REPO]

  -R, --repo OWNER/REPO   Upstream repository, when giving just a number
      --set-key           Replace the ANTHROPIC_API_KEY secret in your fork
      --no-watch          Start the review and exit without waiting for the result
```

With no argument, it uses the pull request for your current branch.

Exit codes: `0` passed, nothing to do, or the result isn't in yet; `1` bounced, or something went wrong; `2` stopped with Ctrl-C; `4` not logged in to GitHub CLI. Colors follow `gh`: only on a terminal, and `NO_COLOR`, `CLICOLOR`, `CLICOLOR_FORCE` and `GH_FORCE_TTY` work as usual.

## How it works

The review and the gate live in [gh-bouncer/action](https://github.com/gh-bouncer/action), including why a contributor can't fake a passing review. `gh bouncer` reads the result from the bouncer's state comment on the pull request, the same one the gate reads and updates (only comments by `github-actions[bot]` count, and of those the first), so what it shows is what the gate decided.

## Development

`test/run.sh` runs the script against a stub `gh` (`test/gh`), offline. The stub answers with GitHub-shaped JSON and applies the script's `--jq` filters with `jq`, so it needs `jq` installed. CI also runs `shellcheck`.
