#!/bin/zsh
# Runs the unit tests with the Command Line Tools.
# The CLT toolchain doesn't always find the Swift Testing macro plugin on its own, so pass it explicitly.
set -euo pipefail
cd "${0:A:h}/.."

plugins=/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
extra=()
[[ -d $plugins ]] && extra=(-Xswiftc -plugin-path -Xswiftc "$plugins")
swift test "${extra[@]}" "$@"
