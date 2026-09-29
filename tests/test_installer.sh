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

directory_launcher_prefix="$TEST_HOME/directory-launcher"
mkdir -p "$directory_launcher_prefix/bin/git-tp"
if GIT_TP_SOURCE_URL="file://$ARCHIVE" bash "$INSTALLER" --install-dir "$directory_launcher_prefix" \
    >"$TEST_HOME/stdout" 2>"$TEST_HOME/stderr"; then
    fail 'installer succeeded when the stable launcher path was a directory'
fi
[[ -d "$directory_launcher_prefix/bin/git-tp" ]] || fail 'installer replaced the launcher directory'
[[ ! -e "$directory_launcher_prefix/.git-tp/current" ]] || fail 'directory launcher failure published a current release'

launcher_failure_prefix="$TEST_HOME/launcher failure"
launcher_failure_bin="$TEST_HOME/launcher-failure-bin"
launcher_failure_marker="$TEST_HOME/launcher-failure-seen"
mkdir -p "$launcher_failure_bin"
GIT_TP_SOURCE_URL="file://$ARCHIVE" bash "$INSTALLER" --install-dir "$launcher_failure_prefix" \
    >"$TEST_HOME/stdout" 2>"$TEST_HOME/stderr" || {
    cat "$TEST_HOME/stderr" >&2
    fail 'unable to install launcher-failure fixture'
}
launcher_failure_current=$(readlink "$launcher_failure_prefix/.git-tp/current")
cat > "$launcher_failure_prefix/bin/git-tp" <<'EOF'
#!/bin/sh
install_root=$(CDPATH= cd "$(dirname "$0")/.." && pwd -P)
exec "$install_root/.git-tp/current/bin/git-tp" "$@"
EOF
chmod +x "$launcher_failure_prefix/bin/git-tp"
real_mv=$(command -v mv)
cat > "$launcher_failure_bin/mv" <<EOF
#!/bin/sh
if [ "\${2:-}" = "$launcher_failure_prefix/bin/git-tp" ]; then
    : > "$launcher_failure_marker"
    case "\${1:-}" in
        "$launcher_failure_prefix"/bin/*) ;;
        *) : > "$launcher_failure_prefix/bin/git-tp" ;;
    esac
    exit 1
fi
exec "$real_mv" "\$@"
EOF
chmod +x "$launcher_failure_bin/mv"
if PATH="$launcher_failure_bin:$PATH" GIT_TP_SOURCE_URL="file://$ARCHIVE" \
    bash "$INSTALLER" --install-dir "$launcher_failure_prefix" \
    >"$TEST_HOME/stdout" 2>"$TEST_HOME/stderr"; then
    fail 'installer succeeded after stable launcher replacement failed'
fi
[[ -e "$launcher_failure_marker" ]] || fail 'launcher failure test did not intercept the launcher replacement'
[[ "$(readlink "$launcher_failure_prefix/.git-tp/current")" == "$launcher_failure_current" ]] || fail 'launcher failure did not restore the previous current release'
[[ "$("$launcher_failure_prefix/bin/git-tp" --version)" == 'git-tp 0.1.0' ]] || fail 'launcher failure damaged the previous entry point'

no_rmdir_path="$TEST_HOME/no-rmdir-path"
mkdir -p "$no_rmdir_path"
for command_name in bash git realpath curl tar mktemp find cp mv rm dirname chmod mkdir wc awk grep readlink ln cat gzip; do
    command_path=$(command -v "$command_name") || fail "test setup could not find $command_name"
    ln -s "$command_path" "$no_rmdir_path/$command_name"
done
no_rmdir_prefix="$TEST_HOME/no-rmdir-prefix"
if PATH="$no_rmdir_path" GIT_TP_INSTALL_ROOT= GIT_TP_SOURCE_URL="file://$ARCHIVE" \
    "$no_rmdir_path/bash" "$INSTALLER" --install-dir "$no_rmdir_prefix" \
    >"$TEST_HOME/stdout" 2>"$TEST_HOME/stderr"; then
    fail 'installer accepted a PATH without rmdir'
fi
grep -Fq 'required command not found: rmdir' "$TEST_HOME/stderr" || fail 'missing rmdir did not report the required dependency'
[[ ! -e "$no_rmdir_prefix/.git-tp.lock" ]] || fail 'missing rmdir left an installation lock'

lock_race_prefix="$TEST_HOME/lock-race-prefix"
lock_race_bin="$TEST_HOME/lock-race-bin"
lock_race_marker="$TEST_HOME/lock-race-seen"
mkdir -p "$lock_race_bin"
real_mv=$(command -v mv)
cat > "$lock_race_bin/mv" <<EOF
#!/bin/sh
destination=''
for argument do destination=\$argument; done
if [ "\$destination" = "$lock_race_prefix/.git-tp.lock" ] && [ ! -e "$lock_race_marker" ]; then
    "$real_mv" "\$@" || exit
    : > "$lock_race_marker"
    kill -TERM "\$PPID"
    exit 1
fi
exec "$real_mv" "\$@"
EOF
chmod +x "$lock_race_bin/mv"
if PATH="$lock_race_bin:$PATH" GIT_TP_SOURCE_URL="file://$ARCHIVE" \
    bash "$INSTALLER" --install-dir "$lock_race_prefix" \
    >"$TEST_HOME/stdout" 2>"$TEST_HOME/stderr"; then
    fail 'installer succeeded after SIGTERM immediately following lock publication'
else
    lock_race_status=$?
    [[ "$lock_race_status" -eq 143 ]] || fail "SIGTERM during lock publication returned $lock_race_status instead of 143"
fi
[[ -e "$lock_race_marker" ]] || fail 'lock race test did not signal after publishing the lock directory'
[[ ! -e "$lock_race_prefix/.git-tp.lock" ]] || fail 'SIGTERM during lock publication left a stale lock'

busy_lock_prefix="$TEST_HOME/busy-lock-prefix"
mkdir -p "$busy_lock_prefix/.git-tp.lock"
printf '98765432\n' > "$busy_lock_prefix/.git-tp.lock/pid"
if GIT_TP_SOURCE_URL="file://$ARCHIVE" bash "$INSTALLER" --install-dir "$busy_lock_prefix" \
    >"$TEST_HOME/stdout" 2>"$TEST_HOME/stderr"; then
    fail 'installer replaced an existing installation lock'
fi
grep -Fq 'lock owner PID: 98765432' "$TEST_HOME/stderr" || fail 'existing installation lock did not report its owner'
[[ "$(<"$busy_lock_prefix/.git-tp.lock/pid")" == '98765432' ]] || fail 'failed lock acquisition changed another installer lock'

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

copy_failure_bin="$TEST_HOME/copy-failure-bin"
mkdir -p "$copy_failure_bin"
real_cp=$(command -v cp)
cat > "$copy_failure_bin/cp" <<EOF
#!/bin/sh
destination=''
for argument do destination=\$argument; done
case "\$destination" in
    */.git-tp/versions/release.*/lib/git-tp) exit 1 ;;
