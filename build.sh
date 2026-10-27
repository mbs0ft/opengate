#!/bin/bash
set -e
cd "$(dirname "$0")"

VERSION=$(grep '^Version:' control | awk '{print $2}')
echo "[+] Building OpenGate version: $VERSION"

rm -rf packages/*.deb .theos/obj

echo "[+] Building rootful package..."
make package
ROOTFUL=$(ls -t packages/*.deb | head -1)
mv "$ROOTFUL" "packages/mbsoft.opengate_${VERSION}_iphoneos-arm-rootful.deb"
echo "[+] Built: packages/mbsoft.opengate_${VERSION}_iphoneos-arm-rootful.deb"

rm -rf .theos/obj
echo "[+] Building rootless package..."
make package THEOS_PACKAGE_SCHEME=rootless
ROOTLESS=$(ls -t packages/*.deb | head -1)
mv "$ROOTLESS" "packages/mbsoft.opengate_${VERSION}_iphoneos-arm64-rootless.deb"
echo "[+] Built: packages/mbsoft.opengate_${VERSION}_iphoneos-arm64-rootless.deb"

echo ""
echo "=== Packages ready ==="
ls -la packages/*.deb
