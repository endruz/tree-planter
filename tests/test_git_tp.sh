#!/usr/bin/env bash
set -u

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
GIT_TP="$ROOT_DIR/bin/git-tp"
MODE=${1:-all}

failures=0

test_start() {
    test_name=$1
    test_home=$(mktemp -d)
    export HOME="$test_home"
    export TEST_REPO="$test_home/repo"
    mkdir -p "$TEST_REPO"
    git -C "$TEST_REPO" init -q
    git -C "$TEST_REPO" config user.email test@example.com
    git -C "$TEST_REPO" config user.name Test
    printf 'initial\n' > "$TEST_REPO/README"
    git -C "$TEST_REPO" add README
    git -C "$TEST_REPO" commit -qm initial
    printf '%s\n' "$test_name"
}

test_end() {
    rm -rf "$test_home"
}

assert_success() {
    if ! "$@" >/tmp/git-tp-test.stdout 2>/tmp/git-tp-test.stderr; then
        printf 'FAIL: expected success: %s\n' "$*" >&2
        cat /tmp/git-tp-test.stderr >&2
        failures=$((failures + 1))
    fi
}

assert_failure() {
    if "$@" >/tmp/git-tp-test.stdout 2>/tmp/git-tp-test.stderr; then
        printf 'FAIL: expected failure: %s\n' "$*" >&2
        failures=$((failures + 1))
    fi
}

assert_stdout_contains() {
    if ! grep -Fq -- "$1" /tmp/git-tp-test.stdout; then
        printf 'FAIL: stdout does not contain %s\n' "$1" >&2
        cat /tmp/git-tp-test.stdout >&2
        failures=$((failures + 1))
    fi
}

assert_stderr_contains() {
    if ! grep -Fq -- "$1" /tmp/git-tp-test.stderr; then
        printf 'FAIL: stderr does not contain %s\n' "$1" >&2
        cat /tmp/git-tp-test.stderr >&2
        failures=$((failures + 1))
    fi
}

assert_stderr_not_contains() {
    if grep -Fq -- "$1" /tmp/git-tp-test.stderr; then
        printf 'FAIL: stderr unexpectedly contains %s\n' "$1" >&2
        cat /tmp/git-tp-test.stderr >&2
        failures=$((failures + 1))
    fi
}

assert_file_contains() {
    if ! grep -Fq -- "$1" "$2"; then
        printf 'FAIL: %s does not contain %s\n' "$2" "$1" >&2
        [[ -f "$2" ]] && cat "$2" >&2
        failures=$((failures + 1))
    fi
}

write_config() {
    printf '%s\n' "$1" > "$HOME/.git-tp.toml"
}

run_git_tp() {
    (cd "$TEST_REPO" && "$GIT_TP" "$@")
}

run_git_tp_from() {
    (cd "$1" && "$GIT_TP" "${@:2}")
}

run_cli_tests() {
    test_start cli
    assert_success "$GIT_TP" --help
    assert_stdout_contains 'git tp add'
    grep -Fxq '  git tp update [--check]' /tmp/git-tp-test.stdout || {
        printf 'FAIL: top-level update help has inconsistent indentation\n' >&2
        failures=$((failures + 1))
    }
    grep -Fxq '  git tp update --version <version>' /tmp/git-tp-test.stdout || {
        printf 'FAIL: top-level versioned update help has inconsistent indentation\n' >&2
        failures=$((failures + 1))
    }
    assert_success "$GIT_TP" --version
    assert_stdout_contains 'git-tp '
    assert_success "$GIT_TP" add --help
    assert_stdout_contains 'git tp add'
    assert_success "$GIT_TP" remove --help
    assert_stdout_contains 'git tp remove'
    assert_success "$GIT_TP" cleanup --help
    assert_stdout_contains 'git tp cleanup'
    assert_failure run_git_tp add main
    assert_stderr_contains 'Configuration file not found'
    test_end
}