esac
exec "$real_cp" "\$@"
EOF
chmod +x "$copy_failure_bin/cp"
current_release_before_copy_failure=$(readlink "$PREFIX/.git-tp/current")
if PATH="$copy_failure_bin:$PATH" "$PREFIX/bin/git-tp" update \
    >"$TEST_HOME/stdout" 2>"$TEST_HOME/stderr"; then
    fail 'update published a release after copying the runtime failed'
fi
grep -Fq 'unable to stage release runtime' "$TEST_HOME/stderr" ||
    fail 'runtime copy failure did not report its staging error'
[[ "$(readlink "$PREFIX/.git-tp/current")" == "$current_release_before_copy_failure" ]] ||
    fail 'runtime copy failure changed the current release pointer'
[[ "$("$PREFIX/bin/git-tp" --version)" == 'git-tp 0.1.0' ]] ||
    fail 'runtime copy failure damaged the working installation'

invalid_runtime_root="$TEST_HOME/invalid-runtime-source"
mkdir -p "$invalid_runtime_root"
cp -R "$ROOT_DIR/bin" "$ROOT_DIR/lib" "$invalid_runtime_root/"
cp "$ROOT_DIR/install.sh" "$invalid_runtime_root/"
sed -i 's/GIT_TP_VERSION="0.1.0"/GIT_TP_VERSION="0.2.0"/' "$invalid_runtime_root/bin/git-tp"
printf '\nif then\n' >> "$invalid_runtime_root/bin/git-tp"
invalid_runtime_archive="$TEST_HOME/invalid-runtime.tar.gz"
tar -czf "$invalid_runtime_archive" -C "$invalid_runtime_root" bin lib install.sh
previous_release=$(readlink "$PREFIX/.git-tp/current")
printf 'file://%s\n' "$invalid_runtime_archive" > "$PREFIX/.git-tp/current/source"
if "$PREFIX/bin/git-tp" update --check >"$TEST_HOME/stdout" 2>"$TEST_HOME/stderr"; then
    fail 'update check accepted an unusable source executable'
fi
grep -Fq 'source executable cannot be run' "$TEST_HOME/stderr" || fail 'update check did not reject an invalid source executable'
[[ "$(readlink "$PREFIX/.git-tp/current")" == "$previous_release" ]] || fail 'invalid source executable check changed the current release pointer'
[[ "$("$PREFIX/bin/git-tp" --version)" == 'git-tp 0.1.0' ]] || fail 'invalid source executable check damaged the working installation'
if "$PREFIX/bin/git-tp" update >"$TEST_HOME/stdout" 2>"$TEST_HOME/stderr"; then
    fail 'update accepted an unusable source executable'
fi
grep -Fq 'source executable cannot be run' "$TEST_HOME/stderr" || fail 'invalid source executable did not report a runtime error'
[[ "$(readlink "$PREFIX/.git-tp/current")" == "$previous_release" ]] || fail 'invalid source executable changed the current release pointer'
[[ "$($PREFIX/bin/git-tp --version)" == 'git-tp 0.1.0' ]] || fail 'invalid source executable damaged the working installation'

invalid_installer_root="$TEST_HOME/invalid-installer-source"
mkdir -p "$invalid_installer_root"
cp -R "$ROOT_DIR/bin" "$ROOT_DIR/lib" "$invalid_installer_root/"
cp "$ROOT_DIR/install.sh" "$invalid_installer_root/"
sed -i 's/GIT_TP_VERSION="0.1.0"/GIT_TP_VERSION="0.2.0"/' "$invalid_installer_root/bin/git-tp"
printf '\nif then\n' >> "$invalid_installer_root/install.sh"
invalid_installer_archive="$TEST_HOME/invalid-installer.tar.gz"
tar -czf "$invalid_installer_archive" -C "$invalid_installer_root" bin lib install.sh
printf 'file://%s\n' "$invalid_installer_archive" > "$PREFIX/.git-tp/current/source"
if "$PREFIX/bin/git-tp" update >"$TEST_HOME/stdout" 2>"$TEST_HOME/stderr"; then
    fail 'update accepted an installer with invalid shell syntax'
fi
grep -Fq 'source installer contains invalid shell syntax' "$TEST_HOME/stderr" || fail 'update did not reject an invalid archived installer'
[[ "$(readlink "$PREFIX/.git-tp/current")" == "$previous_release" ]] || fail 'invalid archived installer changed the current release pointer'
[[ "$($PREFIX/bin/git-tp --version)" == 'git-tp 0.1.0' ]] || fail 'invalid archived installer damaged the working installation'
printf 'file://%s\n' "$ARCHIVE" > "$PREFIX/.git-tp/current/source"

