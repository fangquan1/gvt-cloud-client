#include <windows.h>
#include <commctrl.h>
#include <shellapi.h>
#include <stdbool.h>
#include <stdio.h>

#define IDC_ENDPOINT 1001
#define IDC_CONNECT 1002
#define IDC_STATUS 1003
#define IDC_CODEC 1004
#define IDC_LATENCY 1005
#define IDC_WIDTH 1006
#define IDC_HEIGHT 1007

static HWND endpoint_combo;
static HWND connect_button;
static HWND status_label;
static HWND codec_combo;
static HWND latency_edit;
static HWND width_edit;
static HWND height_edit;
static HINSTANCE app_instance;
static wchar_t app_dir[MAX_PATH];
static HFONT ui_font;

static void set_status(const wchar_t *text)
{
    SetWindowTextW(status_label, text);
}

static void path_join(wchar_t *out, size_t out_count, const wchar_t *a, const wchar_t *b)
{
    _snwprintf(out, out_count, L"%s\\%s", a, b);
    out[out_count - 1] = 0;
}

static bool file_exists(const wchar_t *path)
{
    DWORD attrs = GetFileAttributesW(path);
    return attrs != INVALID_FILE_ATTRIBUTES && !(attrs & FILE_ATTRIBUTE_DIRECTORY);
}

static bool dir_exists(const wchar_t *path)
{
    DWORD attrs = GetFileAttributesW(path);
    return attrs != INVALID_FILE_ATTRIBUTES && (attrs & FILE_ATTRIBUTE_DIRECTORY);
}

static void init_app_dir(void)
{
    wchar_t *slash;
    GetModuleFileNameW(NULL, app_dir, MAX_PATH);
    slash = wcsrchr(app_dir, L'\\');
    if (slash) {
        *slash = 0;
    }
}

static void history_path(wchar_t *out, size_t out_count)
{
    path_join(out, out_count, app_dir, L"gvt_client_history.txt");
}

static void debug_log(const wchar_t *text)
{
    wchar_t path[MAX_PATH];
    FILE *fp;
    path_join(path, MAX_PATH, app_dir, L"gvt_client_debug.log");
    fp = _wfopen(path, L"at, ccs=UTF-8");
    if (!fp) {
        return;
    }
    fwprintf(fp, L"%s\n", text);
    fclose(fp);
}

static void load_history(void)
{
    wchar_t path[MAX_PATH];
    wchar_t line[256];
    FILE *fp;
    int count = 0;

    history_path(path, MAX_PATH);
    fp = _wfopen(path, L"rt, ccs=UTF-8");
    if (!fp) {
        SendMessageW(endpoint_combo, CB_ADDSTRING, 0, (LPARAM)L"192.168.0.188:5004");
        SetWindowTextW(endpoint_combo, L"192.168.0.188:5004");
        return;
    }

    while (fgetws(line, 256, fp) && count < 8) {
        size_t len = wcslen(line);
        while (len > 0 && (line[len - 1] == L'\n' || line[len - 1] == L'\r' || line[len - 1] == L' ' || line[len - 1] == L'\t')) {
            line[--len] = 0;
        }
        if (len > 0) {
            SendMessageW(endpoint_combo, CB_ADDSTRING, 0, (LPARAM)line);
            if (count == 0) {
                SetWindowTextW(endpoint_combo, line);
            }
            count++;
        }
    }
    fclose(fp);

    if (count == 0) {
        SendMessageW(endpoint_combo, CB_ADDSTRING, 0, (LPARAM)L"192.168.0.188:5004");
        SetWindowTextW(endpoint_combo, L"192.168.0.188:5004");
    }
}

