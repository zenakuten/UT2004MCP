# UT2004 MCP Server - client configuration

The `UT2004MCP` mutator (`UT2004MCP.MutMCP`) runs an **MCP (Model Context Protocol) server**
inside a running UT2004 server, so AI agents can query and control the game.

These configs currently register only the in-game server. The repository's
prebuilt `Editor/bridge/unrealed-send.exe` helper is not yet an MCP server and must not
be added to client MCP configuration until the local stdio wrapper exists.

- **Transport:** Streamable HTTP (plain JSON responses, stateless)
- **Endpoint:** `http://<server-host>:6900/mcp`
- **Port:** `6900` by default - configurable via `ListenPort` in `MCP.ini`
  (`[UT2004MCP.MutMCP] ListenPort=6900`)
- **Auth:** none (firewall the port; intended for trusted/LAN use)

Use `localhost` if your agent runs on the same machine as the game server
(recommended: run UT2004 as a **listen server** so the agent can also read the
local `ScreenShots/` folder). Otherwise use the server's IP/hostname.

## Tools

| Tool | Args | What it does |
|------|------|--------------|
| `query_game_info` | - | gametype, map, player counts, score/time limits |
| `list_players` | - | connected players: score, deaths, ping, team, flags |
| `say` | `message` | broadcast a message to all players |
| `switch_map` | `map` | travel all players to a new map (name or URL) |
| `kick` | `player` | kick a player by exact name |
| `add_bot` | `count?` | add AI bots (default 1) |
| `remove_bots` | `count?` | remove bots (0 / omitted = all) |
| `player_input` | `player`, `command` | run a bound input command as a player (Jump, Fire, ...) |
| `screenshot` | `player` | capture a real player's view to `ScreenShots/ShotNNNNN.bmp` |
| `gui_click` | `player`, `caption` | click a menu button (by caption) in a player's open menu |

## Which config file do I use?

Copy the matching file from this folder to your client's config location:

| Client | File here | Put it at |
|--------|-----------|-----------|
| Claude Code | `claude-code.mcp.json` | `.mcp.json` in your project root (or merge into `~/.claude.json`) |
| VS Code (Copilot) | `vscode-mcp.json` | `.vscode/mcp.json` in your workspace |
| GitHub Copilot CLI | `copilot-cli-mcp-config.json` | merge into `~/.copilot/mcp-config.json` (or `$COPILOT_HOME/mcp-config.json`) |
| Cursor | `cursor-mcp.json` | `.cursor/mcp.json` (project) or `~/.cursor/mcp.json` (global) |
| Claude Desktop | `claude-desktop-config.json` | merge into `claude_desktop_config.json` |

> Note: VS Code Copilot and the GitHub Copilot **CLI** are different tools with
> different config files - use `vscode-mcp.json` for the editor and
> `copilot-cli-mcp-config.json` for the terminal CLI.

In every file, change the `url` host/port if your game server is not on
`localhost:6900`.

### Claude Code (CLI, no file editing)

```bash
claude mcp add --transport http ut2004 http://localhost:6900/mcp
```

### GitHub Copilot CLI (no file editing)

In interactive mode, run `/mcp add` and fill in the form (type `http`, the URL
above), or manage servers with the `copilot mcp` subcommands. Servers are saved to
`~/.copilot/mcp-config.json`.

### Quick manual test (no client needed)

```bash
curl -s -X POST http://localhost:6900/mcp -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
```
