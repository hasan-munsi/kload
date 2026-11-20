#!/usr/bin/env bash
# Release kload:  scripts/release.sh 0.2.0
# Tags the version, publishes a GitHub release, and points the Homebrew formula at it.
# Needs gh (signed in) and a clone of the tap next to this repository (or KLOAD_TAP_DIR).
set -euo pipefail

version=${1:?usage: scripts/release.sh <version, for example 0.2.0>}
repo=hasan-munsi/kload
root=$(cd "$(dirname "$0")/.." && pwd)
tap=${KLOAD_TAP_DIR:-$root/../homebrew-tap}
formula=$tap/Formula/kload.rb

cd "$root"
[[ -z $(git status --porcelain) ]] || { echo "Commit your changes first." >&2; exit 1; }
grep -q "^typeset -g KLOAD_VERSION=$version\$" kload.zsh \
  || { echo "Set KLOAD_VERSION=$version in kload.zsh and commit it first." >&2; exit 1; }
[[ -f $formula ]] || { echo "No formula at $formula; set KLOAD_TAP_DIR." >&2; exit 1; }
zsh tests/run.zsh > /dev/null || { echo "Tests fail: zsh tests/run.zsh" >&2; exit 1; }

git tag -a "v$version" -m "kload $version"
git push origin HEAD "v$version"
gh release create "v$version" --repo "$repo" --title "kload $version" --generate-notes

url="https://github.com/$repo/archive/refs/tags/v$version.tar.gz"
sha=$(curl -fsSL "$url" | shasum -a 256 | cut -d' ' -f1)
sed -i.bak -e "s|^  url \".*\"|  url \"$url\"|" -e "s|^  sha256 \".*\"|  sha256 \"$sha\"|" "$formula"
rm "$formula.bak"
git -C "$tap" commit -am "kload $version"
git -C "$tap" push

echo "Released kload $version. Users get it with: brew upgrade kload"