static void save_history(const wchar_t *endpoint)
{
    wchar_t path[MAX_PATH];
    wchar_t existing[8][256] = {{0}};
    wchar_t line[256];
    FILE *fp;
    int count = 0;

    history_path(path, MAX_PATH);
    fp = _wfopen(path, L"rt, ccs=UTF-8");
    if (fp) {
        while (fgetws(line, 256, fp) && count < 8) {
            size_t len = wcslen(line);
            while (len > 0 && (line[len - 1] == L'\n' || line[len - 1] == L'\r' || line[len - 1] == L' ' || line[len - 1] == L'\t')) {
                line[--len] = 0;
            }
            if (len > 0 && wcscmp(line, endpoint) != 0) {
                wcsncpy(existing[count++], line, 255);
            }
        }
        fclose(fp);
    }

    fp = _wfopen(path, L"wt, ccs=UTF-8");
    if (!fp) {
        return;
    }
    fwprintf(fp, L"%s\n", endpoint);
    for (int i = 0; i < count && i < 7; i++) {
        fwprintf(fp, L"%s\n", existing[i]);
    }
    fclose(fp);
}

static bool parse_endpoint(const wchar_t *input, wchar_t *host, size_t host_count, int *video_port)
{
    wchar_t temp[256];
    wchar_t *colon;
    wchar_t *prefix;
    wchar_t *end = NULL;
    long port;

    wcsncpy(temp, input, 255);
    temp[255] = 0;
    while (temp[0] == L' ' || temp[0] == L'\t') {
        memmove(temp, temp + 1, wcslen(temp) * sizeof(wchar_t));
    }
    prefix = wcsstr(temp, L"://");
    if (prefix) {
        memmove(temp, prefix + 3, (wcslen(prefix + 3) + 1) * sizeof(wchar_t));
    }
    colon = wcsrchr(temp, L':');
    if (colon) {
        *colon = 0;
        port = wcstol(colon + 1, &end, 10);
        if (end == colon + 1 || *end || port <= 0 || port > 65535) {
            return false;
        }
        *video_port = (int)port;
    } else {
        *video_port = 5004;
    }
    if (!temp[0] || wcspbrk(temp, L" \t/")) {
        return false;
    }
    wcsncpy(host, temp, host_count - 1);
    host[host_count - 1] = 0;
    return true;
}

static void find_viewer(wchar_t *viewer, size_t viewer_count)
{
    wchar_t candidate[MAX_PATH];
    DWORD len = GetEnvironmentVariableW(L"GVT_VIEWER_EXE", candidate, MAX_PATH);
    if (len > 0 && len < MAX_PATH && file_exists(candidate)) {
        wcsncpy(viewer, candidate, viewer_count - 1);
        viewer[viewer_count - 1] = 0;
        return;
    }
    path_join(candidate, MAX_PATH, app_dir, L"app\\viewer\\gvt_spice_viewer.exe");
    if (file_exists(candidate)) {
        wcsncpy(viewer, candidate, viewer_count - 1);
        viewer[viewer_count - 1] = 0;
        return;
    }
    path_join(candidate, MAX_PATH, app_dir, L"viewer\\gvt_spice_viewer.exe");
    if (file_exists(candidate)) {
        wcsncpy(viewer, candidate, viewer_count - 1);
        viewer[viewer_count - 1] = 0;
        return;
    }
    viewer[0] = 0;
}

static void quote_append(wchar_t *cmd, size_t cmd_count, const wchar_t *value)
{
    if (cmd[0]) {
        wcsncat(cmd, L" ", cmd_count - wcslen(cmd) - 1);
    }
    wcsncat(cmd, L"\"", cmd_count - wcslen(cmd) - 1);
    for (const wchar_t *p = value; *p && wcslen(cmd) + 3 < cmd_count; p++) {
        if (*p == L'"') {
            wcsncat(cmd, L"\\\"", cmd_count - wcslen(cmd) - 1);
        } else {
            wchar_t ch[2] = {*p, 0};
            wcsncat(cmd, ch, cmd_count - wcslen(cmd) - 1);
        }
    }
    wcsncat(cmd, L"\"", cmd_count - wcslen(cmd) - 1);
}

static void append_flag_value(wchar_t *cmd, size_t cmd_count, const wchar_t *flag, const wchar_t *value)
{
    wcsncat(cmd, L" ", cmd_count - wcslen(cmd) - 1);
    wcsncat(cmd, flag, cmd_count - wcslen(cmd) - 1);
    quote_append(cmd, cmd_count, value);
}

