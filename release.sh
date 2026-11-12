#!/bin/zsh
# Builds, notarizes and publishes a GitHub release: ./release.sh 1.1
# One-time setup: xcrun notarytool store-credentials shade-notary
set -e
cd "$(dirname "$0")"
VERSION=${1:?usage: ./release.sh <version>}
ZIP=dist/Shade-$VERSION.zip
PROFILE=${NOTARY_PROFILE:-shade-notary}

[[ -z $(git status --porcelain) ]] || { echo "Commit your changes first"; exit 1; }

VERSION=$VERSION ./build.sh
codesign -dv Shade.app 2>&1 | grep -q "Authority=Developer ID Application" \
  || { echo "Shade.app isn't signed with a Developer ID certificate"; exit 1; }

mkdir -p dist
rm -f $ZIP
ditto -c -k --keepParent Shade.app $ZIP
xcrun notarytool submit $ZIP --keychain-profile $PROFILE --wait
xcrun stapler staple Shade.app
# Zip again so the download carries the stapled ticket and opens offline too.
rm -f $ZIP
ditto -c -k --keepParent Shade.app $ZIP
spctl --assess --type execute -v Shade.app

git tag v$VERSION
git push origin v$VERSION
gh release create v$VERSION $ZIP --title "Shade $VERSION" --generate-notes
