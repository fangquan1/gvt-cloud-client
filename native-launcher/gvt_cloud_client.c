#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0600
#endif

#include <winsock2.h>
#include <windows.h>
#include <commctrl.h>
#include <shellapi.h>
#include <windowsx.h>
#include <stdbool.h>
#include <stdio.h>
#include <wchar.h>

#ifndef PROCESS_QUERY_LIMITED_INFORMATION
#define PROCESS_QUERY_LIMITED_INFORMATION 0x1000
#endif

#define IDC_ENDPOINT 1001
#define IDC_CONNECT 1002
#define IDC_STATUS 1003
#define IDC_SETTINGS 1004
#define IDC_HELP_BUTTON 1005
#define IDC_ADD_CONNECTION 1006
#define IDC_MORE 1007

#define IDC_EDIT_ENDPOINT 2001
#define IDC_EDIT_NAME 2002
#define IDC_EDIT_CODEC 2003
#define IDC_EDIT_FPS 2004
#define IDC_EDIT_BITRATE 2005
#define IDC_EDIT_LATENCY 2006
#define IDC_EDIT_REMOTE_RES 2007
#define IDC_EDIT_RECONNECT 2008
#define IDC_EDIT_RECONNECT_ATTEMPTS 2009
#define IDC_EDIT_RECONNECT_INTERVAL 2010
#define IDC_EDIT_START_VIEWER 2011
#define IDC_EDIT_MINIMIZE_TRAY 2012
#define IDC_EDIT_TEST 2013
#define IDC_EDIT_SAVE 2014
#define IDC_EDIT_SAVE_RECONNECT 2015
#define IDC_EDIT_CANCEL 2016

#define IDC_SET_CODEC 3001
#define IDC_SET_FPS 3002
#define IDC_SET_BITRATE 3003
#define IDC_SET_LATENCY 3004
#define IDC_SET_REMOTE_RES 3005
#define IDC_SET_RECONNECT 3006
#define IDC_SET_RECONNECT_ATTEMPTS 3007
#define IDC_SET_RECONNECT_INTERVAL 3008
#define IDC_SET_START_VIEWER 3009
#define IDC_SET_MINIMIZE_TRAY 3010
#define IDC_SET_REMEMBER_RECENT 3011
#define IDC_SET_RESTORE 3012
#define IDC_SET_SAVE 3013
#define IDC_SET_APPLY 3014
#define IDC_SET_CANCEL 3015

#define CARD_CLASS_NAME L"GVTCloudClientCard"
#define EDIT_CLASS_NAME L"GVTCloudClientEditWindow"
#define SETTINGS_CLASS_NAME L"GVTCloudClientSettingsWindow"
#define MAX_CONNECTIONS 64
#define MAX_CARDS 64
#define WM_TRAYICON (WM_APP + 1)
#define TRAY_ICON_ID 1
#define TIMER_RECONNECT_ID 10

typedef struct {
    wchar_t id[64];
    wchar_t name[128];
    wchar_t endpoint[256];
    wchar_t codec[16];
    int fps;
    int bitrate_mbps;
    int latency_ms;
    BOOL use_remote_resolution;
    BOOL reconnect;
    int reconnect_attempts;
    int reconnect_interval_sec;
    BOOL start_viewer;
    BOOL minimize_tray_on_connect;
    wchar_t thumbnail[MAX_PATH];
    HANDLE viewer_process;
    DWORD viewer_pid;
    BOOL viewer_stop_requested;
    BOOL reconnect_pending;
    int reconnects_done;
    ULONGLONG next_reconnect_tick;
} Connection;

typedef struct {
    wchar_t codec[16];
    int fps;
    int bitrate_mbps;
    int latency_ms;
    BOOL use_remote_resolution;
    BOOL reconnect;
    int reconnect_attempts;
    int reconnect_interval_sec;
    BOOL start_viewer;
    BOOL minimize_tray_on_connect;
    BOOL remember_recent;
} ClientSettings;

static HINSTANCE app_instance;
static HWND main_window;
static HWND endpoint_combo;
static HWND status_label;
static HWND connect_button;
static HWND add_button;
static HWND settings_button;
static HWND help_button;
static HWND more_button;
static HWND card_windows[MAX_CARDS];
static int card_window_count;
static wchar_t app_dir[MAX_PATH];
static HFONT ui_font;
static HFONT title_font;
static HFONT small_font;
static Connection connections[MAX_CONNECTIONS];
static int connection_count;
static ClientSettings settings;
static int selected_connection = -1;
static int edit_index = -1;
static BOOL edit_is_new = FALSE;
static BOOL tray_icon_added = FALSE;

static HWND edit_endpoint;
static HWND edit_name;
static HWND edit_codec;
static HWND edit_fps;
static HWND edit_bitrate;
static HWND edit_latency;
static HWND edit_remote_res;
static HWND edit_reconnect;
static HWND edit_reconnect_attempts;
static HWND edit_reconnect_interval;
static HWND edit_start_viewer;
static HWND edit_minimize_tray;

static HWND set_codec;
static HWND set_fps;
static HWND set_bitrate;
static HWND set_latency;
static HWND set_remote_res;
static HWND set_reconnect;
static HWND set_reconnect_attempts;
static HWND set_reconnect_interval;
static HWND set_start_viewer;
static HWND set_minimize_tray;
static HWND set_remember_recent;

static COLORREF color_blue = RGB(0, 120, 215);
static COLORREF color_text = RGB(18, 32, 64);
static COLORREF color_muted = RGB(103, 116, 142);
static COLORREF color_border = RGB(210, 218, 230);

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

static void settings_path(wchar_t *out, size_t out_count)
{
    path_join(out, out_count, app_dir, L"gvt_client_settings.json");
}

static void connections_path(wchar_t *out, size_t out_count)
{
    path_join(out, out_count, app_dir, L"gvt_client_connections.json");
}

static void history_path(wchar_t *out, size_t out_count)
{
    path_join(out, out_count, app_dir, L"gvt_client_history.txt");
}

static void thumbnails_dir(wchar_t *out, size_t out_count)
{
    path_join(out, out_count, app_dir, L"thumbnails");
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

static void set_status(const wchar_t *text)
{
    if (status_label) {
        SetWindowTextW(status_label, text);
    }
}

static void update_tray_icon(BOOL add)
{
    NOTIFYICONDATAW nid;
    ZeroMemory(&nid, sizeof(nid));
    nid.cbSize = sizeof(nid);
    nid.hWnd = main_window;
    nid.uID = TRAY_ICON_ID;
    nid.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
    nid.uCallbackMessage = WM_TRAYICON;
    nid.hIcon = LoadIcon(NULL, IDI_APPLICATION);
    wcsncpy(nid.szTip, L"GVT Cloud Client", sizeof(nid.szTip) / sizeof(nid.szTip[0]) - 1);
    if (add) {
        if (!tray_icon_added && Shell_NotifyIconW(NIM_ADD, &nid)) {
            tray_icon_added = TRUE;
        } else if (tray_icon_added) {
            Shell_NotifyIconW(NIM_MODIFY, &nid);
        }
    } else if (tray_icon_added) {
        Shell_NotifyIconW(NIM_DELETE, &nid);
        tray_icon_added = FALSE;
    }
}

static void show_from_tray(void)
{
    ShowWindow(main_window, SW_SHOW);
    ShowWindow(main_window, SW_RESTORE);
    SetForegroundWindow(main_window);
}

static BOOL probe_tcp_port(const wchar_t *host_w, int port, int timeout_ms)
{
    WSADATA wsa;
    SOCKET sock = INVALID_SOCKET;
    struct sockaddr_in addr;
    char host[128];
    u_long nonblock = 1;
    fd_set writefds;
    struct timeval tv;
    int err = 0;
    int err_len = sizeof(err);
    BOOL ok = FALSE;

    if (WideCharToMultiByte(CP_UTF8, 0, host_w, -1, host, sizeof(host), NULL, NULL) <= 0) {
        return FALSE;
    }
    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) {
        return FALSE;
    }
    sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (sock == INVALID_SOCKET) {
        WSACleanup();
        return FALSE;
    }
    addr.sin_family = AF_INET;
    addr.sin_port = htons((u_short)port);
    addr.sin_addr.s_addr = inet_addr(host);
    if (addr.sin_addr.s_addr == INADDR_NONE) {
        closesocket(sock);
        WSACleanup();
        return FALSE;
    }
    ioctlsocket(sock, FIONBIO, &nonblock);
    connect(sock, (struct sockaddr *)&addr, sizeof(addr));
    FD_ZERO(&writefds);
    FD_SET(sock, &writefds);
    tv.tv_sec = timeout_ms / 1000;
    tv.tv_usec = (timeout_ms % 1000) * 1000;
    if (select(0, NULL, &writefds, NULL, &tv) > 0) {
        if (getsockopt(sock, SOL_SOCKET, SO_ERROR, (char *)&err, &err_len) == 0 && err == 0) {
            ok = TRUE;
        }
    }
    closesocket(sock);
    WSACleanup();
    return ok;
}

static void default_settings(ClientSettings *out)
{
    wcsncpy(out->codec, L"h265", 15);
    out->codec[15] = 0;
    out->fps = 59;
    out->bitrate_mbps = 18;
    out->latency_ms = 15;
    out->use_remote_resolution = TRUE;
    out->reconnect = FALSE;
    out->reconnect_attempts = 3;
    out->reconnect_interval_sec = 5;
    out->start_viewer = TRUE;
    out->minimize_tray_on_connect = FALSE;
    out->remember_recent = TRUE;
}

