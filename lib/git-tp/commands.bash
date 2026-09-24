#!/usr/bin/env bash

command_add() {
    local create_branch=false branch arg remote_ref requested_branch remote_branch_name local_head remote_head
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

    requested_branch=$branch
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
            if remote_branch_name=$(git_remote_branch_name "$remote_ref"); then
                branch=$remote_branch_name
            else
                case "$?" in
                    3) fail 'unable to inspect remotes' ;;
                    *) fail "unable to resolve remote branch: $requested_branch" ;;
                esac
            fi
            if git show-ref --verify --quiet "refs/heads/$branch"; then
                local_head=$(git rev-parse "refs/heads/$branch") || fail "unable to resolve local branch: $branch"
                remote_head=$(git rev-parse "$remote_ref") || fail "unable to resolve remote branch: $requested_branch"
                [[ "$local_head" == "$remote_head" ]] ||
                    fail "local branch already exists for remote branch: $branch"
            fi
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
    else
        if git_branch_exists "$branch"; then
            :
        else
            case "$?" in
                1) ;;
                2) fail "ambiguous remote branch: $branch; use a qualified remote/branch name" ;;
                3) fail 'unable to inspect remotes' ;;
                *) fail "unable to inspect branch: $branch" ;;
            esac
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
    [[ "$GIT_TP_FOUND_WORKTREE" != "$GIT_TP_MAIN_REPOSITORY" ]] || fail 'cannot remove the main worktree'
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

command_run_archived_installer() (
    local source_url=$1 download_url=$2 install_root=$3 expected_version=$4 bootstrap_dir archive members details member installer_member member_count archive_bytes
    shift 4
    bootstrap_dir=$(mktemp -d "${TMPDIR:-/tmp}/git-tp-update.XXXXXX") || fail 'unable to create update temporary directory'
    trap 'rm -rf "$bootstrap_dir"' EXIT
    archive=$bootstrap_dir/source.tar.gz
    members=$bootstrap_dir/members
    details=$bootstrap_dir/details
    curl -fsSL "$download_url" -o "$archive" || fail "unable to download source: $download_url"
    archive_bytes=$(wc -c < "$archive")
    [ "$archive_bytes" -le 10485760 ] || fail 'source archive is too large'
    tar -tzf "$archive" > "$members" || fail 'unable to inspect source archive'
    installer_member=''
    member_count=0
    while IFS= read -r member; do
        case "$member" in
            -*|/*|../*|*/../*|*/..|..) fail "unsafe archive member: $member" ;;
            install.sh|*/install.sh)
                installer_member=$member
                member_count=$((member_count + 1))
                ;;
        esac
    done < "$members"
    [ "$member_count" -eq 1 ] || fail 'source archive must contain exactly one install.sh'
    tar -tvzf "$archive" -- "$installer_member" > "$details" || fail 'unable to inspect source archive installer'
    awk '$3 !~ /^[0-9]+$/ || $3 > 10485760 || substr($1, 1, 1) != "-" { exit 1 } END { if (NR != 1) exit 1 }' "$details" ||
        fail 'source archive installer is not a regular file'
    installer=$bootstrap_dir/install.sh
    tar -xOzf "$archive" -- "$installer_member" > "$installer" || fail 'unable to read installer from source archive'
    chmod +x "$installer"
    GIT_TP_SOURCE_URL=$source_url GIT_TP_DOWNLOAD_URL=$download_url GIT_TP_EXPECTED_VERSION=$expected_version \
        GIT_TP_ARCHIVE_FILE=$archive \
        "$installer" --install-dir "$install_root" "$@"
)

command_run_update_installer() {
    local installer=$1 source_url=$2 download_url=$3 install_root=$4 expected_version=$5
    shift 5
    if [[ -x "$installer" ]]; then
        GIT_TP_SOURCE_URL=$source_url GIT_TP_DOWNLOAD_URL=$download_url GIT_TP_EXPECTED_VERSION=$expected_version GIT_TP_ARCHIVE_FILE= \
            "$installer" --install-dir "$install_root" "$@"
    else
        command_run_archived_installer "$source_url" "$download_url" "$install_root" "$expected_version" "$@"
    fi
}

command_update() {
    local check=false version='' expected_version='' arg source_file install_root installer source_url download_url tag base old_version new_version
    while (($# > 0)); do
        arg=$1
        shift
        case "$arg" in
            --check) check=true ;;
            --version)
                (($# > 0)) || fail '--version requires a version'
                [[ -n "$1" ]] || fail '--version requires a non-empty version'
                version=$1
                [[ "$version" != -* ]] || fail '--version requires a value without a leading dash'
                shift
                ;;
            --help|-h) print_command_help update; return 0 ;;
            -*) fail "unknown update option: $arg" ;;
            *) fail "unexpected update argument: $arg" ;;
        esac
    done

    install_root=$INSTALL_ROOT
    source_file=$install_root/.git-tp/current/source
    if [[ ! -r "$source_file" ]]; then
        source_file=$install_root/.git-tp-source
    fi
    [[ -r "$source_file" ]] || fail 'installation source is unknown; reinstall with the supported installer'
    source_url=$(<"$source_file")
    [[ -n "$source_url" ]] || fail 'installation source metadata is empty; reinstall with the supported installer'
    download_url=$source_url
    expected_version=$version
    [[ "$version" != v?* ]] || expected_version=${version#v}
    if [[ -n "$version" ]]; then
        tag=$version
        [[ "$tag" == v* ]] || tag=v$tag
        if [[ "$source_url" == *'{version}'* ]]; then
            download_url=${source_url//\{version\}/$version}
        elif [[ "$source_url" == */archive/refs/heads/*.tar.gz || "$source_url" == */archive/refs/tags/*.tar.gz ]]; then
            base=${source_url%/archive/refs/*/*.tar.gz}
            download_url=$base/archive/refs/tags/$tag.tar.gz
        elif [[ "$source_url" == */releases/download/*/* ]]; then
            base=${source_url%/releases/download/*}
            download_url=$base/releases/download/$tag/${source_url##*/}
        else
            fail 'the configured update source does not support --version'
        fi
    fi

    installer=$install_root/.git-tp/current/lib/git-tp/install.sh
    if [[ ! -x "$installer" ]]; then
        installer=$install_root/lib/git-tp/install.sh
    fi
    if [[ "$check" == true && ! -x "$installer" ]]; then
        fail 'cannot safely check a legacy installation without a bundled installer; run git tp update to migrate it'
    fi
    if [[ "$check" == true ]]; then
        command_run_update_installer "$installer" "$source_url" "$download_url" "$install_root" "$expected_version" --check ||
            fail 'update check failed; the previous installation was retained'
    else
        old_version=$("$install_root/bin/git-tp" --version)
        old_version=${old_version#git-tp }
        command_run_update_installer "$installer" "$source_url" "$download_url" "$install_root" "$expected_version" ||
            fail 'update failed; the previous installation was retained'
        new_version=$("$install_root/bin/git-tp" --version)
        new_version=${new_version#git-tp }
        printf 'git-tp updated: %s -> %s\n' "$old_version" "$new_version"
    fi
}
