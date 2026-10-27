#!/bin/zsh
set -eu
cd "${0:A:h}"
mkdir -p build/ModuleCache
app='build/校园网自动登录.app'
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macosx14.0" -O -whole-module-optimization -module-cache-path build/ModuleCache \
  -framework AppKit -framework Security -framework LocalAuthentication -framework SystemConfiguration -framework CoreGraphics -framework IOKit \
  Sources/Core.swift Sources/App.swift -o "$app/Contents/MacOS/CampusAutoLogin"
cp Resources/Info.plist "$app/Contents/Info.plist"
/usr/bin/codesign --force --sign - --identifier local.hbut.autologin "$app"
print '构建完成：校园网自动登录.app'
