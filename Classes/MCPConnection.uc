/*******************************************************************************
	MCPConnection

	One accepted connection. Reads a single HTTP request (headers + optional
	JSON body), dispatches the JSON-RPC method, writes an HTTP response and
	closes. Stateless: no session id, one request per connection.

	MCP handshake handled:
		initialize                 -> capabilities / serverInfo
		notifications/initialized  -> 202 Accepted (notification, no reply body)
		tools/list                 -> tool schemas
		tools/call                 -> run tool, return text content
		ping                       -> {}

	Response transport is plain application/json (no SSE), which is spec-valid
	for a server that never pushes server-initiated messages.
*******************************************************************************/

class MCPConnection extends IpDrv.TcpLink;

var string inBuf;          // accumulated request bytes
var string outBuf;         // pending response bytes to drain
var int    contentLength;  // from Content-Length header (-1 = not yet known)
var int    headerEnd;      // index in inBuf where the body starts
var bool   bHeadersParsed;
var bool   bHandled;       // request dispatched; ignore further input
var bool   bResponding;    // draining outBuf
var bool   bToolError;     // set by a tool to mark its result isError (no out-bool in uscript)

// -----------------------------------------------------------------------------
// Connection lifecycle
// -----------------------------------------------------------------------------

event Accepted()
{
	inBuf = "";
	outBuf = "";
	contentLength = -1;
	headerEnd = 0;
	bHeadersParsed = false;
	bHandled = false;
	bResponding = false;
	SetTimer(15.0, false); // drop the connection if the request never completes
}

event Timer()
{
	Close();
}

event Closed()
{
	Destroy();
}

event ReceivedText(string Text)
{
	if (bHandled)
		return;
	inBuf $= Text;
	if (!bHeadersParsed)
		ParseHeaders();
	if (bHeadersParsed)
		CheckComplete();
}

event Tick(float delta)
{
	Super.Tick(delta);
	if (bResponding && Len(outBuf) > 0)
		DrainSend();
}

// -----------------------------------------------------------------------------
// HTTP request assembly
// -----------------------------------------------------------------------------

function ParseHeaders()
{
	local int e, p;
	local string headers, sub;

	e = InStr(inBuf, Chr(13) $ Chr(10) $ Chr(13) $ Chr(10));
	if (e == -1)
		return;

	bHeadersParsed = true;
	headerEnd = e + 4;
	headers = Left(inBuf, e);

	p = InStr(Caps(headers), "CONTENT-LENGTH:");
	if (p == -1)
	{
		contentLength = 0;
		return;
	}
	sub = Mid(headers, p + 15);
	while (Left(sub, 1) == " ")
		sub = Mid(sub, 1);
	contentLength = int(sub);
}

function CheckComplete()
{
	local string body;

	if (Len(inBuf) - headerEnd < contentLength)
		return;

	bHandled = true;
	SetTimer(0, false);
	body = Mid(inBuf, headerEnd, contentLength);
	HandleRequest(body);
}

// -----------------------------------------------------------------------------
// JSON-RPC dispatch
// -----------------------------------------------------------------------------

function HandleRequest(string body)
{
	local string method, id;

	method = class'MCPJson'.static.GetString(body, "method");
	id = class'MCPJson'.static.GetRaw(body, "id");

	// No id -> JSON-RPC notification (e.g. notifications/initialized). Ack only.
	if (id == "")
	{
		SendResponse(202, "Accepted", "", "");
		return;
	}

	if (method ~= "initialize")
		RespondResult(id, BuildInitialize(body));
	else if (method ~= "tools/list")
		RespondResult(id, BuildToolsList());
	else if (method ~= "tools/call")
		RespondResult(id, CallTool(class'MCPJson'.static.GetString(body, "name"), body));
	else if (method ~= "ping")
		RespondResult(id, "{}");
	else
		RespondError(id, -32601, "Method not found: " $ method);
}

