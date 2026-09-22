#!/bin/sh
set -eu

usage() {
    printf '%s\n' 'Usage: install.sh [--install-dir DIR] [--check]'
}

fail() {
    printf 'git-tp installer: %s\n' "$1" >&2
    exit 1
}

install_dir=${GIT_TP_INSTALL_DIR:-}
source_url=${GIT_TP_SOURCE_URL:-https://github.com/endruz/tree-planter/archive/refs/heads/main.tar.gz}
check_only=false

while [ "$#" -gt 0 ]; do
    case "$1" in
        --install-dir)
            [ "$#" -ge 2 ] || fail '--install-dir requires a directory'
            install_dir=$2
            shift 2
            ;;
        --check)
            check_only=true
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            fail "unknown option: $1"
            ;;
    esac
done

[ -n "$install_dir" ] || install_dir=${HOME:?HOME must be set}/.local

for command_name in bash git realpath curl tar mktemp find cp mv rm dirname chmod mkdir wc awk; do
    command -v "$command_name" >/dev/null 2>&1 || fail "required command not found: $command_name"
done

max_archive_bytes=10485760
max_member_bytes=10485760
max_total_bytes=52428800

temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/git-tp-install.XXXXXX")
archive="$temp_dir/source.tar.gz"
members_file="$temp_dir/members"
details_file="$temp_dir/details"
extracted_dir="$temp_dir/source"
staging_dir="$install_dir/.git-tp-staging.$$"
backup_dir="$install_dir/.git-tp-backup.$$"
lock_dir="$install_dir/.git-tp.lock"
lock_acquired=0
backup_bin=0
backup_lib=0
backup_source=0
installed_bin=0
installed_lib=0
installed_source=0
interrupted=0

handle_sigint() {
    interrupted=1
    exit 130
}

handle_sigterm() {
    interrupted=1
    exit 143
}

cleanup() {
    status=$?
    trap - 0 1 2 3 15
    if [ "$lock_acquired" -eq 1 ]; then
        rmdir "$lock_dir" 2>/dev/null || true
    fi
    rm -rf "$staging_dir"
    if [ "$interrupted" -eq 1 ] || [ "$status" -ne 0 ]; then
        if [ "$backup_bin" -eq 1 ] && [ -e "$backup_dir/bin/git-tp" ]; then
            rm -f "$install_dir/bin/git-tp"
            mv "$backup_dir/bin/git-tp" "$install_dir/bin/git-tp"
        elif [ "$installed_bin" -eq 1 ]; then
            rm -f "$install_dir/bin/git-tp"
        fi
        if [ "$backup_lib" -eq 1 ] && [ -e "$backup_dir/lib/git-tp" ]; then
            rm -rf "$install_dir/lib/git-tp"
            mv "$backup_dir/lib/git-tp" "$install_dir/lib/git-tp"
        elif [ "$installed_lib" -eq 1 ]; then
            rm -rf "$install_dir/lib/git-tp"
        fi
        if [ "$backup_source" -eq 1 ] && [ -e "$backup_dir/source" ]; then
            rm -f "$install_dir/.git-tp-source"
            mv "$backup_dir/source" "$install_dir/.git-tp-source"
        elif [ "$installed_source" -eq 1 ]; then
            rm -f "$install_dir/.git-tp-source"
        fi
    fi
    rm -rf "$temp_dir" "$backup_dir"
    exit "$status"
}
trap cleanup 0
trap handle_sigint 2
trap handle_sigterm 15

if [ "$check_only" = true ]; then
    if [ -e "$lock_dir" ]; then
        fail 'installation is busy'
    fi
    staging_dir="$temp_dir/staging"
    backup_dir="$temp_dir/backup"
else
    mkdir -p "$install_dir/bin" "$install_dir/lib"
    if ! mkdir "$lock_dir" 2>/dev/null; then
        fail 'installation is busy'
    fi
    lock_acquired=1
