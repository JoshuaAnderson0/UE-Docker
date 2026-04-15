# syntax=docker/dockerfile:1.7
# =============================================================================
# UE Build SDK - Builder Image
# Contains all tools needed to compile Unreal Engine from source.
# UE source is NOT included — it is bind-mounted from the host at runtime.
# =============================================================================
FROM ubuntu:22.04 AS builder

ARG JAVA_VERSION=17
ARG ANDROID_NDK_VERSION=27.2.12479018
ARG ANDROID_PLATFORM=android-34
ARG ANDROID_BUILD_TOOLS=35.0.1
ARG ANDROID_CMAKE_VERSION=3.22.1
ARG ANDROID_CMDLINE_TOOLS_VERSION=11076708

ENV DEBIAN_FRONTEND=noninteractive

# --- System dependencies for building UE ---
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        curl \
        git \
        git-lfs \
        libfreetype6-dev \
        libglu1-mesa-dev \
        libnss3 \
        libpulse-dev \
        libssl-dev \
        libxcursor-dev \
        libxinerama-dev \
        libxrandr-dev \
        pkg-config \
        python3 \
        shared-mime-info \
        sudo \
        tzdata \
        unzip \
        wget \
        xdg-user-dirs \
        zip \
    && rm -rf /var/lib/apt/lists/*

# --- OpenJDK (for Android builds) ---
RUN apt-get update && apt-get install -y --no-install-recommends \
        openjdk-${JAVA_VERSION}-jdk-headless \
    && rm -rf /var/lib/apt/lists/*

# --- Non-root user (UBT refuses to run as root) ---
RUN groupadd -g 1000 ue && \
    useradd -u 1000 -g ue -m -s /bin/bash ue && \
    echo "ue ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# --- Android SDK/NDK ---
ENV ANDROID_HOME=/opt/android-sdk
ENV JAVA_HOME=/usr/lib/jvm/java-${JAVA_VERSION}-openjdk-amd64
ENV NDK_ROOT=${ANDROID_HOME}/ndk/${ANDROID_NDK_VERSION}
ENV NDKROOT=${NDK_ROOT}
ENV PATH="${ANDROID_HOME}/cmdline-tools/latest/bin:${ANDROID_HOME}/platform-tools:${NDK_ROOT}:${JAVA_HOME}/bin:${PATH}"

RUN mkdir -p ${ANDROID_HOME} && \
    cd /tmp && \
    wget -q "https://dl.google.com/android/repository/commandlinetools-linux-${ANDROID_CMDLINE_TOOLS_VERSION}_latest.zip" \
         -O cmdline-tools.zip && \
    unzip -q cmdline-tools.zip -d ${ANDROID_HOME}/cmdline-tools-tmp && \
    mkdir -p ${ANDROID_HOME}/cmdline-tools/latest && \
    mv ${ANDROID_HOME}/cmdline-tools-tmp/cmdline-tools/* \
       ${ANDROID_HOME}/cmdline-tools/latest/ && \
    rm -rf ${ANDROID_HOME}/cmdline-tools-tmp cmdline-tools.zip && \
    yes | sdkmanager --licenses > /dev/null 2>&1 && \
    sdkmanager --install \
        "platform-tools" \
        "platforms;${ANDROID_PLATFORM}" \
        "build-tools;${ANDROID_BUILD_TOOLS}" \
        "cmake;${ANDROID_CMAKE_VERSION}" \
        "ndk;${ANDROID_NDK_VERSION}" && \
    chown -R ue:ue ${ANDROID_HOME}

USER ue
WORKDIR /build