function RespondResult(string id, string resultJson)
{
	local string env;
	env = "{" $ jStr("jsonrpc", "2.0") $ "," $ jRaw("id", id) $ "," $ jRaw("result", resultJson) $ "}";
	SendResponse(200, "OK", "application/json", env);
}

function RespondError(string id, int code, string msg)
{
	local string env, errObj;
	errObj = "{" $ jNum("code", code) $ "," $ jStr("message", msg) $ "}";
	env = "{" $ jStr("jsonrpc", "2.0") $ "," $ jRaw("id", id) $ "," $ jRaw("error", errObj) $ "}";
	SendResponse(200, "OK", "application/json", env);
}

// -----------------------------------------------------------------------------
// MCP method bodies
// -----------------------------------------------------------------------------

function string BuildInitialize(string body)
{
	local string pv, caps, srv;

	// Echo back the client's requested protocol version if present.
	pv = class'MCPJson'.static.GetString(body, "protocolVersion");
	if (pv == "")
		pv = "2024-11-05";

	caps = "{" $ jRaw("tools", "{}") $ "}";
	srv  = "{" $ jStr("name", "ut2004-mcp") $ "," $ jStr("version", "0.1.0") $ "}";

	return "{" $ jStr("protocolVersion", pv) $ ","
		$ jRaw("capabilities", caps) $ ","
		$ jRaw("serverInfo", srv) $ "}";
}

function string BuildToolsList()
{
	local string tools;

	tools = tool("query_game_info",
			"Return current game and server info: gametype, map, player counts, score and time limits.",
			emptySchema());
	tools = tools $ "," $ tool("list_players",
			"List connected players with score, deaths, ping, team, and bot/spectator flags.",
			emptySchema());
	tools = tools $ "," $ tool("say",
			"Broadcast a text message to all players on the server.",
			oneStrSchema("message", "The text to broadcast to all players."));
	tools = tools $ "," $ tool("switch_map",
			"Switch the server to a different map (all players travel). Accepts a map name or a full travel URL.",
			oneStrSchema("map", "Map name (e.g. DM-Deck) or a full travel URL."));
	tools = tools $ "," $ tool("kick",
			"Kick a connected player by exact (case-insensitive) player name.",
			oneStrSchema("player", "Exact name of the player to kick."));
	tools = tools $ "," $ tool("player_input",
			"Simulate a key input for a specific player by running the bound input command on their controller. The command is what a key is bound to, e.g. Jump, Fire, AltFire, NextWeapon, PrevWeapon, Use, Suicide, ThrowWeapon, Taunt ThumbsUp.",
			twoStrSchema("player", "Exact name of the target human player.",
				"command", "Input/console command to run as that player (e.g. Jump, Fire, AltFire)."));
	tools = tools $ "," $ tool("screenshot",
			"Capture a screenshot from a human player's viewpoint. Writes a ShotNNNNN.bmp into the server's ScreenShots/ folder (read the newest file there). Only works for real players, not bots.",
			oneStrSchema("player", "Exact name of the human player whose view to capture."));
	tools = tools $ "," $ tool("add_bot",
			"Add AI bots to the current match.",
			optIntSchema("count", "How many bots to add (default 1)."));
	tools = tools $ "," $ tool("remove_bots",
			"Remove AI bots from the current match.",
			optIntSchema("count", "How many bots to remove; 0 or omitted removes all bots."));
	tools = tools $ "," $ tool("gui_click",
			"Click a button in a player's currently-open menu, by button caption (case-insensitive substring). Runs client-side. Fire-and-forget: use screenshot to verify the result.",
			twoStrSchema("player", "Exact name of the player whose menu to click in.",
				"caption", "Caption (or part of it) of the button to click, e.g. Crosshairs, Ready."));
	tools = tools $ "," $ tool("gui_select",
			"Choose a value in a dropdown/combo box in a player's open menu. Targets the index-th combo that contains the value (combos are matched by their items, not a caption). Runs client-side; screenshot to verify.",
			selectSchema());
	tools = tools $ "," $ tool("gui_dropdown",
			"Open (expand) a dropdown's list so it is visible, e.g. for a screenshot. Targets the index-th combo that contains 'value', same as gui_select. Runs client-side.",
			selectSchema());

	return "{" $ jRaw("tools", "[" $ tools $ "]") $ "}";
}

