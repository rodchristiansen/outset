#!/bin/zsh --no-rcs
#
# Builds the release package: one installer, io.macadmins.Outset, carrying
# outset and the Managed State Keeper window together.
#
#   Package/buildReleasePackage.zsh <version> <Outset.app> <Managed State Keeper.app> <output dir>
#
# Payload, installed at /:
#   usr/local/outset/Outset.app and usr/local/outset/outset
#   Applications/Utilities/Managed State Keeper.app (helper and its LaunchDaemon plist inside)
#
# Every bundle installs over an existing copy whatever its version, so a fork
# build replaces an upstream one and a rollback also lands.

set -euo pipefail

VERSION="$1"
OUTSET_APP="$2"
MSK_APP="$3"
OUTPUT_DIR="$4"

REPO_ROOT="${0:A:h:h}"
IDENTIFIER="io.macadmins.Outset"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT
PAYLOAD="${WORK_DIR}/payload"

mkdir -p "${PAYLOAD}/usr/local/outset" "${PAYLOAD}/Applications/Utilities" "${OUTPUT_DIR}"
chmod 755 "${PAYLOAD}/usr" "${PAYLOAD}/usr/local" "${PAYLOAD}/usr/local/outset"
chmod 775 "${PAYLOAD}/Applications" "${PAYLOAD}/Applications/Utilities"

ditto "${OUTSET_APP}" "${PAYLOAD}/usr/local/outset/Outset.app"
cp "${REPO_ROOT}/Package/outset" "${PAYLOAD}/usr/local/outset/outset"
chmod 755 "${PAYLOAD}/usr/local/outset/outset"
ditto "${MSK_APP}" "${PAYLOAD}/Applications/Utilities/Managed State Keeper.app"
ditto "${REPO_ROOT}/Package/Scripts" "${WORK_DIR}/scripts"

# Drop build-host extended attributes such as com.apple.provenance, which
# pkgbuild would otherwise carry into the package as ._ AppleDouble files.
find "${PAYLOAD}" "${WORK_DIR}/scripts" -exec xattr -c {} +

pkgbuild --analyze --root "${PAYLOAD}" "${WORK_DIR}/component.plist"
i=0
while plutil -extract "${i}" xml1 -o - "${WORK_DIR}/component.plist" >/dev/null 2>&1; do
    plutil -replace "${i}.BundleIsVersionChecked" -bool NO "${WORK_DIR}/component.plist"
    plutil -replace "${i}.BundleIsRelocatable" -bool NO "${WORK_DIR}/component.plist"
    i=$(( i + 1 ))
done
if (( i < 2 )); then
    echo "Expected Outset.app and Managed State Keeper.app in the component list, found ${i}" >&2
    exit 1
fi

pkgbuild --root "${PAYLOAD}" --component-plist "${WORK_DIR}/component.plist" \
    --scripts "${WORK_DIR}/scripts" \
    --identifier "${IDENTIFIER}" --version "${VERSION}" --install-location / \
    "${WORK_DIR}/Outset-component.pkg"
productbuild --package "${WORK_DIR}/Outset-component.pkg" --identifier "${IDENTIFIER}" \
    --version "${VERSION}" "${OUTPUT_DIR}/Outset-${VERSION}.pkg"

echo "Built ${OUTPUT_DIR}/Outset-${VERSION}.pkg"