legacy_prefix="$TEST_HOME/legacy"
mkdir -p "$legacy_prefix/bin" "$legacy_prefix/lib"
cp "$ROOT_DIR/bin/git-tp" "$legacy_prefix/bin/git-tp"
cp -R "$ROOT_DIR/lib/git-tp" "$legacy_prefix/lib/"
printf 'file://%s\n' "$ARCHIVE" > "$legacy_prefix/.git-tp-source"
[[ ! -e "$legacy_prefix/lib/git-tp/install.sh" ]] || fail 'legacy fixture unexpectedly contains an installed installer'
legacy_rm_bin="$TEST_HOME/legacy-rm-bin"
legacy_rm_marker="$TEST_HOME/legacy-rm-failure-seen"
mkdir -p "$legacy_rm_bin"
real_rm=$(command -v rm)
cat > "$legacy_rm_bin/rm" <<EOF
#!/bin/sh
for argument do
    if [ "\$argument" = "$legacy_prefix/.git-tp-source" ]; then
        : > "$legacy_rm_marker"
        exit 1
    fi
done
exec "$real_rm" "\$@"
EOF
chmod +x "$legacy_rm_bin/rm"

legacy_check_root="$TEST_HOME/legacy-check-source"
legacy_check_prefix="$TEST_HOME/legacy-check"
mkdir -p "$legacy_check_root" "$legacy_check_prefix/bin" "$legacy_check_prefix/lib"
cp -R "$ROOT_DIR/bin" "$ROOT_DIR/lib" "$legacy_check_root/"
cp "$ROOT_DIR/install.sh" "$legacy_check_root/"
sed -i '/^set -eu/a : > "$GIT_TP_TEST_INSTALLER_MARKER"' "$legacy_check_root/install.sh"
tar -czf "$TEST_HOME/legacy-check-source.tar.gz" -C "$legacy_check_root" bin lib install.sh
cp "$ROOT_DIR/bin/git-tp" "$legacy_check_prefix/bin/git-tp"
cp -R "$ROOT_DIR/lib/git-tp" "$legacy_check_prefix/lib/"
printf 'file://%s/legacy-check-source.tar.gz\n' "$TEST_HOME" > "$legacy_check_prefix/.git-tp-source"
legacy_check_marker="$TEST_HOME/legacy-check-installer-marker"
if GIT_TP_TEST_INSTALLER_MARKER="$legacy_check_marker" \
    "$legacy_check_prefix/bin/git-tp" update --check >"$TEST_HOME/stdout" 2>"$TEST_HOME/stderr"; then
    fail 'legacy update --check unexpectedly succeeded without a trusted installer'
fi
grep -Fq 'cannot safely check a legacy installation' "$TEST_HOME/stderr" || fail 'legacy update --check did not explain the safe migration path'
[[ ! -e "$legacy_check_marker" ]] || fail 'legacy update --check executed install.sh from the source archive'

if ! PATH="$legacy_rm_bin:$PATH" "$legacy_prefix/bin/git-tp" update >"$TEST_HOME/stdout" 2>"$TEST_HOME/stderr"; then
    cat "$TEST_HOME/stderr" >&2
    [[ -e "$legacy_rm_marker" ]] || fail 'legacy update failed before old metadata cleanup'
    fail 'legacy update reported failure after publishing its new release'
fi
[[ -e "$legacy_rm_marker" ]] || fail 'legacy update did not attempt to clean old metadata'
grep -Fq 'warning: unable to remove legacy source metadata' "$TEST_HOME/stderr" || fail 'legacy metadata cleanup failure was not reported as a warning'
[[ "$($legacy_prefix/bin/git-tp --version)" == 'git-tp 0.1.0' ]] || fail 'legacy update did not install the archived version'
[[ -L "$legacy_prefix/.git-tp/current" ]] || fail 'legacy update did not migrate to versioned layout'

old_cli_prefix="$TEST_HOME/old-cli-install"
mkdir -p "$old_cli_prefix/bin" "$old_cli_prefix/lib"
cp "$ROOT_DIR/tests/fixtures/legacy-bin/git-tp" "$old_cli_prefix/bin/git-tp"
chmod +x "$old_cli_prefix/bin/git-tp"
cp -R "$ROOT_DIR/lib/git-tp" "$old_cli_prefix/lib/"
printf 'file://%s\n' "$ARCHIVE" > "$old_cli_prefix/.git-tp-source"
if PATH="$old_cli_prefix/bin:$PATH" git tp update >"$TEST_HOME/stdout" 2>"$TEST_HOME/stderr"; then
    fail 'pre-update CLI unexpectedly accepted git tp update'
fi
grep -Fq 'unknown command: update' "$TEST_HOME/stderr" || fail 'pre-update CLI did not report update as an unknown command'
GIT_TP_SOURCE_URL="file://$ARCHIVE" bash "$INSTALLER" --install-dir "$old_cli_prefix" \
    >"$TEST_HOME/stdout" 2>"$TEST_HOME/stderr" || {
    cat "$TEST_HOME/stderr" >&2
    fail 'supported installer could not migrate the pre-update CLI'
}
[[ -L "$old_cli_prefix/.git-tp/current" ]] || fail 'pre-update CLI installer did not create the versioned layout'
[[ "$($old_cli_prefix/bin/git-tp --version)" == 'git-tp 0.1.0' ]] || fail 'pre-update CLI migration did not install the supported entry point'

unsafe_version_root="$TEST_HOME/unsafe-version-source"
unsafe_version_prefix="$TEST_HOME/unsafe-version-prefix"
mkdir -p "$unsafe_version_root"
cp -R "$ROOT_DIR/bin" "$ROOT_DIR/lib" "$unsafe_version_root/"
cp "$ROOT_DIR/install.sh" "$unsafe_version_root/"
sed -i 's/GIT_TP_VERSION="0.1.0"/GIT_TP_VERSION="..\/..\/escape"/' "$unsafe_version_root/bin/git-tp"
tar -czf "$TEST_HOME/unsafe-version.tar.gz" -C "$unsafe_version_root" bin lib install.sh
GIT_TP_SOURCE_URL="file://$TEST_HOME/unsafe-version.tar.gz" bash "$INSTALLER" --install-dir "$unsafe_version_prefix" \
    >"$TEST_HOME/stdout" 2>"$TEST_HOME/stderr" && fail 'installer accepted a path-like source version'
assert_no_matches "$unsafe_version_prefix/escape.*" 'source version escaped the releases directory'

