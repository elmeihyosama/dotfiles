#!/usr/bin/env bash
# renovate.json: valid JSON with the agreed shape (config:recommended, Monday
# schedule, one "pins" group, github-actions left to Dependabot, the mise
# manager on), and every customManager regex really matches the pins it is
# meant to bump. Each regex runs (perl, same syntax for these patterns as
# Renovate's RE2 with the "g" flag and no "m") over the files its
# managerFilePatterns select, and the match counts and captured values are
# compared with what the files actually pin, so a regex that silently matches
# nothing fails here. The official validator runs only when npx and a Node
# that renovate supports exist (else SKIP).
set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

cd "$TESTS_REPO" || exit 1
cfg=renovate.json
# Pinned validator (renovate's own CLI). Renovate needs Node >= this major.
RENOVATE_VERSION=44.140.0
RENOVATE_NODE_MAJOR=24

if ! jq -e . "$cfg" >/dev/null 2>&1; then
	fail "$cfg exists and is valid JSON"
	exit 1
fi

q() { jq -r "$1" "$cfg"; }
assert_eq "true" "$(q '.extends | index("config:recommended") != null')" "extends config:recommended"
assert_eq "false" "$(q '."github-actions".enabled')" "github-actions manager disabled (Dependabot owns actions)"
assert_eq '["before 6am on monday"]' "$(jq -c .schedule "$cfg")" "schedule is before 6am on Monday"
assert_eq "true" "$(q '.mise.enabled')" "mise manager enabled"
assert_eq '["/^mise\\.toml$/"]' "$(jq -c '.mise.managerFilePatterns' "$cfg")" "mise manager reads only the repo mise.toml"
assert_eq "pins" "$(q '[.packageRules[] | select(.matchPackageNames == ["*"]) | .groupName] | first')" "one pins group for everything"
assert_eq "true" "$(q '[.packageRules[] | select(.matchDatasources == ["docker"]) | .pinDigests] | first')" "docker images keep digest pins"
# ignorePaths keeps config:recommended's defaults (:ignoreModulesAndTests,
# which an explicit ignorePaths replaces) and adds the generated .mise/ locks.
assert_eq '["**/node_modules/**","**/bower_components/**","**/vendor/**","**/examples/**","**/__tests__/**","**/test/**","**/tests/**","**/__fixtures__/**",".mise/**"]' \
	"$(jq -c .ignorePaths "$cfg")" "ignorePaths: the recommended defaults plus .mise/**"
# zjstatus_by_zellij_minor stays manual: no regex targets it, the config says so.
assert_not_contains "$(q '[.customManagers[].matchStrings[]] | join(" ")')" "zjstatus" "no customManager bumps zjstatus_by_zellij_minor"
assert_contains "$(q '.description | join(" ")')" "Manual, not managed here: zjstatus_by_zellij_minor" "renovate.json documents zjstatus as manual"

# --- customManagers: run each regex against the real files ---------------
# Output, one line per match: <file> TAB <depName> TAB <currentValue> TAB
# <currentDigest> TAB <datasource>. depName/datasource fall back to the
# manager's literal templates.
n="$(q '.customManagers | length')"
[ "$n" -gt 0 ] || fail "customManagers present"
files="$(git ls-files)"
all=""
for ((i = 0; i < n; i++)); do
	m=".customManagers[$i]"
	dep_t="$(q "$m.depNameTemplate // \"\"")"
	ds_t="$(q "$m.datasourceTemplate // \"\"")"
	sel=""
	while IFS= read -r pat; do
		pat="${pat#/}"
		pat="${pat%/}"
		sel+="$(printf '%s\n' "$files" | PAT="$pat" perl -ne 'print if /$ENV{PAT}/')"$'\n'
	done < <(q "$m.managerFilePatterns[]")
	[ -n "${sel//$'\n'/}" ] || fail "customManagers[$i] selects at least one file"
	got=""
	while IFS= read -r re; do
		while IFS= read -r f; do
			[ -n "$f" ] || continue
			got+="$(RE="$re" F="$f" DEP="$dep_t" DS="$ds_t" perl -0777 -ne '
				while (/$ENV{RE}/g) {
					printf "%s\t%s\t%s\t%s\t%s\n", $ENV{F}, $+{depName} // $ENV{DEP},
						$+{currentValue} // "", $+{currentDigest} // "", $+{datasource} // $ENV{DS};
				}' "$f")"
			[ -n "$got" ] && got+=$'\n'
		done <<<"$sel"
	done < <(q "$m.matchStrings[]")
	[ -n "${got//$'\n'/}" ] || fail "customManagers[$i] matches something ($(q "$m.description // \"\"" | head -1))"
	all+="$got"
done
# rows FILE-REGEX: matches whose file matches FILE-REGEX, sorted and unique.
rows() { printf '%s' "$all" | awk -F'\t' -v r="$1" '$1 ~ r' | sort -u; }

