# PandaConquest

PandaConquest is an addon for the OctoWoW client (1.12.1, Lua 5.0), dedicated to community PvE achievements.

The goal is to let each player unlock custom achievements, follow their progress, view other users' progress and take part in leaderboards per character or campaign. The addon must work locally without any external service. In-game P2P sharing and optional cloud synchronization can complete this once their constraints are validated.

## Current state

The project is in **phase 0: runtime validation** on OctoWoW. A loadable experimental foundation is present with a bounded SavedVariable, raw captures of `CHAT_MSG_ADDON` and `CHAT_MSG_CHANNEL`, and the `/pc p2p` commands. The code follows Lua 5.0 and the documented limits of the 1.12.1 client:

- addon messages bounded to 255 bytes prefix included, on PARTY, RAID, GUILD and BATTLEGROUND only;
- out-of-group `PandaConquest` channel joined automatically, with sending through `SendChatMessage` requiring no user action, and traffic hidden from every chat tab except one named exactly `PandaConquest`;
- complete channel envelope bounded to 255 bytes;
- exact mount and stealth detection with OctoWoW's nampower or VanillaHelpers DLLs, with a fallback on buff icons.

No two-client campaign has been run on OctoWoW yet: transports, channel reach across zones and between factions, throughput, reconnection and fragmentation remain to be measured. The state and the procedure are in [P2P tests](docs/p2p-testing.md#reference-state-for-octowow).

The full leaderboard, the advanced distributed protocol and the companion application must not be developed before these validations.

A first map foundation is also available: POIs can be registered as points or groups of coordinates, then rendered as gray (neutral), red (Horde), blue (Alliance), yellow (resources) or custom RGB areas, with their type's icon at the center. The contract is described in [POIs and areas on the map](docs/map-pois.md).

## Core principles

- The MVP is about PvE, not territorial control or PvP, with one exception: the capture of `OUTPOST`s ([design](docs/capture.md), decision 0012).
- Each character is a distinct identity: `character@realm`.
- Offline operation is mandatory.
- The companion application and the Cloudflare cloud stay optional ([decision 0030](docs/decisions/0030-cloudflare-cloud-baseline.md)).
- The first progress types are monotonic: boolean, increasing counter or tier.
- P2P or cloud data is no proof from the server.
- Network capabilities must not be assumed before a reproducible two-client test.

## Installation

The `pandaConquest` folder must be placed in:

```text
C:\Games\Wow-Octo\Interface\AddOns\pandaConquest
```

### Requirement: nampower for hunting grounds

Capturing hunting grounds (`HUNTING_GROUNDS`, [decision 0026](docs/decisions/0026-hunting-grounds-capture.md)) **requires nampower**. Only its `UNIT_DIED` event provides the identifier of killed creatures; the standard 1.12 client does not, and there is no fallback.

- Start the game with **the Octo launcher**, which loads the nampower, VanillaHelpers and UnitXP_SP3 DLLs. Starting `WoW.exe` directly does not load them.
- Without nampower, kills are not counted and the ground's HUD asks players to enable NamPower in the Octo launcher.
- In-game check: `/pc hunt` must list nampower functions (`GetNampowerVersion`, `GetUnitGUID`, `GetUnitField`) and its `deaths=` counter rises when a creature dies nearby.
- Outposts (`OUTPOST`) and achievements do not depend on it: nampower only makes mount and stealth detection more precise, with a fallback on buff icons.

The expected client uses interface `11200`. After installing or changing the addon, enable it then `/reload`; a **new Lua file** added to the `.toc` is only loaded after a full client restart. The starting commands are:

```text
/pc p2p status
/pc p2p hello PARTY
/pc p2p ping PARTY
/pc p2p channelsend TEST-P2P
/pc p2p log
/pc map
```

An accepted send call or an event registered without error does not prove delivery. Validation requires two clients and the [P2P tests](docs/p2p-testing.md) procedure.

## Documentation

- [Vision](docs/vision.md)
- [Game design](docs/game-design.md)
- [Architecture](docs/architecture.md)
- [Data model](docs/data-model.md)
- [Achievements](docs/achievements.md)
- [POIs and areas on the map](docs/map-pois.md)
- [POI capture](docs/capture.md)
- [P2P protocol](docs/p2p-protocol.md)
- [P2P safety](docs/p2p-safety.md)
- [P2P tests](docs/p2p-testing.md)
- [Security](docs/security.md)
- [Companion application](docs/companion.md)
- [Roadmap](docs/roadmap.md)
- [Architecture decisions](docs/decisions/README.md)
- [Changelog](CHANGELOG.md)

## Agent-assisted work

Agents must start with [AGENTS.md](AGENTS.md), which points to [CLAUDE.md](CLAUDE.md). Searches in the project go through the standalone index located in `C:\Games\Wow-Octo\#Addons-dev\diagnostics\pandaconquest-index`.

After any change to the addon, documentation included:

```powershell
python -B "C:\Games\Wow-Octo\#Addons-dev\diagnostics\pandaconquest-index\pandaconquest_index.py" build
python -B "C:\Games\Wow-Octo\#Addons-dev\diagnostics\pandaconquest-index\pandaconquest_index.py" status
```

`status` must return exit code 0 (`[UP_TO_DATE]`). The Lua 5.0 checks to run before are described in [CLAUDE.md](CLAUDE.md).

Overlord is a reference for distributed architecture, not a base to port literally. Its index is in `C:\Games\Wow-Octo\#Addons-dev\diagnostics\overlord-index`.
