#!/usr/bin/env bash
set -u

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
INSTALLER="$ROOT_DIR/install.sh"
TEST_HOME=$(mktemp -d)
ARCHIVE="$TEST_HOME/tree-planter.tar.gz"
PREFIX="$TEST_HOME/.local"

cleanup() {
    rm -rf "$TEST_HOME"
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_no_matches() {
    if compgen -G "$1" >/dev/null; then
        fail "$2"
    fi
}

tar -czf "$ARCHIVE" -C "$ROOT_DIR" bin lib install.sh

GIT_TP_SOURCE_URL="file://$ARCHIVE" bash "$INSTALLER" --install-dir "$PREFIX" \
    >"$TEST_HOME/stdout" 2>"$TEST_HOME/stderr" || {
    cat "$TEST_HOME/stderr" >&2
    fail 'installer did not complete successfully'
}

[[ -x "$PREFIX/bin/git-tp" ]] || fail 'installed executable is missing'
[[ -f "$PREFIX/lib/git-tp/config.bash" ]] || fail 'installed supporting files are missing'
[[ -f "$PREFIX/.git-tp-source" ]] || fail 'installation source metadata is missing'
[[ -x "$PREFIX/lib/git-tp/install.sh" ]] || fail 'bundled installer is missing'
[[ "$($PREFIX/bin/git-tp --version)" == 'git-tp 0.1.0' ]] || fail 'installed executable does not run'
grep -Fq "export PATH=\"$PREFIX/bin:\$PATH\"" "$TEST_HOME/stdout" || fail 'PATH guidance is missing'
PATH="$PREFIX/bin:$PATH" git tp -h >"$TEST_HOME/stdout" || fail 'installed git tp -h failed'
grep -Fq 'git tp add' "$TEST_HOME/stdout" || fail 'installed git tp --help output is incomplete'

updated_root="$TEST_HOME/updated-source"
mkdir -p "$updated_root"
cp -R "$ROOT_DIR/bin" "$ROOT_DIR/lib" "$updated_root/"
cp "$ROOT_DIR/install.sh" "$updated_root/"
sed -i 's/GIT_TP_VERSION="0.1.0"/GIT_TP_VERSION="0.2.0"/' "$updated_root/bin/git-tp"
printf 'updated runtime\n' > "$updated_root/lib/git-tp/updated-marker"
updated_archive="$TEST_HOME/updated.tar.gz"
tar -czf "$updated_archive" -C "$updated_root" bin lib install.sh
mkdir -p "$TEST_HOME/archive/refs/heads" "$TEST_HOME/archive/refs/tags"
cp "$ARCHIVE" "$TEST_HOME/archive/refs/heads/main.tar.gz"
cp "$updated_archive" "$TEST_HOME/archive/refs/tags/v0.2.0.tar.gz"
printf 'user configuration\n' > "$PREFIX/user-file"
assert_update() {
    if ! "$@" >"$TEST_HOME/stdout" 2>"$TEST_HOME/stderr"; then
        cat "$TEST_HOME/stderr" >&2
        fail "update command failed: $*"
    fi
}
printf 'file://%s/archive/refs/heads/main.tar.gz\n' "$TEST_HOME" > "$PREFIX/.git-tp-source"
assert_update "$PREFIX/bin/git-tp" update --check --version 0.2.0
grep -Fq 'update available' "$TEST_HOME/stdout" || fail 'update check did not report an available update'
assert_no_matches "$PREFIX/.git-tp-staging.*" 'update check wrote a staging directory'
assert_no_matches "$PREFIX/.git-tp-backup.*" 'update check wrote a backup directory'

malicious_version_root="$TEST_HOME/malicious-version-source"
mkdir -p "$malicious_version_root"
cp -R "$updated_root/bin" "$updated_root/lib" "$malicious_version_root/"
cp "$ROOT_DIR/install.sh" "$malicious_version_root/"
sed -i '/GIT_TP_VERSION=/a printf hacked > "$GIT_TP_MARKER"' "$malicious_version_root/bin/git-tp"
tar -czf "$TEST_HOME/malicious-version.tar.gz" -C "$malicious_version_root" bin lib install.sh
printf 'file://%s/malicious-version.tar.gz\n' "$TEST_HOME" > "$PREFIX/.git-tp-source"
GIT_TP_MARKER="$TEST_HOME/version-marker" assert_update "$PREFIX/bin/git-tp" update --check
[[ ! -e "$TEST_HOME/version-marker" ]] || fail 'update check executed source archive code'

tag_root="$TEST_HOME/tag-source"
mkdir -p "$tag_root/archive/refs/tags"
cp "$updated_archive" "$tag_root/archive/refs/tags/v0.2.0.tar.gz"
printf 'file://%s/archive/refs/tags/v0.1.0.tar.gz\n' "$tag_root" > "$PREFIX/.git-tp-source"
cp "$ARCHIVE" "$tag_root/archive/refs/tags/v0.1.0.tar.gz"
assert_update "$PREFIX/bin/git-tp" update --check --version 0.2.0

release_root="$TEST_HOME/release-source"
mkdir -p "$release_root/releases/download/v0.1.0"
cp "$ARCHIVE" "$release_root/releases/download/v0.1.0/git-tp.tar.gz"
mkdir -p "$release_root/releases/download/v0.2.0"
cp "$updated_archive" "$release_root/releases/download/v0.2.0/git-tp.tar.gz"
printf 'file://%s/releases/download/v0.1.0/git-tp.tar.gz\n' "$release_root" > "$PREFIX/.git-tp-source"
assert_update "$PREFIX/bin/git-tp" update --check --version 0.2.0

mkdir "$PREFIX/.git-tp.lock"
if "$PREFIX/bin/git-tp" update --check >"$TEST_HOME/stdout" 2>"$TEST_HOME/stderr"; then
    fail 'update ignored an active installation lock'
fi
grep -Fq 'installation is busy' "$TEST_HOME/stderr" || fail 'update did not report an active installation lock'
rmdir "$PREFIX/.git-tp.lock"
assert_update "$PREFIX/bin/git-tp" update --version 0.2.0
[[ "$($PREFIX/bin/git-tp --version)" == 'git-tp 0.2.0' ]] || fail 'update did not install the new version'
[[ -f "$PREFIX/lib/git-tp/updated-marker" ]] || fail 'update did not replace runtime files'
[[ -f "$PREFIX/user-file" ]] || fail 'update removed an unrelated installation file'
printf 'file://%s\n' "$TEST_HOME/missing.tar.gz" > "$PREFIX/.git-tp-source"
if "$PREFIX/bin/git-tp" update >"$TEST_HOME/stdout" 2>"$TEST_HOME/stderr"; then
    fail 'failed update unexpectedly succeeded'
fi
[[ "$($PREFIX/bin/git-tp --version)" == 'git-tp 0.2.0' ]] || fail 'failed update damaged the working installation'
grep -Fq 'unable to download source' "$TEST_HOME/stderr" || fail 'failed update did not report the source failure'
GIT_TP_SOURCE_URL="file://$ARCHIVE" bash "$INSTALLER" --install-dir "$PREFIX" \
    >"$TEST_HOME/stdout" 2>"$TEST_HOME/stderr" || {
    cat "$TEST_HOME/stderr" >&2
    fail 'unable to restore initial installation for remaining tests'
}

home_unset_prefix="$TEST_HOME/home-unset"
env -u HOME GIT_TP_SOURCE_URL="file://$ARCHIVE" bash "$INSTALLER" --install-dir "$home_unset_prefix" \
    >"$TEST_HOME/stdout" 2>"$TEST_HOME/stderr" || {
    cat "$TEST_HOME/stderr" >&2
    fail 'custom install directory required HOME'
}
[[ -x "$home_unset_prefix/bin/git-tp" ]] || fail 'custom install with HOME unset is missing executable'

symlink_root="$TEST_HOME/symlink-source"
symlink_archive="$TEST_HOME/symlink.tar.gz"
mkdir -p "$symlink_root"
cp -R "$ROOT_DIR/bin" "$ROOT_DIR/lib" "$symlink_root/"
ln -s /tmp/git-tp-outside "$symlink_root/lib/git-tp/outside-link"
tar -czf "$symlink_archive" -C "$symlink_root" bin lib
GIT_TP_SOURCE_URL="file://$symlink_archive" bash "$INSTALLER" --install-dir "$PREFIX" \
    >"$TEST_HOME/stdout" 2>"$TEST_HOME/stderr" && fail 'installer accepted a symlink archive member'
grep -Fq 'unsafe archive member' "$TEST_HOME/stderr" || fail 'installer did not identify symlink archive member'
[[ "$($PREFIX/bin/git-tp --version)" == 'git-tp 0.1.0' ]] || fail 'symlink archive damaged the existing installation'
printf 'file://%s\n' "$symlink_archive" > "$PREFIX/.git-tp-source"
if "$PREFIX/bin/git-tp" update --check >"$TEST_HOME/stdout" 2>"$TEST_HOME/stderr"; then
    fail 'update check accepted a symlink archive'
fi
[[ "$($PREFIX/bin/git-tp --version)" == 'git-tp 0.1.0' ]] || fail 'update check damaged the working installation'
grep -Fq 'unsafe archive member' "$TEST_HOME/stderr" || fail 'update check did not validate archive members'

malicious_root="$TEST_HOME/malicious"
malicious_archive="$TEST_HOME/malicious.tar.gz"
mkdir -p "$malicious_root"
printf 'malicious\n' > "$malicious_root/payload"
tar -cf "$TEST_HOME/malicious.tar" -C "$ROOT_DIR" bin lib
tar --transform='s,^payload,../escape,' --append -f "$TEST_HOME/malicious.tar" -C "$malicious_root" payload
gzip -c "$TEST_HOME/malicious.tar" > "$malicious_archive"
GIT_TP_SOURCE_URL="file://$malicious_archive" bash "$INSTALLER" --install-dir "$PREFIX" \
    >"$TEST_HOME/stdout" 2>"$TEST_HOME/stderr" && fail 'installer accepted unsafe archive paths'
grep -Fq 'unsafe archive member' "$TEST_HOME/stderr" || fail 'installer did not identify unsafe archive paths'
[[ "$($PREFIX/bin/git-tp --version)" == 'git-tp 0.1.0' ]] || fail 'unsafe archive damaged the existing installation'

GIT_TP_SOURCE_URL="file://$ARCHIVE" bash "$INSTALLER" --install-dir "$PREFIX" \
    >"$TEST_HOME/stdout" 2>"$TEST_HOME/stderr" || {
    cat "$TEST_HOME/stderr" >&2
    fail 'installer did not update an existing installation'
}

GIT_TP_SOURCE_URL="file://$ARCHIVE" sh "$INSTALLER" --install-dir "$PREFIX" \
    >"$TEST_HOME/stdout" 2>"$TEST_HOME/stderr" || {
    cat "$TEST_HOME/stderr" >&2
    fail 'installer did not support sh'
}

GIT_TP_SOURCE_URL="file://$TEST_HOME/missing.tar.gz" bash "$INSTALLER" --install-dir "$PREFIX" \
    >"$TEST_HOME/stdout" 2>"$TEST_HOME/stderr" && fail 'installer accepted a missing archive'
[[ "$($PREFIX/bin/git-tp --version)" == 'git-tp 0.1.0' ]] || fail 'failed update damaged the existing installation'

printf 'old installation\n' > "$PREFIX/bin/git-tp"
mv_command=$(command -v mv)
mkdir -p "$TEST_HOME/bin"
cat > "$TEST_HOME/bin/mv" <<EOF
#!/bin/sh
if [ "\${GIT_TP_INTERRUPT_ON_BACKUP:-}" = 1 ] && [ ! -e "$TEST_HOME/interrupt-seen" ] && case "\${2:-}" in *'.git-tp-backup.'*) true;; *) false;; esac; then
    "$mv_command" "\$@"
    : > "$TEST_HOME/interrupt-seen"
    kill -"\${GIT_TP_INTERRUPT_SIGNAL:-TERM}" "\$PPID"
    exit 143
