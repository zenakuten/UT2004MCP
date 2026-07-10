/*******************************************************************************
	MutMCP

	Mutator entry point for the MCP (Model Context Protocol) agent server.
	When loaded on a server it spawns an MCPServer which listens on its own TCP
	port (default 6900, configurable) for JSON-RPC requests from AI agents.

	The listen port is a plain TCP socket, completely separate from the game
	port -- agents do NOT join as players; nothing enters the game's player or
	replication systems.
*******************************************************************************/

class MutMCP extends Mutator
	config(MCP);

var config int ListenPort;
var MCPServer Server;

function PostBeginPlay()
{
	Super.PostBeginPlay();

	// Server-side only.
	if (Level.NetMode == NM_Client)
		return;

	if (ListenPort <= 0)
		ListenPort = 6900;

	Server = Spawn(class'MCPServer', self);
	if (Server != None)
		Server.BeginListen(ListenPort);
	else
		log("MCP: failed to spawn MCPServer", 'MCP');
}

// Attach a client-side GUI link to each human player by appending an
// MCPPlayerLink to the player's CustomReplicationInfo chain (standard pattern).
// The chain is torn down by the PlayerController's Destroyed(), so no manual
// unlink is needed.
function bool CheckReplacement(Actor Other, out byte bSuperRelevant)
{
	local PlayerReplicationInfo PRI;
	local LinkedReplicationInfo lRI;

	bSuperRelevant = 0;

	PRI = PlayerReplicationInfo(Other);
	if (PRI != None && PlayerController(PRI.Owner) != None)
	{
		if (PRI.CustomReplicationInfo == None)
			PRI.CustomReplicationInfo = Spawn(class'MCPPlayerLink', PRI.Owner);
		else
		{
			lRI = PRI.CustomReplicationInfo;
			while (lRI.NextReplicationInfo != None)
				lRI = lRI.NextReplicationInfo;
			lRI.NextReplicationInfo = Spawn(class'MCPPlayerLink', PRI.Owner);
		}
	}
	return true;
}

event Destroyed()
{
	if (Server != None)
	{
		Server.Shutdown();
		Server = None;
	}
	Super.Destroyed();
}

defaultproperties
{
	ListenPort=6900
	bAddToServerPackages=true
	FriendlyName="MCP Agent Server"
	Description="Runs an MCP (Model Context Protocol) server so AI agents can query and (later) control the game over a dedicated TCP port."
}