/** Assemble one tool entry for tools/list. */
final function string tool(string name, string desc, string schema)
{
	return "{" $ jStr("name", name) $ "," $ jStr("description", desc) $ ","
		$ jRaw("inputSchema", schema) $ "}";
}

/** inputSchema for a tool that takes no arguments. */
final function string emptySchema()
{
	return "{" $ jStr("type", "object") $ "," $ jRaw("properties", "{}") $ ","
		$ jRaw("additionalProperties", "false") $ "}";
}

/** inputSchema for a tool with a single required string argument. */
final function string oneStrSchema(string prop, string desc)
{
	local string props;
	props = "{" $ jRaw(prop, "{" $ jStr("type", "string") $ "," $ jStr("description", desc) $ "}") $ "}";
	return "{" $ jStr("type", "object") $ "," $ jRaw("properties", props) $ ","
		$ jRaw("required", "[" $ Chr(34) $ prop $ Chr(34) $ "]") $ ","
		$ jRaw("additionalProperties", "false") $ "}";
}

/** One JSON property entry: "name":{"type":"string","description":"desc"} */
final function string strPropDef(string prop, string desc)
{
	return jRaw(prop, "{" $ jStr("type", "string") $ "," $ jStr("description", desc) $ "}");
}

/** inputSchema for gui_select: required player + value, optional index. */
final function string selectSchema()
{
	local string props, req;
	props = "{" $ strPropDef("player", "Exact name of the player whose menu to use.") $ ","
		$ strPropDef("value", "The option text (or part of it) to select, e.g. Epic Style.") $ ","
		$ jRaw("index", "{" $ jStr("type", "integer") $ ","
			$ jStr("description", "Which matching combo to use when several contain the value (0 = first, default).") $ "}")
		$ "}";
	req = "[" $ Chr(34) $ "player" $ Chr(34) $ "," $ Chr(34) $ "value" $ Chr(34) $ "]";
	return "{" $ jStr("type", "object") $ "," $ jRaw("properties", props) $ ","
		$ jRaw("required", req) $ "," $ jRaw("additionalProperties", "false") $ "}";
}

/** inputSchema for a tool with a single optional integer argument. */
final function string optIntSchema(string prop, string desc)
{
	local string props;
	props = "{" $ jRaw(prop, "{" $ jStr("type", "integer") $ "," $ jStr("description", desc) $ "}") $ "}";
	return "{" $ jStr("type", "object") $ "," $ jRaw("properties", props) $ ","
		$ jRaw("additionalProperties", "false") $ "}";
}

/** inputSchema for a tool with two required string arguments. */
final function string twoStrSchema(string p1, string d1, string p2, string d2)
{
	local string props, req;
	props = "{" $ strPropDef(p1, d1) $ "," $ strPropDef(p2, d2) $ "}";
	req = "[" $ Chr(34) $ p1 $ Chr(34) $ "," $ Chr(34) $ p2 $ Chr(34) $ "]";
	return "{" $ jStr("type", "object") $ "," $ jRaw("properties", props) $ ","
		$ jRaw("required", req) $ "," $ jRaw("additionalProperties", "false") $ "}";
}

