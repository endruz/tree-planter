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

tar -czf "$ARCHIVE" -C "$ROOT_DIR" bin lib

GIT_TP_SOURCE_URL="file://$ARCHIVE" bash "$INSTALLER" --install-dir "$PREFIX" \
    >"$TEST_HOME/stdout" 2>"$TEST_HOME/stderr" || {
    cat "$TEST_HOME/stderr" >&2
    fail 'installer did not complete successfully'
}

[[ -x "$PREFIX/bin/git-tp" ]] || fail 'installed executable is missing'
[[ -f "$PREFIX/lib/git-tp/config.bash" ]] || fail 'installed supporting files are missing'
[[ "$($PREFIX/bin/git-tp --version)" == 'git-tp 0.1.0' ]] || fail 'installed executable does not run'
grep -Fq "export PATH=\"$PREFIX/bin:\$PATH\"" "$TEST_HOME/stdout" || fail 'PATH guidance is missing'
PATH="$PREFIX/bin:$PATH" git tp -h >"$TEST_HOME/stdout" || fail 'installed git tp -h failed'
grep -Fq 'git tp add' "$TEST_HOME/stdout" || fail 'installed git tp --help output is incomplete'

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