updated_root="$TEST_HOME/updated-source"
mkdir -p "$updated_root"
cp -R "$ROOT_DIR/bin" "$ROOT_DIR/lib" "$updated_root/"
cp "$ROOT_DIR/install.sh" "$updated_root/"
sed -i 's/GIT_TP_VERSION="0.1.0"/GIT_TP_VERSION="0.2.0"/' "$updated_root/bin/git-tp"
printf 'updated runtime\n' > "$updated_root/lib/git-tp/updated-marker"
updated_archive="$TEST_HOME/updated.tar.gz"
tar -czf "$updated_archive" -C "$updated_root" bin lib install.sh
interrupted_prefix="$TEST_HOME/interrupted-update"
GIT_TP_SOURCE_URL="file://$ARCHIVE" bash "$INSTALLER" --install-dir "$interrupted_prefix" \
    >"$TEST_HOME/stdout" 2>"$TEST_HOME/stderr" || {
    cat "$TEST_HOME/stderr" >&2
    fail 'unable to install interrupted-update fixture'
}
interrupted_current=$(readlink "$interrupted_prefix/.git-tp/current")
interrupt_mv_bin="$TEST_HOME/interrupt-mv-bin"
interrupt_mv_marker="$TEST_HOME/interrupt-mv-seen"
mkdir -p "$interrupt_mv_bin"
cat > "$interrupt_mv_bin/mv" <<EOF
#!/bin/sh
destination=''
for argument do destination=\$argument; done
if [ "\$destination" = "\${GIT_TP_TEST_INTERRUPT_TARGET:-}" ] && [ ! -e "\${GIT_TP_TEST_INTERRUPT_MARKER:-}" ]; then
    "$real_mv" "\$@" || exit
    : > "\${GIT_TP_TEST_INTERRUPT_MARKER:?}"
    kill -TERM "\$PPID"
    exit 0
fi
exec "$real_mv" "\$@"
EOF
chmod +x "$interrupt_mv_bin/mv"
if PATH="$interrupt_mv_bin:$PATH" GIT_TP_TEST_INTERRUPT_TARGET="$interrupted_prefix/.git-tp/current" \
    GIT_TP_TEST_INTERRUPT_MARKER="$interrupt_mv_marker" GIT_TP_SOURCE_URL="file://$updated_archive" \
    bash "$INSTALLER" --install-dir "$interrupted_prefix" \
    >"$TEST_HOME/stdout" 2>"$TEST_HOME/stderr"; then
    fail 'installer succeeded after interruption immediately following current publication'
fi
[[ -e "$interrupt_mv_marker" ]] || fail 'interrupted install test did not interrupt after current publication'
[[ "$(readlink "$interrupted_prefix/.git-tp/current")" == "$interrupted_current" ]] || fail 'interrupted install did not restore the previous current release'
[[ "$("$interrupted_prefix/bin/git-tp" --version)" == 'git-tp 0.1.0' ]] || fail 'interrupted install damaged the previous entry point'
cat > "$interrupted_prefix/bin/git-tp" <<'EOF'
#!/bin/sh
install_root=$(CDPATH= cd "$(dirname "$0")/.." && pwd -P)
exec "$install_root/.git-tp/current/bin/git-tp" "$@"
EOF
chmod +x "$interrupted_prefix/bin/git-tp"
launcher_interrupt_bin="$TEST_HOME/launcher-interrupt-bin"
launcher_interrupt_marker="$TEST_HOME/launcher-interrupt-seen"
mkdir -p "$launcher_interrupt_bin"
cat > "$launcher_interrupt_bin/mv" <<EOF
#!/bin/sh
if [ "\${2:-}" = "$interrupted_prefix/bin/git-tp" ] && [ ! -e "$launcher_interrupt_marker" ]; then
    "$real_mv" "\$@" || exit
    : > "$launcher_interrupt_marker"
    kill -TERM "\$PPID"
    exit 0
fi
exec "$real_mv" "\$@"
EOF
chmod +x "$launcher_interrupt_bin/mv"
if PATH="$launcher_interrupt_bin:$PATH" GIT_TP_SOURCE_URL="file://$updated_archive" \
    bash "$INSTALLER" --install-dir "$interrupted_prefix" \
    >"$TEST_HOME/stdout" 2>"$TEST_HOME/stderr"; then
    fail 'installer succeeded after interruption immediately following launcher replacement'
fi
[[ -e "$launcher_interrupt_marker" ]] || fail 'launcher interruption test did not interrupt after launcher replacement'
[[ "$(readlink "$interrupted_prefix/.git-tp/current")" == "$interrupted_current" ]] || fail 'launcher interruption did not restore the previous current release'
[[ "$("$interrupted_prefix/bin/git-tp" --version)" == 'git-tp 0.1.0' ]] || fail 'launcher interruption did not restore the previous entry point'
first_interrupt_prefix="$TEST_HOME/interrupted-first-install"
first_interrupt_marker="$TEST_HOME/first-install-interrupt-seen"
if PATH="$interrupt_mv_bin:$PATH" GIT_TP_TEST_INTERRUPT_TARGET="$first_interrupt_prefix/.git-tp/current" \
    GIT_TP_TEST_INTERRUPT_MARKER="$first_interrupt_marker" GIT_TP_SOURCE_URL="file://$updated_archive" \
    bash "$INSTALLER" --install-dir "$first_interrupt_prefix" \
    >"$TEST_HOME/stdout" 2>"$TEST_HOME/stderr"; then
    fail 'first installation succeeded after interruption immediately following current publication'