function string CallTool(string name, string body)
{
	local string text, item;

	bToolError = false;
	if (name ~= "query_game_info")
		text = BuildGameInfoJson();
	else if (name ~= "list_players")
		text = BuildPlayerListJson();
	else if (name ~= "say")
		text = DoSay(class'MCPJson'.static.GetStringVal(body, "message"));
	else if (name ~= "switch_map")
		text = DoSwitchMap(class'MCPJson'.static.GetStringVal(body, "map"));
	else if (name ~= "kick")
		text = DoKick(class'MCPJson'.static.GetStringVal(body, "player"));
	else if (name ~= "player_input")
		text = DoPlayerInput(class'MCPJson'.static.GetStringVal(body, "player"),
				class'MCPJson'.static.GetStringVal(body, "command"));
	else if (name ~= "screenshot")
		text = DoScreenshot(class'MCPJson'.static.GetStringVal(body, "player"));
	else if (name ~= "add_bot")
		text = DoAddBot(int(class'MCPJson'.static.GetRaw(body, "count")));
	else if (name ~= "remove_bots")
		text = DoRemoveBots(int(class'MCPJson'.static.GetRaw(body, "count")));
	else if (name ~= "gui_click")
		text = DoGuiClick(class'MCPJson'.static.GetStringVal(body, "player"),
				class'MCPJson'.static.GetStringVal(body, "caption"));
	else if (name ~= "gui_select")
		text = DoGuiSelect(class'MCPJson'.static.GetStringVal(body, "player"),
				class'MCPJson'.static.GetStringVal(body, "value"),
				int(class'MCPJson'.static.GetRaw(body, "index")));
	else if (name ~= "gui_dropdown")
		text = DoGuiDropdown(class'MCPJson'.static.GetStringVal(body, "player"),
				class'MCPJson'.static.GetStringVal(body, "value"),
				int(class'MCPJson'.static.GetRaw(body, "index")));
	else
	{
		text = "Unknown tool: " $ name;
		bToolError = true;
	}

	item = "{" $ jStr("type", "text") $ "," $ jStr("text", text) $ "}";
	return "{" $ jRaw("content", "[" $ item $ "]") $ "," $ jBool("isError", bToolError) $ "}";
}

// -----------------------------------------------------------------------------
// Tools (write / actions)
// -----------------------------------------------------------------------------

function string DoSay(string msg)
{
	if (msg == "")
	{
		bToolError = true;
		return "error: 'message' argument is required";
	}
	if (Level.Game == None)
	{
		bToolError = true;
		return "error: no active game";
	}
	Level.Game.Broadcast(Level.Game, msg);
	return "Broadcast sent to all players: " $ msg;
}

function string DoSwitchMap(string map)
{
	if (map == "")
	{
		bToolError = true;
		return "error: 'map' argument is required";
	}
	if (Level.Game == None)
	{
		bToolError = true;
		return "error: no active game";
	}
	Level.Game.ProcessServerTravel(map, false);
	return "Traveling to: " $ map;
}

function string DoKick(string playerName)
{
	local GameReplicationInfo GRI;
	local int i;
	local bool found;

	if (playerName == "")
	{
		bToolError = true;
		return "error: 'player' argument is required";
	}
	if (Level.Game == None)
	{
		bToolError = true;
		return "error: no active game";
	}

	// Confirm the player exists so we can report a useful result.
	GRI = Level.Game.GameReplicationInfo;
	found = false;
	if (GRI != None)
	{
		for (i = 0; i < GRI.PRIArray.Length; i++)
		{
			if (GRI.PRIArray[i] != None && GRI.PRIArray[i].PlayerName ~= playerName)
			{
				found = true;
				break;
			}
		}
	}
	if (!found)
	{
		bToolError = true;
		return "error: no connected player named '" $ playerName $ "'";
	}

	Level.Game.Kick(playerName);
	return "Kicked player: " $ playerName;
}

