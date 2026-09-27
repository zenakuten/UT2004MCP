/*
 * unrealed-ui.exe -- drive UnrealEd's Build Options dialog and menu by control
 * ID, without needing the keyboard focus.
 *
 * unrealed-send.exe types into the bottom-bar Command control, which requires
 * focus -- so it fails with "Could not focus UnrealEd's Command control" (exit 6)
 * whenever a modeless dialog is open, and Build Options is exactly the dialog you
 * need open. It also cannot reach the build settings at all: the lightmap format
 * lives only in GRebuildTools.Current, written by the dialog's combo handler, and
 * no editor console command touches it.
 *
 * WM_COMMAND needs no focus. Epic's WWindow dispatches a control notification
 * sent to the control's PARENT to that control's delegate, so posting
 * WM_COMMAND(MAKEWPARAM(id, code), hwnd) runs the same handler a real click does.
 *
 *   unrealed-ui.exe --lightmap RGB8     select the lightmap format (DXT1/DXT3/RGB8)
 *   unrealed-ui.exe --build             click Build (geometry, BSP, lighting, paths)
 *   unrealed-ui.exe --save              File > Save on the editor frame
 *   unrealed-ui.exe --show-build-options open the dialog if it is hidden
 *   unrealed-ui.exe --close <fragment>  close a window by class fragment
 *   unrealed-ui.exe --cancel-dialogs    Cancel every visible common dialog
 *   unrealed-ui.exe --exec <command>    run an editor command WITHOUT focus
 *
 * --cancel-dialogs exists because File > Save pops a Save As dialog: MAP LOAD
 * does not give the level a save filename, so the menu save always asks. Cancel
 * it and use "MAP SAVE FILE=..." through unrealed-send.exe instead, which names
 * the target explicitly.
 *
 * Control IDs are from UnrealEd/Src/res/resource.h.
 */
#include <windows.h>
#include <stdio.h>
#include <wchar.h>

#define IDCB_LIGHTMAP_FORMAT 1274
#define IDPB_BUILD           28001
#define ID_FileSave          30071
#define ID_BuildOptions      30294
#define IDCB_LOG_COMMAND     19501

typedef struct
{
	const WCHAR *class_fragment;
	int          control_id;
	HWND         window;
	HWND         control;
} Search;

static BOOL get_process_path(HWND window, WCHAR *path, DWORD capacity)
{
	DWORD process_id;
	HANDLE process;
	DWORD length;

	GetWindowThreadProcessId(window, &process_id);
	process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, process_id);
	if (process == NULL)
		return FALSE;
	length = capacity;
	if (!QueryFullProcessImageNameW(process, 0, path, &length))
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
	const WCHAR *base;

	if (!get_process_path(window, path, MAX_PATH))
		return FALSE;
	base = wcsrchr(path, L'\\');
	base = (base == NULL) ? path : base + 1;
	return _wcsicmp(base, L"UnrealEd.exe") == 0;
}

static BOOL CALLBACK find_control(HWND window, LPARAM parameter)
{
	Search *search = (Search *)parameter;

	if (GetDlgCtrlID(window) == search->control_id)
	{
		search->control = window;
		return FALSE;
	}
	return TRUE;
}

static BOOL CALLBACK find_window(HWND window, LPARAM parameter)
{
	Search *search = (Search *)parameter;
	WCHAR class_name[160];

	if (!GetClassNameW(window, class_name, 160))
		return TRUE;
	if (wcsstr(class_name, search->class_fragment) == NULL)
		return TRUE;
	if (!process_is_unrealed(window))
		return TRUE;

	search->window = window;
	if (search->control_id != 0)
	{
		EnumChildWindows(window, find_control, parameter);
		if (search->control == NULL)
			return TRUE;               /* keep looking in other windows */
	}
	return FALSE;
}

static BOOL locate(const WCHAR *class_fragment, int control_id, Search *out)
{
	out->class_fragment = class_fragment;
	out->control_id = control_id;
	out->window = NULL;
	out->control = NULL;
	EnumWindows(find_window, (LPARAM)out);
	return out->window != NULL && (control_id == 0 || out->control != NULL);
}

/* Run a control's handler exactly as a click would: notify its parent. */
static void notify(HWND control, int control_id, WORD code)
{
	SendMessageW(GetParent(control), WM_COMMAND,
	             MAKEWPARAM(control_id, code), (LPARAM)control);
}

