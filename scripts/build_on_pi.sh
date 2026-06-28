#!/bin/sh
set -eu

ROOT="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

dart pub get
(cd apps/dashboard && flutter build web --release)
dart compile exe apps/server/bin/zc_agentbeacon_server.dart -o installers/raspberry-pi/zc-agentbeacon-server
rm -rf installers/raspberry-pi/dashboard
mkdir -p installers/raspberry-pi/dashboard
cp -R apps/dashboard/build/web/. installers/raspberry-pi/dashboard/

echo "Built Raspberry Pi server package in installers/raspberry-pi"
