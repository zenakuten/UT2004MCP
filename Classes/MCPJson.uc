/*******************************************************************************
	MCPJson

	Static string helpers for building JSON responses and extracting a few
	fields from incoming JSON-RPC requests.

	Phase 1 intentionally avoids a full recursive JSON parser: the tools we
	expose take no arguments, so we only need to pull "method", "id" and (for
	tools/call) the "name" out of the request envelope. A proper parser can
	replace GetString/GetRaw in phase 2 when tools gain typed arguments.
*******************************************************************************/

class MCPJson extends Object;

/** Escape a string for inclusion inside a JSON string literal. */
static final function string Esc(coerce string s)
{
	// NOTE: no backslashes or quote chars in these comments -- UCC's comment
	// lexer mishandles backslash-escape sequences and hangs (see CLAUDE.md).
	s = Repl(s, Chr(92), Chr(92) $ Chr(92)); // escape backslash (must be first)
	s = Repl(s, Chr(34), Chr(92) $ Chr(34)); // escape double-quote
	s = Repl(s, Chr(13), Chr(92) $ "r");     // carriage-return -> backslash r
	s = Repl(s, Chr(10), Chr(92) $ "n");     // line-feed -> backslash n
	s = Repl(s, Chr(9),  Chr(92) $ "t");     // tab -> backslash t
	return s;
}

/** "key":"escaped value" */
static final function string Str(string key, coerce string val)
{
	return Chr(34) $ key $ Chr(34) $ ":" $ Chr(34) $ Esc(val) $ Chr(34);
}

/** "key":val   (val is emitted verbatim; use for numbers) */
static final function string Num(string key, coerce string val)
{
	return Chr(34) $ key $ Chr(34) $ ":" $ val;
}

/** "key":rawJson   (rawJson is emitted verbatim; use for objects/arrays) */
static final function string Raw(string key, string rawJson)
{
	return Chr(34) $ key $ Chr(34) $ ":" $ rawJson;
}

/** "key":true|false */
static final function string Bool(string key, bool b)
{
	if (b)
		return Chr(34) $ key $ Chr(34) $ ":true";
	return Chr(34) $ key $ Chr(34) $ ":false";
}

/**
	Return the (unquoted) string value of the first occurrence of "key" in json.
	Returns "" if the key is missing or its value is not a string.
*/
static final function string GetString(string json, string key)
{
	local int j;
	local string sub;

	sub = ValueAfterKey(json, key);
	if (sub == "")
		return "";
	if (Left(sub, 1) != Chr(34))
		return "";
	sub = Mid(sub, 1);
	j = InStr(sub, Chr(34));
	if (j == -1)
		return "";
	return Left(sub, j);
}

/**
	Return the raw JSON token of the first occurrence of "key" (verbatim, so it
	can be echoed straight back). Handles quoted strings and bare numbers.
	Returns "" if the key is missing.
*/
static final function string GetRaw(string json, string key)
{
	local int j, c, b;
	local string sub;

	sub = ValueAfterKey(json, key);
	if (sub == "")
		return "";

	if (Left(sub, 1) == Chr(34))
	{
		sub = Mid(sub, 1);
		j = InStr(sub, Chr(34));
		if (j == -1)
			return "";
		return Chr(34) $ Left(sub, j) $ Chr(34);
	}

	// bare literal: read until ',' or '}'
	c = InStr(sub, ",");
	b = InStr(sub, "}");
	if (c == -1)
		c = Len(sub);
	if (b == -1)
		b = Len(sub);
	j = c;
	if (b < j)
		j = b;
	sub = Left(sub, j);
	while (Right(sub, 1) == " ")
		sub = Left(sub, Len(sub) - 1);
	return sub;
}

/**
	Return the string value of "key", correctly reading a JSON string literal that
	may contain escape sequences, and unescaping the result. Use this for tool
	arguments (values may contain quotes, etc.). Returns "" if key is missing or
	its value is not a string.
*/
static final function string GetStringVal(string json, string key)
{
	local string sub, raw, ch;
	local int i, n;

	sub = ValueAfterKey(json, key);
	if (Left(sub, 1) != Chr(34))
		return "";
	sub = Mid(sub, 1);
	n = Len(sub);
	raw = "";
	i = 0;
	while (i < n)
	{
		ch = Mid(sub, i, 1);
		if (ch == Chr(92))
		{
			// keep the escape pair intact; Unescape resolves it below
			raw = raw $ ch $ Mid(sub, i + 1, 1);
			i += 2;
			continue;
		}
		if (ch == Chr(34))
			break; // closing quote
		raw = raw $ ch;
		i++;
	}
	return Unescape(raw);
}

/** Reverse of Esc: turn JSON escape sequences back into raw characters. */
static final function string Unescape(string s)
{
	s = Repl(s, Chr(92) $ "n", Chr(10));
	s = Repl(s, Chr(92) $ "r", Chr(13));
	s = Repl(s, Chr(92) $ "t", Chr(9));
	s = Repl(s, Chr(92) $ Chr(34), Chr(34));
	s = Repl(s, Chr(92) $ "/", "/");
	s = Repl(s, Chr(92) $ Chr(92), Chr(92)); // must be last
	return s;
}

/** Return everything after `"key":` (leading spaces trimmed), or "" if absent. */
static final function string ValueAfterKey(string json, string key)
{
	local int i, j;
	local string sub;

	i = InStr(json, Chr(34) $ key $ Chr(34));
	if (i == -1)
		return "";
	sub = Mid(json, i + Len(key) + 2);
	j = InStr(sub, ":");
	if (j == -1)
		return "";
	sub = Mid(sub, j + 1);
	while (Left(sub, 1) == " ")
		sub = Mid(sub, 1);
	return sub;
}

defaultproperties
{
}