fi
exec "$mv_command" "\$@"
EOF
chmod +x "$TEST_HOME/bin/mv"
PATH="$TEST_HOME/bin:$PATH" GIT_TP_INTERRUPT_ON_BACKUP=1 GIT_TP_SOURCE_URL="file://$ARCHIVE" \
    bash "$INSTALLER" --install-dir "$PREFIX" \
    >"$TEST_HOME/stdout" 2>"$TEST_HOME/stderr" && fail 'installer ignored SIGTERM'
grep -Fq 'old installation' "$PREFIX/bin/git-tp" || fail 'SIGTERM removed the existing installation'

printf 'old installation\n' > "$PREFIX/bin/git-tp"
rm -f "$TEST_HOME/interrupt-seen"
PATH="$TEST_HOME/bin:$PATH" GIT_TP_INTERRUPT_ON_BACKUP=1 GIT_TP_INTERRUPT_SIGNAL=INT \
    GIT_TP_SOURCE_URL="file://$ARCHIVE" bash "$INSTALLER" --install-dir "$PREFIX" \
    >"$TEST_HOME/stdout" 2>"$TEST_HOME/stderr" && fail 'installer ignored SIGINT'
grep -Fq 'old installation' "$PREFIX/bin/git-tp" || fail 'SIGINT removed the existing installation'