function string DoPlayerInput(string playerName, string command)
{
	local PlayerController PC;
	local string result;

	if (playerName == "")
	{
		bToolError = true;
		return "error: 'player' argument is required";
	}
	if (command == "")
	{
		bToolError = true;
		return "error: 'command' argument is required";
	}
	if (Level.Game == None)
	{
		bToolError = true;
		return "error: no active game";
	}

	PC = FindPlayer(playerName);
	if (PC == None)
	{
		bToolError = true;
		return "error: no connected human player named '" $ playerName $ "'";
	}

	// A keybind is just a command run on the controller; do the same here.
	result = PC.ConsoleCommand(command);
	if (result != "")
		return "Ran input '" $ command $ "' for " $ playerName $ "; result: " $ result;
	return "Ran input '" $ command $ "' for " $ playerName;
}

/** Find a connected human player's controller by exact (case-insensitive) name. */
function PlayerController FindPlayer(string playerName)
{
	local Controller C, NextC;

	for (C = Level.ControllerList; C != None; C = NextC)
	{
		NextC = C.NextController;
		if (C.PlayerReplicationInfo != None
			&& C.PlayerReplicationInfo.PlayerName ~= playerName
			&& PlayerController(C) != None)
			return PlayerController(C);
	}
	return None;
}

function string DoScreenshot(string playerName)
{
	local PlayerController PC;

	if (playerName == "")
	{
		bToolError = true;
		return "error: 'player' argument is required";
	}
	if (Level.Game == None)
	{
		bToolError = true;
		return "error: no active game";
	}

	PC = FindPlayer(playerName);
	if (PC == None)
	{
		bToolError = true;
		return "error: no connected human player named '" $ playerName $ "' (screenshots require a real player, not a bot)";
	}

	PC.ConsoleCommand("shot");
	return "Screenshot captured for " $ playerName $ "; saved as the newest ShotNNNNN.bmp in the server's ScreenShots/ folder.";
}

function string DoAddBot(int count)
{
	local DeathMatch DM;

	if (Level.Game == None)
	{
		bToolError = true;
		return "error: no active game";
	}
	DM = DeathMatch(Level.Game);
	if (DM == None)
	{
		bToolError = true;
		return "error: current gametype does not support bots";
	}

	if (count <= 0)
		count = 1;
	DM.AddBots(count);
	return "Requested " $ count $ " bot(s). Now " $ Level.Game.NumBots $ " bot(s) in game.";
}

function string DoRemoveBots(int count)
{
	local DeathMatch DM;

	if (Level.Game == None)
	{
		bToolError = true;
		return "error: no active game";
	}
	DM = DeathMatch(Level.Game);
	if (DM == None)
	{
		bToolError = true;
		return "error: current gametype does not support bots";
	}

	if (count < 0)
		count = 0;
	DM.KillBots(count); // 0 removes all bots
	return "Removed bots (requested " $ count $ ", 0=all).";
}

function string DoGuiClick(string playerName, string caption)
{
	local PlayerController PC;
	local LinkedReplicationInfo lRI;
	local MCPPlayerLink Link;

	if (playerName == "" || caption == "")
	{
		bToolError = true;
		return "error: 'player' and 'caption' arguments are required";
	}
	if (Level.Game == None)
	{
		bToolError = true;
		return "error: no active game";
	}

	PC = FindPlayer(playerName);
	if (PC == None)
	{
		bToolError = true;
		return "error: no connected human player named '" $ playerName $ "'";
	}
	if (PC.PlayerReplicationInfo == None)
	{
		bToolError = true;
		return "error: player has no replication info yet";
	}

	// Walk the player's CustomReplicationInfo chain for our link.
	for (lRI = PC.PlayerReplicationInfo.CustomReplicationInfo; lRI != None; lRI = lRI.NextReplicationInfo)
	{
		Link = MCPPlayerLink(lRI);
		if (Link != None)
			break;
	}
	if (Link == None)
	{
		bToolError = true;
		return "error: no GUI link attached to player yet (may still be initializing)";
	}

	Link.ClientGuiClick(caption);
	return "Sent GUI click '" $ caption $ "' to " $ playerName $ " (client-side; take a screenshot to verify).";
}