run_config_tests() {
    test_start config
    write_config '[worktree]
root = "~/worktrees"'
    assert_success run_git_tp add --create-branch feature/home-root
    home_root_target="$HOME/worktrees/$(basename "$TEST_REPO")/feature/home-root"
    [[ -d "$home_root_target" ]] || { printf 'FAIL: tilde root was not expanded\n' >&2; failures=$((failures + 1)); }
    assert_stderr_not_contains 'root must be a string'
    assert_stderr_not_contains 'unknown configuration'
    assert_stderr_not_contains 'root is required'

    write_config '[worktree]
root = 42'
    assert_failure "$GIT_TP" add main
    assert_stderr_contains 'root must be a string'

    write_config '[unknown]
root = "/tmp/worktrees"'
    assert_failure "$GIT_TP" add main
    assert_stderr_contains 'unknown configuration'

    write_config '[worktree]'
    assert_failure "$GIT_TP" add main
    assert_stderr_contains 'root is required'
    test_end
}

run_command_tests() {
    test_start commands
    worktree_root="$HOME/worktrees"
    write_config "[worktree]
root = \"$worktree_root\""

    assert_success run_git_tp add --create-branch feature/demo
    target="$worktree_root/$(basename "$TEST_REPO")/feature/demo"
    [[ -d "$target" ]] || { printf 'FAIL: target worktree was not created\n' >&2; failures=$((failures + 1)); }
    git -C "$TEST_REPO" show-ref --verify --quiet refs/heads/feature/demo || { printf 'FAIL: branch was not created\n' >&2; failures=$((failures + 1)); }

    remote_repo="$HOME/origin.git"
    git init --bare -q "$remote_repo"
    git -C "$TEST_REPO" remote add origin "$remote_repo"
    current_branch=$(git -C "$TEST_REPO" branch --show-current)
    git -C "$TEST_REPO" switch -q -c feature/remote-topic
    printf 'remote\n' >> "$TEST_REPO/README"
    git -C "$TEST_REPO" add README
    git -C "$TEST_REPO" commit -qm 'remote topic'
    git -C "$TEST_REPO" push -q origin feature/remote-topic
    git -C "$TEST_REPO" switch -q "$current_branch"
    git -C "$TEST_REPO" branch -Dq feature/remote-topic
    git -C "$TEST_REPO" fetch -q origin
    assert_success run_git_tp add feature/remote-topic
    assert_stderr_not_contains 'cd: --: invalid option'
    remote_target="$worktree_root/$(basename "$TEST_REPO")/feature/remote-topic"
    [[ -d "$remote_target" ]] || { printf 'FAIL: remote branch worktree was not created\n' >&2; failures=$((failures + 1)); }
    remote_head=$(git -C "$TEST_REPO" rev-parse refs/remotes/origin/feature/remote-topic)
    worktree_head=$(git -C "$remote_target" rev-parse HEAD)
    [[ "$worktree_head" == "$remote_head" ]] || { printf 'FAIL: worktree was not created from remote branch\n' >&2; failures=$((failures + 1)); }
    assert_success run_git_tp remove feature/remote-topic
    git -C "$TEST_REPO" branch -Dq feature/remote-topic
    git -C "$TEST_REPO" branch feature/remote-topic "$remote_head"
    assert_success run_git_tp add origin/feature/remote-topic
    assert_success run_git_tp remove feature/remote-topic
    git -C "$TEST_REPO" branch -Dq feature/remote-topic
    git -C "$TEST_REPO" branch feature/remote-topic "$current_branch"
    assert_failure run_git_tp add origin/feature/remote-topic
    assert_stderr_contains 'local branch already exists for remote branch'
    [[ ! -e "$remote_target" ]] || { printf 'FAIL: conflicting remote branch created a worktree\n' >&2; failures=$((failures + 1)); }
    git -C "$TEST_REPO" branch -Dq feature/remote-topic
    assert_success run_git_tp add origin/feature/remote-topic
    qualified_target="$worktree_root/$(basename "$TEST_REPO")/feature/remote-topic"
    [[ -d "$qualified_target" ]] || { printf 'FAIL: qualified remote branch worktree was not created\n' >&2; failures=$((failures + 1)); }
    qualified_head=$(git -C "$qualified_target" rev-parse HEAD)
    [[ "$qualified_head" == "$remote_head" ]] || { printf 'FAIL: qualified worktree was not created from remote branch\n' >&2; failures=$((failures + 1)); }
    git -C "$TEST_REPO" worktree list --porcelain | grep -Fq 'branch refs/heads/feature/remote-topic' || { printf 'FAIL: qualified remote branch created a detached worktree\n' >&2; failures=$((failures + 1)); }
    assert_success run_git_tp remove feature/remote-topic

    nested_remote_repo="$HOME/team-origin.git"
    git init --bare -q "$nested_remote_repo"
    git -C "$TEST_REPO" remote add team/origin "$nested_remote_repo"
    git -C "$TEST_REPO" push -q team/origin refs/remotes/origin/feature/remote-topic:refs/heads/feature/remote-topic
    git -C "$TEST_REPO" fetch -q team/origin
    git -C "$TEST_REPO" branch -Dq feature/remote-topic
    assert_failure run_git_tp add feature/remote-topic
    assert_stderr_contains 'ambiguous remote branch'
    assert_failure run_git_tp remove team/origin/feature/remote-topic
    assert_stderr_contains 'only local branch names'
    assert_success run_git_tp add team/origin/feature/remote-topic
    nested_target="$worktree_root/$(basename "$TEST_REPO")/feature/remote-topic"
    [[ -d "$nested_target" ]] || { printf 'FAIL: slash-containing remote name created the wrong worktree path\n' >&2; failures=$((failures + 1)); }
    git -C "$TEST_REPO" worktree list --porcelain | grep -Fq 'branch refs/heads/feature/remote-topic' || { printf 'FAIL: slash-containing remote name created the wrong local branch\n' >&2; failures=$((failures + 1)); }
    assert_success run_git_tp remove feature/remote-topic

    git -C "$TEST_REPO" remote remove origin
    git -C "$TEST_REPO" update-ref refs/remotes/origin/stale "$remote_head"
    assert_failure run_git_tp add origin/stale
    assert_stderr_contains 'unable to resolve remote branch: origin/stale'

    assert_success run_git_tp add --create-branch origin/topic
    assert_success run_git_tp remove origin/topic
    assert_success run_git_tp add --create-branch refs/heads/full-ref
    assert_failure run_git_tp remove refs/heads/full-ref
    assert_stderr_contains 'only local branch names'
    git -C "$TEST_REPO" worktree remove --force -- "$worktree_root/$(basename "$TEST_REPO")/refs/heads/full-ref"
    git -C "$TEST_REPO" branch -Dq -- refs/heads/full-ref

    assert_failure run_git_tp add --create-branch feature/demo
    assert_stderr_contains 'already used by worktree'

    mkdir -p "$TEST_REPO/hooks"
    printf '#!/usr/bin/env bash\nprintf "%%s|%%s|%%s|%%s|%%s\\n" "$GIT_TP_COMMAND" "$GIT_TP_REPOSITORY" "$GIT_TP_WORKTREE" "$GIT_TP_BRANCH" "$PWD" > "$GIT_TP_REPOSITORY/hook.log"\n' > "$TEST_REPO/hooks/post-add.sh"
    chmod +x "$TEST_REPO/hooks/post-add.sh"
    write_config "[worktree]
root = \"$worktree_root\"

[add.hooks]
post-hook = \"hooks/post-add.sh\""
    assert_success run_git_tp add --create-branch feature/second
    assert_file_contains 'add|' "$TEST_REPO/hook.log"
    assert_file_contains '|feature/second|' "$TEST_REPO/hook.log"

    assert_failure run_git_tp_from "$worktree_root/$(basename "$TEST_REPO")/feature/second" remove feature/second
    assert_stderr_contains 'while inside it'
    assert_failure run_git_tp remove master
    assert_stderr_contains 'main worktree'
    assert_failure run_git_tp remove origin/feature/second
    assert_stderr_contains 'only local branch names'

    existing_target="$worktree_root/$(basename "$TEST_REPO")/feature/existing"
    mkdir -p "$existing_target"
    assert_failure run_git_tp add --create-branch feature/existing
    assert_stderr_contains 'already exists'
    git -C "$TEST_REPO" show-ref --verify --quiet refs/heads/feature/existing && { printf 'FAIL: existing target created a branch\n' >&2; failures=$((failures + 1)); }

    second_repo="$HOME/other/repo"
    mkdir -p "$second_repo"
    git -C "$second_repo" init -q
    git -C "$second_repo" config user.email test@example.com
    git -C "$second_repo" config user.name Test
    printf second > "$second_repo/README"
    git -C "$second_repo" add README
    git -C "$second_repo" commit -qm initial
    assert_failure run_git_tp_from "$second_repo" add --create-branch feature/collision
    assert_stderr_contains 'repository directory name collision'

    printf dirty >> "$target/README"
    assert_failure run_git_tp remove feature/demo
    assert_stderr_contains 'unable to remove worktree'
    assert_success run_git_tp remove --force feature/demo
    [[ ! -e "$target" ]] || { printf 'FAIL: forced remove retained target\n' >&2; failures=$((failures + 1)); }

    test_end
}

