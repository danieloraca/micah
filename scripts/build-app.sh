#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
cargo build --release --locked --offline
app="$PWD/dist/Micah.app"
mkdir -p "$app/Contents/MacOS"
cp target/release/desktop-companion "$app/Contents/MacOS/desktop-companion"
cp native/Info.plist "$app/Contents/Info.plist"
/usr/bin/plutil -lint "$app/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$app"
printf 'Built %s\n' "$app"

