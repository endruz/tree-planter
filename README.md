# git-tp

`git-tp` is a small Linux Bash helper for managing linked Git worktrees. Git discovers the executable as the `git tp` subcommand when its directory is on `PATH`.

## Install

Put `bin/git-tp` on `PATH`, for example:

```bash
export PATH="$HOME/.local/bin:$PATH"
ln -s "$PWD/bin/git-tp" "$HOME/.local/bin/git-tp"
```

The runtime requires Bash, Git, and `realpath`.

## Configuration

Create `~/.git-tp.toml`:

```toml
[worktree]
root = "/home/user/worktrees"

[add.hooks]
pre-hook = "hooks/pre-add.sh"
post-hook = "/home/user/hooks/post-add.sh"

[remove.hooks]
pre-hook = "hooks/pre-remove.sh"
post-hook = "hooks/post-remove.sh"

[cleanup.hooks]
pre-hook = "hooks/pre-cleanup.sh"
post-hook = "hooks/post-cleanup.sh"
```

The worktree path is `<root>/<repository-name>/<branch>`. A leading `~/` is expanded; other environment-variable expansion is not performed. Relative hook paths are resolved from the main repository root. Hook files must be executable.

## Commands

```text
git tp add [--create-branch] <branch>
git tp remove [-f|--force] <branch>
git tp cleanup
```

- `add` creates a linked worktree from a local or remote-tracking branch. For a remote-tracking branch, it creates a corresponding local branch from the remote commit before creating the worktree. With `--create-branch`, a missing branch is created from the caller's current `HEAD`; in an interactive terminal, `add` can also ask for confirmation before doing so.
- An unqualified remote branch name must match at most one remote; use `remote/branch` when multiple remotes contain the same branch.
- `remove` only accepts local branch names and targets their linked worktrees; it protects the main worktree and uncommitted changes unless `--force` is used.
- `cleanup` prunes Git's stale worktree records and never deletes an existing worktree directory.

## Hooks

Hooks receive no positional arguments. They run in these directories:

- add pre: main repository root
- add post: new worktree root
- remove pre: target worktree root
- remove post: main repository root
- cleanup pre/post: main repository root

The following environment variables are exported:

```text
GIT_TP_COMMAND=add|remove|cleanup
GIT_TP_REPOSITORY=/absolute/path/to/repository
GIT_TP_WORKTREE=/absolute/path/to/worktree
GIT_TP_BRANCH=feature/login
GIT_TP_FORCE=true|false
GIT_TP_STALE_COUNT=2
```

`GIT_TP_STALE_COUNT` is provided for cleanup hooks.

## Tests

Run the real-Git integration suite with:

```bash
bash tests/test_git_tp.sh
```

Pull requests targeting `main` run the same suite in GitHub Actions.
Configure the `Tests/test` check as a required status check in the `main` branch protection rules before allowing merges.