fi
[[ -e "$first_interrupt_marker" ]] || fail 'first-install interruption did not occur after current publication'
[[ ! -e "$first_interrupt_prefix/.git-tp/current" ]] || fail 'interrupted first install left a current release published'
[[ ! -e "$first_interrupt_prefix/bin/git-tp" ]] || fail 'interrupted first install left a stable launcher without a current release'
assert_no_matches "$first_interrupt_prefix/.git-tp/versions/release.*" 'interrupted first install left an incomplete release directory'
stale_prefix="$TEST_HOME/stale-update"
GIT_TP_SOURCE_URL="file://$ARCHIVE" bash "$INSTALLER" --install-dir "$stale_prefix" \
    >"$TEST_HOME/stdout" 2>"$TEST_HOME/stderr" || {
    cat "$TEST_HOME/stderr" >&2
    fail 'unable to install stale-update fixture'
}
stale_current=$(readlink "$stale_prefix/.git-tp/current")
GIT_TP_SOURCE_URL="file://$updated_archive" bash "$INSTALLER" --install-dir "$stale_prefix" \
    >"$TEST_HOME/stdout" 2>"$TEST_HOME/stderr" || {
    cat "$TEST_HOME/stderr" >&2
    fail 'unable to advance stale-update fixture'
}
latest_current=$(readlink "$stale_prefix/.git-tp/current")
if GIT_TP_EXPECTED_CURRENT_SET=true GIT_TP_EXPECTED_CURRENT="$stale_current" GIT_TP_SOURCE_URL="file://$ARCHIVE" \
    bash "$INSTALLER" --install-dir "$stale_prefix" \
    >"$TEST_HOME/stdout" 2>"$TEST_HOME/stderr"; then
    fail 'installer accepted an update based on a stale current release'
fi
grep -Fq 'installation changed during update' "$TEST_HOME/stderr" || fail 'stale update did not report that the installation changed'
[[ "$(readlink "$stale_prefix/.git-tp/current")" == "$latest_current" ]] || fail 'stale update replaced the latest release'
[[ "$("$stale_prefix/bin/git-tp" --version)" == 'git-tp 0.2.0' ]] || fail 'stale update damaged the latest executable'
third_root="$TEST_HOME/third-source"
mkdir -p "$third_root"
cp -R "$updated_root/bin" "$updated_root/lib" "$third_root/"
cp "$ROOT_DIR/install.sh" "$third_root/"
sed -i 's/GIT_TP_VERSION="0.2.0"/GIT_TP_VERSION="0.3.0"/' "$third_root/bin/git-tp"
third_archive="$TEST_HOME/template-0.3.0.tar.gz"
tar -czf "$third_archive" -C "$third_root" bin lib install.sh
race_prefix="$TEST_HOME/race-install"
race_template="file://$TEST_HOME/race-{version}.tar.gz"
cp "$updated_archive" "$TEST_HOME/race-0.2.0.tar.gz"
cp "$third_archive" "$TEST_HOME/race-0.3.0.tar.gz"
GIT_TP_SOURCE_URL="file://$ARCHIVE" bash "$INSTALLER" --install-dir "$race_prefix" \
    >"$TEST_HOME/stdout" 2>"$TEST_HOME/stderr" || {
    cat "$TEST_HOME/stderr" >&2
    fail 'unable to install concurrent-update fixture'
}
race_old_current=$(readlink "$race_prefix/.git-tp/current")
GIT_TP_SOURCE_URL="$race_template" GIT_TP_DOWNLOAD_URL="file://$updated_archive" \
    GIT_TP_EXPECTED_CURRENT_SET=true GIT_TP_EXPECTED_CURRENT="$race_old_current" \
    bash "$INSTALLER" --install-dir "$race_prefix" >"$TEST_HOME/stdout" 2>"$TEST_HOME/stderr" || {
    cat "$TEST_HOME/stderr" >&2
    fail 'unable to prepare first concurrent-update version'
}
race_mid_current=$(readlink "$race_prefix/.git-tp/current")
GIT_TP_SOURCE_URL="$race_template" GIT_TP_DOWNLOAD_URL="file://$third_archive" \
    GIT_TP_EXPECTED_CURRENT_SET=true GIT_TP_EXPECTED_CURRENT="$race_mid_current" \
    bash "$INSTALLER" --install-dir "$race_prefix" >"$TEST_HOME/stdout" 2>"$TEST_HOME/stderr" || {
    cat "$TEST_HOME/stderr" >&2
    fail 'unable to prepare latest concurrent-update version'
}
race_latest_current=$(readlink "$race_prefix/.git-tp/current")
race_readlink_bin="$TEST_HOME/race-readlink-bin"
race_readlink_marker="$TEST_HOME/race-readlink-marker"
mkdir -p "$race_readlink_bin"
real_readlink=$(command -v readlink)
cat > "$race_readlink_bin/readlink" <<EOF
#!/bin/sh
if [ "\${1:-}" = "$race_prefix/.git-tp/current" ] && [ ! -e "$race_readlink_marker" ]; then
    : > "$race_readlink_marker"
    printf '%s\\n' "$race_mid_current"
    exit 0
fi
exec "$real_readlink" "\$@"
EOF
chmod +x "$race_readlink_bin/readlink"
if PATH="$race_readlink_bin:$PATH" "$race_prefix/bin/git-tp" update --version 0.2.0 \
    >"$TEST_HOME/stdout" 2>"$TEST_HOME/stderr"; then
    fail 'CLI update published from a stale release snapshot'
fi
grep -Fq 'installation changed during update' "$TEST_HOME/stderr" || fail 'CLI stale update did not report the changed installation'
[[ -e "$race_readlink_marker" ]] || fail 'CLI stale-update test did not intercept the snapshot read'
[[ "$(readlink "$race_prefix/.git-tp/current")" == "$race_latest_current" ]] || fail 'CLI stale update replaced the latest release'
[[ "$("$race_prefix/bin/git-tp" --version)" == 'git-tp 0.3.0' ]] || fail 'CLI stale update damaged the latest executable'
check_link="$race_prefix/.git-tp/.check-current"
ln -s "$race_mid_current" "$check_link"
mv -Tf "$check_link" "$race_prefix/.git-tp/current"
check_curl_bin="$TEST_HOME/check-curl-bin"
check_curl_marker="$TEST_HOME/check-curl-race-seen"
mkdir -p "$check_curl_bin"
real_curl=$(command -v curl)
real_ln=$(command -v ln)
cat > "$check_curl_bin/curl" <<EOF
#!/bin/sh
"$real_curl" "\$@" || exit
if [ ! -e "$check_curl_marker" ]; then
    : > "$check_curl_marker"
    "$real_ln" -s "$race_latest_current" "$race_prefix/.git-tp/.check-current" || exit 1
    "$real_mv" -Tf "$race_prefix/.git-tp/.check-current" "$race_prefix/.git-tp/current" || exit 1