run_legacy_git_tests() {
    test_start legacy-git
    worktree_root="$HOME/worktrees"
    write_config "[worktree]
root = \"$worktree_root\""

    real_git=$(command -v git)
    mkdir -p "$HOME/bin"
    cat > "$HOME/bin/git" <<EOF
#!/usr/bin/env bash
if [[ "\$*" == *"rev-parse --path-format=absolute --git-common-dir"* ]]; then
    printf '%s\n' --
    exit 0
fi
if [[ "\${FAIL_WORKTREE_LIST:-}" == 1 && "\$*" == *"worktree list --porcelain"* ]]; then
    exit 42
fi
if [[ "\${FAIL_REMOTE_LIST:-}" == 1 && "\$*" == "remote" ]]; then
    exit 43
fi
if [[ "\${FAIL_REMOTE_NAME:-}" == 1 && "\$*" == "remote" ]]; then
    exit 44
fi
if [[ "\${FAIL_REMOTE_AFTER_FIRST:-}" == 1 && "\$*" == "remote" ]]; then
    if [[ -e "$HOME/remote-query-seen" ]]; then
        exit 45
    fi
    : > "$HOME/remote-query-seen"
fi
exec "$real_git" "\$@"
EOF
    chmod +x "$HOME/bin/git"
    old_path=$PATH
    PATH="$HOME/bin:$PATH"

    nested_dir="$TEST_REPO/nested"
    mkdir -p "$nested_dir"
    assert_success run_git_tp_from "$nested_dir" add --create-branch feature/first--branch
    assert_success run_git_tp add --create-branch feature/second--branch
    first_target="$worktree_root/$(basename "$TEST_REPO")/feature/first--branch"
    second_target="$worktree_root/$(basename "$TEST_REPO")/feature/second--branch"
    [[ -d "$first_target" && -d "$second_target" ]] || { printf 'FAIL: same-repository worktrees were not both created\n' >&2; failures=$((failures + 1)); }
    assert_stderr_not_contains 'cd: --: invalid option'

    mkdir -p "$worktree_root/$(basename "$TEST_REPO")/unparseable"
    printf 'not a gitdir\n' > "$worktree_root/$(basename "$TEST_REPO")/unparseable/.git"
    assert_success run_git_tp add --create-branch feature/unparseable

    export FAIL_WORKTREE_LIST=1
    assert_failure run_git_tp add --create-branch feature/list-fails
    assert_stderr_contains 'unable to inspect worktrees'
    [[ ! -e "$worktree_root/$(basename "$TEST_REPO")/feature/list-fails" ]] || { printf 'FAIL: worktree-list failure created a target\n' >&2; failures=$((failures + 1)); }
    git -C "$TEST_REPO" show-ref --verify --quiet refs/heads/feature/list-fails && { printf 'FAIL: worktree-list failure created a branch\n' >&2; failures=$((failures + 1)); }
    assert_failure run_git_tp remove feature/first--branch
    assert_stderr_contains 'unable to inspect worktrees'
    [[ -d "$first_target" ]] || { printf 'FAIL: worktree-list failure removed a target\n' >&2; failures=$((failures + 1)); }
    unset FAIL_WORKTREE_LIST

    export FAIL_REMOTE_LIST=1
    assert_failure run_git_tp add --create-branch feature/remote-fails
    assert_stderr_contains 'unable to inspect remotes'
    unset FAIL_REMOTE_LIST

    git -C "$TEST_REPO" update-ref refs/remotes/origin/stale HEAD
    export FAIL_REMOTE_NAME=1
    assert_failure run_git_tp add origin/stale
    assert_stderr_contains 'unable to inspect remotes'
    unset FAIL_REMOTE_NAME

    export FAIL_REMOTE_AFTER_FIRST=1
    assert_failure run_git_tp add --create-branch feature/remote-query-fails
    assert_stderr_contains 'unable to inspect remotes'
    [[ ! -e "$worktree_root/$(basename "$TEST_REPO")/feature/remote-query-fails" ]] || {
        printf 'FAIL: remote query failure created a target\n' >&2
        failures=$((failures + 1))
    }
    unset FAIL_REMOTE_AFTER_FIRST

    second_repo="$HOME/other/other-repo"
    mkdir -p "$second_repo"
    git -C "$second_repo" init -q
    git -C "$second_repo" config user.email test@example.com
    git -C "$second_repo" config user.name Test
    printf second > "$second_repo/README"
    git -C "$second_repo" add README
    git -C "$second_repo" commit -qm initial
    ordinary_repo="$worktree_root/$(basename "$second_repo")/ordinary-repo"
    git init -q "$ordinary_repo"
    assert_failure run_git_tp_from "$second_repo" add --create-branch feature/collision
    assert_stderr_contains 'repository directory name collision'

    PATH=$old_path
    test_end
}

