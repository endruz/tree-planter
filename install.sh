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

for command_name in bash git realpath curl tar mktemp find cp mv rm dirname chmod mkdir grep ln cat rmdir; do
    command -v "$command_name" >/dev/null 2>&1 || fail "required command not found: $command_name"
done

install_dir=$(realpath -m "$install_dir")
[ ! -d "$install_dir/bin/git-tp" ] || fail 'stable launcher path is a directory'
mkdir -p "$install_dir/bin" "$install_dir/.git-tp/versions"
if [ -e "$install_dir/.git-tp/current" ] && [ ! -L "$install_dir/.git-tp/current" ]; then
    fail 'current installation pointer is not a symlink'
fi

lock_dir="$install_dir/.git-tp.lock"
lock_acquired=0
temp_dir=''
staging_dir=''
launcher_file=''
current_link=''

cleanup() {
    status=$?
    trap - 0 1 2 3 15
    [ -z "$current_link" ] || rm -f "$current_link" || true
    [ -z "$launcher_file" ] || rm -f "$launcher_file" || true
    [ -z "$staging_dir" ] || rm -rf "$staging_dir" || true
    [ -z "$temp_dir" ] || rm -rf "$temp_dir" || true
    if [ "$lock_acquired" -eq 1 ]; then
        rm -f "$lock_dir/pid"
        rmdir "$lock_dir" 2>/dev/null || true
    fi
    exit "$status"
}

handle_sigint() {
    exit 130
}

handle_sigterm() {
    exit 143
}

trap cleanup 0
trap handle_sigint 2
trap handle_sigterm 15

if ! mkdir "$lock_dir" 2>/dev/null; then
    lock_owner=$(cat "$lock_dir/pid" 2>/dev/null || printf 'unknown')
    fail "installation is busy (lock owner PID: $lock_owner)"
fi
lock_acquired=1
printf '%s\n' "$$" > "$lock_dir/pid"

temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/git-tp-install.XXXXXX")
archive="$temp_dir/source.tar.gz"
members_file="$temp_dir/members"
details_file="$temp_dir/details"
extracted_dir="$temp_dir/source"
mkdir -p "$extracted_dir"
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
[ -f "$source_root/install.sh" ] || fail 'source archive does not contain install.sh'
sh -n "$source_root/install.sh" || fail 'source installer contains invalid shell syntax'

launcher_is_managed=0
if [ -f "$install_dir/bin/git-tp" ] && grep -Fq '# git-tp managed launcher v1' "$install_dir/bin/git-tp"; then
    launcher_is_managed=1
fi
if [ "$launcher_is_managed" -eq 0 ]; then
    launcher_file=$(mktemp "$install_dir/bin/.git-tp.XXXXXX") || fail 'unable to stage stable launcher'
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
fi

staging_dir=$(mktemp -d "$install_dir/.git-tp/versions/release.XXXXXX") || fail 'unable to stage release'
mkdir -p "$staging_dir/bin" "$staging_dir/lib"
cp "$source_bin" "$staging_dir/bin/git-tp" || fail 'unable to stage source executable'
cp -R "$source_root/lib/git-tp" "$staging_dir/lib/" || fail 'unable to stage source runtime'
cp "$source_root/install.sh" "$staging_dir/lib/git-tp/install.sh" || fail 'unable to stage source installer'
chmod +x "$staging_dir/bin/git-tp" "$staging_dir/lib/git-tp/install.sh"
bash -n "$staging_dir/bin/git-tp" || fail 'source executable contains invalid shell syntax'
for runtime_module in config context path git hooks commands; do
    runtime_file="$staging_dir/lib/git-tp/$runtime_module.bash"
    [ -f "$runtime_file" ] || fail "source archive does not contain runtime file: ${runtime_file##*/}"
    bash -n "$runtime_file" || fail "source runtime contains invalid shell syntax: ${runtime_file##*/}"
done
runtime_version=$("$staging_dir/bin/git-tp" --version) || fail 'source executable cannot be run'
case "$runtime_version" in
    'git-tp '*) ;;
    *) fail 'source executable returned an invalid version' ;;
esac
printf '%s\n' "$source_url" > "$staging_dir/source"

current_link=$(mktemp "$install_dir/.git-tp/.current.XXXXXX") || fail 'unable to stage current pointer'
rm -f "$current_link"
ln -s "versions/${staging_dir##*/}" "$current_link" || fail 'unable to stage current pointer'
staging_dir=''
mv -Tf "$current_link" "$install_dir/.git-tp/current" || fail 'unable to publish current release'
current_link=''

if [ "$launcher_is_managed" -eq 0 ]; then
    mv -T "$launcher_file" "$install_dir/bin/git-tp" || fail 'unable to install stable launcher'
    launcher_file=''
fi

printf 'git-tp installed in %s\n' "$install_dir"
case ":${PATH:-}:" in
    *":$install_dir/bin:"*) ;;
    *) printf 'Add it to PATH with:\n  export PATH="%s/bin:$PATH"\n' "$install_dir" ;;
esac