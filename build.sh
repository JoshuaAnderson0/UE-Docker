#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WIN_SCRIPT_DIR="$(cygpath -w "${SCRIPT_DIR}")"
WIN_SOURCE_DIR="$(cygpath -w "${SCRIPT_DIR}/ue-source")"

# --- Load .env ---
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
    set -a
    source "${SCRIPT_DIR}/.env"
    set +a
else
    echo "ERROR: .env file not found. Copy .env.example to .env"
    exit 1
fi

# --- JSON reader via PowerShell ---
read_json() {
    local win_path
    win_path=$(cygpath -w "$1")
    powershell.exe -NoProfile -Command \
        "\$d = Get-Content '${win_path}' | ConvertFrom-Json; \$d.$2" 2>/dev/null | tr -d '\r'
}

# --- UE version selection ---
echo "Available UE versions:"
for f in "${SCRIPT_DIR}"/versions/*.json; do basename "$f" .json; done
echo ""

if [[ -n "${UE_VERSION:-}" ]]; then
    echo "Using UE_VERSION from .env: ${UE_VERSION}"
else
    read -rp "Which UE version to build? " UE_VERSION
fi

VERSION_FILE="${SCRIPT_DIR}/versions/${UE_VERSION}.json"
if [[ ! -f "${VERSION_FILE}" ]]; then
    echo "ERROR: Version config not found: ${VERSION_FILE}"
    exit 1
fi

# --- Parse version config ---
BRANCH=$(read_json "${VERSION_FILE}" "branch")
ANDROID_NDK_VERSION=$(read_json "${VERSION_FILE}" "android.ndk")
ANDROID_PLATFORM=$(read_json "${VERSION_FILE}" "android.platform")
ANDROID_BUILD_TOOLS=$(read_json "${VERSION_FILE}" "android.buildTools")
ANDROID_CMAKE_VERSION=$(read_json "${VERSION_FILE}" "android.cmake")
ANDROID_CMDLINE_TOOLS=$(read_json "${VERSION_FILE}" "android.cmdlineTools")
JAVA_VERSION=$(read_json "${VERSION_FILE}" "java")
BASE_IMAGE=$(read_json "${VERSION_FILE}" "baseImage")

IMAGE_NAME="${IMAGE_NAME:-ue-build-sdk}"
IMAGE_TAG="${IMAGE_TAG:-${UE_VERSION}}"
SOURCE_DIR="${SCRIPT_DIR}/ue-source"
BUILDER_TAG="ue-builder:${UE_VERSION}"

echo ""
echo "=== UE Build SDK ==="
echo "UE Version:       ${UE_VERSION} (branch: ${BRANCH})"
echo "Image:            ${IMAGE_NAME}:${IMAGE_TAG}"
echo "Android NDK:      ${ANDROID_NDK_VERSION}"
echo "Android Platform: ${ANDROID_PLATFORM}"
echo "Build Tools:      ${ANDROID_BUILD_TOOLS}"
echo "Java:             ${JAVA_VERSION}"
echo "Base Image:       ${BASE_IMAGE}"
echo ""

# --- Step 1: Clone UE source ---
if [[ -d "${SOURCE_DIR}/Engine" ]]; then
    echo "=== Step 1/5: UE source exists, skipping clone ==="
else
    echo "=== Step 1/5: Cloning UE ${BRANCH} (shallow) ==="
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        git clone --depth 1 --branch "${BRANCH}" \
            "https://${GITHUB_TOKEN}@github.com/EpicGames/UnrealEngine.git" \
            "${SOURCE_DIR}"
    elif [[ -n "${GIT_SSH_KEY:-}" ]]; then
        GIT_SSH_COMMAND="ssh -i ${GIT_SSH_KEY} -o StrictHostKeyChecking=no" \
        git clone --depth 1 --branch "${BRANCH}" \
            "git@github.com:EpicGames/UnrealEngine.git" \
            "${SOURCE_DIR}"
    else
        echo "ERROR: Set GITHUB_TOKEN or GIT_SSH_KEY in .env"
        exit 1
    fi
fi

# --- Copy compile script into source tree ---
mkdir -p "${SOURCE_DIR}/scripts"
cp "${SCRIPT_DIR}/scripts/compile.sh" "${SOURCE_DIR}/scripts/compile.sh"

# --- Step 2: Build builder Docker image ---
echo ""
echo "=== Step 2/5: Building builder image ==="
DOCKER_BUILDKIT=1 docker build \
    -f "${WIN_SCRIPT_DIR}\Dockerfile.builder" \
    --build-arg JAVA_VERSION="${JAVA_VERSION}" \
    --build-arg ANDROID_NDK_VERSION="${ANDROID_NDK_VERSION}" \
    --build-arg ANDROID_PLATFORM="${ANDROID_PLATFORM}" \
    --build-arg ANDROID_BUILD_TOOLS="${ANDROID_BUILD_TOOLS}" \
    --build-arg ANDROID_CMAKE_VERSION="${ANDROID_CMAKE_VERSION}" \
    --build-arg ANDROID_CMDLINE_TOOLS_VERSION="${ANDROID_CMDLINE_TOOLS}" \
    --tag "${BUILDER_TAG}" \
    --progress=plain \
    "${WIN_SCRIPT_DIR}"

# --- Step 3: Compile UE in builder container ---
echo ""
echo "=== Step 3/5: Compiling Unreal Engine (this will take several hours) ==="
MSYS_NO_PATHCONV=1 docker run --rm \
    -v "${WIN_SOURCE_DIR}:/build" \
    --shm-size=8g \
    "${BUILDER_TAG}" \
    bash /build/scripts/compile.sh

# --- Step 4: Build final SDK image ---
INSTALLED_DIR="${SOURCE_DIR}/LocalBuilds/Engine"
WIN_INSTALLED_DIR="$(cygpath -w "${INSTALLED_DIR}")"
if [[ ! -d "${INSTALLED_DIR}/Linux" ]]; then
    echo "ERROR: Installed Build not found at ${INSTALLED_DIR}/Linux"
    exit 1
fi

echo ""
echo "=== Step 4/5: Building final SDK image ==="
cp "${SCRIPT_DIR}/Dockerfile.sdk" "${INSTALLED_DIR}/Dockerfile.sdk"

DOCKER_BUILDKIT=1 docker build \
    -f "${WIN_INSTALLED_DIR}\Dockerfile.sdk" \
    --build-arg BASE_IMAGE="${BASE_IMAGE}" \
    --build-arg BUILDER_IMAGE="${BUILDER_TAG}" \
    --build-arg JAVA_VERSION="${JAVA_VERSION}" \
    --build-arg ANDROID_NDK_VERSION="${ANDROID_NDK_VERSION}" \
    --build-arg UE_VERSION="${UE_VERSION}" \
    --tag "${IMAGE_NAME}:${IMAGE_TAG}" \
    --progress=plain \
    "${WIN_INSTALLED_DIR}"

# --- Step 5: Summary ---
echo ""
echo "=== Step 5/5: Build complete ==="
echo "Image: ${IMAGE_NAME}:${IMAGE_TAG}"
IMAGE_SIZE=$(docker image inspect "${IMAGE_NAME}:${IMAGE_TAG}" --format='{{.Size}}')
echo "Size: $(numfmt --to=iec ${IMAGE_SIZE} 2>/dev/null || echo "${IMAGE_SIZE} bytes")"
echo ""
echo "To build a game project:"
echo "  docker run --rm -v /path/to/MyGame:/game -v /path/to/output:/output ${IMAGE_NAME}:${IMAGE_TAG} \\"
echo "    /home/ue/UnrealEngine/Engine/Build/BatchFiles/RunUAT.sh BuildCookRun \\"
echo "      -project=/game/MyGame.uproject -platform=Linux -server -noclient \\"
echo "      -serverconfig=Development -build -cook -stage -pak -archive -archivedirectory=/output"