int wmain(int argc, WCHAR **argv)
{
	Search s;

	if (argc < 2)
	{
		fwprintf(stderr,
		         L"Usage: unrealed-ui.exe --lightmap <DXT1|DXT3|RGB8> | --build "
		         L"| --save | --show-build-options\n");
		return 2;
	}

	if (_wcsicmp(argv[1], L"--show-build-options") == 0)
	{
		if (!locate(L"WEditorFrame", 0, &s))
		{
			fwprintf(stderr, L"Could not find UnrealEd's frame window.\n");
			return 3;
		}
		SendMessageW(s.window, WM_COMMAND, MAKEWPARAM(ID_BuildOptions, 0), 0);
		wprintf(L"Build Options requested.\n");
		return 0;
	}

	if (_wcsicmp(argv[1], L"--exec") == 0)
	{
		/* The better way to run an editor command. unrealed-send.exe types into
		 * the Command control, which needs the keyboard focus -- so it fails
		 * whenever a dialog is open, and its keystrokes are dropped outright
		 * while the editor is busy.
		 *
		 * The bottom bar subclasses the edit inside the Command combo and, on
		 * WM_KEYDOWN/VK_RETURN, reads the control's text with GetWindowTextA and
		 * calls GUnrealEd->Exec on it (UnrealEd/Inc/BottomBarStandard.h:74). So
		 * setting the text and posting that one key delivers the command with no
		 * focus at all, and SendMessage does not return until the editor has run
		 * it -- which makes it both un-droppable and its own completion signal.
		 */
		HWND edit;
		char narrow[1024];
		int i;

		if (argc < 3)
		{
			fwprintf(stderr, L"--exec needs a command.\n");
			return 2;
		}
		if (!locate(L"UnrealEd", IDCB_LOG_COMMAND, &s))
		{
			fwprintf(stderr, L"Could not find UnrealEd's Command combo.\n");
			return 3;
		}
		edit = GetWindow(s.control, GW_CHILD);
		if (edit == NULL)
		{
			fwprintf(stderr, L"The Command combo has no edit control.\n");
			return 3;
		}
		/* GetWindowTextA on the far side, so set it as ANSI. */
		for (i = 0; argv[2][i] != L'\0' && i < 1023; i++)
			narrow[i] = (char)argv[2][i];
		narrow[i] = '\0';
		SendMessageA(edit, WM_SETTEXT, 0, (LPARAM)narrow);
		SendMessageW(edit, WM_KEYDOWN, VK_RETURN, 0);
		wprintf(L"%ls\n", argv[2]);
		return 0;
	}

	if (_wcsicmp(argv[1], L"--cancel-dialogs") == 0)
	{
		/* Visible common dialogs (#32770) owned by UnrealEd. A modal dialog
		 * blocks the editor's own message loop but keeps its own, so IDCANCEL
		 * still reaches it. */
		int closed = 0;
		HWND window = NULL;
		while ((window = FindWindowExW(NULL, window, L"#32770", NULL)) != NULL)
		{
			if (!IsWindowVisible(window) || !process_is_unrealed(window))
				continue;
			PostMessageW(window, WM_COMMAND, MAKEWPARAM(IDCANCEL, 0), 0);
			closed++;
		}
		wprintf(L"Cancelled %d dialog(s).\n", closed);
		return 0;
	}

	if (_wcsicmp(argv[1], L"--close") == 0)
	{
		if (argc < 3)
		{
			fwprintf(stderr, L"--close needs a window class fragment.\n");
			return 2;
		}
		if (!locate(argv[2], 0, &s))
		{
			fwprintf(stderr, L"No UnrealEd window matching %ls.\n", argv[2]);
			return 3;
		}
		PostMessageW(s.window, WM_CLOSE, 0, 0);
		wprintf(L"Closed %ls.\n", argv[2]);
		return 0;
	}

	if (_wcsicmp(argv[1], L"--save") == 0)
	{
		if (!locate(L"WEditorFrame", 0, &s))
		{
			fwprintf(stderr, L"Could not find UnrealEd's frame window.\n");
			return 3;
		}
		SendMessageW(s.window, WM_COMMAND, MAKEWPARAM(ID_FileSave, 0), 0);
		wprintf(L"File > Save sent.\n");
		return 0;
	}

	if (_wcsicmp(argv[1], L"--lightmap") == 0)
	{
		LRESULT index;

		if (argc < 3)
		{
			fwprintf(stderr, L"--lightmap needs DXT1, DXT3 or RGB8.\n");
			return 2;
		}
		if (!locate(L"WBuildPropSheet", IDCB_LIGHTMAP_FORMAT, &s))
		{
			fwprintf(stderr,
			         L"Could not find the lightmap format combo. Open Build "
			         L"Options first (--show-build-options).\n");
			return 3;
		}
		index = SendMessageW(s.control, CB_FINDSTRINGEXACT, (WPARAM)-1,
		                     (LPARAM)argv[2]);
		if (index == CB_ERR)
		{
			fwprintf(stderr, L"The combo has no entry %ls.\n", argv[2]);
			return 4;
		}
		SendMessageW(s.control, CB_SETCURSEL, (WPARAM)index, 0);
		/* The combo's own handler is what writes GRebuildTools.Current. */
		notify(s.control, IDCB_LIGHTMAP_FORMAT, CBN_SELCHANGE);
		wprintf(L"Lightmap format set to %ls.\n", argv[2]);
		return 0;
	}

	if (_wcsicmp(argv[1], L"--build") == 0)
	{
		if (!locate(L"WBuildPropSheet", IDPB_BUILD, &s))
		{
			fwprintf(stderr,
			         L"Could not find the Build button. Open Build Options "
			         L"first (--show-build-options).\n");
			return 3;
		}
		/* Returns only when the whole build has finished: the handler runs
		 * MAP REBUILD, BSP REBUILD, LIGHT APPLY, PATHS DEFINE and FLUID REBUILD
		 * synchronously on the editor's thread. */
		notify(s.control, IDPB_BUILD, BN_CLICKED);
		wprintf(L"Build finished.\n");
		return 0;
	}

	fwprintf(stderr, L"Unknown option %ls.\n", argv[1]);
	return 2;
}
