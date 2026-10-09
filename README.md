# gh bouncer

Stop drowning in low-effort pull requests. With bouncer installed, a pull request from someone outside your team waits until its author runs a thorough AI review of it, **in their own fork, on their own Anthropic API key**, against your rules. Passing pull requests reach you with a review attached. The rest are closed with reasons. You pay nothing, and there is no server: everything runs in GitHub Actions.

```
gh extension install gh-bouncer/gh-bouncer
```

## Maintainers

```
gh bouncer init
```

Run it in a clone of your repository (or pass `-R owner/repo`). It opens a pull request that adds:

- `.github/workflows/bouncer.yml`, which runs the gate (`gh-bouncer/action@v1`) in your repository and the review job in forks.
- `.bouncer.yml`: model, effort, deadlines and rules. Edit the rules and `guidance` before merging. Guidance about scope and what you never accept matters most.

Members, collaborators, prior contributors and listed bots are exempt, and so is any pull request labeled `bouncer:skip`. Reopening a bounced pull request yourself overrides the verdict.

Adding workflow files needs the `workflow` permission on your `gh` login. If it's missing, `gh bouncer init` tells you to run `gh auth refresh -s workflow`.

## Contributors

The bouncer's comment on your pull request tells you to run:

```
gh bouncer https://github.com/OWNER/REPO/pull/123
```

1. It checks the pull request comes from a fork you own.
2. It makes sure your fork has the project's workflow, syncing your fork's default branch if it's out of date. It never touches your pull request's branch.
3. It turns the workflow on. Forks start with workflows switched off. If GitHub insists on a one-time click in the browser, it tells you where.
4. It stores your key as the `ANTHROPIC_API_KEY` secret in your fork, from your environment or a hidden prompt. The key is never passed on the command line and never leaves your fork's secrets.
5. It starts the review, follows it until it finishes, and comments `/bouncer check` so the gate looks right away.

After that, every push to your pull request is reviewed automatically. You only need `gh bouncer` again after reopening a closed pull request.

```
gh bouncer [<pr-url> | <owner/repo#number> | <number>] [flags]
gh bouncer init [-R OWNER/REPO]

  -R, --repo OWNER/REPO   Upstream repository, when giving just a number
      --set-key           Replace the ANTHROPIC_API_KEY secret in your fork
      --no-watch          Start the review and exit without waiting for it
```

With no argument, it uses the pull request for your current branch.

## How it works

The review and the gate live in [gh-bouncer/action](https://github.com/gh-bouncer/action), including why a contributor can't fake a passing review.

## Development

`test/run.sh` runs the script against a stub `gh` (`test/gh`), offline. The stub answers with GitHub-shaped JSON and applies the script's `--jq` filters with `jq`, so it needs `jq` installed. CI also runs `shellcheck`.
