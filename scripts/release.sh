#!/bin/zsh
# Builds the release artifacts for the version in orbit/__init__.py:
#   build/orbit-<version>.tar.gz   the source, which scripts/install.sh downloads
#   build/checksums.txt            its SHA-256, which the installer checks
#
# The Mac app isn't shipped here. It's signed for the Mac that builds it, and a
# copy downloaded from the internet is blocked by Gatekeeper, so scripts/install.sh
# builds it on the machine installing Orbit instead.
#
#   scripts/release.sh            build them
#   scripts/release.sh --upload   also attach them to the draft GitHub release
#                                 v<version> and publish it (run after the Release
#                                 workflow has drafted it; published releases are
#                                 immutable, so assets can only be added to a draft)
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"
VERSION=$(sed -n 's/^__version__ = "\(.*\)"$/\1/p' orbit/__init__.py)
[[ -n "$VERSION" ]] || { echo "no __version__ in orbit/__init__.py"; exit 1; }
TAG="v$VERSION"
TARBALL="orbit-$VERSION.tar.gz"
UPLOAD=false
[[ "${1:-}" == "--upload" ]] && UPLOAD=true

if $UPLOAD; then
  [[ "$(git rev-parse -q --verify "$TAG^{commit}")" == "$(git rev-parse HEAD)" ]] \
    || { echo "HEAD isn't $TAG: git switch release/$VERSION && git pull"; exit 1; }
  [[ -z "$(git status --porcelain)" ]] || { echo "uncommitted changes: commit or stash them first"; exit 1; }
  REF="$TAG"
else
  # Before the tag exists, build from HEAD so the artifacts can be tried out.
  REF="$TAG"
  git rev-parse -q --verify "$TAG^{commit}" >/dev/null || REF=HEAD
fi

mkdir -p build
echo "Building $TARBALL from ${REF}"
git archive --format=tar.gz --prefix="orbit-$VERSION/" -o "build/$TARBALL" "$REF"
( cd build && shasum -a 256 "$TARBALL" > checksums.txt )

# The installer reads these, so a broken archive should fail here, not on someone's Mac.
tar -tzf "build/$TARBALL" >/dev/null
for f in orbit/__init__.py requirements.txt scripts/service.sh scripts/install.sh web/index.html; do
  tar -tzf "build/$TARBALL" "orbit-$VERSION/$f" >/dev/null 2>&1 \
    || { echo "$TARBALL is missing $f"; exit 1; }
done
if tar -tzf "build/$TARBALL" | grep -qE 'orbit-[^/]+/(data/|\.venv/|scripts/probe_report\.json)'; then
  echo "$TARBALL contains local data"; exit 1
fi
echo "built build/$TARBALL ($(du -h "build/$TARBALL" | cut -f1))"

if $UPLOAD; then
  [[ "$(gh release view "$TAG" --json isDraft --jq .isDraft)" == "true" ]] \
    || { echo "$TAG is already published (immutable): assets can only be added to a draft"; exit 1; }
  gh release upload "$TAG" "build/$TARBALL" build/checksums.txt --clobber
  gh release edit "$TAG" --draft=false --latest >/dev/null
  echo "published $(gh release view "$TAG" --json url --jq .url)"
fi
