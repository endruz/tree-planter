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
download_url=${GIT_TP_DOWNLOAD_URL:-$source_url}
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

for command_name in bash git realpath curl tar mktemp find cp mv rm dirname chmod mkdir wc awk grep readlink ln cat rmdir; do
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
staging_dir="$temp_dir/staging"
release_dir=''
release_published=0
current_link=''
launcher_file="$temp_dir/launcher"
lock_dir="$install_dir/.git-tp.lock"
lock_acquired=0
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
        rm -f "$lock_dir/pid"
        rmdir "$lock_dir" 2>/dev/null || true
    fi
    if [ "$release_published" -eq 0 ] && [ -n "$release_dir" ]; then
        published_target=$(readlink "$install_dir/.git-tp/current" 2>/dev/null || true)
        [ "$published_target" = "versions/${release_dir##*/}" ] && release_published=1
    fi
    if [ "$release_published" -eq 0 ] && [ -n "$release_dir" ]; then
        rm -rf "$release_dir"
    fi
    [ -z "$current_link" ] || rm -f "$current_link"
    rm -rf "$temp_dir"
    exit "$status"
}
trap cleanup 0
trap handle_sigint 2
trap handle_sigterm 15

if [ "$check_only" != true ]; then
    mkdir -p "$install_dir/bin" "$install_dir/.git-tp/versions"
fi
install_dir=$(realpath -m "$install_dir")
lock_dir="$install_dir/.git-tp.lock"
if [ "$check_only" = true ]; then
    if [ -e "$lock_dir" ]; then
        lock_owner=$(cat "$lock_dir/pid" 2>/dev/null || printf 'unknown')
        fail "installation is busy (lock owner PID: $lock_owner); verify it is stale before removing $lock_dir"
    fi
else
    mkdir -p "$install_dir/bin" "$install_dir/.git-tp/versions"
    if ! mkdir "$lock_dir" 2>/dev/null; then
        lock_owner=$(cat "$lock_dir/pid" 2>/dev/null || printf 'unknown')
        fail "installation is busy (lock owner PID: $lock_owner); verify it is stale before removing $lock_dir"
    fi
    lock_acquired=1
    printf '%s\n' "$$" > "$lock_dir/pid"
fi
mkdir -p "$extracted_dir" "$staging_dir"
curl -fsSL "$download_url" -o "$archive" || fail "unable to download source: $download_url"
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
case "$source_version" in
    *[!A-Za-z0-9._+-]*) fail 'source executable contains an invalid version declaration' ;;
esac
expected_version=${GIT_TP_EXPECTED_VERSION:-}
if [ -n "$expected_version" ] && [ "$source_version" != "$expected_version" ]; then
    fail "requested version $expected_version does not match source version $source_version"
fi
if [ "$check_only" = true ]; then
    current_version='not installed'
    if [ -x "$install_dir/bin/git-tp" ]; then
        current_version=$("$install_dir/bin/git-tp" --version)
    fi
    current_version=${current_version#git-tp }
    if [ "$current_version" = "$source_version" ]; then
        printf 'git-tp is up to date (%s)\n' "$current_version"
    else
        printf 'update available: %s -> %s\n' "$current_version" "$source_version"
    fi
    exit 0
fi

release_dir=$(mktemp -d "$install_dir/.git-tp/versions/release.XXXXXX")
mkdir -p "$release_dir/bin" "$release_dir/lib"
cp "$staging_dir/git-tp" "$release_dir/bin/git-tp"
cp -R "$staging_dir/git-tp-lib" "$release_dir/lib/git-tp"
bash -n "$release_dir/bin/git-tp" || fail 'source executable cannot be run'
runtime_version=$(GIT_TP_INSTALL_ROOT= "$release_dir/bin/git-tp" --version) || fail 'source executable cannot be run'
[ "$runtime_version" = "git-tp $source_version" ] || fail 'source executable version does not match its version declaration'
printf '%s\n' "$source_url" > "$release_dir/source"
cat > "$launcher_file" <<'EOF'
#!/bin/sh
set -eu
# git-tp managed launcher v1
install_root=$(CDPATH= cd "$(dirname "$0")/.." && pwd -P)
current="$install_root/.git-tp/current"
if [ ! -x "$current/bin/git-tp" ]; then
    printf 'git-tp: installed runtime is missing under %s\n' "$current" >&2
    exit 1
fi
GIT_TP_INSTALL_ROOT=$install_root
export GIT_TP_INSTALL_ROOT
exec "$current/bin/git-tp" "$@"
EOF
chmod +x "$launcher_file"
if [ -e "$install_dir/.git-tp/current" ] && [ ! -L "$install_dir/.git-tp/current" ]; then
    fail 'current installation pointer is not a symlink; remove it after verifying the installation'
fi
current_link="$install_dir/.git-tp/.current.$$"
rm -f "$current_link"
ln -s "versions/${release_dir##*/}" "$current_link"
mv -Tf "$current_link" "$install_dir/.git-tp/current"
release_published=1
if [ ! -f "$install_dir/bin/git-tp" ] || ! grep -Fq '# git-tp managed launcher v1' "$install_dir/bin/git-tp"; then
    mv "$launcher_file" "$install_dir/bin/git-tp"
fi
rm -f "$install_dir/.git-tp-source"

printf 'git-tp installed in %s\n' "$install_dir"
case ":${PATH:-}:" in
    *":$install_dir/bin:"*) ;;
    *) printf 'Add it to PATH with:\n  export PATH="%s/bin:$PATH"\n' "$install_dir" ;;
esac