# Security

The trust model, every known attack on bouncer (including this extension), what stops each one, what's still open, and the rules for future changes are in one place: [gh-bouncer/action SECURITY.md](https://github.com/gh-bouncer/action/blob/main/SECURITY.md).

What this extension itself must keep true:

- **The API key never leaks.** It's read without echo, passed to `gh secret set` on stdin, and stripped from the environment of every other `gh` call. It never goes on argv or into output.
  - Any new `gh` call must go through the same wrapper, and tests must keep checking that the key isn't on any command line.
- **Contributors never pay twice for one commit.** Before dispatching a review, the extension checks the bouncer's state, any running review of the same commit, and any existing attestation of the same subject in the fork.
  - New ways of starting a review must run the same checks first.
- **The verdict shown is the bouncer's.** The terminal shows only the gate's state for the current commit, read from the first state comment by `github-actions[bot]`, never the review run's own summary.
  - Don't print a verdict from the run, and don't read state comments from any other author.

**Reporting a vulnerability:** use GitHub's private vulnerability reporting on [gh-bouncer/action](https://github.com/gh-bouncer/action/security). Don't open a public issue.
