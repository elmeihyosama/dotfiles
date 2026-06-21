#!/usr/bin/env bash
# Shared lint logic for GitLab CI and pre-commit. Render-aware (chezmoi templates)
# and zsh-aware (shellcheck is bash-only; zsh is checked with `zsh -n`).
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO" || exit 1
FIXTURE="ci/fixture.toml"
fail=0
note() { printf '[lint:%s] %s\n' "$1" "$2" >&2; }

# Render a chezmoi template file to stdout using the CI fixture + repo data.
render() { chezmoi execute-template --source "$REPO" --config "$FIXTURE" <"$1"; }

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
	# Shell-content templates whose filename lacks a .zsh/.sh infix.
	for f in home/dot_zshrc.tmpl home/dot_bashrc.tmpl; do
		[ -f "$f" ] || continue
		case "$f" in
		*bashrc*)
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
}

lint_config() {
	local f
	# Every template must render without error.
	while IFS= read -r f; do
		render "$f" >/dev/null || {
			note config "render: $f"
			fail=1
		}
	done < <(git ls-files '*.tmpl')
	# Parse-validate JSON / TOML / YAML for non-template config (yq handles all three).
	while IFS= read -r f; do
		yq -p json -oy '.' "$f" >/dev/null || {
			note config "json: $f"
			fail=1
		}
	done < <(git ls-files '*.json')
	while IFS= read -r f; do
		yq -p toml -oy '.' "$f" >/dev/null || {
			note config "toml: $f"
			fail=1
		}
	done < <(git ls-files '*.toml' | grep -v '\.tmpl$')
	while IFS= read -r f; do
		yq -p yaml -oy '.' "$f" >/dev/null || {
			note config "yaml: $f"
			fail=1
		}
	done < <(git ls-files '*.yml' '*.yaml' | grep -v '\.tmpl$')
}

main() {
	case "${1:-all}" in
	shell) lint_shell ;;
	ansible) lint_ansible ;;
	lua) lint_lua ;;
	config) lint_config ;;
	all)
		lint_shell
		lint_ansible
		lint_lua
		lint_config
		;;
	*)
		echo "usage: ci/lint.sh {shell|ansible|lua|config|all}" >&2
		exit 2
		;;
	esac
	exit "$fail"
}
main "$@"
