#!/bin/zsh
# Builds a Release app and copies it to /Applications, over any previous version.
set -euo pipefail
cd "${0:A:h}/.."
xcodegen generate --quiet
xcodebuild -scheme BetterView -configuration Release -derivedDataPath build -quiet build
ditto build/Build/Products/Release/BetterView.app /Applications/BetterView.app
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/BetterView.app
echo "Installé : /Applications/BetterView.app"
