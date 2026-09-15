#!/usr/bin/env bash

git_remote_branch_ref() {
    local branch=$1 remote remote_ref remote_list remote_count=0 remote_match=''
    if git show-ref --verify --quiet "refs/remotes/$branch"; then
        printf 'refs/remotes/%s\n' "$branch"
        return 0
    fi
    remote_list=$(git remote) || return 3
    while IFS= read -r remote; do
        remote_ref="refs/remotes/$remote/$branch"
        if git show-ref --verify --quiet "$remote_ref"; then
            remote_count=$((remote_count + 1))
            remote_match=$remote_ref
        fi
    done <<< "$remote_list"
    if (( remote_count == 1 )); then
        printf '%s\n' "$remote_match"
        return 0
    fi
    if (( remote_count > 1 )); then
        return 2
    fi
    return 1
}

git_remote_branch_name() {
    local remote_ref=$1 suffix remote prefix remote_list remote_length=0 branch=''
    suffix=${remote_ref#refs/remotes/}
    remote_list=$(git remote) || return 3
    while IFS= read -r remote; do
        prefix="$remote/"
        if [[ "$suffix" == "$prefix"* ]] && (( ${#remote} > remote_length )); then
            remote_length=${#remote}
            branch=${suffix:$((remote_length + 1))}
        fi
    done <<< "$remote_list"
    [[ -n "$branch" ]] || return 1
    printf '%s\n' "$branch"
}

git_branch_exists() {
    git show-ref --verify --quiet "refs/heads/$1" || git_remote_branch_ref "$1" >/dev/null
}

git_branch_in_use() {
    local branch=$1 worktree line current='' worktree_list
    worktree_list=$(git worktree list --porcelain) || return 2
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
    done <<< "$worktree_list"
    return 1
}

git_create_branch() {
    git branch -- "$1" "${2:-$GIT_TP_CURRENT_HEAD}"
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
