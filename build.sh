#!/bin/sh
# Builds build/Claude Usage Island.app (universal, ad-hoc signed).
set -e
cd "$(dirname "$0")"
APP="build/Claude Usage Island.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
for arch in arm64 x86_64; do
    swiftc -parse-as-library -O -target $arch-apple-macos14 Island.swift -o build/Island-$arch
done
lipo -create build/Island-arm64 build/Island-x86_64 -output "$APP/Contents/MacOS/Island"
rm build/Island-*
cp Info.plist "$APP/Contents/"
codesign --force --sign - "$APP"
echo "$APP"
