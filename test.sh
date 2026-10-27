#!/bin/zsh
set -eu
cd "${0:A:h}"
mkdir -p build/ModuleCache
xcrun swiftc -swift-version 5 -O -module-cache-path build/ModuleCache \
  -framework Security -framework LocalAuthentication -framework SystemConfiguration \
  Sources/Core.swift Tests/CoreTests.swift -o build/CoreTests
build/CoreTests
