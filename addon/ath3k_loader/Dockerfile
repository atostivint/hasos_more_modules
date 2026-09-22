# Supervisor no longer provides BUILD_FROM automatically, so the base image is
# declared explicitly with a working default for manual builds.
ARG BUILD_FROM=ghcr.io/home-assistant/base:latest
FROM ${BUILD_FROM}

ARG BUILD_VERSION=0.2.0
ARG BUILD_ARCH=amd64

LABEL \
  io.hass.version="${BUILD_VERSION}" \
  io.hass.type="app" \
  io.hass.arch="${BUILD_ARCH}"

# kmod provides insmod/modinfo used by run.sh to load and inspect the module.
RUN apk add --no-cache kmod

# The kernel module is shipped inside the image so the app is self-contained.
# It is only loaded after run.sh verified it matches the running kernel.
COPY modules/ /opt/ath3k/modules/

COPY run.sh /
RUN chmod 0755 /run.sh

CMD ["/run.sh"]