run_hook_cleanup_tests() {
    test_start hooks
    worktree_root="$HOME/worktrees"
    mkdir -p "$TEST_REPO/hooks"
    printf '#!/usr/bin/env bash\nprintf blocked > "$GIT_TP_REPOSITORY/pre-marker"\nexit 7\n' > "$TEST_REPO/hooks/pre-add.sh"
    chmod +x "$TEST_REPO/hooks/pre-add.sh"
    write_config "[worktree]
root = \"$worktree_root\"

[add.hooks]
pre-hook = \"hooks/pre-add.sh\""
    assert_failure run_git_tp add --create-branch blocked
    [[ -e "$TEST_REPO/pre-marker" ]] || { printf 'FAIL: pre-hook did not run\n' >&2; failures=$((failures + 1)); }
    git -C "$TEST_REPO" show-ref --verify --quiet refs/heads/blocked && { printf 'FAIL: pre-hook created a branch\n' >&2; failures=$((failures + 1)); }

    printf '#!/usr/bin/env bash\nexit 8\n' > "$TEST_REPO/hooks/post-fail.sh"
    chmod +x "$TEST_REPO/hooks/post-fail.sh"
    write_config "[worktree]
root = \"$worktree_root\"

[add.hooks]
post-hook = \"hooks/post-fail.sh\""
    assert_failure run_git_tp add --create-branch feature/post-fail
    post_fail_target="$worktree_root/$(basename "$TEST_REPO")/feature/post-fail"
    [[ -d "$post_fail_target" ]] || { printf 'FAIL: post-hook failure removed worktree\n' >&2; failures=$((failures + 1)); }

    printf '#!/usr/bin/env bash\nprintf "%%s|%%s|%%s\\n" "$GIT_TP_COMMAND" "$GIT_TP_STALE_COUNT" "$PWD" > "$GIT_TP_REPOSITORY/cleanup.log"\n' > "$TEST_REPO/hooks/cleanup.sh"
    chmod +x "$TEST_REPO/hooks/cleanup.sh"
    write_config "[worktree]
root = \"$worktree_root\"

[cleanup.hooks]
pre-hook = \"hooks/cleanup.sh\"
post-hook = \"hooks/cleanup.sh\""
    assert_success run_git_tp add --create-branch feature/stale
    stale_target="$worktree_root/$(basename "$TEST_REPO")/feature/stale"
    rm -rf "$stale_target"
    assert_success run_git_tp cleanup
    assert_file_contains 'cleanup|1|' "$TEST_REPO/cleanup.log"
    git -C "$TEST_REPO" worktree list --porcelain | grep -Fq 'feature/stale' && { printf 'FAIL: stale record remains\n' >&2; failures=$((failures + 1)); }
    test_end
}