fi
EOF
chmod +x "$check_curl_bin/curl"
if PATH="$check_curl_bin:$PATH" "$race_prefix/bin/git-tp" update --check --version 0.2.0 \
    >"$TEST_HOME/stdout" 2>"$TEST_HOME/stderr"; then
    fail 'CLI update --check accepted a stale current snapshot'
fi
grep -Fq 'installation changed during update check' "$TEST_HOME/stderr" || fail 'CLI stale update check did not report the changed installation'
if grep -Fq 'update available: 0.3.0 -> 0.2.0' "$TEST_HOME/stdout"; then
    fail 'CLI update --check reported an update to a version older than the current release'
fi
[[ -e "$check_curl_marker" ]] || fail 'CLI stale update check did not switch current during download'
[[ "$(readlink "$race_prefix/.git-tp/current")" == "$race_latest_current" ]] || fail 'CLI stale update check changed the latest release'
template_prefix="$TEST_HOME/template-install"
GIT_TP_SOURCE_URL="file://$ARCHIVE" bash "$INSTALLER" --install-dir "$template_prefix" \
    >"$TEST_HOME/stdout" 2>"$TEST_HOME/stderr" || {
    cat "$TEST_HOME/stderr" >&2
    fail 'unable to install template update fixture'
}
template_url="file://$TEST_HOME/template-{version}.tar.gz"
printf '%s\n' "$template_url" > "$template_prefix/.git-tp/current/source"
cp "$updated_archive" "$TEST_HOME/template-0.2.0.tar.gz"
if ! "$template_prefix/bin/git-tp" update --check --version 0.2.0 >"$TEST_HOME/stdout" 2>"$TEST_HOME/stderr"; then
    cat "$TEST_HOME/stderr" >&2
    fail 'version-template update check failed'
fi
grep -Fq 'update available: 0.1.0 -> 0.2.0' "$TEST_HOME/stdout" || fail 'version-template check reported incorrect versions'
[[ "$(<"$template_prefix/.git-tp/current/source")" == "$template_url" ]] || fail 'version-template check changed source metadata'
if ! "$template_prefix/bin/git-tp" update --version 0.2.0 >"$TEST_HOME/stdout" 2>"$TEST_HOME/stderr"; then
    cat "$TEST_HOME/stderr" >&2
    fail 'first update from a version template failed'
fi
[[ "$(<"$template_prefix/.git-tp/current/source")" == "$template_url" ]] || fail 'first update discarded the source version template'
rm "$template_prefix/.git-tp/current/lib/git-tp/install.sh"
template_release_before_copy_failure=$(readlink "$template_prefix/.git-tp/current")
if PATH="$copy_failure_bin:$PATH" "$template_prefix/bin/git-tp" update --version 0.3.0 \
    >"$TEST_HOME/stdout" 2>"$TEST_HOME/stderr"; then
    fail 'bootstrap update published a release after copying the runtime failed'
fi
grep -Fq 'unable to stage release runtime' "$TEST_HOME/stderr" ||
    fail 'bootstrap runtime copy failure did not report its staging error'
[[ "$(readlink "$template_prefix/.git-tp/current")" == "$template_release_before_copy_failure" ]] ||
    fail 'bootstrap runtime copy failure changed the current release pointer'
[[ "$("$template_prefix/bin/git-tp" --version)" == 'git-tp 0.2.0' ]] ||
    fail 'bootstrap runtime copy failure damaged the working installation'
bootstrap_curl_bin="$TEST_HOME/bootstrap-curl-bin"
bootstrap_curl_count="$TEST_HOME/bootstrap-curl-count"
mkdir -p "$bootstrap_curl_bin"
real_curl=$(command -v curl)
cat > "$bootstrap_curl_bin/curl" <<EOF
#!/bin/sh
printf 'curl\n' >> "$bootstrap_curl_count"
exec "$real_curl" "\$@"
EOF
chmod +x "$bootstrap_curl_bin/curl"
if ! PATH="$bootstrap_curl_bin:$PATH" "$template_prefix/bin/git-tp" update --version 0.3.0 \
    >"$TEST_HOME/stdout" 2>"$TEST_HOME/stderr"; then
    cat "$TEST_HOME/stderr" >&2
    fail 'second update from a version template failed after installer bootstrap'
fi
[[ "$(wc -l < "$bootstrap_curl_count")" -eq 1 ]] || fail 'bootstrap update downloaded its source archive more than once'
[[ "$("$template_prefix/bin/git-tp" --version)" == 'git-tp 0.3.0' ]] || fail 'second template update did not install version 0.3.0'
[[ "$(<"$template_prefix/.git-tp/current/source")" == "$template_url" ]] || fail 'second update discarded the source version template'
template_current_release=$(readlink "$template_prefix/.git-tp/current")
cp "$third_archive" "$TEST_HOME/template-0.2.0.tar.gz"
if "$template_prefix/bin/git-tp" update --version 0.2.0 >"$TEST_HOME/stdout" 2>"$TEST_HOME/stderr"; then
    fail 'update installed a source version different from the requested version'
fi
grep -Fq 'requested version 0.2.0 does not match source version 0.3.0' "$TEST_HOME/stderr" ||
    fail 'mismatched source version did not report the requested and actual versions'
