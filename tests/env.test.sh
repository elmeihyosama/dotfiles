#!/usr/bin/env bash
# 00-env.zsh.tmpl: Linux-only vars are conditional; macOS output is unchanged.
set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

tmpl="$TESTS_REPO/home/dot_config/zsh/conf.d/00-env.zsh.tmpl"
mk_home
export TESTS_CHEZMOI_OS=linux

# Stub dir prepended to PATH so locale availability never depends on the host.
stubs="$(mktemp -d)"
_tests_tmpdirs+=("$stubs")
printf '#!/bin/sh\necho C.UTF-8\n' >"$stubs/locale"
chmod +x "$stubs/locale"
stub_path="$stubs:$PATH"

# Strip inherited desktop/ssh/locale vars so only the case's own vars count.
clean=(-u BROWSER -u WAYLAND_DISPLAY -u DISPLAY -u SSH_CONNECTION -u SSH_TTY
	-u QT_QPA_PLATFORM -u XDG_SESSION_TYPE -u MOZ_ENABLE_WAYLAND -u LANG -u LC_ALL)

# ssh_no_desktop_vars: over ssh with no display, no BROWSER and no Wayland vars.
out="$(run_zsh_env "$tmpl" "${clean[@]}" SSH_CONNECTION="1.2.3.4 1 5.6.7.8 22")"
assert_not_contains "$out" "BROWSER=" "ssh_no_desktop_vars: BROWSER unset over ssh"
assert_not_contains "$out" "QT_QPA_PLATFORM" "ssh_no_desktop_vars: no QT_QPA_PLATFORM"
assert_not_contains "$out" "MOZ_ENABLE_WAYLAND" "ssh_no_desktop_vars: no MOZ_ENABLE_WAYLAND"
assert_not_contains "$out" "XDG_SESSION_TYPE=wayland" "ssh_no_desktop_vars: no XDG_SESSION_TYPE"

# ssh with X forwarding (DISPLAY set): still no BROWSER.
out="$(run_zsh_env "$tmpl" "${clean[@]}" SSH_CONNECTION="1.2.3.4 1 5.6.7.8 22" DISPLAY=localhost:10.0)"
assert_not_contains "$out" "BROWSER=" "ssh_with_display: BROWSER unset"

# SSH_TTY alone (no SSH_CONNECTION) counts as ssh too.
out="$(run_zsh_env "$tmpl" "${clean[@]}" SSH_TTY=/dev/pts/1 DISPLAY=:0)"
assert_not_contains "$out" "BROWSER=" "ssh_tty_only: BROWSER unset"

# no display and no ssh (e.g. a TTY): still no BROWSER on Linux.
out="$(run_zsh_env "$tmpl" "${clean[@]}")"
assert_not_contains "$out" "BROWSER=" "linux without display: BROWSER unset"

# wayland_desktop
out="$(run_zsh_env "$tmpl" "${clean[@]}" WAYLAND_DISPLAY=wayland-0)"
assert_contains "$out" "QT_QPA_PLATFORM=wayland" "wayland_desktop: QT_QPA_PLATFORM"
assert_contains "$out" "XDG_SESSION_TYPE=wayland" "wayland_desktop: XDG_SESSION_TYPE"
assert_contains "$out" "MOZ_ENABLE_WAYLAND=1" "wayland_desktop: MOZ_ENABLE_WAYLAND"
assert_contains "$out" "BROWSER=firefox" "wayland_desktop: BROWSER"

# X11 desktop: BROWSER yes, Wayland vars no.
out="$(run_zsh_env "$tmpl" "${clean[@]}" DISPLAY=:0)"
assert_contains "$out" "BROWSER=firefox" "x11_desktop: BROWSER"
assert_not_contains "$out" "QT_QPA_PLATFORM" "x11_desktop: no Wayland vars"

# locale_fallback: no en_US in `locale -a` -> C.UTF-8
out="$(run_zsh_env "$tmpl" "${clean[@]}" PATH="$stub_path")"
assert_contains "$out" "LC_ALL=C.UTF-8" "locale_fallback: LC_ALL"
assert_contains "$out" "LANG=C.UTF-8" "locale_fallback: LANG"

# locale_present: en_US.utf8 listed -> en_US.UTF-8
printf '#!/bin/sh\nprintf "C\\nen_US.utf8\\nPOSIX\\n"\n' >"$stubs/locale"
out="$(run_zsh_env "$tmpl" "${clean[@]}" PATH="$stub_path")"
assert_contains "$out" "LC_ALL=en_US.UTF-8" "locale_present: LC_ALL"

# darwin_unchanged
export TESTS_CHEZMOI_OS=darwin
rendered="$(render_tmpl "$tmpl")"
assert_contains "$rendered" "export LC_ALL=en_US.UTF-8" "darwin_unchanged: LC_ALL literal"
assert_not_contains "$rendered" "QT_QPA_PLATFORM" "darwin_unchanged: no Wayland"
assert_contains "$rendered" 'export BROWSER="firefox"' "darwin_unchanged: BROWSER still set"