run_nested_root_tests() {
    test_name=nested-root
    test_home=$(mktemp -d)
    export HOME="$test_home"
    export TEST_REPO="$test_home/repo"
    mkdir -p "$TEST_REPO"
    git init --separate-git-dir "$test_home/git" -q "$TEST_REPO"
    git -C "$TEST_REPO" config user.email test@example.com
    git -C "$TEST_REPO" config user.name Test
    printf 'initial\n' > "$TEST_REPO/README"
    git -C "$TEST_REPO" add README
    git -C "$TEST_REPO" commit -qm initial
    mkdir -p "$TEST_REPO/nested"
    printf '#!/usr/bin/env bash\nprintf "%%s|%%s|%%s|%%s|%%s\\n" "$GIT_TP_COMMAND" "$GIT_TP_REPOSITORY" "$GIT_TP_WORKTREE" "$GIT_TP_BRANCH" "$PWD" >> "$GIT_TP_REPOSITORY/hook.log"\n' > "$TEST_REPO/hooks.sh"
    chmod +x "$TEST_REPO/hooks.sh"
    worktree_root="$HOME/worktrees"
    write_config "[worktree]
root = \"$worktree_root\"

[add.hooks]
pre-hook = \"hooks.sh\""

    assert_success run_git_tp add --create-branch feature/nested-root
    target="$worktree_root/$(basename "$TEST_REPO")/feature/nested-root"
    assert_failure run_git_tp remove master
    assert_stderr_contains 'main worktree'
    assert_success run_git_tp remove feature/nested-root
    git -C "$TEST_REPO" branch -Dq feature/nested-root
    assert_success run_git_tp_from "$TEST_REPO/nested" add --create-branch feature/nested-root
    [[ -d "$target" ]] || { printf 'FAIL: root and nested invocations used different worktree slots\n' >&2; failures=$((failures + 1)); }
    hook_count=$(wc -l < "$TEST_REPO/hook.log")
    [[ "$hook_count" -eq 2 ]] || { printf 'FAIL: expected one hook invocation per working directory, got %s\n' "$hook_count" >&2; failures=$((failures + 1)); }
    root_hook=$(sed -n '1p' "$TEST_REPO/hook.log")
    nested_hook=$(sed -n '2p' "$TEST_REPO/hook.log")
    [[ "$root_hook" == "$nested_hook" ]] || {
        printf 'FAIL: root and nested invocations passed different hook parameters\nroot: %s\nnested: %s\n' "$root_hook" "$nested_hook" >&2
        failures=$((failures + 1))
    }
    linked_repo="$test_home/linked-repo"
    git init -q "$linked_repo"
    git -C "$linked_repo" config user.email test@example.com
    git -C "$linked_repo" config user.name Test
    printf 'linked\n' > "$linked_repo/README"
    git -C "$linked_repo" add README
    git -C "$linked_repo" commit -qm initial
    linked_worktree="$test_home/linked-worktree"
    git -C "$linked_repo" worktree add -q "$linked_worktree" -b linked-base
    mkdir -p "$linked_worktree/nested"
    printf '#!/usr/bin/env bash\nprintf "%%s|%%s|%%s|%%s|%%s\\n" "$GIT_TP_COMMAND" "$GIT_TP_REPOSITORY" "$GIT_TP_WORKTREE" "$GIT_TP_BRANCH" "$PWD" >> "$GIT_TP_REPOSITORY/hook.log"\n' > "$linked_repo/hooks.sh"
    chmod +x "$linked_repo/hooks.sh"
    write_config "[worktree]
root = \"$worktree_root\"

[add.hooks]
pre-hook = \"hooks.sh\"

[remove.hooks]
pre-hook = \"hooks.sh\""
    assert_success run_git_tp_from "$linked_worktree" add --create-branch feature/from-linked
    linked_target="$worktree_root/$(basename "$linked_repo")/feature/from-linked"
    assert_success run_git_tp_from "$linked_worktree" remove feature/from-linked
    git -C "$linked_repo" branch -Dq feature/from-linked
    assert_success run_git_tp_from "$linked_worktree/nested" add --create-branch feature/from-linked
    [[ -d "$linked_target" ]] || { printf 'FAIL: linked-worktree invocations used different repository slots\n' >&2; failures=$((failures + 1)); }
    assert_success run_git_tp_from "$linked_worktree/nested" remove feature/from-linked
    linked_root_add_hook=$(sed -n '1p' "$linked_repo/hook.log")
    linked_root_remove_hook=$(sed -n '2p' "$linked_repo/hook.log")
    linked_nested_add_hook=$(sed -n '3p' "$linked_repo/hook.log")
    linked_nested_remove_hook=$(sed -n '4p' "$linked_repo/hook.log")
    [[ "$linked_root_add_hook" == "$linked_nested_add_hook" ]] || {
        printf 'FAIL: linked-worktree root and nested add invocations passed different hook parameters\nroot: %s\nnested: %s\n' "$linked_root_add_hook" "$linked_nested_add_hook" >&2
        failures=$((failures + 1))
    }
    [[ "$linked_root_remove_hook" == "$linked_nested_remove_hook" ]] || {
        printf 'FAIL: linked-worktree root and nested remove invocations passed different hook parameters\nroot: %s\nnested: %s\n' "$linked_root_remove_hook" "$linked_nested_remove_hook" >&2
        failures=$((failures + 1))
    }
    test_end
}

