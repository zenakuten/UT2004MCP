#include <windows.h>
#include <stdio.h>
#include <wchar.h>

#define IDCB_LOG_COMMAND 19501

typedef struct
{
	HWND editor_window;
	HWND command_edit;
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
	if (base_name == NULL)
		base_name = path;
	else
		base_name++;

	return _wcsicmp(base_name, L"UnrealEd.exe") == 0;
}

static BOOL CALLBACK print_child_window(HWND window, LPARAM parameter)
{
	WCHAR title[256];
	WCHAR class_name[128];

	(void)parameter;
	GetWindowTextW(window, title, 256);
	GetClassNameW(window, class_name, 128);
	wprintf(
		L"  child hwnd=%p class=%ls title=%ls style=0x%lx\n",
		window,
		class_name,
		title,
		(unsigned long)GetWindowLongPtrW(window, GWL_STYLE)
	);
	return TRUE;
}

static BOOL CALLBACK print_top_window(HWND window, LPARAM parameter)
{
	DWORD process_id;
	WCHAR title[256];
	WCHAR class_name[128];
	WCHAR path[MAX_PATH];

	(void)parameter;
	GetWindowThreadProcessId(window, &process_id);
	GetWindowTextW(window, title, 256);
	GetClassNameW(window, class_name, 128);
	if (!get_process_path(window, path, MAX_PATH))
		wcscpy(path, L"<unavailable>");

	wprintf(
		L"hwnd=%p pid=%lu exe=%ls class=%ls title=%ls visible=%d\n",
		window,
		(unsigned long)process_id,
		path,
		class_name,
		title,
		IsWindowVisible(window)
	);
	EnumChildWindows(window, print_child_window, 0);
	return TRUE;
}

static BOOL CALLBACK find_command_edit(HWND window, LPARAM parameter)
{
	SearchResult *result;
	WCHAR class_name[64];
	HWND parent;

	result = (SearchResult *)parameter;
	if (!GetClassNameW(window, class_name, 64))
		return TRUE;
	if (_wcsicmp(class_name, L"Edit") != 0)
		return TRUE;

	parent = GetParent(window);
	if (parent == NULL || GetDlgCtrlID(parent) != IDCB_LOG_COMMAND)
		return TRUE;

	result->command_edit = window;
	return FALSE;
}

static BOOL CALLBACK find_editor_window(HWND window, LPARAM parameter)
{
	SearchResult *result;

	result = (SearchResult *)parameter;
	if (!process_is_unrealed(window))
		return TRUE;

	result->command_edit = NULL;
	EnumChildWindows(window, find_command_edit, parameter);
	if (result->command_edit == NULL)
		return TRUE;

	result->editor_window = window;
	return FALSE;
}

static int send_command(HWND editor_window, HWND command_edit, const WCHAR *command)
{
	DWORD editor_thread;
	DWORD helper_thread;
	INPUT *input;
	UINT input_count;
	UINT input_index;
	size_t character_index;
	UINT sent_count;

	editor_thread = GetWindowThreadProcessId(command_edit, NULL);
	helper_thread = GetCurrentThreadId();
	if (!AttachThreadInput(helper_thread, editor_thread, TRUE))
	{
		fwprintf(stderr, L"Could not attach to UnrealEd's input thread.\n");
		return 5;
	}

	ShowWindow(editor_window, SW_RESTORE);
	SetForegroundWindow(editor_window);
	SetFocus(command_edit);
	if (GetFocus() != command_edit)
	{
		AttachThreadInput(helper_thread, editor_thread, FALSE);
		fwprintf(stderr, L"Could not focus UnrealEd's Command control.\n");
		return 6;
	}
	Sleep(50);

	SendMessageW(command_edit, EM_SETSEL, 0, -1);
	input_count = 4 + (UINT)(wcslen(command) * 2);
	input = HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof(INPUT) * input_count);
	if (input == NULL)
	{
		AttachThreadInput(helper_thread, editor_thread, FALSE);
		fwprintf(stderr, L"Could not allocate keyboard input.\n");
		return 6;
	}

	input_index = 0;
	input[input_index].type = INPUT_KEYBOARD;
	input[input_index++].ki.wVk = VK_BACK;
	input[input_index].type = INPUT_KEYBOARD;
	input[input_index].ki.wVk = VK_BACK;
	input[input_index++].ki.dwFlags = KEYEVENTF_KEYUP;

	for (character_index = 0; command[character_index] != L'\0'; character_index++)
	{
		input[input_index].type = INPUT_KEYBOARD;
		input[input_index].ki.wScan = command[character_index];
		input[input_index++].ki.dwFlags = KEYEVENTF_UNICODE;
		input[input_index].type = INPUT_KEYBOARD;
		input[input_index].ki.wScan = command[character_index];
		input[input_index++].ki.dwFlags = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP;
	}

	input[input_index].type = INPUT_KEYBOARD;
	input[input_index++].ki.wVk = VK_RETURN;
	input[input_index].type = INPUT_KEYBOARD;
	input[input_index].ki.wVk = VK_RETURN;
	input[input_index++].ki.dwFlags = KEYEVENTF_KEYUP;

	sent_count = SendInput(input_count, input, sizeof(INPUT));
	HeapFree(GetProcessHeap(), 0, input);
	AttachThreadInput(helper_thread, editor_thread, FALSE);
	if (sent_count != input_count)
	{
		fwprintf(stderr, L"Could not send the command to UnrealEd.\n");
		return 7;
	}

	return 0;
}

int wmain(int argc, WCHAR **argv)
{
	SearchResult result;
	WCHAR command[1024];
	size_t required_length;
	int argument_index;

	if (argc < 2)
	{
		fwprintf(stderr, L"Usage: unrealed-send.exe <editor command>\n");
		return 2;
	}

	if (_wcsicmp(argv[1], L"--list") == 0)
	{
		EnumWindows(print_top_window, 0);
		return 0;
	}

	result.editor_window = NULL;
	result.command_edit = NULL;
	EnumWindows(find_editor_window, (LPARAM)&result);
	if (result.command_edit == NULL)
	{
		fwprintf(
			stderr,
			L"Could not find UnrealEd's bottom-bar Command control. Ensure "
			L"UnrealEd is running under the same Wine prefix.\n"
		);
		return 3;
	}

	command[0] = L'\0';
	for (argument_index = 1; argument_index < argc; argument_index++)
	{
		required_length = wcslen(command) + wcslen(argv[argument_index]);
		if (argument_index > 1)
			required_length++;
		if (required_length >= 1024)
		{
			fwprintf(stderr, L"Command is too long.\n");
			return 4;
		}
		if (argument_index > 1)
			wcscat(command, L" ");
		wcscat(command, argv[argument_index]);
	}

	return send_command(result.editor_window, result.command_edit, command);
}