fi
mkdir -p "$extracted_dir" "$staging_dir" "$backup_dir/bin" "$backup_dir/lib"
curl -fsSL "$source_url" -o "$archive" || fail "unable to download source: $source_url"
archive_bytes=$(wc -c < "$archive")
[ "$archive_bytes" -le "$max_archive_bytes" ] || fail 'source archive is too large'
tar -tzf "$archive" > "$members_file" || fail 'unable to inspect source archive'
tar -tvzf "$archive" > "$details_file" || fail 'unable to inspect source archive'
awk -v max_member="$max_member_bytes" -v max_total="$max_total_bytes" '
    $3 !~ /^[0-9]+$/ || $3 > max_member { exit 2 }
    { total += $3 }
    total > max_total { exit 3 }
' "$details_file" || {
    case "$?" in
        2) fail 'source archive contains an oversized file' ;;
        *) fail 'source archive contents are too large' ;;
    esac
}
while IFS= read -r entry; do
    case "$entry" in
        -*) ;;
        d*) ;;
        *) fail "unsafe archive member: $entry" ;;
    esac
done < "$details_file"
while IFS= read -r member; do
    case "$member" in
        /*|../*|*/../*|*/..|..)
            fail "unsafe archive member: $member"
            ;;
    esac
done < "$members_file"
tar -xzf "$archive" -C "$extracted_dir" || fail 'unable to extract source archive'

source_bin=$(find "$extracted_dir" -type f -path '*/bin/git-tp' -print -quit)
[ -n "$source_bin" ] || fail 'source archive does not contain bin/git-tp'
source_root=$(dirname "$(dirname "$source_bin")")
[ -f "$source_root/lib/git-tp/config.bash" ] || fail 'source archive does not contain lib/git-tp'
[ -f "$source_root/install.sh" ] || fail 'source archive does not contain install.sh'

cp "$source_bin" "$staging_dir/git-tp"
cp -R "$source_root/lib/git-tp" "$staging_dir/git-tp-lib"
cp "$source_root/install.sh" "$staging_dir/git-tp-lib/install.sh"
chmod +x "$staging_dir/git-tp"
chmod +x "$staging_dir/git-tp-lib/install.sh"
source_version=''
while IFS= read -r source_line || [ -n "$source_line" ]; do
    case "$source_line" in
        *GIT_TP_VERSION=\"*\")
            source_version=${source_line#*\"}
            source_version=${source_version%%\"*}
            break
            ;;
    esac
done < "$source_bin"
[ -n "$source_version" ] || fail 'source executable does not contain a version declaration'
if [ "$check_only" = true ]; then
    current_version='not installed'
    if [ -x "$install_dir/bin/git-tp" ]; then
        current_version=$($install_dir/bin/git-tp --version)
    fi
    if [ "$current_version" = "$source_version" ]; then
        printf 'git-tp is up to date (%s)\n' "${current_version#git-tp }"
    else
        printf 'update available: %s -> %s\n' "${current_version#git-tp }" "${source_version#git-tp }"
    fi
    exit 0
fi

if [ -e "$install_dir/bin/git-tp" ]; then
    backup_bin=1
    mv "$install_dir/bin/git-tp" "$backup_dir/bin/git-tp"
fi
if [ -e "$install_dir/lib/git-tp" ]; then
    backup_lib=1
    mv "$install_dir/lib/git-tp" "$backup_dir/lib/git-tp"
fi
if [ -e "$install_dir/.git-tp-source" ]; then
    backup_source=1
    mv "$install_dir/.git-tp-source" "$backup_dir/source"
fi
installed_bin=1
mv "$staging_dir/git-tp" "$install_dir/bin/git-tp"
installed_lib=1
mv "$staging_dir/git-tp-lib" "$install_dir/lib/git-tp"
printf '%s\n' "$source_url" > "$staging_dir/source"
installed_source=1
mv "$staging_dir/source" "$install_dir/.git-tp-source"

printf 'git-tp installed in %s\n' "$install_dir"
case ":${PATH:-}:" in
    *":$install_dir/bin:"*) ;;
    *) printf 'Add it to PATH with:\n  export PATH="%s/bin:$PATH"\n' "$install_dir" ;;
esac