run_update_integration_tests() {
    test_start update
    install_root="$HOME/tools"
    initial_archive="$HOME/git-tp-initial.tar.gz"
    tar -czf "$initial_archive" -C "$ROOT_DIR" bin lib install.sh
    GIT_TP_SOURCE_URL="file://$initial_archive" bash "$ROOT_DIR/install.sh" --install-dir "$install_root" \
        >"/tmp/git-tp-test.stdout" 2>"/tmp/git-tp-test.stderr" || {
        cat /tmp/git-tp-test.stderr >&2
        printf 'FAIL: unable to install git-tp for update integration\n' >&2
        failures=$((failures + 1))
        test_end
        return
    }

    updated_root="$HOME/updated-source"
    mkdir -p "$updated_root"
    cp -R "$ROOT_DIR/bin" "$ROOT_DIR/lib" "$updated_root/"
    cp "$ROOT_DIR/install.sh" "$updated_root/"
    sed -i 's/GIT_TP_VERSION="0.1.0"/GIT_TP_VERSION="0.2.0"/' "$updated_root/bin/git-tp"
    printf 'updated runtime\n' > "$updated_root/lib/git-tp/updated-marker"
    updated_archive="$HOME/git-tp-updated.tar.gz"
    tar -czf "$updated_archive" -C "$updated_root" bin lib install.sh
    printf 'file://%s\n' "$updated_archive" > "$install_root/.git-tp/current/source"

    run_installed_git_tp() {
        (cd "$TEST_REPO" && "$install_root/bin/git-tp" "$@")
    }

    worktree_root="$HOME/worktrees"
    write_config "[worktree]
root = \"$worktree_root\""
    assert_success run_installed_git_tp add --create-branch feature/before-update
    [[ -d "$worktree_root/$(basename "$TEST_REPO")/feature/before-update" ]] || {
        printf 'FAIL: installed git-tp did not create a real Git worktree before update\n' >&2
        failures=$((failures + 1))
    }

    current_release=$(readlink "$install_root/.git-tp/current")
    assert_success run_installed_git_tp update
    assert_stdout_contains 'git-tp updated: 0.1.0 -> 0.2.0'
    [[ "$($install_root/bin/git-tp --version)" == 'git-tp 0.2.0' ]] || {
        printf 'FAIL: installed git-tp did not switch to the updated release\n' >&2
        failures=$((failures + 1))
    }
    [[ -f "$install_root/.git-tp/current/lib/git-tp/updated-marker" ]] || {
        printf 'FAIL: updated release runtime is missing\n' >&2
        failures=$((failures + 1))
    }
    [[ "$(readlink "$install_root/.git-tp/current")" != "$current_release" ]] || {
        printf 'FAIL: successful update did not switch the release pointer\n' >&2
        failures=$((failures + 1))
    }
    assert_success run_installed_git_tp add --create-branch feature/after-update
    [[ -d "$worktree_root/$(basename "$TEST_REPO")/feature/after-update" ]] || {
        printf 'FAIL: updated git-tp did not create a real Git worktree\n' >&2
        failures=$((failures + 1))
    }

    current_release=$(readlink "$install_root/.git-tp/current")
    printf 'file://%s/missing.tar.gz\n' "$HOME" > "$install_root/.git-tp/current/source"
    assert_failure run_installed_git_tp update
    assert_stderr_contains 'unable to download source'
    [[ "$(readlink "$install_root/.git-tp/current")" == "$current_release" ]] || {
        printf 'FAIL: failed real-Git update changed the release pointer\n' >&2
        failures=$((failures + 1))
    }
    [[ "$($install_root/bin/git-tp --version)" == 'git-tp 0.2.0' ]] || {
        printf 'FAIL: failed update damaged the installed git-tp version\n' >&2
        failures=$((failures + 1))
    }
    assert_success run_installed_git_tp add --create-branch feature/after-failed-update
    test_end
}

case "$MODE" in
    cli)
        run_cli_tests
        ;;
    config)
        run_config_tests
        ;;
    commands)
        run_command_tests
        ;;
    hooks)
        run_hook_cleanup_tests
        ;;
    nested-root)
        run_nested_root_tests
        ;;
    legacy-git)
        run_legacy_git_tests
        ;;
    update)
        run_update_integration_tests
        ;;
    all)
        run_cli_tests
        run_config_tests
        run_command_tests
        run_hook_cleanup_tests
        run_nested_root_tests
        run_legacy_git_tests
        run_update_integration_tests
        ;;
    *)
        printf 'unknown test mode: %s\n' "$MODE" >&2
        exit 2
        ;;
esac

rm -f /tmp/git-tp-test.stdout /tmp/git-tp-test.stderr
if (( failures > 0 )); then
    printf '%d test assertion(s) failed\n' "$failures" >&2
    exit 1
fi
printf 'PASS\n'
