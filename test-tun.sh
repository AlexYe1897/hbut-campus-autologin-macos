#!/bin/zsh
set -eu
cd "${0:A:h}"
mkdir -p build/ModuleCache
frameworks=(-framework Security -framework LocalAuthentication -framework SystemConfiguration)
xcrun swiftc -swift-version 5 -D TUN_COMPAT -O -module-cache-path build/ModuleCache \
  "${frameworks[@]}" Sources/Core.swift Sources/TUNSupport.swift Tests/CoreTests.swift -o build/CoreTests-TUN
build/CoreTests-TUN
xcrun swiftc -swift-version 5 -D TUN_COMPAT -O -module-cache-path build/ModuleCache \
  "${frameworks[@]}" Sources/Core.swift Sources/TUNSupport.swift Tests/TUNTests.swift -o build/TUNTests
build/TUNTests
