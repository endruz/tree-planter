#!/bin/sh
set -eu

usage() {
    printf '%s\n' 'Usage: install.sh [--install-dir DIR]'
}

fail() {
    printf 'git-tp installer: %s\n' "$1" >&2
    exit 1
}

install_dir=${GIT_TP_INSTALL_DIR:-}
source_url=${GIT_TP_SOURCE_URL:-https://github.com/endruz/tree-planter/archive/refs/heads/main.tar.gz}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --install-dir)
            [ "$#" -ge 2 ] || fail '--install-dir requires a directory'
            install_dir=$2
            shift 2
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

for command_name in bash git realpath curl tar mktemp find cp mv rm dirname chmod mkdir; do
    command -v "$command_name" >/dev/null 2>&1 || fail "required command not found: $command_name"
done

temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/git-tp-install.XXXXXX")
archive="$temp_dir/source.tar.gz"
members_file="$temp_dir/members"
details_file="$temp_dir/details"
extracted_dir="$temp_dir/source"
staging_dir="$install_dir/.git-tp-staging.$$"
backup_dir="$install_dir/.git-tp-backup.$$"
backup_bin=0
backup_lib=0
installed_bin=0
installed_lib=0
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
    fi
    rm -rf "$temp_dir" "$backup_dir"
    exit "$status"
}
trap cleanup 0
trap handle_sigint 2
trap handle_sigterm 15

mkdir -p "$install_dir/bin" "$install_dir/lib"
mkdir -p "$extracted_dir" "$staging_dir" "$backup_dir/bin" "$backup_dir/lib"
curl -fsSL "$source_url" -o "$archive" || fail "unable to download source: $source_url"
tar -tzf "$archive" > "$members_file" || fail 'unable to inspect source archive'
tar -tvzf "$archive" > "$details_file" || fail 'unable to inspect source archive'
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

cp "$source_bin" "$staging_dir/git-tp"
cp -R "$source_root/lib/git-tp" "$staging_dir/git-tp-lib"
chmod +x "$staging_dir/git-tp"

if [ -e "$install_dir/bin/git-tp" ]; then
    backup_bin=1
    mv "$install_dir/bin/git-tp" "$backup_dir/bin/git-tp"
fi
if [ -e "$install_dir/lib/git-tp" ]; then
    backup_lib=1
    mv "$install_dir/lib/git-tp" "$backup_dir/lib/git-tp"
fi
installed_bin=1
mv "$staging_dir/git-tp" "$install_dir/bin/git-tp"
installed_lib=1
mv "$staging_dir/git-tp-lib" "$install_dir/lib/git-tp"

printf 'git-tp installed in %s\n' "$install_dir"
case ":${PATH:-}:" in
    *":$install_dir/bin:"*) ;;
    *) printf 'Add it to PATH with:\n  export PATH="%s/bin:$PATH"\n' "$install_dir" ;;
esac