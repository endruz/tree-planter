# git-tp

`git-tp` is a small Linux Bash helper for managing linked Git worktrees. Git discovers the executable as the `git tp` subcommand when its directory is on `PATH`.

## Install

Install the latest source from GitHub into `~/.local`:

```bash
curl -fsSL https://raw.githubusercontent.com/endruz/tree-planter/main/install.sh | sh
```

The installer requires Bash, Git, `curl`, `tar`, and these standard utilities:
`realpath`, `mktemp`, `find`, `cp`, `mv`, `rm`, `dirname`, `chmod`, `mkdir`,
`wc`, `awk`, `grep`, `readlink`, `ln`, `cat`, and `rmdir`.
It installs:

```text
~/.local/bin/git-tp
~/.local/.git-tp/current -> versions/<release>/
```

Each version directory contains the executable, runtime files, and source
metadata. Updates switch the `current` symlink atomically; `bin/git-tp` remains
the stable command entry point.

If `~/.local/bin` is not already on `PATH`, the installer prints the exact
`export` command to add it. Verify the installation with:

```bash
git tp --version
git tp -h
```

Git reserves `git tp --help` for its man-page lookup. Use `git tp -h` or
`git-tp --help` to print the command help directly.

To install into another prefix, use either form:

```bash
GIT_TP_INSTALL_DIR="$HOME/tools" sh install.sh
sh install.sh --install-dir "$HOME/tools"
```

Running the installer again updates an existing installation. Supported
installations record their source in `~/.local/.git-tp/current/source`; update
them without locating the repository again:

```bash
git tp update
git tp update --check
git tp update --version 0.1.0
```

The source must be a release-aware archive URL, or a URL containing
`{version}` for `--version`. An update downloads and stages a complete release,
then atomically switches the `current` symlink so the executable, runtime, and
source metadata move together. Download, archive, permission, or source
validation failures leave the previous installation active. Configuration,
hooks, and unrelated files are outside the versioned runtime and are preserved.
Archives larger than 10 MiB, files larger than 10 MiB, or archives containing
more than 50 MiB of files are rejected. Only one install or update may run at a
time for an installation prefix.

A forced termination such as `SIGKILL` can leave the lock directory behind.
The busy message reports its owner PID and lock path. Check that the process is
not currently installing or updating that prefix before clearing a stale lock:

```bash
lock="$HOME/.local/.git-tp.lock"
pid=$(cat "$lock/pid" 2>/dev/null || true)
if [ -n "$pid" ]; then ps -p "$pid" -o pid=,args=; fi
# After confirming that no installer is active for this prefix:
rm "$lock/pid"
rmdir "$lock"
```

For a custom prefix, replace `~/.local` with that prefix. Do not remove a lock
while its installer process is still active.

Installations missing both `.git-tp/current/source` and the legacy
`.git-tp-source` metadata cannot be updated through `git tp update`; rerun the
supported installer first. Installations with only the legacy metadata can be
updated and are migrated to the versioned layout.

Legacy installations without a bundled installer must run `git tp update` once
before `git tp update --check` is available. The check fails closed rather than
executing an installer script from the source archive.

To uninstall the default installation:

```bash
rm -f "$HOME/.local/bin/git-tp"
rm -rf "$HOME/.local/.git-tp"
rm -rf "$HOME/.local/lib/git-tp"
rm -f "$HOME/.local/.git-tp-source"
```

The current installer follows `main`. A versioned installer URL alone does not
select the source archive, so set both URLs to the same release tag to install a
fixed version:

```bash
version=0.2.0
source_url="https://github.com/endruz/tree-planter/archive/refs/tags/v$version.tar.gz"
installer_url="https://raw.githubusercontent.com/endruz/tree-planter/v$version/install.sh"
GIT_TP_SOURCE_URL="$source_url" sh -c 'curl -fsSL "$1" | sh' sh "$installer_url"
```

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
git tp update [--check]
git tp update --version <version>
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
Configure the `Tests / test` check (workflow `Tests`, job `test`) as a required status check in the `main` branch protection rules before allowing merges.
