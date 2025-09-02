#!/bin/bash

# Build Release
xcodebuild -project Hex.xcodeproj -scheme Hex -configuration Release -derivedDataPath build clean build | cat

# Replace the app
osascript -e 'tell application "Hex" to quit' || true
rm -rf "/Applications/Hex.app"
ditto "build/Build/Products/Release/Hex.app" "/Applications/Hex.app"

# Remove quarantine
xattr -dr com.apple.quarantine "/Applications/Hex.app" || true

# Create ad‑hoc entitlements with disable-library-validation (lets the app load its embedded Sparkle)
cp "Hex/Hex.entitlements" /tmp/adhoc-hex.entitlements
/usr/libexec/PlistBuddy -c 'Add :com.apple.security.cs.disable-library-validation bool true' /tmp/adhoc-hex.entitlements 2>/dev/null || true

# Re-sign all nested code ad‑hoc (frameworks, XPCs/apps), then the host with entitlements
find "/Applications/Hex.app/Contents/Frameworks" -maxdepth 3 \
  \( -name "*.framework" -o -name "*.xpc" -o -name "*.app" \) \
  -exec codesign --force --options runtime -s - "{}" \;

codesign --force --deep --options runtime --entitlements /tmp/adhoc-hex.entitlements -s - "/Applications/Hex.app"

# Sanity check (TeamIdentifier should be empty for both app and Sparkle)
codesign -dv --verbose=4 "/Applications/Hex.app" | sed -n 's/^\\(Identifier\\|TeamIdentifier\\|Signature\\).*/\\0/p'
codesign -dv --verbose=4 "/Applications/Hex.app/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle" | sed -n 's/^\\(Identifier\\|TeamIdentifier\\|Signature\\).*/\\0/p'

# Launch
open -a "/Applications/Hex.app"
