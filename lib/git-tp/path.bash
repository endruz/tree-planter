#!/usr/bin/env bash

path_absolute() {
    local path=$1 base=${2:-}
    [[ "$path" == /* ]] || path="${base:-$PWD}/$path"
    realpath -m -- "$path"
}

path_validate_branch() {
    local branch=$1
    [[ -n "$branch" ]] || fail 'branch is required'
    [[ "$branch" != -* && "$branch" != /* ]] || fail "invalid branch name: $branch"
    git check-ref-format --branch "$branch" >/dev/null 2>&1 || fail "invalid branch name: $branch"
}

path_validate_remove_branch() {
    local branch=$1 remote_ref remote_status
    [[ "$branch" != refs/* ]] || fail "remove accepts only local branch names: $branch"
    git show-ref --verify --quiet "refs/heads/$branch" && return 0
    [[ "$branch" != origin/* ]] || fail "remove accepts only local branch names: $branch"
    remote_ref=$(git_remote_branch_ref "$branch" 2>/dev/null)
    remote_status=$?
    if (( remote_status == 0 )); then
        fail "remove accepts only local branch names: $branch"
    fi
    case "$remote_status" in
        2) fail "remove accepts only local branch names: $branch" ;;
        3) fail 'unable to inspect remotes' ;;
    esac
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
            existing_common=$(path_absolute "$existing_common" "$existing_root")
            if [[ -n "$existing_common" && "$existing_common" != "$GIT_TP_COMMON_DIR" ]]; then
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
    local worktree
    path_validate_remove_branch "$branch"
    GIT_TP_FOUND_WORKTREE=''
    worktree=$(git_worktree_path_checked "$branch") || return $?
                    GIT_TP_FOUND_WORKTREE=$(git_main_worktree_path "$worktree")
}

path_is_inside() {
    local candidate=$1 parent=$2
    candidate=$(realpath -m -- "$candidate")
    parent=$(realpath -m -- "$parent")
    [[ "$candidate" == "$parent" || "$candidate" == "$parent"/* ]]
}
