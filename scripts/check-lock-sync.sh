#!/usr/bin/env bash
# check-lock-sync.sh: the locks must cover what the pins say. Fails (exit 1) when
#   (a) a tool with a backend+version in tools.yaml is missing from the home lock
#       (home/dot_config/mise-dotfiles/mise.lock) at that version,
#   (a2) per locked platform (macos-arm64, linux-x64, linux-arm64), a tool that
#       select-tools installs from mise there (so missing_on / native_on are
#       respected) lacks, in that version's lock entry: a url, a url whose
#       asset name names the platform's OS, or a checksum (unless the home
#       exceptions file lists `<backend> <platform>`); for macos-arm64 also a url
#       naming an x86_64 build (x86_64/amd64/x64/intel, not universal) unless the
#       arch exceptions file lists it: it needs Rosetta 2, which a fresh Apple
#       Silicon Mac lacks,
#   (b) a tool in the repo mise.toml is missing from mise.lock at that version,
#   (c) a .mise/locks/pipx-*/<ver>/ dir (a pipx tool's hash-pinned uv.lock) is not
#       referenced by the repo mise.lock any more (orphaned after a bump).
# On mismatch it prints `run scripts/relock.sh`. Needs yq (mikefarah) and jq.
# Options override the default paths (used by tests):
#   --root DIR --tools FILE --home-lock FILE --mise-toml FILE --repo-lock FILE
#   --home-exceptions FILE (default .github/scripts/lock-exceptions-home.txt,
#   the check-lock.sh format: `tool-key platform  # reason`)
#   --arch-exceptions FILE (default .github/scripts/lock-arch-exceptions-home.txt,
#   same format: macos-arm64 entries allowed to be an x86_64 build)
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tools="" home_lock="" mise_toml="" repo_lock="" home_exc="" arch_exc=""
while [ $# -gt 0 ]; do
	[ $# -ge 2 ] || {
		echo "usage: check-lock-sync.sh [--root D] [--tools F] [--home-lock F] [--mise-toml F] [--repo-lock F] [--home-exceptions F] [--arch-exceptions F]" >&2
		exit 2
	}
	case "$1" in
	--root) root="$2" ;;
	--tools) tools="$2" ;;
	--home-lock) home_lock="$2" ;;
	--mise-toml) mise_toml="$2" ;;
	--repo-lock) repo_lock="$2" ;;
	--home-exceptions) home_exc="$2" ;;
	--arch-exceptions) arch_exc="$2" ;;
	*)
		echo "check-lock-sync: unknown option $1" >&2
		exit 2
		;;
	esac
	shift 2
done
: "${tools:=$root/home/.chezmoidata/tools.yaml}"
: "${home_lock:=$root/home/dot_config/mise-dotfiles/mise.lock}"
: "${mise_toml:=$root/mise.toml}"
: "${repo_lock:=$root/mise.lock}"
: "${home_exc:=$root/.github/scripts/lock-exceptions-home.txt}"
: "${arch_exc:=$root/.github/scripts/lock-arch-exceptions-home.txt}"

status=0
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bad() {
	echo "check-lock-sync: $*"
	status=1
}
for f in "$tools" "$home_lock" "$mise_toml" "$repo_lock" "$home_exc" "$arch_exc"; do
	[ -f "$f" ] || {
		bad "missing file: $f"
		echo "run scripts/relock.sh"
		exit 1
	}
done

# lock_json FILE -> {"tool-key": ["version", ...]}
lock_json() {
	yq -p toml -o json '.tools // {}' "$1" |
		jq -c 'with_entries(.value = ([.value | if type == "array" then .[] else . end | .version]))'
}
# have LOCKJSON KEY VERSION
have() { jq -e --arg k "$2" --arg v "$3" '(.[$k] // []) | index($v) != null' <<<"$1" >/dev/null; }

home_json="$(lock_json "$home_lock")" || exit 2
repo_json="$(lock_json "$repo_lock")" || exit 2

# (a) tools.yaml backend+version rows, TSV. Same skips as the pins template:
# bootstrap and provided_by tools are never pinned.
while IFS=$'\t' read -r name backend version; do
	[ -n "$backend" ] || continue
	have "$home_json" "$backend" "$version" ||
		bad "tools.yaml: $name ($backend@$version) is not in $home_lock"
done < <(yq -o json '.tools' "$tools" | jq -r 'to_entries[] | select(.value.backend != null and .value.version != null and .value.bootstrap != true and .value.provided_by == null) | [.key, .value.backend, .value.version] | @tsv')

