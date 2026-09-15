#!/usr/bin/env bash

path_validate_branch() {
    local branch=$1
    [[ -n "$branch" ]] || fail 'branch is required'
    [[ "$branch" != -* && "$branch" != /* ]] || fail "invalid branch name: $branch"
    git check-ref-format --branch "$branch" >/dev/null 2>&1 || fail "invalid branch name: $branch"
}

path_load_hook_paths() {
    local hook_name path hook_var
    for hook_name in ADD_PRE ADD_POST REMOVE_PRE REMOVE_POST CLEANUP_PRE CLEANUP_POST; do
        hook_var="GIT_TP_${hook_name}_HOOK"
        path=${!hook_var}
        if [[ -n "$path" && "$path" != /* ]]; then
            path="$GIT_TP_HOOK_BASE/$path"
        fi
        printf -v "GIT_TP_${hook_name}_HOOK" '%s' "$path"
    done
}

path_resolve_worktree() {
    local branch=$1
    local repository_slot target existing_git existing_root existing_common repository_entries
    path_validate_branch "$branch"
    repository_slot="$GIT_TP_ROOT/$GIT_TP_REPOSITORY_NAME"
    target="$repository_slot/$branch"
    GIT_TP_TARGET_WORKTREE=$(realpath -m -- "$target")
    repository_slot=$(realpath -m -- "$repository_slot")
    if [[ -d "$repository_slot" ]]; then
        repository_entries=$(find "$repository_slot" -name .git \( -type f -o -type d \) -print 2>/dev/null) ||
            fail "unable to inspect repository directory: $repository_slot"
        while IFS= read -r existing_git; do
            existing_root=$(dirname "$existing_git")
            existing_common=$(git -C "$existing_root" rev-parse --git-common-dir 2>/dev/null || true)
            [[ -n "$existing_common" ]] || continue
            case "$existing_common" in
                /*) ;;
                *) existing_common="$existing_root/$existing_common" ;;
            esac
            if [[ -n "$existing_common" && "$(realpath -m -- "$existing_common")" != "$GIT_TP_COMMON_DIR" ]]; then
                fail "repository directory name collision: $repository_slot is used by $(git -C "$existing_root" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$existing_root")"
            fi
        done <<< "$repository_entries"
    fi
    case "$GIT_TP_TARGET_WORKTREE/" in
        "$repository_slot"/*) ;;
        *) fail "target path escapes repository directory: $branch" ;;
    esac
    [[ ! -e "$GIT_TP_TARGET_WORKTREE" ]] || fail "target worktree already exists: $GIT_TP_TARGET_WORKTREE"
}

path_find_worktree_for_branch() {
    local branch=$1
    local worktree current_branch worktree_list remote_ref
    [[ "$branch" != refs/* ]] || fail "remove accepts only local branch names: $branch"
    if ! git show-ref --verify --quiet "refs/heads/$branch"; then
        [[ "$branch" != origin/* ]] || fail "remove accepts only local branch names: $branch"
        if remote_ref=$(git_remote_branch_ref "$branch" 2>/dev/null); then
            fail "remove accepts only local branch names: $branch"
        else
            case "$?" in
                2) fail "remove accepts only local branch names: $branch" ;;
                3) fail 'unable to inspect remotes' ;;
            esac
        fi
    fi
    GIT_TP_FOUND_WORKTREE=''
    worktree_list=$(git worktree list --porcelain) || return 2
    worktree=''
    current_branch=''
    while IFS= read -r line; do
        case "$line" in
            'worktree '*) worktree=${line#worktree } ;;
            'branch refs/heads/'*)
                current_branch=${line#branch refs/heads/}
                if [[ "$current_branch" == "$branch" ]]; then
                    GIT_TP_FOUND_WORKTREE=$worktree
                    return 0
                fi
                ;;
        esac
    done <<< "$worktree_list"
    return 1
}

path_is_inside() {
    local candidate=$1 parent=$2
    candidate=$(realpath -m -- "$candidate")
    parent=$(realpath -m -- "$parent")
    [[ "$candidate" == "$parent" || "$candidate" == "$parent"/* ]]
}
