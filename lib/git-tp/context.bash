#!/usr/bin/env bash

context_load() {
    local main_worktree git_dir
    GIT_TP_CURRENT_WORKTREE=$(git rev-parse --show-toplevel 2>/dev/null) || fail 'not inside a Git worktree'
    GIT_TP_CURRENT_WORKTREE=$(path_absolute "$GIT_TP_CURRENT_WORKTREE")
    GIT_TP_CURRENT_HEAD=$(git rev-parse HEAD 2>/dev/null) || fail 'unable to resolve current HEAD'
    GIT_TP_COMMON_DIR=$(git -C "$GIT_TP_CURRENT_WORKTREE" rev-parse --git-common-dir 2>/dev/null) || fail 'unable to locate Git common directory'
    GIT_TP_COMMON_DIR=$(path_absolute "$GIT_TP_COMMON_DIR" "$GIT_TP_CURRENT_WORKTREE")
    git_dir=$(git -C "$GIT_TP_CURRENT_WORKTREE" rev-parse --git-dir 2>/dev/null) || fail 'unable to locate Git directory'
    git_dir=$(path_absolute "$git_dir" "$GIT_TP_CURRENT_WORKTREE")
    main_worktree=$(git_main_worktree) || fail 'unable to inspect worktrees'
    if [[ "$git_dir" == "$GIT_TP_COMMON_DIR" ]]; then
        GIT_TP_MAIN_REPOSITORY=$GIT_TP_CURRENT_WORKTREE
    else
        GIT_TP_MAIN_REPOSITORY=$(cd "$main_worktree" && pwd -P) || fail 'unable to resolve main worktree'
    fi
    GIT_TP_REPOSITORY=$GIT_TP_MAIN_REPOSITORY
    GIT_TP_REPOSITORY_NAME=$(basename "$GIT_TP_REPOSITORY")
    GIT_TP_HOOK_BASE=$GIT_TP_REPOSITORY
}