static void ensure_range_int(int *value, int min_value, int max_value, int fallback)
{
    if (*value < min_value || *value > max_value) {
        *value = fallback;
    }
}

static void normalize_connection(Connection *conn)
{
    ensure_range_int(&conn->fps, 1, 120, settings.fps);
    ensure_range_int(&conn->bitrate_mbps, 1, 100, settings.bitrate_mbps);
    ensure_range_int(&conn->latency_ms, 1, 500, settings.latency_ms);
    ensure_range_int(&conn->reconnect_attempts, 0, 99, settings.reconnect_attempts);
    ensure_range_int(&conn->reconnect_interval_sec, 1, 3600, settings.reconnect_interval_sec);
    if (_wcsicmp(conn->codec, L"h264") && _wcsicmp(conn->codec, L"h265")) {
        wcsncpy(conn->codec, settings.codec, 15);
        conn->codec[15] = 0;
    }
}

static void make_connection_id(wchar_t *out, size_t out_count, const wchar_t *endpoint)
{
    unsigned int hash = 2166136261u;
    for (const wchar_t *p = endpoint; *p; p++) {
        hash ^= (unsigned int)(*p);
        hash *= 16777619u;
    }
    _snwprintf(out, out_count, L"conn-%08x", hash);
    out[out_count - 1] = 0;
}

static void connection_thumbnail_path(Connection *conn)
{
    wchar_t dir[MAX_PATH];
    thumbnails_dir(dir, MAX_PATH);
    CreateDirectoryW(dir, NULL);
    _snwprintf(conn->thumbnail, MAX_PATH, L"%s\\%s.png", dir, conn->id);
    conn->thumbnail[MAX_PATH - 1] = 0;
}

static void init_connection_defaults(Connection *conn, const wchar_t *endpoint, const wchar_t *name)
{
    ZeroMemory(conn, sizeof(*conn));
    make_connection_id(conn->id, 64, endpoint);
    wcsncpy(conn->endpoint, endpoint, 255);
    conn->endpoint[255] = 0;
    wcsncpy(conn->name, name && name[0] ? name : endpoint, 127);
    conn->name[127] = 0;
    wcsncpy(conn->codec, settings.codec, 15);
    conn->codec[15] = 0;
    conn->fps = settings.fps;
    conn->bitrate_mbps = settings.bitrate_mbps;
    conn->latency_ms = settings.latency_ms;
    conn->use_remote_resolution = settings.use_remote_resolution;
    conn->reconnect = settings.reconnect;
    conn->reconnect_attempts = settings.reconnect_attempts;
    conn->reconnect_interval_sec = settings.reconnect_interval_sec;
    conn->start_viewer = settings.start_viewer;
    conn->minimize_tray_on_connect = settings.minimize_tray_on_connect;
    connection_thumbnail_path(conn);
}

static void json_write_escaped(FILE *fp, const wchar_t *value)
{
    fputwc(L'"', fp);
    for (const wchar_t *p = value; *p; p++) {
        if (*p == L'\\' || *p == L'"') {
            fputwc(L'\\', fp);
        }
        if (*p == L'\n') {
            fputws(L"\\n", fp);
        } else if (*p == L'\r') {
            fputws(L"\\r", fp);
        } else {
            fputwc(*p, fp);
        }
    }
    fputwc(L'"', fp);
}

static wchar_t *read_text_file(const wchar_t *path)
{
    FILE *fp = _wfopen(path, L"rt, ccs=UTF-8");
    wchar_t *buffer;
    size_t cap = 65536;
    size_t len = 0;
    wchar_t chunk[512];

    if (!fp) {
        return NULL;
    }
    buffer = (wchar_t *)calloc(cap, sizeof(wchar_t));
    if (!buffer) {
        fclose(fp);
        return NULL;
    }
    while (fgetws(chunk, 512, fp)) {
        size_t chunk_len = wcslen(chunk);
        if (len + chunk_len + 1 >= cap) {
            break;
        }
        wcscpy(buffer + len, chunk);
        len += chunk_len;
    }
    fclose(fp);
    return buffer;
}

static wchar_t *json_find_key(wchar_t *object, const wchar_t *key)
{
    wchar_t pattern[128];
    _snwprintf(pattern, 128, L"\"%s\"", key);
    pattern[127] = 0;
    return wcsstr(object, pattern);
}

static BOOL json_get_string(wchar_t *object, const wchar_t *key, wchar_t *out, size_t out_count)
{
    wchar_t *p = json_find_key(object, key);
    wchar_t *start;
    size_t len = 0;
    if (!p) return FALSE;
    p = wcschr(p, L':');
    if (!p) return FALSE;
    p++;
    while (*p == L' ' || *p == L'\t' || *p == L'\r' || *p == L'\n') p++;
    if (*p != L'"') return FALSE;
    start = ++p;
    while (*p && (*p != L'"' || (p > start && p[-1] == L'\\'))) p++;
    while (start < p && len + 1 < out_count) {
        if (*start == L'\\' && start + 1 < p) {
            start++;
        }
        out[len++] = *start++;
    }
    out[len] = 0;
    return TRUE;
}

static BOOL json_get_int(wchar_t *object, const wchar_t *key, int *out)
{
    wchar_t *p = json_find_key(object, key);
    if (!p) return FALSE;
    p = wcschr(p, L':');
    if (!p) return FALSE;
    *out = _wtoi(p + 1);
    return TRUE;
}

static BOOL json_get_bool(wchar_t *object, const wchar_t *key, BOOL *out)
{
    wchar_t *p = json_find_key(object, key);
    if (!p) return FALSE;
    p = wcschr(p, L':');
    if (!p) return FALSE;
    p++;
    while (*p == L' ' || *p == L'\t' || *p == L'\r' || *p == L'\n') p++;
    if (!_wcsnicmp(p, L"true", 4)) {
        *out = TRUE;
        return TRUE;
    }
    if (!_wcsnicmp(p, L"false", 5)) {
        *out = FALSE;
        return TRUE;
    }
    return FALSE;
}

static void save_settings(void)
{
    wchar_t path[MAX_PATH];
    FILE *fp;
    settings_path(path, MAX_PATH);
    fp = _wfopen(path, L"wt, ccs=UTF-8");
    if (!fp) return;
    fwprintf(fp, L"{\n");
    fwprintf(fp, L"  \"codec\": "); json_write_escaped(fp, settings.codec); fwprintf(fp, L",\n");
    fwprintf(fp, L"  \"fps\": %d,\n", settings.fps);
    fwprintf(fp, L"  \"bitrate_mbps\": %d,\n", settings.bitrate_mbps);
    fwprintf(fp, L"  \"latency_ms\": %d,\n", settings.latency_ms);
    fwprintf(fp, L"  \"use_remote_resolution\": %s,\n", settings.use_remote_resolution ? L"true" : L"false");
    fwprintf(fp, L"  \"reconnect\": %s,\n", settings.reconnect ? L"true" : L"false");
    fwprintf(fp, L"  \"reconnect_attempts\": %d,\n", settings.reconnect_attempts);
    fwprintf(fp, L"  \"reconnect_interval_sec\": %d,\n", settings.reconnect_interval_sec);
    fwprintf(fp, L"  \"start_viewer\": %s,\n", settings.start_viewer ? L"true" : L"false");
    fwprintf(fp, L"  \"minimize_tray_on_connect\": %s,\n", settings.minimize_tray_on_connect ? L"true" : L"false");
    fwprintf(fp, L"  \"remember_recent\": %s\n", settings.remember_recent ? L"true" : L"false");
    fwprintf(fp, L"}\n");
    fclose(fp);
}

static void load_settings(void)
{
    wchar_t path[MAX_PATH];
    wchar_t *text;
    default_settings(&settings);
    settings_path(path, MAX_PATH);
    text = read_text_file(path);
    if (!text) {
        return;
    }
    json_get_string(text, L"codec", settings.codec, 16);
    json_get_int(text, L"fps", &settings.fps);
    json_get_int(text, L"bitrate_mbps", &settings.bitrate_mbps);
    json_get_int(text, L"latency_ms", &settings.latency_ms);
    json_get_bool(text, L"use_remote_resolution", &settings.use_remote_resolution);
    json_get_bool(text, L"reconnect", &settings.reconnect);
    json_get_int(text, L"reconnect_attempts", &settings.reconnect_attempts);
    json_get_int(text, L"reconnect_interval_sec", &settings.reconnect_interval_sec);
    json_get_bool(text, L"start_viewer", &settings.start_viewer);
    json_get_bool(text, L"minimize_tray_on_connect", &settings.minimize_tray_on_connect);
    json_get_bool(text, L"remember_recent", &settings.remember_recent);
    ensure_range_int(&settings.fps, 1, 120, 59);
    ensure_range_int(&settings.bitrate_mbps, 1, 100, 18);
    ensure_range_int(&settings.latency_ms, 1, 500, 15);
    free(text);
}