# (a2) platform coverage: every tool select-tools marks source "mise" on a locked
# platform (default selection) needs, in its version's lock entry for that
# platform, a url to an asset named for the platform's OS (a man page or the
# other OS's build passes a plain url check) and a checksum. An upstream with
# no asset for a platform goes in tools.yaml (native_on / missing_on); one that
# publishes no checksum goes in the home exceptions file. On macos-arm64 the
# asset must not be an x86_64 build: it runs only under Rosetta 2, which a
# fresh Apple Silicon Mac does not have (universal and arch-less names pass).
# Use native_on: [darwin] (brew) instead, or list it in the arch exceptions.
# Linux arches are not checked (no Linux asset here names the wrong one).
# exceptions as "key<TAB>platform" lines (`*` = every platform)
exc_lines() { sed -e 's/#.*//' "$1" | awk 'NF >= 2 { print $1 "\t" $2 }'; }
exc="$(exc_lines "$home_exc")"
arch_excs="$(exc_lines "$arch_exc")"
# has_exception KEY PLATFORM [LINES]
has_exception() { printf '%s\n' "${3-$exc}" | grep -qxF -e "$1"$'\t'"$2" -e "$1"$'\t*'; }
intel_re='x86[_-]?64|amd64|intel|(^|[^a-z0-9])x64([^a-z0-9]|$)'
home_all="$(yq -p toml -o json '.tools // {}' "$home_lock")" || exit 2
for plat in macos-arm64 linux-x64 linux-arm64; do
	os=linux os_re='linux'
	if [ "${plat%%-*}" = macos ]; then
		os=darwin os_re='darwin|apple|macos|osx'
	fi
	while IFS=$'\t' read -r name backend version; do
		[ -n "$backend" ] || continue
		# url<TAB>checksum of that version's entry for this platform ("" if none)
		entry="$(jq -r --arg k "$backend" --arg v "$version" --arg p "$plat" '
			[(.[$k] // []) | if type == "array" then .[] else . end
				| select(.version == $v) | .["platforms." + $p] // {}][0] // {}
			| [.url // "", .checksum // ""] | @tsv' <<<"$home_all")"
		url="${entry%%$'\t'*}"
		sum="${entry#*$'\t'}"
		if [ -z "$url" ]; then
			bad "$name ($backend@$version) has no $plat asset in $home_lock: add it to native_on or missing_on in tools.yaml"
			continue
		fi
		asset="${url%%\?*}"
		asset="${asset##*/}"
		if ! grep -Eiq "$os_re" <<<"$asset"; then
			bad "$name ($backend@$version): the $plat url does not look like a ${plat%%-*} asset ($asset); fix the backend's asset match (mise_options) or set native_on / missing_on"
		fi
		if [ "$plat" = macos-arm64 ] && grep -Eiq "$intel_re" <<<"$asset" &&
			! grep -iq universal <<<"$asset" && ! has_exception "$backend" "$plat" "$arch_excs"; then
			bad "$name ($backend@$version): the $plat url is an x86_64 asset ($asset), which needs Rosetta 2; set native_on: [darwin], or list '$backend $plat' in $arch_exc with a reason"
		fi
		if [ -z "$sum" ] && ! has_exception "$backend" "$plat"; then
			bad "$name ($backend@$version) has no $plat checksum in $home_lock: relock, or list '$backend $plat' in $home_exc with a reason"
		fi
	done < <("$here/select-tools.sh" --os "$os" --arch "${plat#*-}" --local /nonexistent --tools "$tools" |
		jq -r '.[] | select(.source == "mise") | [.name, .backend, .version] | @tsv')
done

# (b) repo mise.toml tools; the value is a version string or a table with .version
while IFS=$'\t' read -r key version; do
	[ -n "$key" ] || continue
	have "$repo_json" "$key" "$version" ||
		bad "mise.toml: $key@$version is not in $repo_lock"
done < <(yq -p toml -o json '.tools // {}' "$mise_toml" | jq -r 'to_entries[] | [.key, (.value | if type == "object" then .version else . end)] | @tsv')

# (c) orphaned pipx uv.lock dirs (paths in the lock are relative to the repo root)
refs="$(grep -o 'path = "[^"]*"' "$repo_lock" | sed -e 's/^path = "//' -e 's/"$//')"
for d in "$root"/.mise/locks/pipx-*/*/; do
	[ -d "$d" ] || continue
	rel="${d#"$root"/}"
	rel="${rel%/}"
	printf '%s\n' "$refs" | grep -qxF "$rel" || bad "orphaned $rel (not referenced by $repo_lock)"
done

if [ "$status" -ne 0 ]; then
	echo "run scripts/relock.sh"
fi
exit "$status"
