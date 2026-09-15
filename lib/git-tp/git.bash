#!/usr/bin/env bash

git_branch_exists() {
    local remote_ref remote_count=0
    git show-ref --verify --quiet "refs/heads/$1" || git show-ref --verify --quiet "refs/remotes/$1" && return 0
    while IFS= read -r remote_ref; do
        remote_count=$((remote_count + 1))
    done < <(git for-each-ref --format='%(refname)' "refs/remotes/*/$1")
    (( remote_count == 1 ))
}

git_branch_in_use() {
    local branch=$1 worktree line current=''
    while IFS= read -r line; do
        case "$line" in
            'worktree '*) worktree=${line#worktree } ;;
            'branch refs/heads/'*)
                current=${line#branch refs/heads/}
                if [[ "$current" == "$branch" ]]; then
                    GIT_TP_BRANCH_WORKTREE=$worktree
                    return 0
                fi
                ;;
        esac
    done < <(git worktree list --porcelain)
    return 1
}

git_create_branch() {
    git branch -- "$1" "$GIT_TP_CURRENT_HEAD"
}

git_delete_branch() {
    git branch -D -- "$1"
}

git_add_worktree() {
    git worktree add -- "$1" "$2"
}

git_remove_worktree() {
    local force=$1 path=$2
    if [[ "$force" == true ]]; then
        git worktree remove --force -- "$path"
    else
        git worktree remove -- "$path"
    fi
}

git_stale_count() {
    local output
    output=$(git worktree prune --dry-run 2>&1) || return 1
    if [[ -z "$output" ]]; then
        printf '0\n'
    else
        printf '%s\n' "$output" | awk 'NF { count++ } END { print count + 0 }'
    fi
}

git_prune_worktrees() {
    git worktree prune
}
