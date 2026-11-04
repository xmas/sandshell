# syntax=docker/dockerfile:1
# The Codex workload ships no Node: the overlay carries the node binary, the
# adapter with the codex it depends on (installed here, so starting a chat
# needs no registry) and a launcher. All under /opt/sandshell.
FROM node:24-trixie-slim AS build
ARG ACP_VERSION
RUN npm install --silent --no-audit --no-fund \
      --prefix /opt/sandshell/codex-acp "@agentclientprotocol/codex-acp@${ACP_VERSION}"

FROM scratch
COPY --from=build /usr/local/bin/node /opt/sandshell/bin/node
COPY --from=build /opt/sandshell/codex-acp /opt/sandshell/codex-acp
COPY --chmod=0755 scripts/sandshell-codex-acp /opt/sandshell/bin/sandshell-codex-acp