function string DoGuiSelect(string playerName, string value, int index)
{
	local PlayerController PC;
	local LinkedReplicationInfo lRI;
	local MCPPlayerLink Link;

	if (playerName == "" || value == "")
	{
		bToolError = true;
		return "error: 'player' and 'value' arguments are required";
	}
	if (Level.Game == None)
	{
		bToolError = true;
		return "error: no active game";
	}

	PC = FindPlayer(playerName);
	if (PC == None)
	{
		bToolError = true;
		return "error: no connected human player named '" $ playerName $ "'";
	}
	if (PC.PlayerReplicationInfo == None)
	{
		bToolError = true;
		return "error: player has no replication info yet";
	}

	for (lRI = PC.PlayerReplicationInfo.CustomReplicationInfo; lRI != None; lRI = lRI.NextReplicationInfo)
	{
		Link = MCPPlayerLink(lRI);
		if (Link != None)
			break;
	}
	if (Link == None)
	{
		bToolError = true;
		return "error: no GUI link attached to player yet (may still be initializing)";
	}

	if (index < 0)
		index = 0;
	Link.ClientGuiSelect(value, index);
	return "Sent GUI select value='" $ value $ "' (combo #" $ index $ ") to " $ playerName $ " (client-side; take a screenshot to verify).";
}

function string DoGuiDropdown(string playerName, string value, int index)
{
	local PlayerController PC;
	local LinkedReplicationInfo lRI;
	local MCPPlayerLink Link;

	if (playerName == "" || value == "")
	{
		bToolError = true;
		return "error: 'player' and 'value' arguments are required";
	}
	if (Level.Game == None)
	{
		bToolError = true;
		return "error: no active game";
	}

	PC = FindPlayer(playerName);
	if (PC == None)
	{
		bToolError = true;
		return "error: no connected human player named '" $ playerName $ "'";
	}
	if (PC.PlayerReplicationInfo == None)
	{
		bToolError = true;
		return "error: player has no replication info yet";
	}

	for (lRI = PC.PlayerReplicationInfo.CustomReplicationInfo; lRI != None; lRI = lRI.NextReplicationInfo)
	{
		Link = MCPPlayerLink(lRI);
		if (Link != None)
			break;
	}
	if (Link == None)
	{
		bToolError = true;
		return "error: no GUI link attached to player yet (may still be initializing)";
	}

	if (index < 0)
		index = 0;
	Link.ClientGuiDropdown(value, index);
	return "Opened dropdown containing '" $ value $ "' (combo #" $ index $ ") for " $ playerName $ " (client-side; take a screenshot to verify).";
}

// -----------------------------------------------------------------------------
// Tools (read-only game queries)
// -----------------------------------------------------------------------------

function string BuildGameInfoJson()
{
	local GameInfo G;
	local GameReplicationInfo GRI;
	local string map, serverName;
	local int q, goalScore, timeLimit, remainingTime, elapsedTime;

	G = Level.Game;
	if (G == None)
		return "{}";
	GRI = G.GameReplicationInfo;

	// GRI is effectively always set on a running server, but guard anyway.
	if (GRI != None)
	{
		serverName = GRI.ServerName;
		goalScore = GRI.GoalScore;
		timeLimit = GRI.TimeLimit;
		remainingTime = GRI.RemainingTime;
		elapsedTime = GRI.ElapsedTime;
	}

	map = Level.GetLocalURL();
	q = InStr(map, "?");
	if (q != -1)
		map = Left(map, q);
	// GetLocalURL prefixes "host/" (e.g. "0.0.0.0/DM-Goliath"); keep only the map.
	q = InStr(map, "/");
	while (q != -1)
	{
		map = Mid(map, q + 1);
		q = InStr(map, "/");
	}

	return "{"
		$ jStr("serverName", serverName) $ ","
		$ jStr("gameType", string(G.Class)) $ ","
		$ jStr("gameName", G.GameName) $ ","
		$ jStr("map", map) $ ","
		$ jStr("mapTitle", Level.Title) $ ","
		$ jNum("numPlayers", G.NumPlayers) $ ","
		$ jNum("numBots", G.NumBots) $ ","
		$ jNum("maxPlayers", G.MaxPlayers) $ ","
		$ jNum("goalScore", goalScore) $ ","
		$ jNum("timeLimit", timeLimit) $ ","
		$ jNum("remainingTime", remainingTime) $ ","
		$ jNum("elapsedTime", elapsedTime)
		$ "}";
}

