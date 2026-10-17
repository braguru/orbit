#!/bin/bash
# Runs on every push to main (.github/workflows/release.yml): if orbit/__init__.py
# holds a version that isn't released yet, creates release/<version>, the
# annotated tag v<version> and a *draft* GitHub release with notes generated from
# the merged pull requests.
#
# Nothing is attached here: the tarball and the Mac app are built and uploaded
# from a Mac (scripts/release.sh --upload), which also publishes the draft.
# Published releases are immutable, so the assets must go on while it's a draft.
set -euo pipefail

version=$(sed -n 's/^__version__ = "\(.*\)"$/\1/p' orbit/__init__.py)
[ -n "$version" ] || { echo "no __version__ in orbit/__init__.py"; exit 1; }
tag="v$version"

if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
  echo "::notice::$tag is already released; nothing to do."
  exit 0
fi

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git push origin "HEAD:refs/heads/release/$version"
git tag -a "$tag" -m "$tag"
git push origin "$tag"
gh release create "$tag" --verify-tag --title "Orbit $version" --generate-notes --draft
echo "::notice::Drafted $tag. Build and publish from your Mac: git switch release/$version && scripts/release.sh --upload"
