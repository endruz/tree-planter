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
[[ -L "$PREFIX/.git-tp/current" ]] || fail 'current installation pointer is missing'
[[ -f "$PREFIX/.git-tp/current/lib/git-tp/config.bash" ]] || fail 'installed supporting files are missing'
[[ -f "$PREFIX/.git-tp/current/source" ]] || fail 'installation source metadata is missing'
[[ -x "$PREFIX/.git-tp/current/lib/git-tp/install.sh" ]] || fail 'bundled installer is missing'
[[ "$($PREFIX/bin/git-tp --version)" == 'git-tp 0.1.0' ]] || fail 'installed executable does not run'
grep -Fq "export PATH=\"$PREFIX/bin:\$PATH\"" "$TEST_HOME/stdout" || fail 'PATH guidance is missing'
PATH="$PREFIX/bin:$PATH" git tp -h >"$TEST_HOME/stdout" || fail 'installed git tp -h failed'
grep -Fq 'git tp add' "$TEST_HOME/stdout" || fail 'installed git tp --help output is incomplete'

update_prefix="$TEST_HOME/update prefix"
update_root="$TEST_HOME/update-source"
update_archive="$TEST_HOME/update-source.tar.gz"
mkdir -p "$update_root"
cp -R "$ROOT_DIR/bin" "$ROOT_DIR/lib" "$update_root/"
cp "$ROOT_DIR/install.sh" "$update_root/"
tar -czf "$update_archive" -C "$update_root" bin lib install.sh
GIT_TP_SOURCE_URL="file://$update_archive" bash "$INSTALLER" --install-dir "$update_prefix" \
    >"$TEST_HOME/stdout" 2>"$TEST_HOME/stderr" || {
    cat "$TEST_HOME/stderr" >&2
    fail 'unable to install update fixture'
}
sed -i 's/GIT_TP_VERSION="0.1.0"/GIT_TP_VERSION="0.2.0"/' "$update_root/bin/git-tp"
tar -czf "$update_archive" -C "$update_root" bin lib install.sh
if ! "$update_prefix/bin/git-tp" update >"$TEST_HOME/stdout" 2>"$TEST_HOME/stderr"; then
    cat "$TEST_HOME/stderr" >&2
    fail 'installed CLI did not update from its recorded source'
fi
[[ "$("$update_prefix/bin/git-tp" --version)" == 'git-tp 0.2.0' ]] || fail 'update did not activate the new executable'
[[ -L "$update_prefix/.git-tp/current" ]] || fail 'update did not publish a versioned current release'
current_before_failed_update=$(readlink "$update_prefix/.git-tp/current")
mkdir "$update_prefix/.git-tp.lock"
printf '98765432\n' > "$update_prefix/.git-tp.lock/pid"
if "$update_prefix/bin/git-tp" update >"$TEST_HOME/stdout" 2>"$TEST_HOME/stderr"; then
    fail 'update replaced an existing installation lock'
fi
grep -Fq 'lock owner PID: 98765432' "$TEST_HOME/stderr" || fail 'busy update did not report its lock owner'
[[ "$(readlink "$update_prefix/.git-tp/current")" == "$current_before_failed_update" ]] ||
    fail 'busy update changed the current release pointer'
[[ "$(<"$update_prefix/.git-tp.lock/pid")" == '98765432' ]] || fail 'busy update changed another installer lock'
rm "$update_prefix/.git-tp.lock/pid"
rmdir "$update_prefix/.git-tp.lock"
mv "$update_root/lib/git-tp/commands.bash" "$update_root/commands.bash"
tar -czf "$update_archive" -C "$update_root" bin lib install.sh
if "$update_prefix/bin/git-tp" update >"$TEST_HOME/stdout" 2>"$TEST_HOME/stderr"; then
    fail 'update accepted a source archive missing a required runtime module'
fi
grep -Fq 'source archive does not contain runtime file: commands.bash' "$TEST_HOME/stderr" ||
    fail 'missing runtime module did not report its validation error'
[[ "$(readlink "$update_prefix/.git-tp/current")" == "$current_before_failed_update" ]] ||
    fail 'missing runtime module changed the current release pointer'
[[ "$("$update_prefix/bin/git-tp" --version)" == 'git-tp 0.2.0' ]] ||
    fail 'missing runtime module damaged the active executable'
mv "$update_root/commands.bash" "$update_root/lib/git-tp/commands.bash"
tar -czf "$update_archive" -C "$update_root" bin lib install.sh
rm "$update_archive"
if "$update_prefix/bin/git-tp" update >"$TEST_HOME/stdout" 2>"$TEST_HOME/stderr"; then
    fail 'update succeeded after its source archive became unavailable'
fi
[[ "$(readlink "$update_prefix/.git-tp/current")" == "$current_before_failed_update" ]] ||
    fail 'failed update changed the current release pointer'
[[ "$("$update_prefix/bin/git-tp" --version)" == 'git-tp 0.2.0' ]] ||
    fail 'failed update damaged the active executable'

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

malicious_root="$TEST_HOME/malicious"
malicious_archive="$TEST_HOME/malicious.tar.gz"
mkdir -p "$malicious_root"
printf 'malicious\n' > "$malicious_root/payload"
tar -cf "$TEST_HOME/malicious.tar" -C "$ROOT_DIR" bin lib
current_before_malicious_archive=$(readlink "$PREFIX/.git-tp/current")
tar --transform='s,^payload,../../escape,' --append -f "$TEST_HOME/malicious.tar" -C "$malicious_root" payload
gzip -c "$TEST_HOME/malicious.tar" > "$malicious_archive"
tar -tzf "$malicious_archive" > "$TEST_HOME/malicious-members"
grep -Fxq '../../escape' "$TEST_HOME/malicious-members" || fail 'malicious archive fixture lacks its traversal member'
TMPDIR="$TEST_HOME" GIT_TP_SOURCE_URL="file://$malicious_archive" bash "$INSTALLER" --install-dir "$PREFIX" \
    >"$TEST_HOME/stdout" 2>"$TEST_HOME/stderr" && fail 'installer accepted unsafe archive paths'
grep -Fq 'unsafe archive member' "$TEST_HOME/stderr" || fail 'installer did not identify unsafe archive paths'
[[ ! -e "$TEST_HOME/escape" ]] || fail 'unsafe archive wrote outside its extraction directory'
[[ "$(readlink "$PREFIX/.git-tp/current")" == "$current_before_malicious_archive" ]] || fail 'unsafe archive changed the active release'
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

REAL_CURL=$(command -v curl)
REAL_TAR=$(command -v tar)
mkdir -p "$TEST_HOME/bin"

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