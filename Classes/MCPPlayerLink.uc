/*******************************************************************************
	MCPPlayerLink

	A per-player LinkedReplicationInfo owned by the player's controller. The
	server calls client-replicated functions on it (reliable, owning client) to
	run code on that player's CLIENT, where the GUI lives. This works both for
	remote clients and for the listen-server host: inside the client function
	Level.GetLocalPlayerController() returns the correct local controller, and
	on a listen server the call simply executes locally.

	The MutMCP mutator spawns/tracks one of these per human player.
*******************************************************************************/

class MCPPlayerLink extends LinkedReplicationInfo;

replication
{
	// server -> owning client
	reliable if (Role == ROLE_Authority && bNetOwner)
		ClientGuiClick, ClientGuiSelect, ClientGuiDropdown;
}

/**
	Runs on the owning client: find a button on the currently open menu whose
	caption contains `caption` (case-insensitive), move the cursor over it, and
	fire its OnClick handler (what a real mouse click does).
*/
simulated function ClientGuiClick(string caption)
{
	local PlayerController PC;
	local GUIController GC;
	local GUIButton Btn;

	PC = Level.GetLocalPlayerController();
	if (PC == None || PC.Player == None)
		return;

	GC = GUIController(PC.Player.GUIController);
	if (GC == None || GC.ActivePage == None)
		return;

	Btn = FindButton(GC.ActivePage, caption);
	if (Btn == None)
		return;

	// Place the cursor over the button (nice for screenshots) then click.
	GC.MouseX = Btn.ActualLeft() + Btn.ActualWidth() / 2;
	GC.MouseY = Btn.ActualTop() + Btn.ActualHeight() / 2;
	Btn.OnClick(Btn);
}

/**
	Runs on the owning client: pick a value in a dropdown/combo box. Combos have
	no captions here, so we target the `index`-th combo (in tree order) that
	contains an item matching `value`, set it, and fire OnChange to apply it.
*/
simulated function ClientGuiSelect(string value, int index)
{
	local PlayerController PC;
	local GUIController GC;
	local array<GUIComboBox> combos;
	local GUIComboBox cb;
	local int idx;

	PC = Level.GetLocalPlayerController();
	if (PC == None || PC.Player == None)
		return;

	GC = GUIController(PC.Player.GUIController);
	if (GC == None || GC.ActivePage == None)
		return;

	CollectCombos(GC.ActivePage, value, combos);
	if (index < 0)
		index = 0;
	if (index >= combos.Length)
		return;

	cb = combos[index];
	idx = cb.FindIndex(value, false);
	if (idx < 0)
		idx = cb.FindIndex(value, true);
	if (idx < 0)
		return;

	cb.SetIndex(idx);
	cb.OnChange(cb); // apply (same handler a real selection fires)
}

/**
	Runs on the owning client: open (expand) a dropdown's list so it shows in a
	screenshot. Targets the `index`-th combo containing `value`, like gui_select.
*/
simulated function ClientGuiDropdown(string value, int index)
{
	local PlayerController PC;
	local GUIController GC;
	local array<GUIComboBox> combos;
	local GUIComboBox cb;

	PC = Level.GetLocalPlayerController();
	if (PC == None || PC.Player == None)
		return;

	GC = GUIController(PC.Player.GUIController);
	if (GC == None || GC.ActivePage == None)
		return;

	CollectCombos(GC.ActivePage, value, combos);
	if (index < 0)
		index = 0;
	if (index >= combos.Length)
		return;

	cb = combos[index];
	// The show-list button's OnClick toggles the dropdown list open.
	if (cb.MyShowListBtn != None)
		cb.MyShowListBtn.OnClick(cb.MyShowListBtn);
}

/** Collect combos that contain an item matching `value` (combos are terminal). */
simulated function CollectCombos(GUIComponent Comp, string value, out array<GUIComboBox> combos)
{
	local int i;
	local GUIComboBox cb;
	local GUIMultiComponent MC;

	cb = GUIComboBox(Comp);
	if (cb != None)
	{
		if (cb.FindIndex(value, false) >= 0)
			combos[combos.Length] = cb;
		return; // do not descend into a combo's internal list
	}

	MC = GUIMultiComponent(Comp);
	if (MC != None)
		for (i = 0; i < MC.Controls.Length; i++)
			if (MC.Controls[i] != None)
				CollectCombos(MC.Controls[i], value, combos);
}

/** Depth-first search of the component tree for a GUIButton by caption substring. */
simulated function GUIButton FindButton(GUIComponent Comp, string caption)
{
	local int i;
	local GUIButton Btn, Found;
	local GUIMultiComponent MC;

	Btn = GUIButton(Comp);
	if (Btn != None && Btn.Caption != "" && InStr(Caps(Btn.Caption), Caps(caption)) != -1)
		return Btn;

	MC = GUIMultiComponent(Comp);
	if (MC != None)
	{
		for (i = 0; i < MC.Controls.Length; i++)
		{
			if (MC.Controls[i] == None)
				continue;
			Found = FindButton(MC.Controls[i], caption);
			if (Found != None)
				return Found;
		}
	}
	return None;
}

defaultproperties
{
	NetUpdateFrequency=100.000000
}
