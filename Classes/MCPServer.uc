/*******************************************************************************
	MCPServer

	A dedicated TCP listener (its own port, separate from the game port) that
	accepts HTTP connections carrying MCP (Model Context Protocol) JSON-RPC
	requests. Each accepted connection is handled by a spawned MCPConnection.

	This is the same listen/accept pattern used by UWeb.WebServer: BindPort +
	Listen, with AcceptClass spawning a child TcpLink per connection.
*******************************************************************************/

class MCPServer extends IpDrv.TcpLink;

var int ConnectionCount;

function BeginListen(int port)
{
	local int bound;

	bound = BindPort(port);
	if (bound == 0)
	{
		log("MCP: BindPort(" $ port $ ") failed -- port in use?", 'MCP');
		return;
	}

	if (!Listen())
	{
		log("MCP: Listen() failed on port " $ bound, 'MCP');
		return;
	}

	log("MCP: listening for agent connections on TCP port " $ bound, 'MCP');
}

event GainedChild(Actor C)
{
	Super.GainedChild(C);
	ConnectionCount++;
}

event LostChild(Actor C)
{
	Super.LostChild(C);
	ConnectionCount--;
}

function Shutdown()
{
	Close();
	Destroy();
}

defaultproperties
{
	AcceptClass=class'MCPConnection'
	LinkMode=MODE_Text
	ReceiveMode=RMODE_Event
}