static void show_last_error(const wchar_t *title, const wchar_t *context)
{
    DWORD err = GetLastError();
    wchar_t *message = NULL;
    wchar_t text[2048];

    FormatMessageW(FORMAT_MESSAGE_ALLOCATE_BUFFER |
                   FORMAT_MESSAGE_FROM_SYSTEM |
                   FORMAT_MESSAGE_IGNORE_INSERTS,
                   NULL, err, 0, (LPWSTR)&message, 0, NULL);
    _snwprintf(text, 2048, L"%s\n\nWindows error %lu: %s",
               context, err, message ? message : L"unknown error");
    text[2047] = 0;
    MessageBoxW(NULL, text, title, MB_ICONERROR);
    if (message) {
        LocalFree(message);
    }
}

static void append_flag_int(wchar_t *cmd, size_t cmd_count, const wchar_t *flag, int value)
{
    wchar_t text[32];
    _snwprintf(text, 32, L"%d", value);
    append_flag_value(cmd, cmd_count, flag, text);
}

static void append_portable_runtime_args(wchar_t *cmd, size_t cmd_count)
{
    wchar_t gst[MAX_PATH];
    wchar_t spice[MAX_PATH];
    path_join(gst, MAX_PATH, app_dir, L"tools\\gstreamer-1.0-mingw-x86_64-1.18.6\\gstreamer\\1.0\\mingw_x86_64");
    path_join(spice, MAX_PATH, app_dir, L"runtime\\virtviewer\\bin");
    if (dir_exists(gst)) {
        append_flag_value(cmd, cmd_count, L"--gst-root", gst);
    }
    if (dir_exists(spice)) {
        append_flag_value(cmd, cmd_count, L"--spice-runtime", spice);
    }
}

static void set_viewer_low_latency_env(void)
{
    SetEnvironmentVariableW(L"GVT_SPICE_VIEWER_DROP_COMPLETE_FRAMES", L"1");
    SetEnvironmentVariableW(L"GVT_SPICE_VIEWER_UDP_BUFFER_SIZE", L"2097152");
    SetEnvironmentVariableW(
        L"GVT_SPICE_VIEWER_VIDEO_TAIL",
        L"queue name=post_decode_q leaky=downstream max-size-buffers=1 "
        L"max-size-time=0 max-size-bytes=0 ! "
        L"d3d11videosink name=vsink sync=false async=false qos=true "
        L"max-lateness=0 processing-deadline=0 render-delay=0 "
        L"enable-last-sample=false");
}

static void start_gst_warmup(void)
{
    wchar_t viewer[MAX_PATH];
    wchar_t cmd[4096] = L"";
    STARTUPINFOW si = {0};
    PROCESS_INFORMATION pi = {0};

    find_viewer(viewer, MAX_PATH);
    if (!viewer[0]) {
        return;
    }

    quote_append(cmd, 4096, viewer);
    wcsncat(cmd, L" --gst-warmup", 4096 - wcslen(cmd) - 1);
    append_portable_runtime_args(cmd, 4096);

    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESHOWWINDOW;
    si.wShowWindow = SW_HIDE;
    debug_log(L"starting GStreamer warmup");
    debug_log(cmd);
    if (CreateProcessW(viewer, cmd, NULL, NULL, FALSE,
                       CREATE_NO_WINDOW, NULL, app_dir, &si, &pi)) {
        CloseHandle(pi.hThread);
        CloseHandle(pi.hProcess);
    }
}