[[ "$(readlink "$template_prefix/.git-tp/current")" == "$template_current_release" ]] || fail 'mismatched source version changed the current release pointer'
[[ "$("$template_prefix/bin/git-tp" --version)" == 'git-tp 0.3.0' ]] || fail 'mismatched source version damaged the working installation'
PINNED_PREFIX="$TEST_HOME/pinned"
GIT_TP_SOURCE_URL="file://$updated_archive" sh -c 'cat "$1" | sh -s -- --install-dir "$2"' \
    sh "$INSTALLER" "$PINNED_PREFIX" >"$TEST_HOME/stdout" 2>"$TEST_HOME/stderr" || {
    cat "$TEST_HOME/stderr" >&2
    fail 'version-pinned installer command failed'
}
[[ "$($PINNED_PREFIX/bin/git-tp --version)" == 'git-tp 0.2.0' ]] || fail 'version-pinned installer did not install the requested release'
mkdir -p "$TEST_HOME/archive/refs/heads" "$TEST_HOME/archive/refs/tags"
cp "$ARCHIVE" "$TEST_HOME/archive/refs/heads/main.tar.gz"
cp "$updated_archive" "$TEST_HOME/archive/refs/tags/v0.2.0.tar.gz"
space_prefix="$TEST_HOME/prefix with spaces"
GIT_TP_SOURCE_URL="file://$TEST_HOME/archive/refs/heads/main.tar.gz" bash "$INSTALLER" --install-dir "$space_prefix" \
    >"$TEST_HOME/stdout" 2>"$TEST_HOME/stderr" || {
    cat "$TEST_HOME/stderr" >&2
    fail 'installer did not support an install prefix containing spaces'
}
if ! "$space_prefix/bin/git-tp" update --check --version 0.2.0 \
    >"$TEST_HOME/stdout" 2>"$TEST_HOME/stderr"; then
    cat "$TEST_HOME/stderr" >&2
    fail 'update --check failed with an install prefix containing spaces'
fi
grep -Fq 'update available: 0.1.0 -> 0.2.0' "$TEST_HOME/stdout" || fail 'spaced-prefix check reported incorrect versions'
if ! "$space_prefix/bin/git-tp" update --version 0.2.0 \
    >"$TEST_HOME/stdout" 2>"$TEST_HOME/stderr"; then
    cat "$TEST_HOME/stderr" >&2
    fail 'update failed with an install prefix containing spaces'
fi
grep -Fq 'git-tp updated: 0.1.0 -> 0.2.0' "$TEST_HOME/stdout" || fail 'spaced-prefix update reported incorrect versions'
[[ "$("$space_prefix/bin/git-tp" --version)" == 'git-tp 0.2.0' ]] || fail 'spaced-prefix update did not install the new version'
printf 'user configuration\n' > "$PREFIX/user-file"
assert_update() {
    if ! "$@" >"$TEST_HOME/stdout" 2>"$TEST_HOME/stderr"; then
        cat "$TEST_HOME/stderr" >&2
        fail "update command failed: $*"
    fi
}
printf 'file://%s/archive/refs/heads/main.tar.gz\n' "$TEST_HOME" > "$PREFIX/.git-tp/current/source"
assert_update "$PREFIX/bin/git-tp" update --check --version 0.2.0
grep -Fq 'update available' "$TEST_HOME/stdout" || fail 'update check did not report an available update'
assert_update "$PREFIX/bin/git-tp" update --check
grep -Fq 'git-tp is up to date (0.1.0)' "$TEST_HOME/stdout" || fail 'same-version check reported an update'
if "$PREFIX/bin/git-tp" update --version '' >"$TEST_HOME/stdout" 2>"$TEST_HOME/stderr"; then
    fail 'update accepted an empty version'
fi
grep -Fq -- '--version requires a non-empty version' "$TEST_HOME/stderr" || fail 'empty version did not report a clear error'
assert_no_matches "$PREFIX/.git-tp-staging.*" 'update check wrote a staging directory'
assert_no_matches "$PREFIX/.git-tp-backup.*" 'update check wrote a backup directory'

malicious_version_root="$TEST_HOME/malicious-version-source"
mkdir -p "$malicious_version_root"
cp -R "$updated_root/bin" "$updated_root/lib" "$malicious_version_root/"
cp "$ROOT_DIR/install.sh" "$malicious_version_root/"
sed -i '/GIT_TP_VERSION=/a printf hacked > "$GIT_TP_MARKER"' "$malicious_version_root/bin/git-tp"
tar -czf "$TEST_HOME/malicious-version.tar.gz" -C "$malicious_version_root" bin lib install.sh
printf 'file://%s/malicious-version.tar.gz\n' "$TEST_HOME" > "$PREFIX/.git-tp/current/source"
GIT_TP_MARKER="$TEST_HOME/version-marker" assert_update "$PREFIX/bin/git-tp" update --check
[[ ! -e "$TEST_HOME/version-marker" ]] || fail 'update check executed source archive code'

tag_root="$TEST_HOME/tag-source"
mkdir -p "$tag_root/archive/refs/tags"
cp "$updated_archive" "$tag_root/archive/refs/tags/v0.2.0.tar.gz"
printf 'file://%s/archive/refs/tags/v0.1.0.tar.gz\n' "$tag_root" > "$PREFIX/.git-tp/current/source"
cp "$ARCHIVE" "$tag_root/archive/refs/tags/v0.1.0.tar.gz"
assert_update "$PREFIX/bin/git-tp" update --check --version 0.2.0
tagged_prefix="$TEST_HOME/tagged-update"
GIT_TP_SOURCE_URL="file://$tag_root/archive/refs/tags/v0.1.0.tar.gz" bash "$INSTALLER" --install-dir "$tagged_prefix" \
    >"$TEST_HOME/stdout" 2>"$TEST_HOME/stderr" || {
    cat "$TEST_HOME/stderr" >&2
    fail 'unable to install tag-pinned update fixture'
}
assert_update "$tagged_prefix/bin/git-tp" update --version 0.2.0
assert_update "$tagged_prefix/bin/git-tp" update
[[ "$($tagged_prefix/bin/git-tp --version)" == 'git-tp 0.2.0' ]] || fail 'ordinary update downgraded the explicitly selected release'
[[ "$(<"$tagged_prefix/.git-tp/current/source")" == "file://$tag_root/archive/refs/tags/v0.2.0.tar.gz" ]] || fail 'pinned update did not persist the selected tag source'

