---
created_at: 2026-05-07T10:40:41.731Z
updated_at: 2026-05-07T10:40:41.731Z
sources: ["v3-new-commands"]
tags: ["entity"]
inbound_links: ["source_v3_new_commands"]
outbound_links: []
---

# Linux

**Type:** entity

## Overview

- macOS: registers a launchd plist at ~/Library/LaunchAgents/com.devloop.<project>.plist for auto-start on login
- Linux: registers a systemd user service at ~/.config/systemd/user/devloop-<project>.service

*Introduced in: v3-new-commands*