function string BuildPlayerListJson()
{
	local GameInfo G;
	local GameReplicationInfo GRI;
	local PlayerReplicationInfo PRI;
	local int i;
	local string arr, obj, team;

	G = Level.Game;
	if (G == None)
		return "{}";
	GRI = G.GameReplicationInfo;
	if (GRI == None)
		return "{" $ jNum("count", 0) $ "," $ jRaw("players", "[]") $ "}";

	arr = "";
	for (i = 0; i < GRI.PRIArray.Length; i++)
	{
		PRI = GRI.PRIArray[i];
		if (PRI == None)
			continue;

		team = "";
		if (PRI.Team != None)
			team = PRI.Team.TeamName;

		obj = "{"
			$ jStr("name", PRI.PlayerName) $ ","
			$ jNum("score", int(PRI.Score)) $ ","
			$ jNum("deaths", int(PRI.Deaths)) $ ","
			$ jNum("ping", PRI.Ping * 4) $ ","
			$ jStr("team", team) $ ","
			$ jBool("bot", PRI.bBot) $ ","
			$ jBool("spectator", PRI.bIsSpectator)
			$ "}";

		if (arr != "")
			arr $= ",";
		arr $= obj;
	}

	return "{" $ jNum("count", GRI.PRIArray.Length) $ "," $ jRaw("players", "[" $ arr $ "]") $ "}";
}

// -----------------------------------------------------------------------------
// HTTP response writing
// -----------------------------------------------------------------------------

function SendResponse(int code, string reason, string contentType, string body)
{
	local string resp, crlf;

	crlf = Chr(13) $ Chr(10);
	resp = "HTTP/1.1 " $ code $ " " $ reason $ crlf;
	if (contentType != "")
		resp $= "Content-Type: " $ contentType $ crlf;
	resp $= "Content-Length: " $ Len(body) $ crlf;
	resp $= "Connection: close" $ crlf;
	resp $= "Access-Control-Allow-Origin: *" $ crlf;
	resp $= crlf;
	resp $= body;

	outBuf = resp;
	bResponding = true;
	DrainSend();
}

function DrainSend()
{
	local int sent, chunk;

	while (Len(outBuf) > 0)
	{
		if (!IsConnected())
			return;
		chunk = Len(outBuf);
		if (chunk > 512)
			chunk = 512;
		sent = SendText(Left(outBuf, chunk));
		if (sent <= 0)
			return; // send buffer full; retry on next Tick
		outBuf = Mid(outBuf, sent);
	}

	bResponding = false;
	Close();
}

// -----------------------------------------------------------------------------
// Small JSON helpers (thin wrappers over MCPJson for readability)
// -----------------------------------------------------------------------------

final function string jStr(string k, coerce string v) { return class'MCPJson'.static.Str(k, v); }
final function string jNum(string k, coerce string v)  { return class'MCPJson'.static.Num(k, v); }
final function string jRaw(string k, string v)         { return class'MCPJson'.static.Raw(k, v); }
final function string jBool(string k, bool b)          { return class'MCPJson'.static.Bool(k, b); }

defaultproperties
{
	LinkMode=MODE_Text
	ReceiveMode=RMODE_Event
}
