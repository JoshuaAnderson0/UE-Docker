#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# UE Build SDK - Compile Script
# Runs inside the builder container with UE source mounted at /build.
# Produces an Installed Build at /build/LocalBuilds/Engine/Linux/
# =============================================================================

BUILD_DIR="/build"
cd "${BUILD_DIR}"

echo "=== UE Build SDK: Starting compilation ==="
echo "Working directory: $(pwd)"
echo "Engine version: $(cat Engine/Build/Build.version 2>/dev/null || echo 'unknown')"

# --- Step 1: Download engine dependencies (Linux + Android only) ---
echo ""
echo "=== Step 1/5: Downloading engine dependencies ==="
bash Setup.sh \
    --force \
    -exclude=Win32 \
    -exclude=Win64 \
    -exclude=Mac \
    -exclude=osx \
    -exclude=osx64 \
    -exclude=HoloLens

# --- Step 2: Generate project files ---
echo ""
echo "=== Step 2/5: Generating project files ==="
bash GenerateProjectFiles.sh

# --- Step 3: Fix read-only files in toolchain so packaging can copy them ---
echo ""
echo "=== Step 3/5: Fixing file permissions ==="
chmod -R u+w "${BUILD_DIR}/Engine/Extras/ThirdPartyNotUE/SDKs/" 2>/dev/null || true
echo "Permissions fixed"

# --- Step 4: Patch plugins with known build issues ---
echo ""
echo "=== Step 4/5: Patching plugins ==="
PLUGIN_FILE="${BUILD_DIR}/Engine/Plugins/Runtime/ExternalGPUStatistics/ExternalGPUStatistics.uplugin"
if [ -f "${PLUGIN_FILE}" ]; then
    sed -i 's/"Type": "Runtime"/"Type": "ClientOnlyNoCommandlet"/' "${PLUGIN_FILE}"
    echo "Patched ExternalGPUStatistics plugin"
fi

# --- Step 5: Build Installed Engine ---
echo ""
echo "=== Step 5/5: Building Installed Engine (this will take several hours) ==="
# Use script -c to capture output while preserving exit code (tee masks it)
bash Engine/Build/BatchFiles/RunUAT.sh BuildGraph \
    -script=Engine/Build/InstalledEngineBuild.xml \
    -target="Make Installed Build Linux" \
    -nosign \
    -set:HostPlatformOnly=false \
    -set:WithLinux=true \
    -set:WithInstalledLinux=false \
    -set:WithAndroid=true \
    -set:WithWin64=false \
    -set:WithMac=false \
    -set:WithIOS=false \
    -set:WithTVOS=false \
    -set:WithLinuxArm64=false \
    -set:WithClient=true \
    -set:WithServer=true \
    -set:WithDDC=false \
    -set:GameConfigurations="Development;Shipping"
BUILD_EXIT=$?

echo ""
echo "RunUAT exit code: ${BUILD_EXIT}"

if [ ${BUILD_EXIT} -ne 0 ]; then
    echo "=== ERROR: RunUAT failed with exit code ${BUILD_EXIT} ==="
    exit ${BUILD_EXIT}
fi

# --- Verify output ---
INSTALLED_DIR="${BUILD_DIR}/LocalBuilds/Engine/Linux"
if [ -f "${INSTALLED_DIR}/Engine/Build/InstalledBuild.txt" ]; then
    echo ""
    echo "=== Build successful ==="
    echo "Installed Build location: ${INSTALLED_DIR}"
    echo "InstalledBuild.txt contents:"
    cat "${INSTALLED_DIR}/Engine/Build/InstalledBuild.txt"
    echo ""
    echo "Build.version contents:"
    cat "${INSTALLED_DIR}/Engine/Build/Build.version" 2>/dev/null || echo "(not found)"
    echo ""
    du -sh "${INSTALLED_DIR}" 2>/dev/null || true

    # Clean up .git now that build succeeded (saves space)
    rm -rf "${BUILD_DIR}/.git" 2>/dev/null || true
else
    echo ""
    echo "=== ERROR: Build failed ==="
    echo "InstalledBuild.txt not found at ${INSTALLED_DIR}/Engine/Build/InstalledBuild.txt"
    exit 1
fi
