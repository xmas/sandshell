# syntax=docker/dockerfile:1
# The Claude workload ships no Node: the overlay carries the node binary, the
# adapter (installed here, so starting a chat needs no registry), Sandshell's
# wrapper, and a launcher. All under /opt/sandshell, clear of other kits.
#
# --omit=optional drops the SDK's vendored claude binary: the launcher points
# the adapter at the sandbox's own claude (CLAUDE_CODE_EXECUTABLE).
FROM node:24-trixie-slim AS build
ARG ACP_VERSION
RUN npm install --silent --no-audit --no-fund --omit=optional \
      --prefix /opt/sandshell/claude-acp "@agentclientprotocol/claude-agent-acp@${ACP_VERSION}"

FROM scratch
COPY --from=build /usr/local/bin/node /opt/sandshell/bin/node
COPY --from=build /opt/sandshell/claude-acp /opt/sandshell/claude-acp
COPY scripts/sandshell-acp.mjs /opt/sandshell/sandshell-acp.mjs
COPY --chmod=0755 scripts/sandshell-claude-acp /opt/sandshell/bin/sandshell-claude-acp