static void connect_now(void)
{
    wchar_t endpoint[256];
    wchar_t host[128];
    wchar_t viewer[MAX_PATH];
    wchar_t codec[16];
    wchar_t latency_text[32];
    wchar_t width_text[32];
    wchar_t height_text[32];
    wchar_t cmd[8192] = L"";
    STARTUPINFOW si = {0};
    PROCESS_INFORMATION pi = {0};
    int video_port;
    int slot;
    int spice_port;
    int input_port;
    int latency;
    int width;
    int height;

    GetWindowTextW(endpoint_combo, endpoint, 256);
    if (!parse_endpoint(endpoint, host, 128, &video_port)) {
        MessageBoxW(NULL, L"Use an address like 192.168.0.188:5004.", L"GVT Cloud Client", MB_ICONWARNING);
        return;
    }

    find_viewer(viewer, MAX_PATH);
    if (!viewer[0]) {
        MessageBoxW(NULL, L"gvt_spice_viewer.exe was not found in this portable folder.", L"GVT Cloud Client", MB_ICONERROR);
        return;
    }

    slot = video_port >= 5004 ? (video_port - 5004) / 4 : 0;
    if (slot < 0) {
        slot = 0;
    }
    spice_port = 5900 + slot;
    input_port = 5905 + slot;

    GetWindowTextW(codec_combo, codec, 16);
    GetWindowTextW(latency_edit, latency_text, 32);
    GetWindowTextW(width_edit, width_text, 32);
    GetWindowTextW(height_edit, height_text, 32);
    latency = _wtoi(latency_text);
    width = _wtoi(width_text);
    height = _wtoi(height_text);
    if (latency <= 0) latency = 15;
    if (width <= 0) width = 1920;
    if (height <= 0) height = 1200;

    quote_append(cmd, 8192, viewer);
    append_flag_value(cmd, 8192, L"--video-codec", codec[0] ? codec : L"h264");
    append_flag_int(cmd, 8192, L"--video-port", video_port);
    append_flag_int(cmd, 8192, L"--latency", latency);
    append_flag_value(cmd, 8192, L"--spice-host", host);
    append_flag_int(cmd, 8192, L"--spice-port", spice_port);
    append_flag_value(cmd, 8192, L"--input-host", host);
    append_flag_int(cmd, 8192, L"--input-port", input_port);
    append_flag_value(cmd, 8192, L"--stream-control-host", host);
    append_flag_int(cmd, 8192, L"--stream-control-port", video_port);
    append_flag_int(cmd, 8192, L"--source-width", width);
    append_flag_int(cmd, 8192, L"--source-height", height);
    wcsncat(cmd, L" --native-input --invert-case --spice-input-tablet --no-drop-on-latency --auto-size", 8192 - wcslen(cmd) - 1);
    append_portable_runtime_args(cmd, 8192);

    si.cb = sizeof(si);
    debug_log(cmd);
    set_viewer_low_latency_env();
    if (!CreateProcessW(viewer, cmd, NULL, NULL, FALSE, 0, NULL, app_dir, &si, &pi)) {
        show_last_error(L"GVT Cloud Client",
                        L"Failed to start the desktop viewer.");
        return;
    }
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    save_history(endpoint);
    set_status(L"Viewer started. Close the viewer window to disconnect.");
}

static HWND make_label(HWND parent, const wchar_t *text, int x, int y, int w, int h)
{
    HWND hwnd = CreateWindowW(L"STATIC", text, WS_CHILD | WS_VISIBLE, x, y, w, h, parent, NULL, app_instance, NULL);
    SendMessageW(hwnd, WM_SETFONT, (WPARAM)ui_font, TRUE);
    return hwnd;
}

static HWND make_edit(HWND parent, int id, const wchar_t *text, int x, int y, int w, int h)
{
    HWND hwnd = CreateWindowExW(WS_EX_CLIENTEDGE, L"EDIT", text, WS_CHILD | WS_VISIBLE | ES_AUTOHSCROLL,
                               x, y, w, h, parent, (HMENU)(INT_PTR)id, app_instance, NULL);
    SendMessageW(hwnd, WM_SETFONT, (WPARAM)ui_font, TRUE);
    return hwnd;
}