static void save_connections(void)
{
    wchar_t path[MAX_PATH];
    FILE *fp;
    connections_path(path, MAX_PATH);
    fp = _wfopen(path, L"wt, ccs=UTF-8");
    if (!fp) return;
    fwprintf(fp, L"{\n  \"connections\": [\n");
    for (int i = 0; i < connection_count; i++) {
        Connection *c = &connections[i];
        fwprintf(fp, L"    {\n");
        fwprintf(fp, L"      \"id\": "); json_write_escaped(fp, c->id); fwprintf(fp, L",\n");
        fwprintf(fp, L"      \"name\": "); json_write_escaped(fp, c->name); fwprintf(fp, L",\n");
        fwprintf(fp, L"      \"endpoint\": "); json_write_escaped(fp, c->endpoint); fwprintf(fp, L",\n");
        fwprintf(fp, L"      \"codec\": "); json_write_escaped(fp, c->codec); fwprintf(fp, L",\n");
        fwprintf(fp, L"      \"fps\": %d,\n", c->fps);
        fwprintf(fp, L"      \"bitrate_mbps\": %d,\n", c->bitrate_mbps);
        fwprintf(fp, L"      \"latency_ms\": %d,\n", c->latency_ms);
        fwprintf(fp, L"      \"use_remote_resolution\": %s,\n", c->use_remote_resolution ? L"true" : L"false");
        fwprintf(fp, L"      \"reconnect\": %s,\n", c->reconnect ? L"true" : L"false");
        fwprintf(fp, L"      \"reconnect_attempts\": %d,\n", c->reconnect_attempts);
        fwprintf(fp, L"      \"reconnect_interval_sec\": %d,\n", c->reconnect_interval_sec);
        fwprintf(fp, L"      \"start_viewer\": %s,\n", c->start_viewer ? L"true" : L"false");
        fwprintf(fp, L"      \"minimize_tray_on_connect\": %s,\n", c->minimize_tray_on_connect ? L"true" : L"false");
        fwprintf(fp, L"      \"thumbnail\": "); json_write_escaped(fp, c->thumbnail); fwprintf(fp, L"\n");
        fwprintf(fp, L"    }%s\n", i + 1 < connection_count ? L"," : L"");
    }
    fwprintf(fp, L"  ]\n}\n");
    fclose(fp);
}

static void add_connection_from_endpoint(const wchar_t *endpoint, const wchar_t *name)
{
    if (connection_count >= MAX_CONNECTIONS) return;
    init_connection_defaults(&connections[connection_count], endpoint, name);
    normalize_connection(&connections[connection_count]);
    connection_count++;
}

static void load_connections_from_history(void)
{
    wchar_t path[MAX_PATH];
    wchar_t line[256];
    FILE *fp;
    int index = 1;
    history_path(path, MAX_PATH);
    fp = _wfopen(path, L"rt, ccs=UTF-8");
    if (!fp) {
        add_connection_from_endpoint(L"192.168.0.188:5004", L"Engineering VM");
        return;
    }
    while (fgetws(line, 256, fp) && connection_count < MAX_CONNECTIONS) {
        size_t len = wcslen(line);
        wchar_t name[64];
        while (len > 0 && (line[len - 1] == L'\n' || line[len - 1] == L'\r' ||
                           line[len - 1] == L' ' || line[len - 1] == L'\t')) {
            line[--len] = 0;
        }
        if (len > 0) {
            _snwprintf(name, 64, index == 1 ? L"Engineering VM" : L"Connection %d", index);
            name[63] = 0;
            add_connection_from_endpoint(line, name);
            index++;
        }
    }
    fclose(fp);
    if (connection_count == 0) {
        add_connection_from_endpoint(L"192.168.0.188:5004", L"Engineering VM");
    }
}

