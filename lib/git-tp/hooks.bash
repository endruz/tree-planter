#!/usr/bin/env bash

hook_run() {
    local hook=$1 working_directory=$2 worktree=$3 branch=$4 force=$5 stale_count=$6
    [[ -n "$hook" ]] || return 0
    [[ -f "$hook" ]] || fail "hook is not a file: $hook"
    [[ -x "$hook" ]] || fail "hook is not executable: $hook"
    (
        cd "$working_directory" || exit 1
        export GIT_TP_COMMAND GIT_TP_REPOSITORY GIT_TP_WORKTREE GIT_TP_BRANCH GIT_TP_FORCE
        GIT_TP_COMMAND=$GIT_TP_ACTIVE_COMMAND
        GIT_TP_REPOSITORY=$GIT_TP_REPOSITORY
        GIT_TP_WORKTREE=$worktree
        GIT_TP_BRANCH=$branch
        GIT_TP_FORCE=$force
        if [[ -n "$stale_count" ]]; then
            export GIT_TP_STALE_COUNT
            GIT_TP_STALE_COUNT=$stale_count
        else
            unset GIT_TP_STALE_COUNT
        fi
        "$hook"
    )
}
