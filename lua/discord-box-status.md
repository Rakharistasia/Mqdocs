---
tags:
    - lua
---
# Discord Status Card for Your Boxes

`boxstatus.lua` keeps a live status card in a Discord channel for every box you are running, so you can check on a grinding group from your phone. It is plain Lua: no plugin, no bot account, and it does not depend on MQ2Discord.

Each box publishes a snapshot of itself over [actors](actors.md). One box, the **hub**, collects the snapshots and keeps one Discord message up to date through a webhook. The message is edited in place rather than reposted, so the channel doesn't fill up.

Each box gets its own embed showing:

- name, level and class, zone, and combat state
- HP, mana (casters only) and endurance bars
- current target and extended target count
- RGMercs status: running, paused or off
- XP and AA per hour over a rolling hour
- when the box last reported, as a live relative time

The embed is green when the box is healthy, yellow when RGMercs is paused or HP is low, and red when the box is dead, silent, or RGMercs is off.

## Setup

1. In Discord, open the channel settings, then **Integrations > Webhooks > New Webhook**, and copy the webhook URL.
2. Save the script below as `boxstatus.lua` in your MacroQuest `lua` folder.
3. On the hub box, run `/lua run boxstatus hub`. The first run writes `config/boxstatus.lua` and exits.
4. Edit that file and paste in your `webhook_url`. Run `/lua run boxstatus hub` again.
5. On every other box, run `/lua run boxstatus`.

The script installs `lua-curl` and `lua-cjson` through [PackageMan](luarocks-modules.md) the first time it runs, and PackageMan may ask you to confirm.

Anyone with the webhook URL can post to that channel, so keep it private.

### Config

`config/boxstatus.lua` on the hub:

| Setting | Default | Meaning |
|---------|---------|---------|
| `webhook_url` | | Discord webhook URL (required) |
| `mention` | | Discord user ID to ping on alerts. Turn on developer mode in Discord, then right-click your name and choose Copy User ID. |
| `title` | `Box Status` | Heading shown above the cards |
| `interval` | `30` | Seconds between card updates |
| `stale_after` | `45` | Seconds without a snapshot before a box is shown as silent |
| `low_hp` | `30` | HP% below which a card turns yellow |

## Alerts

Cards edit silently, so they never notify your phone. The hub sends a separate message, with a ping if `mention` is set, when a box enters one of these states:

- **dead**: the character is hovering.
- **silent**: no snapshot arrived within `stale_after`, for example after a crash, a disconnect or camping to character select.
- **rgmercs off**: the `rgmercs` script is no longer running on that box.

Each state alerts once, and again only after the box has left that state.

## Commands

| Command | Effect |
|---------|--------|
| `/boxstatus stop` | Stop the script on this box |
| `/boxstatus post` | Hub only: update the card now |
| `/boxstatus forget <name>` | Hub only: drop a box from the card, for example one you logged out on purpose |

## Notes

- The hub's card update is a blocking HTTP call with a 5 second timeout, so the hub can stall for a moment if Discord is slow. Keep the hub on a box that isn't doing anything timing-sensitive.
- Discord rate limits are handled: on a 429 the hub waits for the requested time and tries again.
- The card is split into several messages, six boxes each, to stay inside Discord's embed limits.
- The script finds RGMercs by looking for a running Lua script named `rgmercs`, and also reads `RGMercs.Paused` if that TLO exists. Neither lookup has been checked against a live RGMercs install. If the status is wrong for you, the lookup is `rgmercsStatus()` near the top of the script, and it is the only part that needs changing.

## Script

```lua
--8<-- "lua/examples/boxstatus.lua"
```
