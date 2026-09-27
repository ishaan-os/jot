#!/bin/zsh
# Regenerates README media into assets/: hero.png, widget.png, demo.gif, demo.mp4.
# Run from a normal terminal session (the H.264 encoder isn't available to headless/background jobs).
set -e
cd "$(dirname "$0")/.."
mkdir -p promo/bin
FLAGS=()
[[ -f .toolchain-fix/overlay.yaml ]] && FLAGS=(-vfsoverlay .toolchain-fix/overlay.yaml -module-cache-path $PWD/.toolchain-fix/module-cache)
swiftc -O -swift-version 5 $FLAGS promo/Promo.swift -o promo/bin/promo
promo/bin/promo assets "${1:-all}"
