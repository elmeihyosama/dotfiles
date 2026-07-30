#!/usr/bin/env bash
# Shared lint logic for GitHub Actions CI and pre-commit. Render-aware (chezmoi
# templates) and zsh-aware (shellcheck is bash-only; zsh is checked with `zsh -n`).
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO" || exit 1
FIXTURE="ci/fixture.toml"
fail=0
note() { printf '[lint:%s] %s\n' "$1" "$2" >&2; }

# Render a chezmoi template file to stdout using the CI fixture + repo data.
render() { chezmoi execute-template --source "$REPO" --config "$FIXTURE" <"$1"; }

# A shared_home=true variant of the fixture, generated on the fly, so the
# architecture-specific template branches get render-checked too (the committed
# fixture only sets shared_home=false). chezmoi infers config format from the
# extension, so the temp file must keep a .toml name. Cleaned up on exit.
_shared_tmpdir="$(mktemp -d)"
SHARED_FIXTURE="$_shared_tmpdir/fixture.toml"
trap 'rm -rf "$_shared_tmpdir"' EXIT
sed 's/shared_home[[:space:]]*=[[:space:]]*false/shared_home = true/' "$FIXTURE" >"$SHARED_FIXTURE"
render_shared() { chezmoi execute-template --source "$REPO" --config "$SHARED_FIXTURE" <"$1"; }

# Bash files; zsh handled separately.
bash_files() {
	printf '%s\n' install.sh ci/lint.sh
	git ls-files '*.sh' | grep -v '^ci/lint.sh$'
}

lint_shell() {
	local f
	# Bash: shellcheck + shfmt
	while IFS= read -r f; do
		[ -f "$f" ] || continue
		shellcheck "$f" || {
			note shell "shellcheck: $f"
			fail=1
		}
		shfmt -d "$f" || {
			note shell "shfmt: $f"
			fail=1
		}
	done < <(bash_files | sort -u)
	# zsh (non-template)
	while IFS= read -r f; do
		[ -f "$f" ] || continue
		zsh -n "$f" || {
			note shell "zsh -n: $f"
			fail=1
		}
	done < <(git ls-files '*.zsh')
	# zsh templates: render then zsh -n
	while IFS= read -r f; do
		[ -f "$f" ] || continue
		render "$f" | zsh -n /dev/stdin || {
			note shell "render+zsh -n: $f"
			fail=1
		}
	done < <(git ls-files '*.zsh.tmpl')
	# bash/sh templates (e.g. chezmoi-templated executable_*.sh.tmpl):
	# render, then shellcheck + shfmt the rendered output.
	while IFS= read -r f; do
		[ -f "$f" ] || continue
		local rendered
		rendered="$(mktemp)"
		if render "$f" >"$rendered"; then
			shellcheck "$rendered" || {
				note shell "render+shellcheck: $f"
				fail=1
			}
			shfmt -d "$rendered" || {
				note shell "render+shfmt: $f"
				fail=1
			}
		else
			note shell "render: $f"
			fail=1
		fi
		rm -f "$rendered"
	done < <(git ls-files '*.sh.tmpl')
	# Shell-content templates whose filename lacks a .zsh/.sh infix.
	for f in home/dot_zshenv.tmpl home/dot_zshrc.tmpl home/dot_bashrc.tmpl home/dot_bash_profile.tmpl; do
		[ -f "$f" ] || continue
		case "$f" in
		*bashrc* | *bash_profile*)
			render "$f" | bash -n /dev/stdin || {
				note shell "render+bash -n: $f"
				fail=1
			}
			;;
		*)
			render "$f" | zsh -n /dev/stdin || {
				note shell "render+zsh -n: $f"
				fail=1
			}
			;;
		esac
	done
	# Arch-aware templates: also render the shared_home=true branch so BOTH code
	# paths stay syntax-valid (the loops above only exercise shared_home=false).
	for f in home/dot_zshenv.tmpl home/dot_config/zsh/conf.d/00-env.zsh.tmpl home/dot_bashrc.tmpl; do
		[ -f "$f" ] || continue
		case "$f" in
		*bashrc*)
			render_shared "$f" | bash -n /dev/stdin || {
				note shell "render(shared_home)+bash -n: $f"
				fail=1
			}
			;;
		*)
			render_shared "$f" | zsh -n /dev/stdin || {
				note shell "render(shared_home)+zsh -n: $f"
				fail=1
			}
			;;
		esac
	done
}

