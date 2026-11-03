#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
cargo fmt --all --check
cargo clippy --offline --locked --all-targets -- -D warnings
cargo test --offline --locked
/usr/bin/plutil -lint native/Info.plist

