# UT2004 MCP Server

An [MCP (Model Context Protocol)](https://modelcontextprotocol.io) server that runs
**inside** an Unreal Tournament 2004 server, implemented as a UT2004 mutator
(`UT2004MCP.MutMCP`). Load the mutator and AI agents can query and control the running game
over the network - no game client / player slot required.

The repository also contains the start of **UnrealEd automation**. Its external Windows
helper drives the editor's bottom-bar Command control without screen coordinates. A
prebuilt 64-bit `unrealed-send.exe` is included, but the helper is not yet an MCP server:
the local stdio MCP wrapper and editor tool schemas still need to be added.

The mutator binds its own TCP port and speaks MCP over HTTP, so any MCP-capable agent
(Claude Code, Claude Desktop, VS Code, Cursor, ...) can connect and use the tools below.

## Features

| Tool | Arguments | Description |
|------|-----------|-------------|
| `query_game_info` | - | Gametype, map, player counts, score & time limits |
| `list_players` | - | Connected players: score, deaths, ping, team, bot/spectator |
| `say` | `message` | Broadcast a message to all players |
| `switch_map` | `map` | Travel all players to a new map (name or full URL) |
| `kick` | `player` | Kick a player by exact (case-insensitive) name |
| `add_bot` | `count?` | Add AI bots (default 1) |
| `remove_bots` | `count?` | Remove bots (0 / omitted = all) |
| `player_input` | `player`, `command` | Run a bound input command as a player (`Jump`, `Fire`, `NextWeapon`, ...) |
| `screenshot` | `player` | Capture a real player's view to `ScreenShots/ShotNNNNN.bmp` |
| `gui_click` | `player`, `caption` | Click a menu button (by caption) in a player's open menu |

`player_input` + `screenshot` + `gui_click` together let an agent drive a real client:
screenshot to read the screen, click a menu button by name, screenshot again.

## Requirements

- A UT2004 server install (dedicated or **listen** server).
- Standard packages only: `Engine`, `IpDrv`, `UnrealGame`, `XInterface`.

> **Tip:** Run UT2004 as a **listen server** on the same machine as your agent. The
> agent then connects over the network *and* can read the local `ScreenShots/` folder --
> `screenshot` writes files on the machine the player's client runs on, so screenshots
> are only useful for the local host player.

## Building

This project is a UT2004 mutator; compile it with the game's script compiler, `UCC`.

1. Add the package to `[Editor.EditorEngine]` in `System/UT2004.ini`:

   ```ini
   EditPackages=UT2004MCP
   ```

2. Compile from the `System/` folder:

   ```bash
   UCC make
   ```

   This produces `System/UT2004MCP.u`.

## Running

Load the mutator on your server via the URL:

```
?Mutator=UT2004MCP.MutMCP
```

for example:

```bash
ucc server DM-Goliath?Game=XGame.xDeathMatch?Mutator=UT2004MCP.MutMCP
```

The mutator sets `bAddToServerPackages=true`, so the package is automatically
replicated to clients (needed for the client-side `gui_click`) - no `ServerPackages=`
line required.

On startup you should see in the server log:

```
MCP: listening for agent connections on TCP port 6900
```

## Configuration

Settings live in `System/MCP.ini`:

```ini
[UT2004MCP.MutMCP]
ListenPort=6900
```

- **`ListenPort`** - TCP port the MCP server listens on (default `6900`). This is a
  separate port from the game port.
- **Auth** - none. The port is unauthenticated, so **firewall it** and treat it as
  trusted/LAN-only.

## Connecting an agent

The server endpoint is:

```
http://<server-host>:6900/mcp
```

Use `localhost` if the agent runs on the same machine, otherwise the server's IP.
Ready-to-use config files for popular clients are in [`Agents/`](Agents/) - copy the
one matching your client (see [`Agents/README.md`](Agents/README.md)).

Minimal Claude Code config (`.mcp.json` in your project root):

```json
{
  "mcpServers": {
    "ut2004": { "type": "http", "url": "http://localhost:6900/mcp" }
  }
}
```

Or add it from the CLI:

```bash
claude mcp add --transport http ut2004 http://localhost:6900/mcp
```

> MCP client config formats change quickly. If a client rejects `"type": "http"`,
> use the `claude mcp add --transport http ...` command above, or bridge with
> [`mcp-remote`](https://www.npmjs.com/package/mcp-remote) (see the Claude Desktop
> example in `Agents/`).

Quick test without any client:

```bash
curl -s -X POST http://localhost:6900/mcp -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
```

## How it works

- **Transport:** MCP over Streamable HTTP. The mutator listens on its own
  `TcpLink` port and answers each JSON-RPC request with a plain `application/json`
  HTTP response (stateless - no session id, one request per connection).
- **Game control** (`say`, `kick`, `switch_map`, bots, ...) runs server-side against
  the live `GameInfo` / `GameReplicationInfo`.
- **Client control** (`gui_click`) runs *on the player's client*: a
  `LinkedReplicationInfo` is attached to each player and a reliable client function
  finds the local `GUIController` and fires the target button's `OnClick`. This works
  for remote clients and the listen-server host alike.

## Project layout

```
UT2004MCP/
  Classes/        UnrealScript source
    MutMCP.uc         mutator entry point; spawns the listener, links players
    MCPServer.uc      TCP listener (accepts connections)
    MCPConnection.uc  per-connection HTTP parse + JSON-RPC dispatch + tools
    MCPJson.uc        JSON build/escape + request field extraction
    MCPPlayerLink.uc  per-player client link (client-side GUI actions)
  Agents/         ready-to-use MCP client configs + guide
  Editor/
    bridge/
      unrealed-send.c  Win32 helper for sending one UnrealEd command
      unrealed-send.exe  prebuilt 64-bit Windows helper
      build.sh         MinGW build script
```

## UnrealEd command bridge

A prebuilt 64-bit helper is included. To rebuild it on Linux with MinGW:

```bash
cd Editor/bridge
./build.sh
```

With UnrealEd running under Wine, use the same Wine prefix:

```bash
wine Editor/bridge/unrealed-send.exe "OBJ LIST CLASS=LEVEL"
```

The helper finds `UnrealEd.exe`, locates the bottom-bar **Command** edit control, focuses
it and delivers the command with Win32 `SendInput`. Open **View > Log** in UnrealEd to
read the immediate result. The visible console can update before `System/UnrealEd.log`
is flushed.

The bridge briefly brings UnrealEd to the foreground. A zero exit code means the input
was delivered; verify the editor output or requested persistent change before treating
the command as successful.
