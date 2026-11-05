# syntax=docker/dockerfile:1
# bd from its release, and the kit's scripts, under /opt/berg-kit (bd also
# on the PATH at /usr/local/bin). berg itself comes from your hub when the
# sandbox starts: Iceberg isn't public, and the hub serves the berg it runs.
FROM debian:trixie-slim AS build
ARG BD_VERSION
ARG TARGETARCH
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends ca-certificates curl >/dev/null \
 && curl -fsSL "https://github.com/gastownhall/beads/releases/download/v${BD_VERSION}/beads_${BD_VERSION}_linux_${TARGETARCH}.tar.gz" \
      | tar -xz -C /tmp \
 && install -D -m 0755 "$(find /tmp -type f -name bd | head -1)" /opt/berg-kit/bin/bd

FROM scratch
COPY --from=build /opt/berg-kit/bin/bd /opt/berg-kit/bin/bd
COPY --from=build /opt/berg-kit/bin/bd /usr/local/bin/bd
COPY --chmod=0755 scripts/berg-kit-setup /opt/berg-kit/bin/berg-kit-setup
