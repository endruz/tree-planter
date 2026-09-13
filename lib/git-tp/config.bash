#!/usr/bin/env bash

config_load() {
    local config_file=${HOME:-}/.git-tp.toml
    local section=''
    local line key value
    GIT_TP_ROOT=''
    GIT_TP_ADD_PRE_HOOK=''
    GIT_TP_ADD_POST_HOOK=''
    GIT_TP_REMOVE_PRE_HOOK=''
    GIT_TP_REMOVE_POST_HOOK=''
    GIT_TP_CLEANUP_PRE_HOOK=''
    GIT_TP_CLEANUP_POST_HOOK=''

    if [[ ! -e "$config_file" ]]; then
        fail "Configuration file not found: $config_file\nCreate it with:\n\n[worktree]\nroot = \"/home/user/worktrees\""
    fi
    if [[ ! -r "$config_file" ]]; then
        fail "Configuration file is not readable: $config_file"
    fi

    while IFS= read -r line || [[ -n "$line" ]]; do
        line=${line%%#*}
        line="${line#${line%%[![:space:]]*}}"
        line="${line%${line##*[![:space:]]}}"
        [[ -z "$line" ]] && continue
        if [[ "$line" =~ ^\[([^]]+)\]$ ]]; then
            section=${BASH_REMATCH[1]}
            case "$section" in
                worktree|add.hooks|remove.hooks|cleanup.hooks) ;;
                *) fail "unknown configuration section: [$section]" ;;
            esac
            continue
        fi
        if [[ ! "$line" =~ ^([a-z-]+)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
            fail "invalid TOML syntax in $config_file: $line"
        fi
        key=${BASH_REMATCH[1]}
        value=${BASH_REMATCH[2]}
        if [[ ${#value} -lt 2 || ${value:0:1} != '"' || ${value: -1} != '"' ]]; then
            case "$section.$key" in
                worktree.root) fail 'worktree.root must be a string' ;;
                *) fail "configuration value must be a string: $section.$key" ;;
            esac
        fi
        value=${value:1:${#value}-2}
        case "$section.$key" in
            worktree.root)
                [[ -n "$GIT_TP_ROOT" ]] && fail 'duplicate configuration key: worktree.root'
                GIT_TP_ROOT=$value
                ;;
            add.hooks.pre-hook) GIT_TP_ADD_PRE_HOOK=$value ;;
            add.hooks.post-hook) GIT_TP_ADD_POST_HOOK=$value ;;
            remove.hooks.pre-hook) GIT_TP_REMOVE_PRE_HOOK=$value ;;
            remove.hooks.post-hook) GIT_TP_REMOVE_POST_HOOK=$value ;;
            cleanup.hooks.pre-hook) GIT_TP_CLEANUP_PRE_HOOK=$value ;;
            cleanup.hooks.post-hook) GIT_TP_CLEANUP_POST_HOOK=$value ;;
            *) fail "unknown configuration key: $section.$key" ;;
        esac
    done < "$config_file"

    [[ -n "$GIT_TP_ROOT" ]] || fail 'worktree.root is required'
    if [[ $GIT_TP_ROOT == '~' ]]; then
        GIT_TP_ROOT=$HOME
    elif [[ ${GIT_TP_ROOT:0:2} == '~/' ]]; then
        GIT_TP_ROOT="$HOME/${GIT_TP_ROOT#~/}"
    fi
    [[ $GIT_TP_ROOT == /* ]] || fail 'worktree.root must be an absolute path or start with ~/'
}
