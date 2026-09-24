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
printf 'file://%s\n' "$ARCHIVE" > "$PREFIX/.git-tp/current/source"

legacy_prefix="$TEST_HOME/legacy"
mkdir -p "$legacy_prefix/bin" "$legacy_prefix/lib"
cp "$ROOT_DIR/bin/git-tp" "$legacy_prefix/bin/git-tp"
cp -R "$ROOT_DIR/lib/git-tp" "$legacy_prefix/lib/"
printf 'file://%s\n' "$ARCHIVE" > "$legacy_prefix/.git-tp-source"
[[ ! -e "$legacy_prefix/lib/git-tp/install.sh" ]] || fail 'legacy fixture unexpectedly contains an installed installer'

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

if ! "$legacy_prefix/bin/git-tp" update >"$TEST_HOME/stdout" 2>"$TEST_HOME/stderr"; then
    cat "$TEST_HOME/stderr" >&2
    fail 'legacy installation without a bundled installer could not update'
fi
[[ "$($legacy_prefix/bin/git-tp --version)" == 'git-tp 0.1.0' ]] || fail 'legacy update did not install the archived version'
[[ -L "$legacy_prefix/.git-tp/current" ]] || fail 'legacy update did not migrate to versioned layout'

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
third_root="$TEST_HOME/third-source"
mkdir -p "$third_root"
cp -R "$updated_root/bin" "$updated_root/lib" "$third_root/"
cp "$ROOT_DIR/install.sh" "$third_root/"
sed -i 's/GIT_TP_VERSION="0.2.0"/GIT_TP_VERSION="0.3.0"/' "$third_root/bin/git-tp"
third_archive="$TEST_HOME/template-0.3.0.tar.gz"
tar -czf "$third_archive" -C "$third_root" bin lib install.sh
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

release_root="$TEST_HOME/release-source"
mkdir -p "$release_root/releases/download/v0.1.0"
cp "$ARCHIVE" "$release_root/releases/download/v0.1.0/git-tp.tar.gz"
mkdir -p "$release_root/releases/download/v0.2.0"
cp "$updated_archive" "$release_root/releases/download/v0.2.0/git-tp.tar.gz"
printf 'file://%s/releases/download/v0.1.0/git-tp.tar.gz\n' "$release_root" > "$PREFIX/.git-tp/current/source"
assert_update "$PREFIX/bin/git-tp" update --check --version 0.2.0

mkdir "$PREFIX/.git-tp.lock"
printf '99999999\n' > "$PREFIX/.git-tp.lock/pid"
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