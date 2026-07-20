# Git Commit Cheat Sheet — Conventional Commits

The de-facto standard for commit messages. Machine-parseable (enables auto-changelogs/versioning)
and reads cleanly in `git log`.

## Format
```
<type>(<scope>): <subject>

<body — optional: what & why, not how>

<footer — optional: BREAKING CHANGE / issue refs>
```
Example: `docs(cloudfront): add optional CDN wizard steps to 03 and 04`

## Types
| Type | Use for | Example |
|------|---------|---------|
| `feat` | a new feature/capability | `feat(argocd): expose UI via ALB ingress` |
| `fix` | a bug fix | `fix(alb): use v2.13.0 policy for SetRulePriorities` |
| `docs` | docs only | `docs(readme): add teardown order` |
| `chore` | tooling/deps/housekeeping | `chore(gitignore): ignore tfplan and app/` |
| `refactor` | code change, no behavior change | `refactor(eks): drop CRB, use access policy` |
| `ci` | pipelines/workflows | `ci: build backend+frontend, push to ECR` |
| `test` | tests only | `test(backend): add /healthz check` |
| `perf` | performance | `perf(cf): cache static assets at edge` |
| `build` | build system/images | `build(frontend): pin nginx-unprivileged 1.27` |
| `revert` | reverting a commit | `revert: feat(argocd): expose UI` |

For infra repos, `feat`/`fix`/`docs`/`chore`/`ci`/`refactor` cover ~95%.

## The 7 rules for the subject line
1. **`<type>(scope):` prefix** — scope optional but helpful (`eks`, `alb`, `route53`, `docs`, `ci`).
2. **Imperative mood** — "add", not "added"/"adds" (reads as "this commit will *add*…").
3. **Lowercase**, no trailing period.
4. **≤ 50 chars** for the subject.
5. **Blank line** before the body.
6. **Body wraps at ~72 chars**; explain *what & why*, not *how*.
7. **Footer** for `BREAKING CHANGE:` and issue refs (`Closes #12`).

## Examples (this repo)
```bash
git commit -m "feat(eks): provision cluster + bastion via terraform"
git commit -m "fix(alb): refresh IAM policy to v2.13.0 (SetRulePriorities)"
git commit -m "docs(cloudfront): add optional CDN steps to 03 and 04"
git commit -m "ci: build backend+frontend images and push to ECR"
git commit -m "chore: rename policy file to alb-controller-iam-policy.json"
git commit -m "refactor(eks): grant bastion admin via access policy, drop CRB"
```

Commit with a body (repeated `-m`):
```bash
git commit -m "fix(alb): use v2.13.0 IAM policy" \
           -m "The v2.9.2 policy omits elasticloadbalancing:SetRulePriorities, which the controller needs when a 2nd ingress joins a shared ALB group. Empty ingress ADDRESS + 403 until fixed." \
           -m "Refs: docs/03 §A2"
```

## Quick git command cheat sheet
```bash
git status                      # what changed
git diff                        # unstaged changes
git add -p                      # stage hunks interactively (clean, focused commits)
git commit -m "type(scope): subject"
git log --oneline --graph -10   # readable history
git commit --amend              # fix the LAST commit (before pushing only)
git restore --staged <file>     # unstage
git switch -c feat/my-thing     # new branch
```

## Optional: a commit template
```bash
# ~/.gitmessage.txt
# <type>(<scope>): <subject 50 chars>
#
# Why / what (72-char wrap)
#
# Footer: BREAKING CHANGE / Closes #

git config --global commit.template ~/.gitmessage.txt
```
Bare `git commit` then opens the editor pre-filled with the format reminder.

---

**Golden rule:** one logical change per commit — if your subject needs "and", it's probably two commits.
