/*
 * unrealed-log.exe -- print the text of UnrealEd's log window.
 *
 * Companion to unrealed-send.exe. It exists because System/UnrealEd.log on disk
 * lags the log WINDOW by an unbounded amount: a command can be visibly finished
 * in the window with nothing written to the file yet, so an agent that polls the
 * file cannot tell a slow command from a lost one. The window's control holds the
 * text the editor has actually emitted, so reading it is the real-time view.
 *
 * The log window is a top-level window of UnrealEd.exe with class
 * UnrealEdUnrealWLog; the scrolling text is its UnrealEdUnrealWEditTerminal
 * child. Both are Epic's own subclasses of the standard Edit control, so
 * WM_GETTEXTLENGTH/WM_GETTEXT work across processes.
 *
 * With -tail N, only the last N lines are printed.
 */
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <wchar.h>

typedef struct
{
	HWND terminal;
} SearchResult;

static BOOL get_process_path(HWND window, WCHAR *path, DWORD capacity)
{
	DWORD process_id;
	HANDLE process;
	DWORD path_length;

	GetWindowThreadProcessId(window, &process_id);
	process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, process_id);
	if (process == NULL)
		return FALSE;

	path_length = capacity;
	if (!QueryFullProcessImageNameW(process, 0, path, &path_length))
	{
		CloseHandle(process);
		return FALSE;
	}
	CloseHandle(process);
	return TRUE;
}

static BOOL process_is_unrealed(HWND window)
{
	WCHAR path[MAX_PATH];
	const WCHAR *base_name;

	if (!get_process_path(window, path, MAX_PATH))
		return FALSE;

	base_name = wcsrchr(path, L'\\');
	base_name = (base_name == NULL) ? path : base_name + 1;
	return _wcsicmp(base_name, L"UnrealEd.exe") == 0;
}

static BOOL CALLBACK find_terminal(HWND window, LPARAM parameter)
{
	SearchResult *result;
	WCHAR class_name[128];

	result = (SearchResult *)parameter;
	if (!GetClassNameW(window, class_name, 128))
		return TRUE;
	if (wcsstr(class_name, L"WEditTerminal") == NULL)
		return TRUE;

	result->terminal = window;
	return FALSE;
}

static BOOL CALLBACK find_log_window(HWND window, LPARAM parameter)
{
	SearchResult *result;
	WCHAR class_name[128];

	result = (SearchResult *)parameter;
	if (!GetClassNameW(window, class_name, 128))
		return TRUE;
	if (wcsstr(class_name, L"WLog") == NULL)
		return TRUE;
	if (!process_is_unrealed(window))
		return TRUE;

	EnumChildWindows(window, find_terminal, parameter);
	return result->terminal == NULL;
}

int wmain(int argc, WCHAR **argv)
{
	SearchResult result;
	LRESULT length;
	WCHAR *text;
	long tail_lines = 0;

	if (argc >= 3 && _wcsicmp(argv[1], L"-tail") == 0)
		tail_lines = wcstol(argv[2], NULL, 10);

	result.terminal = NULL;
	EnumWindows(find_log_window, (LPARAM)&result);
	if (result.terminal == NULL)
	{
		fwprintf(
			stderr,
			L"Could not find UnrealEd's log window. Start the editor with "
			L"-log, or open View > Log.\n"
		);
		return 3;
	}

	length = SendMessageW(result.terminal, WM_GETTEXTLENGTH, 0, 0);
	if (length <= 0)
	{
		fwprintf(stderr, L"The log window holds no text.\n");
		return 4;
	}

	text = (WCHAR *)calloc((size_t)length + 1, sizeof(WCHAR));
	if (text == NULL)
	{
		fwprintf(stderr, L"Out of memory for %ld characters.\n", (long)length);
		return 5;
	}
	SendMessageW(result.terminal, WM_GETTEXT, (WPARAM)(length + 1), (LPARAM)text);

	if (tail_lines > 0)
	{
		/* Walk back from the end over `tail_lines` newlines. */
		WCHAR *cursor = text + wcslen(text);
		long seen = 0;
		while (cursor > text)
		{
			cursor--;
			if (*cursor == L'\n' && ++seen > tail_lines)
			{
				cursor++;
				break;
			}
		}
		fputws(cursor, stdout);
	}
	else
	{
		fputws(text, stdout);
	}

	free(text);
	return 0;
}