# tools.yaml: every backend tool, depName OWNER/REPO and its pinned version.
want="$(yq -r '.tools[] | select(has("backend")) | (.backend | sub("^[a-z]+:"; "")) + "\t" + .version + "\tgithub-releases"' home/.chezmoidata/tools.yaml | sort -u)"
assert_eq "35" "$(printf '%s\n' "$want" | wc -l | tr -d ' ')" "tools.yaml has the expected 35 backend tools"
got="$(rows '^home/\.chezmoidata/tools\.yaml$' | awk -F'\t' '$2 != "jdx/mise" {print $2 "\t" $3 "\t" $5}')"
assert_eq "$want" "$got" "tools.yaml regex captures every backend tool's OWNER/REPO and version"
# tools.yaml's bootstrap mise entry moves with mise_version.
mv="$(sed -nE 's/^mise_version: "([^"]+)".*/\1/p' ansible/group_vars/all.yml)"
assert_eq "jdx/mise	$mv	github-releases" "$(rows '^home/\.chezmoidata/tools\.yaml$' | awk -F'\t' '$2 == "jdx/mise" {print $2 "\t" $3 "\t" $5}')" "tools.yaml bootstrap mise entry is tracked"

# group_vars: the five automated pins (zjstatus stays manual).
gv() { sed -nE "s/^$1: \"([^\"]+)\".*/\\1/p" ansible/group_vars/all.yml; }
want="$(printf '%s\n' \
	"ansible-core	$(gv ansible_core_version)	pypi" \
	"astral-sh/uv	$(gv uv_version)	github-releases" \
	"jdx/mise	$(gv mise_version)	github-releases" \
	"pre-commit	$(gv pre_commit_version)	pypi" \
	"ryanoasis/nerd-fonts	$(gv nerd_font_version)	github-releases" | sort)"
assert_eq "$want" "$(rows '^ansible/group_vars/all\.yml$' | cut -f2,3,5)" "group_vars pins: mise, uv, ansible-core, pre-commit, nerd-fonts"

# CI mise binary pins (setup-lint and the macOS job), equal to mise_version.
want="$(printf '%s\n' ".github/actions/setup-lint/action.yml	jdx/mise	$mv" ".github/workflows/provision.yml	jdx/mise	$mv")"
assert_eq "$want" "$(rows '^\.github/' | awk -F'\t' '$2 == "jdx/mise"' | cut -f1-3)" "CI mise version inputs are tracked"

# Container images: every image:<name>:<tag>@sha256 line in the workflows,
# per file (provision.yml and bootstrap.yml copies bump in the same PR).
want="$(grep -HoE 'image: [a-z0-9./_-]+:[A-Za-z0-9._-]+@sha256:[0-9a-f]{64}' .github/workflows/*.yml |
	awk '{f = $0; sub(/:image: .*/, "", f); r = $0; sub(/^[^:]+:image: /, "", r)
		split(r, a, "@"); n = index(a[1], ":"); print f "\t" substr(a[1], 1, n - 1) "\t" substr(a[1], n + 1) "\t" a[2] "\tdocker"}' | sort -u)"
assert_eq "8" "$(printf '%s\n' "$want" | wc -l | tr -d ' ')" "workflows pin 8 container image lines"
assert_eq "$want" "$(rows '^\.github/workflows/' | awk -F'\t' '$5 == "docker"')" "every workflow container image (tag + digest) is tracked"

# sheldon: rev pins via git-refs (default branch HEAD), forgit by tag.
sh_file=home/dot_config/sheldon/plugins.toml
want="$(awk -F'"' '/^github = / {r=$2} /^rev = / {print "https://github.com/" r "\t\t" $2 "\tgit-refs"}' "$sh_file" | sort)"
assert_eq "5" "$(printf '%s\n' "$want" | wc -l | tr -d ' ')" "sheldon has 5 rev pins"
# git-refs packageName is the clone URL (packageNameTemplate).
pnt="$(q '[.customManagers[] | select(.datasourceTemplate == "git-refs") | .packageNameTemplate] | first')"
assert_eq 'https://github.com/{{{depName}}}' "$pnt" "git-refs packageName is the GitHub clone URL"
got="$(rows "^$sh_file\$" | awk -F'\t' '$5 == "git-refs" {print "https://github.com/" $2 "\t" $3 "\t" $4 "\t" $5}')"
assert_eq "$want" "$got" "every sheldon rev is tracked (digest only, no currentValue)"
assert_eq "wfxr/forgit	26.08.0	github-tags" "$(rows "^$sh_file\$" | awk -F'\t' '$5 == "github-tags"' | cut -f2,3,5)" "forgit tag is tracked via github-tags"

# --- official validator --------------------------------------------------
node_major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
if ! command -v npx >/dev/null 2>&1; then
	echo "SKIP renovate-config-validator: npx not found"
elif [ "$node_major" -lt "$RENOVATE_NODE_MAJOR" ]; then
	echo "SKIP renovate-config-validator: node $node_major < $RENOVATE_NODE_MAJOR"
elif ! out="$(npx --yes --loglevel=error --package "renovate@$RENOVATE_VERSION" -- renovate-config-validator --strict 2>&1)"; then
	fail "renovate-config-validator --strict (repo config: $cfg)"
	printf '%s\n' "$out" >&2
fi
