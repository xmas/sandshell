# Hatch Mac Bridge — boot status

- boot time (UTC): 2026-10-08T20:51:39Z
- hatch-mcp reachable at boot: yes
- hatch MCP registered with Claude Code: yes (local scope: /Users/xmas/Code/xmas-sandshell)
- tool-call approvals: on (token accepted; tool calls may need approval in Hatch Approvals on the Mac)
- sandbox name: xmas-sandshell
- endpoint: http://host.docker.internal:31337/mcp

This reflects sandbox boot, not now. Live check (any HTTP
status code back means the server is up):

    curl -s -o /dev/null -w "%{http_code}" -m 3 \
      http://host.docker.internal:31337/mcp