static void load_connections(void)
{
    wchar_t path[MAX_PATH];
    wchar_t *text;
    connection_count = 0;
    connections_path(path, MAX_PATH);
    text = read_text_file(path);
    if (!text) {
        load_connections_from_history();
        save_connections();
        return;
    }

    wchar_t *p = wcschr(text, L'[');
    while (p && connection_count < MAX_CONNECTIONS) {
        wchar_t *start = wcschr(p, L'{');
        wchar_t *end;
        int depth = 0;
        if (!start) break;
        end = start;
        while (*end) {
            if (*end == L'{') depth++;
            if (*end == L'}') {
                depth--;
                if (depth == 0) break;
            }
            end++;
        }
        if (!*end) break;
        wchar_t saved = end[1];
        end[1] = 0;
        Connection *c = &connections[connection_count];
        ZeroMemory(c, sizeof(*c));
        if (json_get_string(start, L"endpoint", c->endpoint, 256)) {
            json_get_string(start, L"id", c->id, 64);
            json_get_string(start, L"name", c->name, 128);
            json_get_string(start, L"codec", c->codec, 16);
            json_get_int(start, L"fps", &c->fps);
            json_get_int(start, L"bitrate_mbps", &c->bitrate_mbps);
            json_get_int(start, L"latency_ms", &c->latency_ms);
            json_get_bool(start, L"use_remote_resolution", &c->use_remote_resolution);
            json_get_bool(start, L"reconnect", &c->reconnect);
            json_get_int(start, L"reconnect_attempts", &c->reconnect_attempts);
            json_get_int(start, L"reconnect_interval_sec", &c->reconnect_interval_sec);
            json_get_bool(start, L"start_viewer", &c->start_viewer);
            json_get_bool(start, L"minimize_tray_on_connect", &c->minimize_tray_on_connect);
            json_get_string(start, L"thumbnail", c->thumbnail, MAX_PATH);
            if (!c->id[0]) make_connection_id(c->id, 64, c->endpoint);
            if (!c->name[0]) wcsncpy(c->name, c->endpoint, 127);
            if (!c->thumbnail[0]) connection_thumbnail_path(c);
            normalize_connection(c);
            connection_count++;
        }
        end[1] = saved;
        p = end + 1;
    }
    free(text);
    if (connection_count == 0) {
        load_connections_from_history();
        save_connections();
    }
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

static BOOL test_connection_endpoint(const wchar_t *endpoint, wchar_t *message, size_t message_count)
{
    wchar_t host[128];
    int video_port;
    int slot;
    int spice_port;
    int input_port;
    BOOL control_ok;
    BOOL spice_ok;
    BOOL input_ok;

    if (!parse_endpoint(endpoint, host, 128, &video_port)) {
        wcsncpy(message, L"Invalid server address.", message_count - 1);
        message[message_count - 1] = 0;
        return FALSE;
    }
    slot = video_port >= 5004 ? (video_port - 5004) / 4 : 0;
    if (slot < 0) slot = 0;
    spice_port = 5900 + slot;
    input_port = 5905 + slot;
    control_ok = probe_tcp_port(host, video_port, 1500);
    spice_ok = probe_tcp_port(host, spice_port, 1500);
    input_ok = probe_tcp_port(host, input_port, 1500);
    _snwprintf(message, message_count,
               L"Control %d: %s\nSPICE %d: %s\nInput %d: %s",
               video_port, control_ok ? L"OK" : L"failed",
               spice_port, spice_ok ? L"OK" : L"failed",
               input_port, input_ok ? L"OK" : L"failed");
    message[message_count - 1] = 0;
    return control_ok && spice_ok && input_ok;
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

static bool viewer_handle_running(Connection *conn)
{
    DWORD exit_code;
    if (!conn->viewer_process) return false;
    if (!GetExitCodeProcess(conn->viewer_process, &exit_code)) return false;
    return exit_code == STILL_ACTIVE;
}

static void close_viewer_handle(Connection *conn)
{
    if (conn->viewer_process) {
        CloseHandle(conn->viewer_process);
        conn->viewer_process = NULL;
    }
    conn->viewer_pid = 0;
}

static void stop_connection_viewer(Connection *conn)
{
    conn->viewer_stop_requested = TRUE;
    conn->reconnect_pending = FALSE;
    if (viewer_handle_running(conn)) {
        TerminateProcess(conn->viewer_process, 0);
        WaitForSingleObject(conn->viewer_process, 3000);
    }
    close_viewer_handle(conn);
}

static void show_last_error(const wchar_t *title, const wchar_t *context)
{
    DWORD err = GetLastError();
    wchar_t *message = NULL;
    wchar_t text[2048];
    FormatMessageW(FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM |
                   FORMAT_MESSAGE_IGNORE_INSERTS, NULL, err, 0,
                   (LPWSTR)&message, 0, NULL);
    _snwprintf(text, 2048, L"%s\n\nWindows error %lu: %s",
               context, err, message ? message : L"unknown error");
    text[2047] = 0;
    MessageBoxW(NULL, text, title, MB_ICONERROR);
    if (message) LocalFree(message);
}

static void refresh_cards(void);
static void fill_endpoint_combo(void);

static int find_connection_by_endpoint(const wchar_t *endpoint)
{
    for (int i = 0; i < connection_count; i++) {
        if (!_wcsicmp(connections[i].endpoint, endpoint)) {
            return i;
        }
    }
    return -1;
}

static BOOL start_viewer_for_connection(int index, BOOL force_start, BOOL auto_reconnect)
{
    Connection *conn;
    wchar_t host[128];
    wchar_t viewer[MAX_PATH];
    wchar_t cmd[8192] = L"";
    STARTUPINFOW si = {0};
    PROCESS_INFORMATION pi = {0};
    int video_port;
    int slot;
    int spice_port;
    int input_port;
    int bitrate_kbps;
    wchar_t status[256];

    if (index < 0 || index >= connection_count) return FALSE;
    conn = &connections[index];
    normalize_connection(conn);
    if (!force_start && !conn->start_viewer) {
        selected_connection = index;
        fill_endpoint_combo();
        refresh_cards();
        set_status(L"Connection saved. Start viewer on connect is disabled.");
        return TRUE;
    }

    if (!parse_endpoint(conn->endpoint, host, 128, &video_port)) {
        MessageBoxW(main_window, L"Use an address like 192.168.0.188:5004.",
                    L"GVT Cloud Client", MB_ICONWARNING);
        return FALSE;
    }
    find_viewer(viewer, MAX_PATH);
    if (!viewer[0]) {
        MessageBoxW(main_window, L"gvt_spice_viewer.exe was not found in this portable folder.",
                    L"GVT Cloud Client", MB_ICONERROR);
        return FALSE;
    }

    slot = video_port >= 5004 ? (video_port - 5004) / 4 : 0;
    if (slot < 0) slot = 0;
    spice_port = 5900 + slot;
    input_port = 5905 + slot;
    bitrate_kbps = conn->bitrate_mbps * 1000;
    if (bitrate_kbps < 256) bitrate_kbps = 18000;
    if (bitrate_kbps > 100000) bitrate_kbps = 100000;

    quote_append(cmd, 8192, viewer);
    append_flag_value(cmd, 8192, L"--video-codec", conn->codec);
    append_flag_int(cmd, 8192, L"--video-port", video_port);
    append_flag_int(cmd, 8192, L"--latency", conn->latency_ms);
    append_flag_int(cmd, 8192, L"--stream-fps", conn->fps);
    append_flag_int(cmd, 8192, L"--stream-bitrate-kbps", bitrate_kbps);
    append_flag_int(cmd, 8192, L"--stream-keyint", conn->fps);
    append_flag_value(cmd, 8192, L"--connection-id", conn->id);
    append_flag_value(cmd, 8192, L"--thumbnail-path", conn->thumbnail);
    append_flag_value(cmd, 8192, L"--spice-host", host);
    append_flag_int(cmd, 8192, L"--spice-port", spice_port);
    append_flag_value(cmd, 8192, L"--input-host", host);
    append_flag_int(cmd, 8192, L"--input-port", input_port);
    append_flag_value(cmd, 8192, L"--stream-control-host", host);
    append_flag_int(cmd, 8192, L"--stream-control-port", video_port);
    wcsncat(cmd, L" --native-input --invert-case --spice-input-tablet --no-drop-on-latency --auto-size",
            8192 - wcslen(cmd) - 1);
    append_portable_runtime_args(cmd, 8192);

    debug_log(cmd);
    set_viewer_low_latency_env();
    stop_connection_viewer(conn);
    conn->viewer_stop_requested = FALSE;

    si.cb = sizeof(si);
    if (!CreateProcessW(viewer, cmd, NULL, NULL, FALSE, 0, NULL, app_dir, &si, &pi)) {
        show_last_error(L"GVT Cloud Client", L"Failed to start the desktop viewer.");
        return FALSE;
    }
    CloseHandle(pi.hThread);
    conn->viewer_process = pi.hProcess;
    conn->viewer_pid = pi.dwProcessId;
    conn->reconnect_pending = FALSE;
    if (!auto_reconnect) {
        conn->reconnects_done = 0;
    }
    selected_connection = index;
    save_connections();
    fill_endpoint_combo();
    refresh_cards();

    _snwprintf(status, 256, L"Connected to %s with %s, %d fps, %d Mbps.",
               conn->endpoint, !_wcsicmp(conn->codec, L"h265") ? L"H.265" : L"H.264",
               conn->fps, conn->bitrate_mbps);
    status[255] = 0;
    set_status(status);
    if (conn->minimize_tray_on_connect) {
        update_tray_icon(TRUE);
        ShowWindow(main_window, SW_MINIMIZE);
    }
    return TRUE;
}

static void connect_from_address_bar(void)
{
    wchar_t endpoint[256];
    wchar_t host[128];
    int port;
    int index;
    GetWindowTextW(endpoint_combo, endpoint, 256);
    if (!parse_endpoint(endpoint, host, 128, &port)) {
        MessageBoxW(main_window, L"Use an address like 192.168.0.188:5004.",
                    L"GVT Cloud Client", MB_ICONWARNING);
        return;
    }
    if (wcsrchr(endpoint, L':') == NULL) {
        _snwprintf(endpoint, 256, L"%s:%d", host, port);
        endpoint[255] = 0;
    }
    index = find_connection_by_endpoint(endpoint);
    if (index < 0) {
        if (connection_count >= MAX_CONNECTIONS) {
            MessageBoxW(main_window, L"Connection list is full.", L"GVT Cloud Client", MB_ICONWARNING);
            return;
        }
        add_connection_from_endpoint(endpoint, endpoint);
        index = connection_count - 1;
        save_connections();
        fill_endpoint_combo();
        refresh_cards();
    }
    start_viewer_for_connection(index, FALSE, FALSE);
}

static HWND make_control(HWND parent, const wchar_t *cls, const wchar_t *text, DWORD style,
                         DWORD ex_style, int id, int x, int y, int w, int h)
{
    HWND hwnd = CreateWindowExW(ex_style, cls, text, WS_CHILD | WS_VISIBLE | style,
                                x, y, w, h, parent, (HMENU)(INT_PTR)id, app_instance, NULL);
    SendMessageW(hwnd, WM_SETFONT, (WPARAM)ui_font, TRUE);
    return hwnd;
}

static HWND make_label(HWND parent, const wchar_t *text, int x, int y, int w, int h)
{
    return make_control(parent, L"STATIC", text, 0, 0, 0, x, y, w, h);
}

static HWND make_button(HWND parent, const wchar_t *text, int id, int x, int y, int w, int h)
{
    return make_control(parent, L"BUTTON", text, BS_OWNERDRAW, 0, id, x, y, w, h);
}

static HWND make_edit(HWND parent, int id, const wchar_t *text, int x, int y, int w, int h)
{
    return make_control(parent, L"EDIT", text, ES_AUTOHSCROLL, WS_EX_CLIENTEDGE, id, x, y, w, h);
}

static HWND make_number_edit(HWND parent, int id, int value, int x, int y, int w, int h)
{
    wchar_t text[32];
    _snwprintf(text, 32, L"%d", value);
    return make_control(parent, L"EDIT", text, ES_AUTOHSCROLL | ES_NUMBER, WS_EX_CLIENTEDGE, id, x, y, w, h);
}

static HWND make_checkbox(HWND parent, int id, const wchar_t *text, BOOL checked, int x, int y, int w, int h)
{
    HWND hwnd = make_control(parent, L"BUTTON", text, BS_AUTOCHECKBOX, 0, id, x, y, w, h);
    SendMessageW(hwnd, BM_SETCHECK, checked ? BST_CHECKED : BST_UNCHECKED, 0);
    return hwnd;
}

static int get_int_from_edit(HWND hwnd, int fallback)
{
    wchar_t text[64];
    int value;
    GetWindowTextW(hwnd, text, 64);
    value = _wtoi(text);
    return value > 0 ? value : fallback;
}

static BOOL get_check(HWND hwnd)
{
    return SendMessageW(hwnd, BM_GETCHECK, 0, 0) == BST_CHECKED;
}

static void set_combo_codec(HWND combo, const wchar_t *codec)
{
    SendMessageW(combo, CB_RESETCONTENT, 0, 0);
    SendMessageW(combo, CB_ADDSTRING, 0, (LPARAM)L"H.265");
    SendMessageW(combo, CB_ADDSTRING, 0, (LPARAM)L"H.264");
    SendMessageW(combo, CB_SETCURSEL, !_wcsicmp(codec, L"h264") ? 1 : 0, 0);
}

static void get_combo_codec(HWND combo, wchar_t *out, size_t out_count)
{
    LRESULT sel = SendMessageW(combo, CB_GETCURSEL, 0, 0);
    wcsncpy(out, sel == 1 ? L"h264" : L"h265", out_count - 1);
    out[out_count - 1] = 0;
}

static void draw_text_color(HDC hdc, const wchar_t *text, RECT rc, HFONT font,
                            COLORREF color, UINT format)
{
    HFONT old_font = (HFONT)SelectObject(hdc, font ? font : ui_font);
    SetTextColor(hdc, color);
    SetBkMode(hdc, TRANSPARENT);
    DrawTextW(hdc, text, -1, &rc, format);
    SelectObject(hdc, old_font);
}

static void draw_monitor_icon(HDC hdc, RECT rc, COLORREF color)
{
    HPEN pen = CreatePen(PS_SOLID, 3, color);
    HPEN old_pen = (HPEN)SelectObject(hdc, pen);
    HBRUSH old_brush = (HBRUSH)SelectObject(hdc, GetStockObject(NULL_BRUSH));
    int cx = (rc.left + rc.right) / 2;
    int top = rc.top + 16;
    int left = cx - 42;
    int right = cx + 42;
    int bottom = top + 54;
    RoundRect(hdc, left, top, right, bottom, 4, 4);
    MoveToEx(hdc, cx - 12, bottom, NULL);
    LineTo(hdc, cx - 18, bottom + 28);
    MoveToEx(hdc, cx + 12, bottom, NULL);
    LineTo(hdc, cx + 18, bottom + 28);
    MoveToEx(hdc, cx - 38, bottom + 28, NULL);
    LineTo(hdc, cx + 38, bottom + 28);
    SelectObject(hdc, old_brush);
    SelectObject(hdc, old_pen);
    DeleteObject(pen);
}

static void draw_app_icon(HDC hdc, int x, int y, int size)
{
    HBRUSH blue = CreateSolidBrush(color_blue);
    HPEN pen = CreatePen(PS_SOLID, 1, color_blue);
    HBRUSH old_brush = (HBRUSH)SelectObject(hdc, blue);
    HPEN old_pen = (HPEN)SelectObject(hdc, pen);
    RoundRect(hdc, x, y, x + size, y + size, 8, 8);
    SelectObject(hdc, GetStockObject(NULL_BRUSH));
    SelectObject(hdc, GetStockObject(WHITE_PEN));
    RoundRect(hdc, x + 8, y + 8, x + size - 14, y + size - 16, 4, 4);
    MoveToEx(hdc, x + size - 19, y + size - 16, NULL);
    LineTo(hdc, x + size - 9, y + size - 8);
    SelectObject(hdc, old_brush);
    SelectObject(hdc, old_pen);
    DeleteObject(blue);
    DeleteObject(pen);
}

static BOOL draw_button_item(LPARAM lp)
{
    DRAWITEMSTRUCT *dis = (DRAWITEMSTRUCT *)lp;
    wchar_t text[160];
    BOOL primary = dis->CtlID == IDC_CONNECT || dis->CtlID == IDC_EDIT_SAVE ||
                   dis->CtlID == IDC_SET_SAVE;
    BOOL outline = dis->CtlID == IDC_ADD_CONNECTION || dis->CtlID == IDC_EDIT_SAVE_RECONNECT ||
                   dis->CtlID == IDC_SET_APPLY;
    BOOL flat_text = dis->CtlID == IDC_SETTINGS || dis->CtlID == IDC_HELP_BUTTON;
    BOOL pressed = (dis->itemState & ODS_SELECTED) != 0;
    COLORREF fill = primary ? color_blue : RGB(255, 255, 255);
    COLORREF border_color = primary || outline ? color_blue : color_border;
    COLORREF text_color = primary ? RGB(255, 255, 255) : (outline ? RGB(35, 74, 135) : color_text);
    HBRUSH brush;
    HPEN pen;
    HBRUSH old_brush;
    HPEN old_pen;
    RECT rc = dis->rcItem;
    GetWindowTextW(dis->hwndItem, text, 160);
    if (pressed && primary) fill = RGB(0, 96, 180);
    if (pressed && !primary) fill = RGB(236, 244, 255);

    if (flat_text) {
        FillRect(dis->hDC, &rc, (HBRUSH)GetStockObject(WHITE_BRUSH));
        draw_text_color(dis->hDC, text, rc, ui_font, color_text,
                        DT_SINGLELINE | DT_CENTER | DT_VCENTER);
        return TRUE;
    }

    brush = CreateSolidBrush(fill);
    pen = CreatePen(PS_SOLID, 1, border_color);
    old_brush = (HBRUSH)SelectObject(dis->hDC, brush);
    old_pen = (HPEN)SelectObject(dis->hDC, pen);
    RoundRect(dis->hDC, rc.left, rc.top, rc.right, rc.bottom, 6, 6);
    if (dis->CtlID == IDC_MORE) {
        HBRUSH dots = CreateSolidBrush(color_text);
        int cx = (rc.left + rc.right) / 2;
        int cy = (rc.top + rc.bottom) / 2;
        SelectObject(dis->hDC, dots);
        Ellipse(dis->hDC, cx - 2, cy - 12, cx + 3, cy - 7);
        Ellipse(dis->hDC, cx - 2, cy - 2, cx + 3, cy + 3);
        Ellipse(dis->hDC, cx - 2, cy + 8, cx + 3, cy + 13);
        DeleteObject(dots);
    } else {
        draw_text_color(dis->hDC, text, rc, ui_font, text_color,
                        DT_SINGLELINE | DT_CENTER | DT_VCENTER);
    }
    SelectObject(dis->hDC, old_brush);
    SelectObject(dis->hDC, old_pen);
    DeleteObject(brush);
    DeleteObject(pen);
    return TRUE;
}

static void draw_main_background(HDC hdc, RECT rc)
{
    HBRUSH white = CreateSolidBrush(RGB(255, 255, 255));
    HBRUSH band = CreateSolidBrush(RGB(246, 248, 252));
    HPEN border = CreatePen(PS_SOLID, 1, color_border);
    FillRect(hdc, &rc, white);
    RECT top = {0, 0, rc.right, 86};
    FillRect(hdc, &top, white);
    RECT toolbar = {0, 86, rc.right, 176};
    FillRect(hdc, &toolbar, band);
    RECT bottom = {0, rc.bottom - 48, rc.right, rc.bottom};
    FillRect(hdc, &bottom, band);
    SelectObject(hdc, border);
    MoveToEx(hdc, 0, 86, NULL); LineTo(hdc, rc.right, 86);
    MoveToEx(hdc, 0, 176, NULL); LineTo(hdc, rc.right, 176);
    MoveToEx(hdc, 0, rc.bottom - 48, NULL); LineTo(hdc, rc.right, rc.bottom - 48);
    DeleteObject(border);
    DeleteObject(white);
    DeleteObject(band);
}

static LRESULT CALLBACK card_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
    int index = (int)(INT_PTR)GetWindowLongPtrW(hwnd, GWLP_USERDATA);
    switch (msg) {
    case WM_NCCREATE:
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, (LONG_PTR)((CREATESTRUCTW *)lp)->lpCreateParams);
        return TRUE;
    case WM_LBUTTONUP:
        index = (int)(INT_PTR)GetWindowLongPtrW(hwnd, GWLP_USERDATA);
        start_viewer_for_connection(index, FALSE, FALSE);
        return 0;
    case WM_RBUTTONUP:
    case WM_CONTEXTMENU: {
        HMENU menu = CreatePopupMenu();
        POINT pt;
        index = (int)(INT_PTR)GetWindowLongPtrW(hwnd, GWLP_USERDATA);
        AppendMenuW(menu, MF_STRING, 1, L"Connect");
        AppendMenuW(menu, MF_STRING, 2, L"Edit");
        AppendMenuW(menu, MF_STRING, 3, L"Delete");
        if (msg == WM_CONTEXTMENU) {
            pt.x = GET_X_LPARAM(lp);
            pt.y = GET_Y_LPARAM(lp);
        } else {
            pt.x = GET_X_LPARAM(lp);
            pt.y = GET_Y_LPARAM(lp);
            ClientToScreen(hwnd, &pt);
        }
        int cmd = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON, pt.x, pt.y, 0, hwnd, NULL);
        DestroyMenu(menu);
        if (cmd == 1) {
            start_viewer_for_connection(index, FALSE, FALSE);
        } else if (cmd == 2) {
            edit_index = index;
            edit_is_new = FALSE;
            CreateWindowExW(WS_EX_DLGMODALFRAME, EDIT_CLASS_NAME, L"GVT Cloud Client | Edit Connection",
                            WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU,
                            CW_USEDEFAULT, CW_USEDEFAULT, 880, 760,
                            main_window, NULL, app_instance, NULL);
        } else if (cmd == 3 && index >= 0 && index < connection_count) {
            stop_connection_viewer(&connections[index]);
            for (int i = index; i + 1 < connection_count; i++) {
                connections[i] = connections[i + 1];
            }
            connection_count--;
            if (selected_connection >= connection_count) selected_connection = connection_count - 1;
            save_connections();
            fill_endpoint_combo();
            refresh_cards();
        }
        return 0;
    }
    case WM_PAINT: {
        PAINTSTRUCT ps;
        RECT rc;
        HDC hdc = BeginPaint(hwnd, &ps);
        GetClientRect(hwnd, &rc);
        Connection *c = &connections[index];
        BOOL selected = index == selected_connection;
        BOOL running = viewer_handle_running(c);
        HBRUSH bg = CreateSolidBrush(RGB(255, 255, 255));
        HBRUSH thumb = CreateSolidBrush(RGB(235, 243, 255));
        HBRUSH dot = CreateSolidBrush(running ? RGB(28, 178, 45) : RGB(145, 151, 160));
        HPEN border = CreatePen(PS_SOLID, selected ? 2 : 1, selected ? color_blue : color_border);
        HPEN old_pen = (HPEN)SelectObject(hdc, border);
        HBRUSH old_brush = (HBRUSH)SelectObject(hdc, bg);
        RoundRect(hdc, rc.left + 1, rc.top + 1, rc.right - 1, rc.bottom - 1, 8, 8);
        RECT tr = {14, 14, rc.right - 14, 188};
        SelectObject(hdc, thumb);
        SelectObject(hdc, GetStockObject(NULL_PEN));
        RoundRect(hdc, tr.left, tr.top, tr.right, tr.bottom, 4, 4);
        draw_monitor_icon(hdc, tr, color_blue);
        SelectObject(hdc, dot);
        Ellipse(hdc, 13, 176, 33, 196);
        RECT name_rc = {18, 224, rc.right - 44, 252};
        RECT ep_rc = {18, 258, rc.right - 24, 286};
        draw_text_color(hdc, c->name, name_rc, title_font, color_text,
                        DT_SINGLELINE | DT_END_ELLIPSIS | DT_VCENTER);
        draw_text_color(hdc, c->endpoint, ep_rc, ui_font, color_muted,
                        DT_SINGLELINE | DT_END_ELLIPSIS | DT_VCENTER);
        HBRUSH dots = CreateSolidBrush(RGB(45, 56, 78));
        SelectObject(hdc, dots);
        Ellipse(hdc, rc.right - 30, 226, rc.right - 25, 231);
        Ellipse(hdc, rc.right - 30, 237, rc.right - 25, 242);
        Ellipse(hdc, rc.right - 30, 248, rc.right - 25, 253);
        DeleteObject(dots);
        SelectObject(hdc, old_brush);
        SelectObject(hdc, old_pen);
        DeleteObject(bg);
        DeleteObject(thumb);
        DeleteObject(dot);
        DeleteObject(border);
        EndPaint(hwnd, &ps);
        return 0;
    }
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

static void fill_endpoint_combo(void)
{
    if (!endpoint_combo) return;
    SendMessageW(endpoint_combo, CB_RESETCONTENT, 0, 0);
    for (int i = 0; i < connection_count; i++) {
        SendMessageW(endpoint_combo, CB_ADDSTRING, 0, (LPARAM)connections[i].endpoint);
    }
    if (selected_connection >= 0 && selected_connection < connection_count) {
        SetWindowTextW(endpoint_combo, connections[selected_connection].endpoint);
    } else if (connection_count > 0) {
        SetWindowTextW(endpoint_combo, connections[0].endpoint);
    } else {
        SetWindowTextW(endpoint_combo, L"192.168.0.188:5004");
    }
}

static void refresh_cards(void)
{
    RECT rc;
    int left = 26;
    int top = 216;
    int card_w = 260;
    int card_h = 316;
    int gap = 20;
    int columns;
    if (!main_window) return;
    for (int i = 0; i < card_window_count; i++) {
        DestroyWindow(card_windows[i]);
    }
    card_window_count = 0;
    GetClientRect(main_window, &rc);
    columns = (rc.right - left * 2 + gap) / (card_w + gap);
    if (columns < 1) columns = 1;
    for (int i = 0; i < connection_count && i < MAX_CARDS; i++) {
        int col = i % columns;
        int row = i / columns;
        HWND card = CreateWindowExW(0, CARD_CLASS_NAME, L"",
                                    WS_CHILD | WS_VISIBLE,
                                    left + col * (card_w + gap),
                                    top + row * (card_h + gap),
                                    card_w, card_h, main_window, NULL, app_instance,
                                    (LPVOID)(INT_PTR)i);
        card_windows[card_window_count++] = card;
    }
    wchar_t status[128];
    _snwprintf(status, 128, L"%d device%s", connection_count, connection_count == 1 ? L"" : L"s");
    status[127] = 0;
    InvalidateRect(main_window, NULL, TRUE);
}

static void layout_main_window(void)
{
    RECT rc;
    int w;
    if (!main_window) return;
    GetClientRect(main_window, &rc);
    w = rc.right;
    MoveWindow(settings_button, 20, 50, 78, 28, TRUE);
    MoveWindow(help_button, 112, 50, 60, 28, TRUE);
    MoveWindow(endpoint_combo, 30, 126, w - 560, 38, TRUE);
    MoveWindow(connect_button, w - 520, 126, 150, 38, TRUE);
    MoveWindow(add_button, w - 340, 126, 170, 38, TRUE);
    MoveWindow(more_button, w - 136, 126, 54, 38, TRUE);
    MoveWindow(status_label, w - 180, rc.bottom - 38, 150, 28, TRUE);
    refresh_cards();
}

static BOOL collect_edit_connection(Connection *out)
{
    wchar_t endpoint[256];
    wchar_t host[128];
    int port;
    GetWindowTextW(edit_endpoint, endpoint, 256);
    if (!parse_endpoint(endpoint, host, 128, &port)) {
        MessageBoxW(NULL, L"Use an address like 192.168.0.188:5004.", L"GVT Cloud Client", MB_ICONWARNING);
        return FALSE;
    }
    if (wcsrchr(endpoint, L':') == NULL) {
        _snwprintf(endpoint, 256, L"%s:%d", host, port);
        endpoint[255] = 0;
    }
    GetWindowTextW(edit_name, out->name, 128);
    if (!out->name[0]) wcsncpy(out->name, endpoint, 127);
    wcsncpy(out->endpoint, endpoint, 255);
    out->endpoint[255] = 0;
    if (!out->id[0]) make_connection_id(out->id, 64, endpoint);
    get_combo_codec(edit_codec, out->codec, 16);
    out->fps = get_int_from_edit(edit_fps, settings.fps);
    out->bitrate_mbps = get_int_from_edit(edit_bitrate, settings.bitrate_mbps);
    out->latency_ms = get_int_from_edit(edit_latency, settings.latency_ms);
    out->use_remote_resolution = get_check(edit_remote_res);
    out->reconnect = get_check(edit_reconnect);
    out->reconnect_attempts = get_int_from_edit(edit_reconnect_attempts, settings.reconnect_attempts);
    out->reconnect_interval_sec = get_int_from_edit(edit_reconnect_interval, settings.reconnect_interval_sec);
    out->start_viewer = get_check(edit_start_viewer);
    out->minimize_tray_on_connect = get_check(edit_minimize_tray);
    if (!out->thumbnail[0]) connection_thumbnail_path(out);
    normalize_connection(out);
    return TRUE;
}

static void save_edit_window(HWND hwnd, BOOL reconnect)
{
    Connection temp;
    int target_index = edit_index;
    if (edit_is_new) {
        if (connection_count >= MAX_CONNECTIONS) {
            MessageBoxW(hwnd, L"Connection list is full.", L"GVT Cloud Client", MB_ICONWARNING);
            return;
        }
        ZeroMemory(&temp, sizeof(temp));
        temp.use_remote_resolution = settings.use_remote_resolution;
        temp.reconnect = settings.reconnect;
        temp.reconnect_attempts = settings.reconnect_attempts;
        temp.reconnect_interval_sec = settings.reconnect_interval_sec;
        temp.start_viewer = settings.start_viewer;
        temp.minimize_tray_on_connect = settings.minimize_tray_on_connect;
    } else if (edit_index >= 0 && edit_index < connection_count) {
        temp = connections[edit_index];
    } else {
        return;
    }
    if (!collect_edit_connection(&temp)) return;
    if (edit_is_new) {
        connections[connection_count] = temp;
        target_index = connection_count++;
    } else {
        connections[edit_index] = temp;
    }
    selected_connection = target_index;
    save_connections();
    fill_endpoint_combo();
    refresh_cards();
    DestroyWindow(hwnd);
    if (reconnect && target_index >= 0) {
        start_viewer_for_connection(target_index, TRUE, FALSE);
    }
}

static LRESULT CALLBACK edit_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
    (void)lp;
    switch (msg) {
    case WM_CREATE: {
        Connection temp;
        if (edit_is_new || edit_index < 0 || edit_index >= connection_count) {
            init_connection_defaults(&temp, L"192.168.0.188:5004", L"New Connection");
        } else {
            temp = connections[edit_index];
        }
        make_label(hwnd, L"General", 34, 26, 200, 30);
        make_label(hwnd, L"Server address:", 58, 138, 170, 28);
        edit_endpoint = make_edit(hwnd, IDC_EDIT_ENDPOINT, temp.endpoint, 240, 132, 570, 34);
        make_label(hwnd, L"Display name:", 58, 184, 170, 28);
        edit_name = make_edit(hwnd, IDC_EDIT_NAME, temp.name, 240, 178, 570, 34);
        make_label(hwnd, L"Connection options", 58, 250, 260, 28);
        make_label(hwnd, L"Codec:", 78, 302, 180, 28);
        edit_codec = make_control(hwnd, L"COMBOBOX", L"", CBS_DROPDOWNLIST, 0, IDC_EDIT_CODEC, 270, 296, 170, 120);
        set_combo_codec(edit_codec, temp.codec);
        make_label(hwnd, L"Frame rate (fps):", 78, 348, 180, 28);
        edit_fps = make_number_edit(hwnd, IDC_EDIT_FPS, temp.fps, 270, 342, 170, 34);
        make_label(hwnd, L"Bitrate (Mbps):", 78, 394, 180, 28);
        edit_bitrate = make_number_edit(hwnd, IDC_EDIT_BITRATE, temp.bitrate_mbps, 270, 388, 170, 34);
        make_label(hwnd, L"Latency target (ms):", 78, 440, 190, 28);
        edit_latency = make_number_edit(hwnd, IDC_EDIT_LATENCY, temp.latency_ms, 270, 434, 170, 34);
        edit_remote_res = make_checkbox(hwnd, IDC_EDIT_REMOTE_RES, L"Use remote desktop resolution",
                                        temp.use_remote_resolution, 500, 344, 280, 28);
        make_label(hwnd, L"Higher bitrate may improve image quality.", 78, 492, 420, 26);
        make_label(hwnd, L"Connection behavior", 58, 548, 260, 28);
        make_label(hwnd, L"Transport:     RTP + TCP", 78, 594, 260, 28);
        edit_reconnect = make_checkbox(hwnd, IDC_EDIT_RECONNECT, L"Reconnect automatically",
                                       temp.reconnect, 78, 628, 260, 28);
        make_label(hwnd, L"Reconnect attempts:", 112, 664, 180, 28);
        edit_reconnect_attempts = make_number_edit(hwnd, IDC_EDIT_RECONNECT_ATTEMPTS,
                                                   temp.reconnect_attempts, 300, 658, 120, 32);
        make_label(hwnd, L"Reconnect interval (s):", 112, 702, 190, 28);
        edit_reconnect_interval = make_number_edit(hwnd, IDC_EDIT_RECONNECT_INTERVAL,
                                                   temp.reconnect_interval_sec, 300, 696, 120, 32);
        edit_start_viewer = make_checkbox(hwnd, IDC_EDIT_START_VIEWER, L"Start viewer on connect",
                                          temp.start_viewer, 500, 628, 260, 28);
        edit_minimize_tray = make_checkbox(hwnd, IDC_EDIT_MINIMIZE_TRAY, L"Minimize to system tray on connect",
                                           temp.minimize_tray_on_connect, 500, 664, 310, 28);
        make_button(hwnd, L"Test Connection", IDC_EDIT_TEST, 26, 700, 170, 38);
        make_button(hwnd, L"Save", IDC_EDIT_SAVE, 390, 700, 140, 38);
        make_button(hwnd, L"Save && Reconnect", IDC_EDIT_SAVE_RECONNECT, 550, 700, 170, 38);
        make_button(hwnd, L"Cancel", IDC_EDIT_CANCEL, 740, 700, 110, 38);
        ShowWindow(hwnd, SW_SHOW);
        return 0;
    }
    case WM_COMMAND:
        switch (LOWORD(wp)) {
        case IDC_EDIT_TEST: {
            wchar_t endpoint[256];
            wchar_t result[512];
            BOOL ok;
            GetWindowTextW(edit_endpoint, endpoint, 256);
            ok = test_connection_endpoint(endpoint, result, 512);
            MessageBoxW(hwnd, result, ok ? L"GVT Cloud Client - Test Connection OK" :
                        L"GVT Cloud Client - Test Connection Failed",
                        ok ? MB_ICONINFORMATION : MB_ICONWARNING);
            return 0;
        }
        case IDC_EDIT_SAVE:
            save_edit_window(hwnd, FALSE);
            return 0;
        case IDC_EDIT_SAVE_RECONNECT:
            save_edit_window(hwnd, TRUE);
            return 0;
        case IDC_EDIT_CANCEL:
            DestroyWindow(hwnd);
            return 0;
        }
        break;
    case WM_DRAWITEM:
        return draw_button_item(lp);
    case WM_CLOSE:
        DestroyWindow(hwnd);
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

static void collect_settings_window(void)
{
    get_combo_codec(set_codec, settings.codec, 16);
    settings.fps = get_int_from_edit(set_fps, 59);
    settings.bitrate_mbps = get_int_from_edit(set_bitrate, 18);
    settings.latency_ms = get_int_from_edit(set_latency, 15);
    settings.use_remote_resolution = get_check(set_remote_res);
    settings.reconnect = get_check(set_reconnect);
    settings.reconnect_attempts = get_int_from_edit(set_reconnect_attempts, 3);
    settings.reconnect_interval_sec = get_int_from_edit(set_reconnect_interval, 5);
    settings.start_viewer = get_check(set_start_viewer);
    settings.minimize_tray_on_connect = get_check(set_minimize_tray);
    settings.remember_recent = get_check(set_remember_recent);
    ensure_range_int(&settings.fps, 1, 120, 59);
    ensure_range_int(&settings.bitrate_mbps, 1, 100, 18);
    ensure_range_int(&settings.latency_ms, 1, 500, 15);
}

static LRESULT CALLBACK settings_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
    (void)lp;
    switch (msg) {
    case WM_CREATE:
        make_label(hwnd, L"Default Connection", 36, 28, 220, 30);
        make_label(hwnd, L"About", 270, 28, 100, 30);
        make_label(hwnd, L"Default streaming parameters", 66, 198, 320, 28);
        make_label(hwnd, L"Default codec:", 84, 256, 220, 28);
        set_codec = make_control(hwnd, L"COMBOBOX", L"", CBS_DROPDOWNLIST, 0, IDC_SET_CODEC, 320, 250, 220, 120);
        set_combo_codec(set_codec, settings.codec);
        make_label(hwnd, L"Default frame rate (fps):", 84, 304, 230, 28);
        set_fps = make_number_edit(hwnd, IDC_SET_FPS, settings.fps, 320, 298, 220, 34);
        make_label(hwnd, L"Default bitrate (Mbps):", 84, 352, 230, 28);
        set_bitrate = make_number_edit(hwnd, IDC_SET_BITRATE, settings.bitrate_mbps, 320, 346, 220, 34);
        make_label(hwnd, L"Default latency target (ms):", 84, 400, 240, 28);
        set_latency = make_number_edit(hwnd, IDC_SET_LATENCY, settings.latency_ms, 320, 394, 220, 34);
        set_remote_res = make_checkbox(hwnd, IDC_SET_REMOTE_RES, L"Use remote desktop resolution",
                                       settings.use_remote_resolution, 84, 456, 320, 28);
        make_label(hwnd, L"These defaults are applied when creating a new connection.", 84, 500, 520, 26);
        make_label(hwnd, L"Default session behavior", 66, 562, 320, 28);
        make_label(hwnd, L"Transport:     RTP + TCP", 84, 612, 280, 28);
        set_reconnect = make_checkbox(hwnd, IDC_SET_RECONNECT, L"Reconnect automatically",
                                      settings.reconnect, 84, 650, 280, 28);
        make_label(hwnd, L"Reconnect attempts:", 126, 688, 180, 28);
        set_reconnect_attempts = make_number_edit(hwnd, IDC_SET_RECONNECT_ATTEMPTS,
                                                  settings.reconnect_attempts, 340, 682, 130, 32);
        make_label(hwnd, L"Reconnect interval (s):", 126, 728, 190, 28);
        set_reconnect_interval = make_number_edit(hwnd, IDC_SET_RECONNECT_INTERVAL,
                                                  settings.reconnect_interval_sec, 340, 722, 130, 32);
        set_start_viewer = make_checkbox(hwnd, IDC_SET_START_VIEWER, L"Start viewer on connect",
                                         settings.start_viewer, 520, 650, 260, 28);
        set_minimize_tray = make_checkbox(hwnd, IDC_SET_MINIMIZE_TRAY, L"Minimize to system tray on connect",
                                          settings.minimize_tray_on_connect, 520, 688, 310, 28);
        set_remember_recent = make_checkbox(hwnd, IDC_SET_REMEMBER_RECENT, L"Remember recent server addresses",
                                            settings.remember_recent, 520, 726, 310, 28);
        make_button(hwnd, L"Restore Defaults", IDC_SET_RESTORE, 24, 812, 170, 38);
        make_button(hwnd, L"Save", IDC_SET_SAVE, 430, 812, 140, 38);
        make_button(hwnd, L"Apply", IDC_SET_APPLY, 600, 812, 140, 38);
        make_button(hwnd, L"Cancel", IDC_SET_CANCEL, 770, 812, 110, 38);
        ShowWindow(hwnd, SW_SHOW);
        return 0;
    case WM_COMMAND:
        switch (LOWORD(wp)) {
        case IDC_SET_RESTORE:
            default_settings(&settings);
            DestroyWindow(hwnd);
            CreateWindowExW(WS_EX_DLGMODALFRAME, SETTINGS_CLASS_NAME, L"GVT Cloud Client | Settings",
                            WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU,
                            CW_USEDEFAULT, CW_USEDEFAULT, 900, 920,
                            main_window, NULL, app_instance, NULL);
            return 0;
        case IDC_SET_SAVE:
            collect_settings_window();
            save_settings();
            DestroyWindow(hwnd);
            return 0;
        case IDC_SET_APPLY:
            collect_settings_window();
            save_settings();
            set_status(L"Settings applied.");
            return 0;
        case IDC_SET_CANCEL:
            DestroyWindow(hwnd);
            return 0;
        }
        break;
    case WM_DRAWITEM:
        return draw_button_item(lp);
    case WM_CLOSE:
        DestroyWindow(hwnd);
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

static void start_gst_warmup(void)
{
    wchar_t viewer[MAX_PATH];
    wchar_t cmd[4096] = L"";
    STARTUPINFOW si = {0};
    PROCESS_INFORMATION pi = {0};
    find_viewer(viewer, MAX_PATH);
    if (!viewer[0]) return;
    quote_append(cmd, 4096, viewer);
    wcsncat(cmd, L" --gst-warmup", 4096 - wcslen(cmd) - 1);
    append_portable_runtime_args(cmd, 4096);
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESHOWWINDOW;
    si.wShowWindow = SW_HIDE;
    if (CreateProcessW(viewer, cmd, NULL, NULL, FALSE, CREATE_NO_WINDOW, NULL, app_dir, &si, &pi)) {
        CloseHandle(pi.hThread);
        CloseHandle(pi.hProcess);
    }
}

static void poll_viewer_processes(void)
{
    ULONGLONG now = GetTickCount64();
    BOOL any_changed = FALSE;
    for (int i = 0; i < connection_count; i++) {
        Connection *conn = &connections[i];
        if (conn->viewer_process) {
            DWORD exit_code = STILL_ACTIVE;
            if (GetExitCodeProcess(conn->viewer_process, &exit_code) && exit_code != STILL_ACTIVE) {
                CloseHandle(conn->viewer_process);
                conn->viewer_process = NULL;
                conn->viewer_pid = 0;
                any_changed = TRUE;
                if (!conn->viewer_stop_requested && conn->reconnect &&
                    conn->reconnects_done < conn->reconnect_attempts) {
                    conn->reconnect_pending = TRUE;
                    conn->next_reconnect_tick = now + (ULONGLONG)conn->reconnect_interval_sec * 1000ULL;
                    wchar_t status[256];
                    _snwprintf(status, 256, L"Viewer exited. Reconnecting %s in %d second(s)...",
                               conn->endpoint, conn->reconnect_interval_sec);
                    status[255] = 0;
                    set_status(status);
                } else {
                    conn->reconnect_pending = FALSE;
                    conn->reconnects_done = 0;
                    conn->viewer_stop_requested = FALSE;
                    set_status(L"Viewer disconnected.");
                }
            }
        }
        if (conn->reconnect_pending && now >= conn->next_reconnect_tick) {
            conn->reconnect_pending = FALSE;
            conn->reconnects_done++;
            start_viewer_for_connection(i, TRUE, TRUE);
            any_changed = TRUE;
        }
    }
    if (any_changed) {
        refresh_cards();
    }
}

static LRESULT CALLBACK window_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
    switch (msg) {
    case WM_CREATE: {
        main_window = hwnd;
        NONCLIENTMETRICSW ncm = {0};
        ncm.cbSize = sizeof(ncm);
        SystemParametersInfoW(SPI_GETNONCLIENTMETRICS, sizeof(ncm), &ncm, 0);
        ui_font = CreateFontIndirectW(&ncm.lfMessageFont);
        title_font = CreateFontW(18, 0, 0, 0, FW_SEMIBOLD, FALSE, FALSE, FALSE,
                                 DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
                                 CLEARTYPE_QUALITY, DEFAULT_PITCH | FF_SWISS, L"Segoe UI");
        small_font = CreateFontW(15, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
                                 DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
                                 CLEARTYPE_QUALITY, DEFAULT_PITCH | FF_SWISS, L"Segoe UI");
        settings_button = make_button(hwnd, L"Settings", IDC_SETTINGS, 20, 50, 78, 28);
        help_button = make_button(hwnd, L"Help", IDC_HELP_BUTTON, 112, 50, 60, 28);
        endpoint_combo = make_control(hwnd, L"COMBOBOX", L"",
                                      CBS_DROPDOWN | CBS_AUTOHSCROLL, WS_EX_CLIENTEDGE,
                                      IDC_ENDPOINT, 30, 126, 600, 180);
        connect_button = make_button(hwnd, L"Connect", IDC_CONNECT, 660, 126, 150, 38);
        add_button = make_button(hwnd, L"Add Connection", IDC_ADD_CONNECTION, 830, 126, 170, 38);
        more_button = make_button(hwnd, L"...", IDC_MORE, 1020, 126, 54, 38);
        status_label = make_label(hwnd, L"Ready", 900, 690, 140, 28);
        fill_endpoint_combo();
        refresh_cards();
        SetTimer(hwnd, TIMER_RECONNECT_ID, 1000, NULL);
        start_gst_warmup();
        return 0;
    }
    case WM_SIZE:
        if (wp == SIZE_MINIMIZED && tray_icon_added) {
            ShowWindow(hwnd, SW_HIDE);
            return 0;
        }
        layout_main_window();
        return 0;
    case WM_TIMER:
        if (wp == TIMER_RECONNECT_ID) {
            poll_viewer_processes();
            return 0;
        }
        break;
    case WM_TRAYICON:
        if (lp == WM_LBUTTONDBLCLK) {
            show_from_tray();
            return 0;
        }
        if (lp == WM_RBUTTONUP || lp == WM_CONTEXTMENU) {
            HMENU menu = CreatePopupMenu();
            POINT pt;
            AppendMenuW(menu, MF_STRING, 1, L"Show GVT Cloud Client");
            AppendMenuW(menu, MF_STRING, 2, L"Exit");
            GetCursorPos(&pt);
            SetForegroundWindow(hwnd);
            int cmd = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON, pt.x, pt.y, 0, hwnd, NULL);
            DestroyMenu(menu);
            if (cmd == 1) {
                show_from_tray();
            } else if (cmd == 2) {
                DestroyWindow(hwnd);
            }
            return 0;
        }
        break;
    case WM_PAINT: {
        PAINTSTRUCT ps;
        RECT rc;
        HDC hdc = BeginPaint(hwnd, &ps);
        GetClientRect(hwnd, &rc);
        draw_main_background(hdc, rc);
        draw_app_icon(hdc, 16, 14, 28);
        RECT title = {54, 12, 320, 44};
        draw_text_color(hdc, L"GVT Cloud Client", title, title_font, RGB(24, 24, 24),
                        DT_SINGLELINE | DT_VCENTER);
        RECT bottom = {26, rc.bottom - 34, 180, rc.bottom - 8};
        wchar_t count_text[64];
        _snwprintf(count_text, 64, L"%d device%s", connection_count, connection_count == 1 ? L"" : L"s");
        draw_text_color(hdc, count_text, bottom, ui_font, color_text, DT_SINGLELINE | DT_VCENTER);
        HBRUSH green = CreateSolidBrush(RGB(25, 174, 45));
        SelectObject(hdc, green);
        Ellipse(hdc, rc.right - 142, rc.bottom - 28, rc.right - 128, rc.bottom - 14);
        DeleteObject(green);
        EndPaint(hwnd, &ps);
        return 0;
    }
    case WM_COMMAND:
        switch (LOWORD(wp)) {
        case IDC_CONNECT:
            connect_from_address_bar();
            return 0;
        case IDC_ADD_CONNECTION:
            edit_index = -1;
            edit_is_new = TRUE;
            CreateWindowExW(WS_EX_DLGMODALFRAME, EDIT_CLASS_NAME, L"GVT Cloud Client | Edit Connection",
                            WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU,
                            CW_USEDEFAULT, CW_USEDEFAULT, 880, 800,
                            hwnd, NULL, app_instance, NULL);
            return 0;
        case IDC_SETTINGS:
            CreateWindowExW(WS_EX_DLGMODALFRAME, SETTINGS_CLASS_NAME, L"GVT Cloud Client | Settings",
                            WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU,
                            CW_USEDEFAULT, CW_USEDEFAULT, 900, 920,
                            hwnd, NULL, app_instance, NULL);
            return 0;
        case IDC_HELP_BUTTON:
            MessageBoxW(hwnd, L"GVT Cloud Client\n\nSelect a saved desktop card or enter a server address and connect.",
                        L"GVT Cloud Client", MB_ICONINFORMATION);
            return 0;
        case IDC_MORE: {
            HMENU menu = CreatePopupMenu();
            RECT br;
            POINT pt;
            AppendMenuW(menu, MF_STRING, 1, L"Add Connection");
            AppendMenuW(menu, MF_STRING, 2, L"Settings");
            GetWindowRect(more_button, &br);
            pt.x = br.left;
            pt.y = br.bottom;
            int cmd = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON, pt.x, pt.y, 0, hwnd, NULL);
            DestroyMenu(menu);
            if (cmd == 1) SendMessageW(hwnd, WM_COMMAND, IDC_ADD_CONNECTION, 0);
            if (cmd == 2) SendMessageW(hwnd, WM_COMMAND, IDC_SETTINGS, 0);
            return 0;
        }
        }
        break;
    case WM_DRAWITEM:
        return draw_button_item(lp);
    case WM_DESTROY:
        KillTimer(hwnd, TIMER_RECONNECT_ID);
        update_tray_icon(FALSE);
        for (int i = 0; i < connection_count; i++) {
            close_viewer_handle(&connections[i]);
        }
        if (ui_font) DeleteObject(ui_font);
        if (title_font) DeleteObject(title_font);
        if (small_font) DeleteObject(small_font);
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE prev, PWSTR cmdline, int show)
{
    WNDCLASSW wc = {0};
    WNDCLASSW card_wc = {0};
    WNDCLASSW edit_wc = {0};
    WNDCLASSW settings_wc = {0};
    HWND hwnd;
    MSG msg;
    (void)prev;
    (void)cmdline;

    app_instance = instance;
    init_app_dir();
    InitCommonControls();
    load_settings();
    load_connections();

    wc.lpfnWndProc = window_proc;
    wc.hInstance = instance;
    wc.lpszClassName = L"GVTCloudClientWindow";
    wc.hCursor = LoadCursor(NULL, IDC_ARROW);
    wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    wc.hIcon = LoadIcon(NULL, IDI_APPLICATION);
    RegisterClassW(&wc);

    card_wc.lpfnWndProc = card_proc;
    card_wc.hInstance = instance;
    card_wc.lpszClassName = CARD_CLASS_NAME;
    card_wc.hCursor = LoadCursor(NULL, IDC_HAND);
    card_wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    RegisterClassW(&card_wc);

    edit_wc.lpfnWndProc = edit_proc;
    edit_wc.hInstance = instance;
    edit_wc.lpszClassName = EDIT_CLASS_NAME;
    edit_wc.hCursor = LoadCursor(NULL, IDC_ARROW);
    edit_wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    RegisterClassW(&edit_wc);

    settings_wc.lpfnWndProc = settings_proc;
    settings_wc.hInstance = instance;
    settings_wc.lpszClassName = SETTINGS_CLASS_NAME;
    settings_wc.hCursor = LoadCursor(NULL, IDC_ARROW);
    settings_wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    RegisterClassW(&settings_wc);

    hwnd = CreateWindowExW(0, wc.lpszClassName, L"GVT Cloud Client",
                           WS_OVERLAPPEDWINDOW,
                           CW_USEDEFAULT, CW_USEDEFAULT, 1180, 780,
                           NULL, NULL, instance, NULL);
    if (!hwnd) return 1;
    ShowWindow(hwnd, show);
    UpdateWindow(hwnd);

    while (GetMessageW(&msg, NULL, 0, 0)) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    return (int)msg.wParam;
}
