#!/usr/bin/env bash

command_add() {
    local create_branch=false branch arg remote_ref
    while (($# > 0)); do
        arg=$1
        shift
        case "$arg" in
            --create-branch) create_branch=true ;;
            --help|-h) print_command_help add; return 0 ;;
            -*) fail "unknown add option: $arg" ;;
            *)
                [[ -z ${branch:-} ]] || fail 'add accepts exactly one branch'
                branch=$arg
                ;;
        esac
    done
    [[ -n ${branch:-} ]] || fail 'add requires a branch'

    path_validate_branch "$branch"
    remote_ref=''
    if ! git show-ref --verify --quiet "refs/heads/$branch"; then
        if remote_ref=$(git_remote_branch_ref "$branch" 2>/dev/null); then
            :
        else
            case "$?" in
                2) fail "ambiguous remote branch: $branch; use a qualified remote/branch name" ;;
                3) fail 'unable to inspect remotes' ;;
                *) remote_ref='' ;;
            esac
        fi
        if [[ -n "$remote_ref" ]]; then
            branch=$(git_remote_branch_name "$remote_ref") || fail "unable to resolve remote branch: $branch"
        fi
    fi
    if git_branch_in_use "$branch"; then
        fail "branch is already used by worktree: $GIT_TP_BRANCH_WORKTREE"
    else
        case "$?" in
            2) fail 'unable to inspect worktrees' ;;
        esac
    fi
    path_resolve_worktree "$branch"

    local new_branch=false
    if [[ -n "$remote_ref" ]] && ! git show-ref --verify --quiet "refs/heads/$branch"; then
        new_branch=true
    elif ! git_branch_exists "$branch"; then
        if [[ "$create_branch" != true ]]; then
            if [[ -t 0 && -t 1 ]]; then
                printf 'Create it from current HEAD? [y/N] '
                read -r answer || answer=''
                case "$answer" in
                    y|yes) ;;
                    *) fail "branch does not exist: $branch" ;;
                esac
            else
                fail "branch does not exist; use --create-branch: $branch"
            fi
        fi
        new_branch=true
    fi

    GIT_TP_ACTIVE_COMMAND=add
    hook_run "$GIT_TP_ADD_PRE_HOOK" "$GIT_TP_REPOSITORY" "$GIT_TP_TARGET_WORKTREE" "$branch" false '' || fail "add pre-hook failed"

    mkdir -p "$(dirname "$GIT_TP_TARGET_WORKTREE")" || fail "unable to create target parent directory"
    if [[ "$new_branch" == true ]]; then
        if ! git_create_branch "$branch" "$remote_ref"; then
            fail "unable to create branch: $branch"
        fi
    fi
    if ! git_add_worktree "$GIT_TP_TARGET_WORKTREE" "$branch"; then
        if [[ "$new_branch" == true ]]; then
            git_delete_branch "$branch" >/dev/null 2>&1 || true
        fi
        fail "unable to add worktree: $GIT_TP_TARGET_WORKTREE"
    fi

    if ! hook_run "$GIT_TP_ADD_POST_HOOK" "$GIT_TP_TARGET_WORKTREE" "$GIT_TP_TARGET_WORKTREE" "$branch" false ''; then
        fail 'add post-hook failed; worktree was retained'
    fi
    printf 'Created worktree %s for branch %s\n' "$GIT_TP_TARGET_WORKTREE" "$branch"
}

command_remove() {
    local force=false branch arg
    while (($# > 0)); do
        arg=$1
        shift
        case "$arg" in
            --force|-f) force=true ;;
            --help|-h) print_command_help remove; return 0 ;;
            -*) fail "unknown remove option: $arg" ;;
            *)
                [[ -z ${branch:-} ]] || fail 'remove accepts exactly one branch'
                branch=$arg
                ;;
        esac
    done
    [[ -n ${branch:-} ]] || fail 'remove requires a branch'
    path_validate_branch "$branch"
    if path_find_worktree_for_branch "$branch"; then
        :
    else
        case "$?" in
            2) fail 'unable to inspect worktrees' ;;
            *) fail "no worktree found for branch: $branch" ;;
        esac
    fi
    [[ "$GIT_TP_FOUND_WORKTREE" != "$GIT_TP_REPOSITORY" ]] || fail 'cannot remove the main worktree'
    if path_is_inside "$GIT_TP_CURRENT_WORKTREE" "$GIT_TP_FOUND_WORKTREE"; then
        fail 'cannot remove a worktree while inside it'
    fi

    GIT_TP_ACTIVE_COMMAND=remove
    hook_run "$GIT_TP_REMOVE_PRE_HOOK" "$GIT_TP_FOUND_WORKTREE" "$GIT_TP_FOUND_WORKTREE" "$branch" "$force" '' || fail 'remove pre-hook failed'
    if ! git_remove_worktree "$force" "$GIT_TP_FOUND_WORKTREE"; then
        fail "unable to remove worktree: $GIT_TP_FOUND_WORKTREE"
    fi
    if ! hook_run "$GIT_TP_REMOVE_POST_HOOK" "$GIT_TP_REPOSITORY" "$GIT_TP_FOUND_WORKTREE" "$branch" "$force" ''; then
        fail 'remove post-hook failed; worktree was removed'
    fi
    printf 'Removed worktree %s for branch %s\n' "$GIT_TP_FOUND_WORKTREE" "$branch"
}

command_cleanup() {
    local stale_count
    stale_count=$(git_stale_count) || fail 'unable to inspect stale worktrees'
    GIT_TP_ACTIVE_COMMAND=cleanup
    hook_run "$GIT_TP_CLEANUP_PRE_HOOK" "$GIT_TP_REPOSITORY" "$GIT_TP_REPOSITORY" '' false "$stale_count" || fail 'cleanup pre-hook failed'
    git_prune_worktrees || fail 'unable to prune stale worktrees'
    if ! hook_run "$GIT_TP_CLEANUP_POST_HOOK" "$GIT_TP_REPOSITORY" "$GIT_TP_REPOSITORY" '' false "$stale_count"; then
        fail 'cleanup post-hook failed; stale records were pruned'
    fi
    printf 'Cleaned up %s stale worktree record(s)\n' "$stale_count"
}
