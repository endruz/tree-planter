#!/usr/bin/env bash

context_load() {
    GIT_TP_CURRENT_WORKTREE=$(git rev-parse --show-toplevel 2>/dev/null) || fail 'not inside a Git worktree'
    GIT_TP_CURRENT_WORKTREE=$(cd "$GIT_TP_CURRENT_WORKTREE" && pwd -P)
    GIT_TP_CURRENT_HEAD=$(git rev-parse HEAD 2>/dev/null) || fail 'unable to resolve current HEAD'
    GIT_TP_COMMON_DIR=$(git rev-parse --git-common-dir 2>/dev/null) || fail 'unable to locate Git common directory'
    case "$GIT_TP_COMMON_DIR" in
        /*) ;;
        *) GIT_TP_COMMON_DIR="$GIT_TP_CURRENT_WORKTREE/$GIT_TP_COMMON_DIR" ;;
    esac
    GIT_TP_COMMON_DIR=$(cd "$GIT_TP_COMMON_DIR" && pwd -P)
    GIT_TP_REPOSITORY=$(dirname "$GIT_TP_COMMON_DIR")
    GIT_TP_REPOSITORY=$(cd "$GIT_TP_REPOSITORY" && pwd -P)
    GIT_TP_REPOSITORY_NAME=$(basename "$GIT_TP_REPOSITORY")
    GIT_TP_HOOK_BASE=$GIT_TP_REPOSITORY
}
