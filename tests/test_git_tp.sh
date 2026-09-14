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
    assert_failure run_git_tp add main
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
    legacy-git)
        run_legacy_git_tests
        ;;
    all)
        run_cli_tests
        run_config_tests
        run_command_tests
        run_hook_cleanup_tests
        run_legacy_git_tests
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