lint_ansible() {
	(cd ansible && ansible-lint) || {
		note ansible "ansible-lint"
		fail=1
	}
	(cd ansible && ansible-playbook site.yml --syntax-check >/dev/null) || {
		note ansible "syntax-check"
		fail=1
	}
}

lint_lua() {
	stylua --check home/dot_config/nvim || {
		note lua "stylua --check"
		fail=1
	}
	# Render each *.lua.tmpl and parse-check the output — rendered Lua isn't
	# covered by stylua's *.lua glob, and a broken render would only surface at
	# nvim startup. Prefer luac -p; fall back to luajit/lua loadfile.
	local f rendered
	while IFS= read -r f; do
		[ -f "$f" ] || continue
		rendered="$(mktemp)"
		if render "$f" >"$rendered"; then
			if command -v luac >/dev/null 2>&1; then
				luac -p "$rendered" || {
					note lua "render+luac: $f"
					fail=1
				}
			elif command -v luajit >/dev/null 2>&1; then
				luajit -e "assert(loadfile('$rendered'))" || {
					note lua "render+luajit: $f"
					fail=1
				}
			elif command -v lua >/dev/null 2>&1; then
				lua -e "assert(loadfile('$rendered'))" || {
					note lua "render+lua: $f"
					fail=1
				}
			else
				note lua "no lua interpreter to check rendered $f (skipped)"
			fi
		else
			note lua "render: $f"
			fail=1
		fi
		rm -f "$rendered"
	done < <(git ls-files '*.lua.tmpl')
}

lint_config() {
	local f
	# Every template must render without error.
	while IFS= read -r f; do
		[ -f "$f" ] || continue
		render "$f" >/dev/null || {
			note config "render: $f"
			fail=1
		}
	done < <(git ls-files '*.tmpl')
	# Parse-validate JSON / TOML / YAML for non-template config (yq handles all three).
	while IFS= read -r f; do
		[ -f "$f" ] || continue
		yq -p json -oy '.' "$f" >/dev/null || {
			note config "json: $f"
			fail=1
		}
	done < <(git ls-files '*.json')
	while IFS= read -r f; do
		[ -f "$f" ] || continue
		yq -p toml -oy '.' "$f" >/dev/null || {
			note config "toml: $f"
			fail=1
		}
	done < <(git ls-files '*.toml' | grep -v '\.tmpl$')
	while IFS= read -r f; do
		[ -f "$f" ] || continue
		yq -p yaml -oy '.' "$f" >/dev/null || {
			note config "yaml: $f"
			fail=1
		}
	done < <(git ls-files '*.yml' '*.yaml' | grep -v '\.tmpl$')
}

# Enforce .editorconfig across the whole tracked tree (catches the file types the
# formatters above don't cover: toml, kdl, json, md, cheat, …).
lint_editorconfig() {
	ec || {
		note editorconfig "editorconfig-checker"
		fail=1
	}
}

main() {
	case "${1:-all}" in
	shell) lint_shell ;;
	ansible) lint_ansible ;;
	lua) lint_lua ;;
	config) lint_config ;;
	editorconfig) lint_editorconfig ;;
	all)
		lint_shell
		lint_ansible
		lint_lua
		lint_config
		lint_editorconfig
		;;
	*)
		echo "usage: ci/lint.sh {shell|ansible|lua|config|editorconfig|all}" >&2
		exit 2
		;;
	esac
	exit "$fail"
}
main "$@"
