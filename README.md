# gh bouncer

Run the [bouncer](https://github.com/pr-bouncer/bouncer) review for your pull request with one command. The review runs in your fork, on your own Anthropic API key, and the project's gate picks up the signed result.

```
gh extension install pr-bouncer/gh-bouncer
gh bouncer https://github.com/OWNER/REPO/pull/123
```

## What it does

1. Finds your pull request and checks it comes from a fork you own.
2. Makes sure your fork has the project's review workflow, syncing your fork's default branch if it's out of date (never your pull request's branch).
3. Turns the workflow on. Forks start with workflows switched off. If GitHub insists on a one-time click in the browser, it tells you where.
4. Stores your key as the `ANTHROPIC_API_KEY` secret in your fork, from your environment or a hidden prompt. It never leaves GitHub's secret store after that, and it's never passed on the command line.
5. Starts the review, follows it until it finishes, and comments `/bouncer check` so the gate looks right away.

Once the key is stored, every push to your pull request is reviewed automatically, so you only need `gh bouncer` again after reopening a closed pull request.

## Usage

```
gh bouncer [<pr-url> | <owner/repo#number> | <number>] [flags]

  -R, --repo OWNER/REPO   Upstream repository, when giving just a number
      --set-key           Replace the ANTHROPIC_API_KEY secret in your fork
      --no-watch          Start the review and exit without waiting for it
```

With no argument, it uses the pull request for your current branch.

## Development

`test/run.sh` runs the script against a stub `gh`. CI also runs `shellcheck`.
