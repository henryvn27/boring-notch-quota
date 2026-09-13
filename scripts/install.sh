#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_DIR="${HOME}/Applications"
INSTALL_PATH="${INSTALL_DIR}/Notch.app"
DERIVED_DATA="${TMPDIR:-/tmp}/notch-derived-data"
AUTO_APPROVE=false
LAUNCH=true

usage() {
  cat <<'EOF'
Usage: ./scripts/install.sh [options]

Builds Notch from this checkout and installs it to ~/Applications/Notch.app
without sudo or changes to system settings.

Options:
  --yes          Replace an existing ~/Applications/Notch.app without prompting.
  --no-launch    Install without opening the app.
  --install-dir  Install to a different directory (the app is always Notch.app).
  --help         Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes)
      AUTO_APPROVE=true
      shift
      ;;
    --no-launch)
      LAUNCH=false
      shift
      ;;
    --install-dir)
      [[ $# -ge 2 ]] || { echo "Missing value for --install-dir" >&2; exit 2; }
      INSTALL_DIR="$2"
      INSTALL_PATH="${INSTALL_DIR}/Notch.app"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Notch is a macOS app. Run this installer on macOS." >&2
  exit 1
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "xcodebuild was not found. Install Xcode 16.4 or newer, then try again." >&2
  exit 1
fi

if [[ ! -d "${REPO_ROOT}/boringNotch.xcodeproj" ]]; then
  echo "Run this script from a Notch checkout; boringNotch.xcodeproj was not found." >&2
  exit 1
fi

echo "Building Notch from ${REPO_ROOT}"
xcodebuild \
  -resolvePackageDependencies \
  -project "${REPO_ROOT}/boringNotch.xcodeproj" \
  -scheme boringNotch \
  -clonedSourcePackagesDirPath "${DERIVED_DATA}/SourcePackages" \
  >/dev/null

xcodebuild \
  -project "${REPO_ROOT}/boringNotch.xcodeproj" \
  -scheme boringNotch \
  -configuration Release \
  -derivedDataPath "${DERIVED_DATA}" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build

APP_SOURCE="${DERIVED_DATA}/Build/Products/Release/Notch.app"
if [[ ! -d "${APP_SOURCE}" ]]; then
  echo "Build completed but ${APP_SOURCE} was not created." >&2
  exit 1
fi

if [[ -e "${INSTALL_PATH}" ]]; then
  if [[ "${AUTO_APPROVE}" != true ]]; then
    read -r -p "Replace ${INSTALL_PATH}? [y/N] " answer
    [[ "${answer}" =~ ^[Yy]$ ]] || { echo "Install cancelled."; exit 0; }
  fi
  rm -rf "${INSTALL_PATH}"
fi

mkdir -p "${INSTALL_DIR}"
ditto "${APP_SOURCE}" "${INSTALL_PATH}"

echo "Installed ${INSTALL_PATH}"
if [[ "${LAUNCH}" == true ]]; then
  open "${INSTALL_PATH}"
  echo "Launched Notch."
fi
