#!/usr/bin/env bash
# Publishes a GitHub release of OpenTelV: a zip of the committed tree (git archive, so
# nothing git ignores can get in: no keystore, report/ or dumbtv.conf), the home screen
# APK on its own, and SHA256SUMS for both.
#   ./opentelv/release.sh v0.1.0 [--dry-run]
# Needs a clean tree on a commit that is pushed, and gh signed in.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

ver=${1:-}
dry=0
[[ ${2:-} == --dry-run ]] && dry=1
[[ $ver =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "usage: $0 vX.Y.Z [--dry-run]" >&2; exit 1; }
[[ -z $(git status --porcelain) ]] || { echo "error: commit or stash your changes first" >&2; exit 1; }
git fetch -q origin
[[ $(git rev-parse HEAD) == $(git rev-parse origin/main) ]] ||
  { echo "error: HEAD is not origin/main; push first" >&2; exit 1; }
# gh would otherwise pick a repo itself, and with dumbtv as `upstream` it picks dumbtv.
repo=$(git remote get-url origin | sed -E 's#^.*[:/]([^/]+/[^/]+)$#\1#; s#\.git$##')
[[ $repo == */* ]] || { echo "error: cannot read owner/repo from origin" >&2; exit 1; }
gh release view "$ver" -R "$repo" >/dev/null 2>&1 && { echo "error: release $ver already exists in $repo" >&2; exit 1; }
# A tag left by an interrupted run is reused, as long as it is this commit.
if git rev-parse -q --verify "refs/tags/$ver" >/dev/null; then
  [[ $(git rev-parse "$ver^{commit}") == $(git rev-parse HEAD) ]] ||
    { echo "error: tag $ver exists on another commit" >&2; exit 1; }
  tagged=1
else
  tagged=0
fi

sha256() {
  if command -v sha256sum >/dev/null; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

out=$(mktemp -d "${TMPDIR:-/tmp}/opentelv-release.XXXXXX")
trap 'rm -rf "$out"' EXIT
zip="opentelv-$ver.zip"
git archive --format=zip --prefix=opentelv/ -o "$out/$zip" HEAD
cp opentelv/home/opentelv-home.apk "$out/"
# The APK must be the one its committed checksum names.
[[ $(sha256 "$out/opentelv-home.apk") == "$(tr -d '[:space:]' < opentelv/home/opentelv-home.apk.sha256)" ]] ||
  { echo "error: opentelv-home.apk does not match opentelv-home.apk.sha256" >&2; exit 1; }
(cd "$out" && for f in "$zip" opentelv-home.apk; do printf '%s  %s\n' "$(sha256 "$f")" "$f"; done) > "$out/SHA256SUMS"

echo "release $ver of $repo from $(git rev-parse --short HEAD)"
cat "$out/SHA256SUMS"
if unzip -l "$out/$zip" | grep -qE 'keystore|/report/|dumbtv\.conf'; then
  echo "error: the zip contains a private file" >&2; exit 1
fi
[[ $dry == 1 ]] && { echo "(dry run: nothing published)"; exit 0; }

if [[ $tagged == 0 ]]; then git tag -a "$ver" -m "OpenTelV $ver"; fi
git push -q origin "$ver"
gh release create "$ver" -R "$repo" --verify-tag "$out/$zip" "$out/opentelv-home.apk" "$out/SHA256SUMS" \
  --title "OpenTelV $ver" --notes-file "${NOTES:-/dev/stdin}"