static LRESULT CALLBACK window_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
    switch (msg) {
    case WM_CREATE: {
        NONCLIENTMETRICSW ncm = {0};
        ncm.cbSize = sizeof(ncm);
        SystemParametersInfoW(SPI_GETNONCLIENTMETRICS, sizeof(ncm), &ncm, 0);
        ui_font = CreateFontIndirectW(&ncm.lfMessageFont);

        make_label(hwnd, L"GVT Cloud Client", 24, 18, 420, 26);
        make_label(hwnd, L"Enter a server address and connect like SPICE or VNC.", 24, 48, 520, 22);
        make_label(hwnd, L"Server", 24, 92, 120, 22);

        endpoint_combo = CreateWindowExW(WS_EX_CLIENTEDGE, L"COMBOBOX", L"",
                                         WS_CHILD | WS_VISIBLE | CBS_DROPDOWN | CBS_AUTOHSCROLL,
                                         24, 116, 350, 180, hwnd, (HMENU)(INT_PTR)IDC_ENDPOINT, app_instance, NULL);
        SendMessageW(endpoint_combo, WM_SETFONT, (WPARAM)ui_font, TRUE);
        load_history();

        connect_button = CreateWindowW(L"BUTTON", L"Connect", WS_CHILD | WS_VISIBLE | BS_DEFPUSHBUTTON,
                                       392, 115, 120, 30, hwnd, (HMENU)(INT_PTR)IDC_CONNECT, app_instance, NULL);
        SendMessageW(connect_button, WM_SETFONT, (WPARAM)ui_font, TRUE);

        make_label(hwnd, L"Codec", 24, 168, 80, 22);
        codec_combo = CreateWindowW(L"COMBOBOX", L"", WS_CHILD | WS_VISIBLE | CBS_DROPDOWNLIST,
                                    24, 192, 110, 100, hwnd, (HMENU)(INT_PTR)IDC_CODEC, app_instance, NULL);
        SendMessageW(codec_combo, WM_SETFONT, (WPARAM)ui_font, TRUE);
        SendMessageW(codec_combo, CB_ADDSTRING, 0, (LPARAM)L"h264");
        SendMessageW(codec_combo, CB_ADDSTRING, 0, (LPARAM)L"h265");
        SendMessageW(codec_combo, CB_SETCURSEL, 0, 0);

        make_label(hwnd, L"Latency ms", 154, 168, 90, 22);
        latency_edit = make_edit(hwnd, IDC_LATENCY, L"15", 154, 192, 82, 26);
        make_label(hwnd, L"Width", 256, 168, 70, 22);
        width_edit = make_edit(hwnd, IDC_WIDTH, L"1920", 256, 192, 82, 26);
        make_label(hwnd, L"Height", 358, 168, 70, 22);
        height_edit = make_edit(hwnd, IDC_HEIGHT, L"1200", 358, 192, 82, 26);

        status_label = make_label(hwnd, L"Ready.", 24, 248, 500, 28);
        start_gst_warmup();
        return 0;
    }
    case WM_COMMAND:
        if (LOWORD(wp) == IDC_CONNECT) {
            connect_now();
            return 0;
        }
        break;
    case WM_DESTROY:
        if (ui_font) {
            DeleteObject(ui_font);
        }
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE prev, PWSTR cmdline, int show)
{
    WNDCLASSW wc = {0};
    HWND hwnd;
    MSG msg;
    (void)prev;
    (void)cmdline;

    app_instance = instance;
    init_app_dir();
    InitCommonControls();

    wc.lpfnWndProc = window_proc;
    wc.hInstance = instance;
    wc.lpszClassName = L"GVTCloudClientWindow";
    wc.hCursor = LoadCursor(NULL, IDC_ARROW);
    wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    wc.hIcon = LoadIcon(NULL, IDI_APPLICATION);
    RegisterClassW(&wc);

    hwnd = CreateWindowExW(0, wc.lpszClassName, L"GVT Cloud Client",
                           WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX,
                           CW_USEDEFAULT, CW_USEDEFAULT, 560, 330,
                           NULL, NULL, instance, NULL);
    if (!hwnd) {
        return 1;
    }
    ShowWindow(hwnd, show);
    UpdateWindow(hwnd);

    while (GetMessageW(&msg, NULL, 0, 0)) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    return (int)msg.wParam;
}
