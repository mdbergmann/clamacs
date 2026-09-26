# The Linux leg of the host frontend (specs/clamacs-host.md, H6): Ubuntu
# with what host/build.sh needs (gcc, g++, pkg-config, GTK 3, WebKitGTK
# 4.1, node) plus Xvfb for a display and libffi for clamiga's FFI.
# verify/host/run-linux.sh builds it and runs the smoke and the drive in it.
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends \
    build-essential pkg-config libffi-dev libgtk-3-dev libwebkit2gtk-4.1-dev \
    xvfb xauth dbus dbus-x11 ca-certificates nodejs npm git procps \
    && rm -rf /var/lib/apt/lists/*
