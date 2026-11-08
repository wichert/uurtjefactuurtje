#!/bin/sh
set -e

cd "$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

swift test
xcodebuild -project UurtjeFactuurtje.xcodeproj -scheme UurtjeFactuurtje -configuration Debug -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO
xcodebuild -project UurtjeFactuurtje.xcodeproj -scheme UurtjeFactuurtje -configuration Debug -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO
plutil -lint UurtjeFactuurtje.xcodeproj/project.pbxproj UurtjeFactuurtje/Info.plist UurtjeFactuurtje/UurtjeFactuurtje.entitlements