release_root="$TEST_HOME/release-source"
mkdir -p "$release_root/releases/download/v0.1.0"
cp "$ARCHIVE" "$release_root/releases/download/v0.1.0/git-tp.tar.gz"
mkdir -p "$release_root/releases/download/v0.2.0"
cp "$updated_archive" "$release_root/releases/download/v0.2.0/git-tp.tar.gz"
printf 'file://%s/releases/download/v0.1.0/git-tp.tar.gz\n' "$release_root" > "$PREFIX/.git-tp/current/source"
assert_update "$PREFIX/bin/git-tp" update --check --version 0.2.0

mkdir "$PREFIX/.git-tp.lock"
printf '99999999\n' > "$PREFIX/.git-tp.lock/pid"
if ! "$PREFIX/bin/git-tp" --help >"$TEST_HOME/stdout" 2>"$TEST_HOME/stderr"; then
    fail 'installation lock blocked the read-only help command'
fi
grep -Fq 'git tp update' "$TEST_HOME/stdout" || fail 'help command did not print usage while the installation lock was present'
if ! "$PREFIX/bin/git-tp" update --help >"$TEST_HOME/stdout" 2>"$TEST_HOME/stderr"; then
    fail 'installation lock blocked the read-only update help command'
fi
grep -Fq 'Usage: git tp update' "$TEST_HOME/stdout" || fail 'update help did not print usage while the installation lock was present'
if ! "$PREFIX/bin/git-tp" update --check --help >"$TEST_HOME/stdout" 2>"$TEST_HOME/stderr"; then
    fail 'installation lock blocked update help after --check'
fi
grep -Fq 'Usage: git tp update' "$TEST_HOME/stdout" || fail 'update --check --help did not print usage while the installation lock was present'
if ! "$PREFIX/bin/git-tp" --version >"$TEST_HOME/stdout" 2>"$TEST_HOME/stderr"; then
    fail 'installation lock blocked the read-only version command'
fi
grep -Fq 'git-tp 0.1.0' "$TEST_HOME/stdout" || fail 'version command did not print the version while the installation lock was present'
if "$PREFIX/bin/git-tp" update --check >"$TEST_HOME/stdout" 2>"$TEST_HOME/stderr"; then
    fail 'update ignored an active installation lock'
fi
grep -Fq 'installation is busy' "$TEST_HOME/stderr" || fail 'update did not report an active installation lock'
grep -Fq 'lock owner PID: 99999999' "$TEST_HOME/stderr" || fail 'busy lock did not report its owner PID'
rm "$PREFIX/.git-tp.lock/pid"
rmdir "$PREFIX/.git-tp.lock"
assert_update "$PREFIX/bin/git-tp" update --version 0.2.0
[[ "$($PREFIX/bin/git-tp --version)" == 'git-tp 0.2.0' ]] || fail 'update did not install the new version'
[[ -f "$PREFIX/.git-tp/current/lib/git-tp/updated-marker" ]] || fail 'update did not replace runtime files'
grep -Fq 'git-tp updated: 0.1.0 -> 0.2.0' "$TEST_HOME/stdout" || fail 'successful update did not report old and new versions'
[[ -f "$PREFIX/user-file" ]] || fail 'update removed an unrelated installation file'
current_release=$(readlink "$PREFIX/.git-tp/current")
printf 'file://%s\n' "$TEST_HOME/missing.tar.gz" > "$PREFIX/.git-tp/current/source"
if "$PREFIX/bin/git-tp" update >"$TEST_HOME/stdout" 2>"$TEST_HOME/stderr"; then
    fail 'failed update unexpectedly succeeded'
fi
[[ "$($PREFIX/bin/git-tp --version)" == 'git-tp 0.2.0' ]] || fail 'failed update damaged the working installation'
[[ "$(readlink "$PREFIX/.git-tp/current")" == "$current_release" ]] || fail 'failed update changed the current release pointer'
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
printf 'file://%s\n' "$symlink_archive" > "$PREFIX/.git-tp/current/source"
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

mv_command=$(command -v mv)
mkdir -p "$TEST_HOME/bin"
cat > "$TEST_HOME/bin/mv" <<EOF
#!/bin/sh
if [ "\${GIT_TP_INTERRUPT_ON_BACKUP:-}" = 1 ] && [ ! -e "$TEST_HOME/interrupt-seen" ] && case "\${3:-}" in *'/.git-tp/current') true;; *) false;; esac; then
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
[[ "$($PREFIX/bin/git-tp --version)" == 'git-tp 0.1.0' ]] || fail 'SIGTERM left an unusable installation'

rm -f "$TEST_HOME/interrupt-seen"
PATH="$TEST_HOME/bin:$PATH" GIT_TP_INTERRUPT_ON_BACKUP=1 GIT_TP_INTERRUPT_SIGNAL=INT \
    GIT_TP_SOURCE_URL="file://$ARCHIVE" bash "$INSTALLER" --install-dir "$PREFIX" \
    >"$TEST_HOME/stdout" 2>"$TEST_HOME/stderr" && fail 'installer ignored SIGINT'
[[ "$($PREFIX/bin/git-tp --version)" == 'git-tp 0.1.0' ]] || fail 'SIGINT left an unusable installation'

REAL_CURL=$(command -v curl)
REAL_TAR=$(command -v tar)

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
[[ "$($PREFIX/bin/git-tp --version)" == 'git-tp 0.1.0' ]] || fail 'download SIGTERM damaged the existing installation'
assert_no_matches "$PREFIX/.git-tp-staging.*" 'download SIGTERM left staging files'
assert_no_matches "$PREFIX/.git-tp-backup.*" 'download SIGTERM left backup files'

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
[[ "$($PREFIX/bin/git-tp --version)" == 'git-tp 0.1.0' ]] || fail 'extract SIGTERM damaged the existing installation'
assert_no_matches "$PREFIX/.git-tp-staging.*" 'extract SIGTERM left staging files'
assert_no_matches "$PREFIX/.git-tp-backup.*" 'extract SIGTERM left backup files'

printf 'PASS\n'