REAL_CURL=$(command -v curl)
REAL_TAR=$(command -v tar)

printf 'old installation\n' > "$PREFIX/bin/git-tp"
cat > "$TEST_HOME/bin/curl" <<EOF
#!/bin/sh
"$REAL_CURL" "\$@" &
child=\$!
kill -TERM "\$PPID"
wait "\$child"
EOF
chmod +x "$TEST_HOME/bin/curl"
PATH="$TEST_HOME/bin:$PATH" GIT_TP_SOURCE_URL="file://$ARCHIVE" \
    bash "$INSTALLER" --install-dir "$PREFIX" \
    >"$TEST_HOME/stdout" 2>"$TEST_HOME/stderr" && fail 'installer ignored download SIGTERM'
grep -Fq 'old installation' "$PREFIX/bin/git-tp" || fail 'download SIGTERM removed the existing installation'
assert_no_matches "$PREFIX/.git-tp-staging.*" 'download SIGTERM left staging files'
assert_no_matches "$PREFIX/.git-tp-backup.*" 'download SIGTERM left backup files'

printf 'old installation\n' > "$PREFIX/bin/git-tp"
cat > "$TEST_HOME/bin/tar" <<EOF
#!/bin/sh
"$REAL_TAR" "\$@" &
child=\$!
kill -TERM "\$PPID"
wait "\$child"
EOF
chmod +x "$TEST_HOME/bin/tar"
PATH="$TEST_HOME/bin:$PATH" GIT_TP_SOURCE_URL="file://$ARCHIVE" \
    bash "$INSTALLER" --install-dir "$PREFIX" \
    >"$TEST_HOME/stdout" 2>"$TEST_HOME/stderr" && fail 'installer ignored extract SIGTERM'
grep -Fq 'old installation' "$PREFIX/bin/git-tp" || fail 'extract SIGTERM removed the existing installation'
assert_no_matches "$PREFIX/.git-tp-staging.*" 'extract SIGTERM left staging files'
assert_no_matches "$PREFIX/.git-tp-backup.*" 'extract SIGTERM left backup files'

printf 'PASS\n'