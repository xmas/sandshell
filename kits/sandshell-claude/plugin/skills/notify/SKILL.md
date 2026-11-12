---
name: notify
description: Send the user a notification on their Mac (and the phone or other devices following the chat) with `sandshell-notify`. Use when the user asks to be told, pinged or notified when something happens — "tell me when the build passes", "let me know when the tests finish", "ping me if the deploy fails" — or when a long job they're waiting on finishes or needs them.
---

# Notify the user

`sandshell-notify` shows a notification on the Mac running Sandshell, and on
Remote Control devices that follow this session. Clicking it opens the chat.

```sh
sandshell-notify --title "Build passed" "All 214 tests pass on main (3m 12s)."
some-command 2>&1 | tail -5 | sandshell-notify --title "Deploy failed"
```

- Say what happened in the title, and the detail that matters in the message:
  the result, the number, the error line. Keep it short (a banner shows ~3 lines).
- Watching for something (a build, a deploy, a test run): wait for it in the
  background, then notify — e.g. run the check with a background shell or a
  loop, and call `sandshell-notify` when it finishes, with pass/fail.
- Notify once per thing the user asked about, not for every step. The user
  already hears when your turn ends; use this for what they asked to hear.
- If the command isn't there (an older sandbox), say so: the user can rebuild
  the sandbox to get it.
