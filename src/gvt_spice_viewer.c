/*
 * GVT-g client prototype:
 * - keeps the existing gvt-stream RTP video path unchanged;
 * - embeds the GStreamer D3D11 video sink window into one Win32 client window;
 * - uses spice-client-glib from the installed VirtViewer runtime for audio and
 *   SPICE inputs, avoiding the QMP input proxy for this prototype.
 *
 * This is deliberately a small proof of direction before patching
 * virt-viewer/spice-gtk proper.
 */
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <windowsx.h>
#include <shellapi.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>

#define SPICE_CHANNEL_MAIN 1
#define SPICE_CHANNEL_DISPLAY 2
#define SPICE_CHANNEL_INPUTS 3
#define SPICE_CHANNEL_CURSOR 4
#define SPICE_CHANNEL_PLAYBACK 5
#define SPICE_CHANNEL_RECORD 6
#define SPICE_CHANNEL_OPENED 10
#define SPICE_CHANNEL_CLOSED 12

#define SPICE_MOUSE_BUTTON_LEFT 1
#define SPICE_MOUSE_BUTTON_MIDDLE 2
#define SPICE_MOUSE_BUTTON_RIGHT 3
#define SPICE_MOUSE_BUTTON_UP 4
#define SPICE_MOUSE_BUTTON_DOWN 5

#define SPICE_MOUSE_BUTTON_MASK_LEFT 1
#define SPICE_MOUSE_BUTTON_MASK_MIDDLE 2
#define SPICE_MOUSE_BUTTON_MASK_RIGHT 4

#define G_PRIORITY_HIGH (-100)
#define G_PRIORITY_DEFAULT_IDLE 200

#define ID_AUTO_SIZE 1001
#define WM_STREAM_READY (WM_APP + 1)
#define TOOLBAR_HEIGHT 32
#define WINDOW_FIT_PERCENT 94

typedef void *gpointer;
typedef int gboolean;
typedef unsigned int guint;
typedef int gint;
typedef void (*GCallback)(void);
typedef void (*GClosureNotify)(gpointer data, void *closure);
typedef void (*GDestroyNotify)(gpointer data);

static HMODULE glib, gobject, spice, gtk, spicegtk;
static void *(*p_spice_session_new)(void);
static gboolean (*p_spice_session_connect)(void *session);
static void (*p_spice_session_disconnect)(void *session);
static gboolean (*p_spice_channel_connect)(void *channel);
static void *(*p_spice_audio_get)(void *session, void *context);
static const char *(*p_spice_channel_type_to_string)(gint type);
static void (*p_spice_inputs_channel_position)(void *channel, gint x, gint y,
                                               gint display, gint button_state);
static void (*p_spice_inputs_channel_button_press)(void *channel, gint button,
                                                   gint button_state);
static void (*p_spice_inputs_channel_button_release)(void *channel, gint button,
                                                     gint button_state);
static void (*p_spice_inputs_channel_key_press)(void *channel, guint scancode);
static void (*p_spice_inputs_channel_key_release)(void *channel, guint scancode);

static void (*p_g_object_set)(gpointer object, const char *first_property_name, ...);
static void (*p_g_object_get)(gpointer object, const char *first_property_name, ...);
static void (*p_g_object_unref)(gpointer object);
static unsigned long (*p_g_signal_connect_data)(gpointer instance,
                                                const char *detailed_signal,
                                                GCallback c_handler,
                                                gpointer data,
                                                GClosureNotify destroy_data,
                                                int connect_flags);
static void *(*p_g_main_loop_new)(void *context, gboolean is_running);
static void (*p_g_main_loop_run)(void *loop);
static void (*p_g_main_loop_quit)(void *loop);
static void (*p_g_main_loop_unref)(void *loop);
static guint (*p_g_idle_add)(gboolean (*function)(gpointer), gpointer data);
static guint (*p_g_idle_add_full)(gint priority, gboolean (*function)(gpointer),
                                  gpointer data, GDestroyNotify notify);
static void (*p_gtk_init)(int *argc, char ***argv);
static void (*p_gtk_main)(void);
static void (*p_gtk_main_quit)(void);
static void *(*p_gtk_window_new)(gint type);
static void (*p_gtk_window_set_title)(void *window, const char *title);
static void (*p_gtk_window_set_default_size)(void *window, gint width, gint height);
static void (*p_gtk_container_add)(void *container, void *widget);
static void (*p_gtk_widget_show_all)(void *widget);
static void (*p_gtk_widget_set_size_request)(void *widget, gint width, gint height);
static void (*p_gtk_widget_queue_draw)(void *widget);
static void *(*p_spice_display_new)(void *session, gint id);

static HMODULE gstlib, gstvideo;
static void (*p_gst_init)(int *argc, char ***argv);
static void *(*p_gst_parse_launch)(const char *pipeline_description, void **error);
static int (*p_gst_element_set_state)(void *element, int state);
static void *(*p_gst_bin_get_by_name)(void *bin, const char *name);
static void (*p_gst_object_unref)(void *object);
static void (*p_gst_video_overlay_set_window_handle)(void *overlay,
                                                     uintptr_t handle);

static const char *spice_runtime = "C:\\Program Files\\VirtViewer v11.0-256\\bin";
static const char *gst_root = NULL;
static const char *spice_host = "192.168.0.188";
static const char *spice_port = "5900";
static char spice_port_storage[16];
static const char *native_input_host = "192.168.0.188";
static int native_input_port = 5905;
static bool native_input_enabled = true;
static int video_port = 5004;
static int video_latency = 15;
static bool video_drop_on_latency = false;
static const char *video_codec = "h264";
static const char *stream_control_host = NULL;
static int stream_control_port = 5004;
static bool stream_control_enabled = true;
static int source_width = 1920;
static int source_height = 1200;
static bool auto_size_on_start = true;
static bool spice_display_mode = false;
static void *display_mode_session;

static HWND main_hwnd;
static HWND video_hwnd;
static HWND auto_button;
static RECT video_rect;
static void *gst_pipeline;
static void *gst_sink;
static void *main_loop;
static void *inputs_channel;
static void *spice_audio_obj;
static bool inputs_ready;
static volatile LONG shutting_down;
static volatile LONG media_started;
static volatile LONG gst_started;
static LONG button_state;
static FILE *log_fp;
static CRITICAL_SECTION input_lock;
static bool input_lock_ready;
static bool pending_position_queued;
static bool pending_position_valid;
static int pending_position_x;
static int pending_position_y;
static int pending_position_buttons;
static CRITICAL_SECTION native_input_lock;
static bool native_input_lock_ready;
static SOCKET native_input_sock = INVALID_SOCKET;
static SOCKET stream_control_sock = INVALID_SOCKET;
static bool winsock_ready;
static ULONGLONG log_start_ms;

static char *dup_app_dir(void);
static void set_gst_environment(void);
static void layout_children(HWND hwnd);
static void resize_window_to_source(HWND hwnd);
static void native_input_close(void);
static void start_media_stack(HWND hwnd);
static int run_spice_display_mode(int argc, char **argv);

typedef enum {
    INPUT_EV_POSITION,
    INPUT_EV_BUTTON,
    INPUT_EV_WHEEL,
    INPUT_EV_KEY,
} InputEvType;

typedef struct InputEv {
    InputEvType type;
    int x;
    int y;
    int button;
    int button_state;
    bool down;
    guint scancode;
} InputEv;

static ULONGLONG viewer_now_ms(void)
{
    return (ULONGLONG)GetTickCount();
}

static void log_line(const char *fmt, ...)
{
    va_list ap;
    ULONGLONG now_ms = viewer_now_ms();

    if (!log_start_ms) {
        log_start_ms = now_ms;
    }
    if (!log_fp) {
        char *app_dir = dup_app_dir();
        char path[MAX_PATH * 2];
        snprintf(path, sizeof(path), "%s\\gvt_spice_viewer.log", app_dir);
        free(app_dir);
        log_fp = fopen(path, "a");
    }
    if (!log_fp) {
        return;
    }
    fprintf(log_fp, "+%I64ums ", (unsigned long long)(now_ms - log_start_ms));
    va_start(ap, fmt);
    vfprintf(log_fp, fmt, ap);
    va_end(ap);
    fputc('\n', log_fp);
    fflush(log_fp);
}

static bool input_debug(void)
{
    static int enabled = -1;

    if (enabled < 0) {
        enabled = GetEnvironmentVariableA("GVT_SPICE_VIEWER_INPUT_DEBUG",
                                          NULL, 0) > 0;
    }
    return enabled != 0;
}

static bool env_is_set(const char *name)
{
    return GetEnvironmentVariableA(name, NULL, 0) > 0;
}

static int getenv_int_clamped(const char *name, int defval, int minval, int maxval)
{
    char value[64];
    char *end = NULL;
    DWORD len;
    long parsed;

    len = GetEnvironmentVariableA(name, value, sizeof(value));
    if (!len || len >= sizeof(value)) {
        return defval;
    }

    parsed = strtol(value, &end, 10);
    if (end == value) {
        return defval;
    }
    if (parsed < minval) {
        return minval;
    }
    if (parsed > maxval) {
        return maxval;
    }
    return (int)parsed;
}

static bool audio_debug(void)
{
    return env_is_set("GVT_SPICE_VIEWER_AUDIO_DEBUG");
}

static bool input_transport_ready(void)
{
    return native_input_enabled || (inputs_channel && inputs_ready);
}

static void ensure_winsock(void)
{
    WSADATA data;

    if (!winsock_ready) {
        if (WSAStartup(MAKEWORD(2, 2), &data) == 0) {
            winsock_ready = true;
        }
    }
}

static void *sym(HMODULE module, const char *name)
{
    void *ptr = (void *)GetProcAddress(module, name);
    if (!ptr) {
        fprintf(stderr, "missing symbol: %s\n", name);
        ExitProcess(2);
    }
    return ptr;
}

static void load_spice_runtime(void)
{
    log_line("load_spice_runtime %s", spice_runtime);
    SetDllDirectoryA(spice_runtime);
    glib = LoadLibraryA("libglib-2.0-0.dll");
    gobject = LoadLibraryA("libgobject-2.0-0.dll");
    spice = LoadLibraryA("libspice-client-glib-2.0-8.dll");
    if (!glib || !gobject || !spice) {
        MessageBoxA(NULL, "Failed to load VirtViewer SPICE runtime DLLs",
                    "GVT SPICE Viewer", MB_ICONERROR);
        ExitProcess(2);
    }

    p_spice_session_new = sym(spice, "spice_session_new");
    p_spice_session_connect = sym(spice, "spice_session_connect");
    p_spice_session_disconnect = sym(spice, "spice_session_disconnect");
    p_spice_channel_connect = sym(spice, "spice_channel_connect");
    p_spice_audio_get = sym(spice, "spice_audio_get");
    p_spice_channel_type_to_string = sym(spice, "spice_channel_type_to_string");
    p_spice_inputs_channel_position = sym(spice, "spice_inputs_channel_position");
    p_spice_inputs_channel_button_press = sym(spice, "spice_inputs_channel_button_press");
    p_spice_inputs_channel_button_release = sym(spice, "spice_inputs_channel_button_release");
    p_spice_inputs_channel_key_press = sym(spice, "spice_inputs_channel_key_press");
    p_spice_inputs_channel_key_release = sym(spice, "spice_inputs_channel_key_release");

    p_g_object_set = sym(gobject, "g_object_set");
    p_g_object_get = sym(gobject, "g_object_get");
    p_g_object_unref = sym(gobject, "g_object_unref");
    p_g_signal_connect_data = sym(gobject, "g_signal_connect_data");
    p_g_main_loop_new = sym(glib, "g_main_loop_new");
    p_g_main_loop_run = sym(glib, "g_main_loop_run");
    p_g_main_loop_quit = sym(glib, "g_main_loop_quit");
    p_g_main_loop_unref = sym(glib, "g_main_loop_unref");
    p_g_idle_add = sym(glib, "g_idle_add");
    p_g_idle_add_full = sym(glib, "g_idle_add_full");
}

static void load_spice_gtk_runtime(void)
{
    load_spice_runtime();
    gtk = LoadLibraryA("libgtk-3-0.dll");
    spicegtk = LoadLibraryA("libspice-client-gtk-3.0-5.dll");
    if (!gtk || !spicegtk) {
        MessageBoxA(NULL, "Failed to load VirtViewer spice-client-gtk DLLs",
                    "GVT SPICE Viewer", MB_ICONERROR);
        ExitProcess(2);
    }

    p_gtk_init = sym(gtk, "gtk_init");
    p_gtk_main = sym(gtk, "gtk_main");
    p_gtk_main_quit = sym(gtk, "gtk_main_quit");
    p_gtk_window_new = sym(gtk, "gtk_window_new");
    p_gtk_window_set_title = sym(gtk, "gtk_window_set_title");
    p_gtk_window_set_default_size = sym(gtk, "gtk_window_set_default_size");
    p_gtk_container_add = sym(gtk, "gtk_container_add");
    p_gtk_widget_show_all = sym(gtk, "gtk_widget_show_all");
    p_gtk_widget_set_size_request = sym(gtk, "gtk_widget_set_size_request");
    p_gtk_widget_queue_draw = sym(gtk, "gtk_widget_queue_draw");
    p_spice_display_new = sym(spicegtk, "spice_display_new");
}

static bool native_input_connect_locked(void)
{
    struct sockaddr_in addr;
    u_long nonblock = 0;
    int one = 1;

    if (native_input_sock != INVALID_SOCKET) {
        return true;
    }

    ensure_winsock();
    if (!winsock_ready) {
        return false;
    }

    native_input_sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (native_input_sock == INVALID_SOCKET) {
        return false;
    }

    setsockopt(native_input_sock, IPPROTO_TCP, TCP_NODELAY,
               (const char *)&one, sizeof(one));
    ioctlsocket(native_input_sock, FIONBIO, &nonblock);

    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons((u_short)native_input_port);
    addr.sin_addr.s_addr = inet_addr(native_input_host);
    if (addr.sin_addr.s_addr == INADDR_NONE ||
        connect(native_input_sock, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        native_input_close();
        return false;
    }

    log_line("native input connected %s:%d", native_input_host,
             native_input_port);
    return true;
}

static void native_input_close(void)
{
    if (native_input_sock != INVALID_SOCKET) {
        closesocket(native_input_sock);
        native_input_sock = INVALID_SOCKET;
    }
}

static void stream_control_close(void)
{
    if (stream_control_sock != INVALID_SOCKET) {
        shutdown(stream_control_sock, SD_BOTH);
        closesocket(stream_control_sock);
        stream_control_sock = INVALID_SOCKET;
    }
}

static int json_get_int_field(const char *json, const char *key, int defval)
{
    char pattern[64];
    const char *p;

    snprintf(pattern, sizeof(pattern), "\"%s\"", key);
    p = strstr(json, pattern);
    if (!p) {
        return defval;
    }
    p = strchr(p, ':');
    if (!p) {
        return defval;
    }
    p++;
    while (*p == ' ' || *p == '\t') {
        p++;
    }
    return atoi(p);
}

static bool stream_control_read_line(char *buffer, size_t size)
{
    size_t used = 0;

    while (used + 1 < size) {
        char byte;
        int ret = recv(stream_control_sock, &byte, 1, 0);
        if (ret <= 0) {
            return false;
        }
        if (byte == '\n') {
            break;
        }
        buffer[used++] = byte;
    }
    buffer[used] = '\0';
    return used > 0;
}

static void stream_control_apply_status(const char *status)
{
    int returned_video;
    int returned_spice;
    int returned_input;

    if (!status || !*status) {
        return;
    }
    log_line("stream-control status %s", status);
    if (strstr(status, "\"ok\":false")) {
        return;
    }

    returned_video = json_get_int_field(status, "video_udp", 0);
    returned_spice = json_get_int_field(status, "spice_tcp", 0);
    returned_input = json_get_int_field(status, "input_tcp", 0);

    if (returned_video > 0 && returned_video <= 65535) {
        video_port = returned_video;
    }
    if (returned_spice > 0 && returned_spice <= 65535) {
        snprintf(spice_port_storage, sizeof(spice_port_storage), "%d",
                 returned_spice);
        spice_port = spice_port_storage;
    }
    if (returned_input > 0 && returned_input <= 65535) {
        native_input_port = returned_input;
        native_input_enabled = true;
    }
    log_line("stream-control using ports video_udp=%d spice_tcp=%s input_tcp=%d",
             video_port, spice_port, native_input_port);
}

static bool stream_control_start_session(void)
{
    struct sockaddr_in addr;
    const char *host = stream_control_host ? stream_control_host : spice_host;
    char hello[256];
    char status[512];
    int one = 1;
    DWORD timeout_ms = 1500;
    DWORD no_timeout = 0;
    ULONGLONG t0 = viewer_now_ms();
    ULONGLONG t_stage;

    log_line("stream-control begin host=%s port=%d",
             host ? host : "", stream_control_port);
    if (!stream_control_enabled || !host || !*host || stream_control_port <= 0) {
        log_line("stream-control skipped enabled=%d host=%s port=%d",
                 stream_control_enabled, host ? host : "", stream_control_port);
        return false;
    }

    t_stage = viewer_now_ms();
    ensure_winsock();
    log_line("stream-control winsock ready=%d dt=%I64ums",
             winsock_ready,
             (unsigned long long)(viewer_now_ms() - t_stage));
    if (!winsock_ready) {
        log_line("stream-control disabled: WSAStartup failed");
        return false;
    }

    t_stage = viewer_now_ms();
    stream_control_sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (stream_control_sock == INVALID_SOCKET) {
        log_line("stream-control socket failed: %d", WSAGetLastError());
        return false;
    }
    log_line("stream-control socket-created dt=%I64ums",
             (unsigned long long)(viewer_now_ms() - t_stage));

    setsockopt(stream_control_sock, IPPROTO_TCP, TCP_NODELAY,
               (const char *)&one, sizeof(one));
    setsockopt(stream_control_sock, SOL_SOCKET, SO_RCVTIMEO,
               (const char *)&timeout_ms, sizeof(timeout_ms));
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons((u_short)stream_control_port);
    addr.sin_addr.s_addr = inet_addr(host);
    t_stage = viewer_now_ms();
    if (addr.sin_addr.s_addr == INADDR_NONE ||
        connect(stream_control_sock, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        log_line("stream-control connect %s:%d failed: %d",
                 host, stream_control_port, WSAGetLastError());
        stream_control_close();
        return false;
    }
    log_line("stream-control connect-ok dt=%I64ums",
             (unsigned long long)(viewer_now_ms() - t_stage));

    snprintf(hello, sizeof(hello),
             "{\"type\":\"start\",\"video_port\":%d,\"codec\":\"%s\"}\n",
             video_port, video_codec ? video_codec : "h265");
    t_stage = viewer_now_ms();
    if (send(stream_control_sock, hello, (int)strlen(hello), 0) <= 0) {
        log_line("stream-control hello send failed: %d", WSAGetLastError());
        stream_control_close();
        return false;
    }
    log_line("stream-control hello-sent dt=%I64ums bytes=%u",
             (unsigned long long)(viewer_now_ms() - t_stage),
             (unsigned)strlen(hello));
    log_line("stream-control connected %s:%d video_port=%d codec=%s",
             host, stream_control_port, video_port,
             video_codec ? video_codec : "h265");

    t_stage = viewer_now_ms();
    if (stream_control_read_line(status, sizeof(status))) {
        log_line("stream-control status-read dt=%I64ums",
                 (unsigned long long)(viewer_now_ms() - t_stage));
        stream_control_apply_status(status);
    } else {
        log_line("stream-control did not return port status after %I64ums, using local ports",
                 (unsigned long long)(viewer_now_ms() - t_stage));
    }
    setsockopt(stream_control_sock, SOL_SOCKET, SO_RCVTIMEO,
               (const char *)&no_timeout, sizeof(no_timeout));
    log_line("stream-control ready total=%I64ums",
             (unsigned long long)(viewer_now_ms() - t0));
    return true;
}

static DWORD WINAPI stream_control_thread(LPVOID opaque)
{
    char byte;
    bool connected;

    (void)opaque;
    connected = stream_control_start_session();
    if (main_hwnd) {
        PostMessageA(main_hwnd, WM_STREAM_READY, connected ? 1 : 0, 0);
    }
    if (stream_control_sock == INVALID_SOCKET) {
        return 0;
    }

    while (InterlockedCompareExchange(&shutting_down, 0, 0) == 0) {
        int ret = recv(stream_control_sock, &byte, 1, 0);
        if (ret == 0) {
            log_line("stream-control server closed session");
            break;
        }
        if (ret < 0) {
            int err = WSAGetLastError();
            if (err == WSAEINTR) {
                continue;
            }
            log_line("stream-control recv failed: %d", err);
            break;
        }
    }
    stream_control_close();
    return 0;
}

static void native_input_send_json(const char *json)
{
    int len;
    int ret;

    if (!native_input_enabled || !native_input_lock_ready || !json) {
        return;
    }

    EnterCriticalSection(&native_input_lock);
    if (!native_input_connect_locked()) {
        LeaveCriticalSection(&native_input_lock);
        return;
    }

    len = (int)strlen(json);
    ret = send(native_input_sock, json, len, 0);
    if (ret != len || send(native_input_sock, "\n", 1, 0) != 1) {
        native_input_close();
    }
    LeaveCriticalSection(&native_input_lock);
}

static const char *native_button_name(int button)
{
    switch (button) {
    case SPICE_MOUSE_BUTTON_LEFT:
        return "left";
    case SPICE_MOUSE_BUTTON_MIDDLE:
        return "middle";
    case SPICE_MOUSE_BUTTON_RIGHT:
        return "right";
    case SPICE_MOUSE_BUTTON_UP:
        return "wheel-up";
    case SPICE_MOUSE_BUTTON_DOWN:
        return "wheel-down";
    default:
        return "left";
    }
}

static const char *qcode_from_scancode(guint scancode)
{
    switch (scancode) {
    case 0x01: return "esc";
    case 0x02: return "1";
    case 0x03: return "2";
    case 0x04: return "3";
    case 0x05: return "4";
    case 0x06: return "5";
    case 0x07: return "6";
    case 0x08: return "7";
    case 0x09: return "8";
    case 0x0a: return "9";
    case 0x0b: return "0";
    case 0x0c: return "minus";
    case 0x0d: return "equal";
    case 0x0e: return "backspace";
    case 0x0f: return "tab";
    case 0x10: return "q";
    case 0x11: return "w";
    case 0x12: return "e";
    case 0x13: return "r";
    case 0x14: return "t";
    case 0x15: return "y";
    case 0x16: return "u";
    case 0x17: return "i";
    case 0x18: return "o";
    case 0x19: return "p";
    case 0x1a: return "bracket_left";
    case 0x1b: return "bracket_right";
    case 0x1c: return "ret";
    case 0x1d: return "ctrl";
    case 0x1e: return "a";
    case 0x1f: return "s";
    case 0x20: return "d";
    case 0x21: return "f";
    case 0x22: return "g";
    case 0x23: return "h";
    case 0x24: return "j";
    case 0x25: return "k";
    case 0x26: return "l";
    case 0x27: return "semicolon";
    case 0x28: return "apostrophe";
    case 0x29: return "grave_accent";
    case 0x2a: return "shift";
    case 0x2b: return "backslash";
    case 0x2c: return "z";
    case 0x2d: return "x";
    case 0x2e: return "c";
    case 0x2f: return "v";
    case 0x30: return "b";
    case 0x31: return "n";
    case 0x32: return "m";
    case 0x33: return "comma";
    case 0x34: return "dot";
    case 0x35: return "slash";
    case 0x36: return "shift_r";
    case 0x37: return "asterisk";
    case 0x38: return "alt";
    case 0x39: return "spc";
    case 0x3a: return "caps_lock";
    case 0x3b: return "f1";
    case 0x3c: return "f2";
    case 0x3d: return "f3";
    case 0x3e: return "f4";
    case 0x3f: return "f5";
    case 0x40: return "f6";
    case 0x41: return "f7";
    case 0x42: return "f8";
    case 0x43: return "f9";
    case 0x44: return "f10";
    case 0x57: return "f11";
    case 0x58: return "f12";
    case 0x11c: return "kp_enter";
    case 0x11d: return "ctrl_r";
    case 0x135: return "kp_divide";
    case 0x138: return "alt_r";
    case 0x147: return "home";
    case 0x148: return "up";
    case 0x149: return "pgup";
    case 0x14b: return "left";
    case 0x14d: return "right";
    case 0x14f: return "end";
    case 0x150: return "down";
    case 0x151: return "pgdn";
    case 0x152: return "insert";
    case 0x153: return "delete";
    default:
        return NULL;
    }
}

static bool dispatch_native_input_event(InputEv *ev)
{
    char json[256];
    const char *qcode;

    if (!native_input_enabled) {
        return false;
    }

    switch (ev->type) {
    case INPUT_EV_POSITION:
        snprintf(json, sizeof(json),
                 "{\"type\":\"move\",\"x\":%d,\"y\":%d}", ev->x, ev->y);
        native_input_send_json(json);
        return true;
    case INPUT_EV_BUTTON:
        snprintf(json, sizeof(json),
                 "{\"type\":\"button\",\"button\":\"%s\",\"down\":%s}",
                 native_button_name(ev->button), ev->down ? "true" : "false");
        native_input_send_json(json);
        return true;
    case INPUT_EV_WHEEL:
        snprintf(json, sizeof(json),
                 "{\"type\":\"wheel\",\"delta\":%d}",
                 ev->button == SPICE_MOUSE_BUTTON_UP ? 1 : -1);
        native_input_send_json(json);
        return true;
    case INPUT_EV_KEY:
        qcode = qcode_from_scancode(ev->scancode);
        if (!qcode) {
            return true;
        }
        snprintf(json, sizeof(json),
                 "{\"type\":\"key\",\"qcode\":\"%s\",\"down\":%s}",
                 qcode, ev->down ? "true" : "false");
        native_input_send_json(json);
        return true;
    }

    return true;
}

static void dispatch_input_event(InputEv *ev)
{
    static unsigned int sent_count;

    if (dispatch_native_input_event(ev)) {
        return;
    }

    if (!inputs_channel || !inputs_ready) {
        if (input_debug()) {
            log_line("input drop on spice thread: inputs channel not ready");
        }
        return;
    }

    sent_count++;
    switch (ev->type) {
    case INPUT_EV_POSITION:
        if (input_debug() &&
            (sent_count <= 80 || (sent_count % 120) == 0)) {
            log_line("input send position x=%d y=%d buttons=%d", ev->x, ev->y,
                     ev->button_state);
        }
        p_spice_inputs_channel_position(inputs_channel, ev->x, ev->y, 0,
                                        ev->button_state);
        break;
    case INPUT_EV_BUTTON:
        if (input_debug()) {
            log_line("input send button button=%d state=%d down=%d", ev->button,
                     ev->button_state, ev->down);
        }
        if (ev->down) {
            p_spice_inputs_channel_button_press(inputs_channel, ev->button,
                                                ev->button_state);
        } else {
            p_spice_inputs_channel_button_release(inputs_channel, ev->button,
                                                  ev->button_state);
        }
        break;
    case INPUT_EV_WHEEL:
        if (input_debug()) {
            log_line("input send wheel button=%d state=%d", ev->button,
                     ev->button_state);
        }
        p_spice_inputs_channel_button_press(inputs_channel, ev->button,
                                            ev->button_state);
        p_spice_inputs_channel_button_release(inputs_channel, ev->button,
                                              ev->button_state);
        break;
    case INPUT_EV_KEY:
        if (input_debug()) {
            log_line("input send key scancode=0x%x down=%d", ev->scancode,
                     ev->down);
        }
        if (ev->down) {
            p_spice_inputs_channel_key_press(inputs_channel, ev->scancode);
        } else {
            p_spice_inputs_channel_key_release(inputs_channel, ev->scancode);
        }
        break;
    }
}

static gboolean send_input_on_spice_thread(gpointer opaque)
{
    InputEv *ev = opaque;

    dispatch_input_event(ev);

    free(ev);
    return 0;
}

static gboolean send_pending_position_on_spice_thread(gpointer opaque)
{
    InputEv ev = { 0 };
    bool have_position = false;
    (void)opaque;

    if (input_lock_ready) {
        EnterCriticalSection(&input_lock);
        if (pending_position_valid) {
            ev.type = INPUT_EV_POSITION;
            ev.x = pending_position_x;
            ev.y = pending_position_y;
            ev.button_state = pending_position_buttons;
            pending_position_valid = false;
            have_position = true;
        }
        pending_position_queued = false;
        LeaveCriticalSection(&input_lock);
    }

    if (have_position) {
        dispatch_input_event(&ev);
    }
    return 0;
}

static void queue_input_event_priority(InputEv *ev, gint priority)
{
    if (!p_g_idle_add || !input_transport_ready()) {
        free(ev);
        return;
    }
    if (p_g_idle_add_full) {
        p_g_idle_add_full(priority, send_input_on_spice_thread, ev, NULL);
    } else {
        p_g_idle_add(send_input_on_spice_thread, ev);
    }
}

static void queue_pending_position(int sx, int sy, int buttons)
{
    bool should_queue = false;

    if (!p_g_idle_add || !input_transport_ready() || !input_lock_ready) {
        return;
    }

    EnterCriticalSection(&input_lock);
    pending_position_x = sx;
    pending_position_y = sy;
    pending_position_buttons = buttons;
    pending_position_valid = true;
    if (!pending_position_queued) {
        pending_position_queued = true;
        should_queue = true;
    }
    LeaveCriticalSection(&input_lock);

    if (should_queue) {
        if (p_g_idle_add_full) {
            p_g_idle_add_full(G_PRIORITY_DEFAULT_IDLE,
                              send_pending_position_on_spice_thread,
                              NULL, NULL);
        } else {
            p_g_idle_add(send_pending_position_on_spice_thread, NULL);
        }
    }
}

static void queue_position_event(int sx, int sy, int buttons, gint priority)
{
    InputEv *ev = calloc(1, sizeof(*ev));

    ev->type = INPUT_EV_POSITION;
    ev->x = sx;
    ev->y = sy;
    ev->button_state = buttons;
    queue_input_event_priority(ev, priority);
}

static void load_gst_runtime(void)
{
    char bin[MAX_PATH * 2];

    if (gstlib && gstvideo) {
        return;
    }

    snprintf(bin, sizeof(bin), "%s\\bin", gst_root);
    log_line("load_gst_runtime %s", bin);
    SetDllDirectoryA(bin);
    gstlib = LoadLibraryA("libgstreamer-1.0-0.dll");
    gstvideo = LoadLibraryA("libgstvideo-1.0-0.dll");
    if (!gstlib || !gstvideo) {
        MessageBoxA(main_hwnd, "Failed to load GStreamer runtime DLLs",
                    "GVT SPICE Viewer", MB_ICONERROR);
        ExitProcess(2);
    }

    p_gst_init = sym(gstlib, "gst_init");
    p_gst_parse_launch = sym(gstlib, "gst_parse_launch");
    p_gst_element_set_state = sym(gstlib, "gst_element_set_state");
    p_gst_bin_get_by_name = sym(gstlib, "gst_bin_get_by_name");
    p_gst_object_unref = sym(gstlib, "gst_object_unref");
    p_gst_video_overlay_set_window_handle =
        sym(gstvideo, "gst_video_overlay_set_window_handle");
}

static void channel_event(void *channel, gint event, void *opaque)
{
    gint type = 0;
    gint id = 0;
    const char *name;
    (void)opaque;

    p_g_object_get(channel, "channel-type", &type, "channel-id", &id, NULL);
    name = p_spice_channel_type_to_string(type);
    log_line("SPICE channel-event type=%d(%s) id=%d event=%d",
             type, name ? name : "?", id, event);
    if (type == SPICE_CHANNEL_INPUTS && event == SPICE_CHANNEL_OPENED) {
        inputs_channel = channel;
        inputs_ready = true;
        SetWindowTextA(main_hwnd, "GVT SPICE Viewer - inputs ready");
    } else if (event >= SPICE_CHANNEL_CLOSED) {
        if (type == SPICE_CHANNEL_INPUTS) {
            inputs_channel = NULL;
            inputs_ready = false;
        }
        if (main_loop && InterlockedCompareExchange(&shutting_down, 0, 0) == 0) {
            log_line("SPICE channel closed, scheduling reconnect");
            p_g_main_loop_quit(main_loop);
        }
    }
}

static void playback_start_cb(void *channel, gint format, gint channels,
                              gint frequency, void *opaque)
{
    (void)channel;
    (void)opaque;
    if (audio_debug()) {
        log_line("SPICE playback-start format=%d channels=%d frequency=%d",
                 format, channels, frequency);
    }
}

static void playback_data_cb(void *channel, gpointer audio, gint size,
                             void *opaque)
{
    static unsigned int chunks;
    static unsigned long long bytes;
    (void)channel;
    (void)audio;
    (void)opaque;

    chunks++;
    bytes += size > 0 ? (unsigned int)size : 0;
    if (audio_debug() && (chunks <= 5 || (chunks % 200) == 0)) {
        log_line("SPICE playback-data chunks=%u bytes=%I64u last=%d",
                 chunks, bytes, size);
    }
}

static void playback_stop_cb(void *channel, void *opaque)
{
    (void)channel;
    (void)opaque;
    if (audio_debug()) {
        log_line("SPICE playback-stop");
    }
}

static void channel_new(void *session, void *channel, void *opaque)
{
    gint type = 0;
    gint id = 0;
    const char *name;
    (void)session;
    (void)opaque;

    p_g_object_get(channel, "channel-type", &type, "channel-id", &id, NULL);
    name = p_spice_channel_type_to_string(type);
    log_line("SPICE channel-new type=%d(%s) id=%d", type, name ? name : "?", id);
    printf("SPICE channel-new type=%d(%s) id=%d\n", type, name ? name : "?", id);
    p_g_signal_connect_data(channel, "channel-event", (GCallback)channel_event,
                            NULL, NULL, 0);
    if (type == SPICE_CHANNEL_PLAYBACK) {
        p_g_signal_connect_data(channel, "playback-start",
                                (GCallback)playback_start_cb, NULL, NULL, 0);
        p_g_signal_connect_data(channel, "playback-data",
                                (GCallback)playback_data_cb, NULL, NULL, 0);
        p_g_signal_connect_data(channel, "playback-stop",
                                (GCallback)playback_stop_cb, NULL, NULL, 0);
    }
    if (type == SPICE_CHANNEL_INPUTS) {
        inputs_channel = channel;
        inputs_ready = false;
        SetWindowTextA(main_hwnd, "GVT SPICE Viewer - waiting for inputs");
        log_line("SPICE inputs connect requested");
        p_spice_channel_connect(channel);
    }
}

static void display_channel_new(void *session, void *channel, void *opaque)
{
    gint type = 0;
    gint id = 0;
    const char *name;
    (void)session;
    (void)opaque;

    p_g_object_get(channel, "channel-type", &type, "channel-id", &id, NULL);
    name = p_spice_channel_type_to_string(type);
    log_line("SPICE display-mode channel-new type=%d(%s) id=%d",
             type, name ? name : "?", id);
    p_g_signal_connect_data(channel, "channel-event", (GCallback)channel_event,
                            NULL, NULL, 0);
    if (type == SPICE_CHANNEL_INPUTS ||
        type == SPICE_CHANNEL_DISPLAY ||
        type == SPICE_CHANNEL_CURSOR ||
        type == SPICE_CHANNEL_PLAYBACK ||
        type == SPICE_CHANNEL_RECORD) {
        p_spice_channel_connect(channel);
    }
}

static DWORD WINAPI spice_thread(LPVOID opaque)
{
    (void)opaque;

    if (!spice) {
        load_spice_runtime();
    }
    log_line("spice thread start host=%s port=%s", spice_host, spice_port);

    while (InterlockedCompareExchange(&shutting_down, 0, 0) == 0) {
        void *session;
        void *loop;

        inputs_channel = NULL;
        inputs_ready = false;
        spice_audio_obj = NULL;

        session = p_spice_session_new();
        p_g_object_set(session, "host", spice_host, "port", spice_port, NULL);
        p_g_signal_connect_data(session, "channel-new", (GCallback)channel_new,
                                NULL, NULL, 0);
        spice_audio_obj = p_spice_audio_get(session, NULL);
        log_line("spice_audio_get returned %p", spice_audio_obj);
        loop = p_g_main_loop_new(NULL, 0);
        main_loop = loop;
        if (!p_spice_session_connect(session)) {
            log_line("spice_session_connect failed; retrying");
        } else {
            log_line("spice_session_connect ok, entering main loop");
            p_g_main_loop_run(loop);
        }

        if (main_loop == loop) {
            main_loop = NULL;
        }
        inputs_channel = NULL;
        inputs_ready = false;
        spice_audio_obj = NULL;

        if (p_g_main_loop_unref) {
            p_g_main_loop_unref(loop);
        }
        if (p_g_object_unref) {
            p_g_object_unref(session);
        }

        if (InterlockedCompareExchange(&shutting_down, 0, 0) == 0) {
            log_line("SPICE reconnect in 1000 ms");
            Sleep(1000);
        }
    }
    return 0;
}

static void gtk_destroy_cb(void *widget, void *opaque)
{
    (void)widget;
    (void)opaque;
    if (display_mode_session && p_spice_session_disconnect) {
        log_line("spice display disconnect on destroy");
        p_spice_session_disconnect(display_mode_session);
    }
    if (p_gtk_main_quit) {
        p_gtk_main_quit();
    }
}

static gboolean gtk_queue_draw_idle(gpointer opaque)
{
    if (opaque && p_gtk_widget_queue_draw) {
        p_gtk_widget_queue_draw(opaque);
    }
    return 0;
}

static int run_spice_display_mode(int argc, char **argv)
{
    void *session;
    void *window;
    void *display;
    char title[256];
    int window_w = source_width > 0 ? source_width : 1024;
    int window_h = source_height > 0 ? source_height : 768;

    load_spice_gtk_runtime();
    log_line("spice display mode host=%s port=%s", spice_host, spice_port);
    p_gtk_init(&argc, &argv);

    session = p_spice_session_new();
    display_mode_session = session;
    p_g_object_set(session, "host", spice_host, "port", spice_port, NULL);
    p_g_signal_connect_data(session, "channel-new",
                            (GCallback)display_channel_new,
                            NULL, NULL, 0);
    spice_audio_obj = p_spice_audio_get(session, NULL);
    log_line("spice display audio=%p", spice_audio_obj);

    window = p_gtk_window_new(0);
    snprintf(title, sizeof(title), "GVT SPICE Install Console - %s:%s",
             spice_host, spice_port);
    p_gtk_window_set_title(window, title);
    if (window_w > 1280) {
        window_w = 1280;
    }
    if (window_h > 900) {
        window_h = 900;
    }
    if (window_w < 640) {
        window_w = 640;
    }
    if (window_h < 480) {
        window_h = 480;
    }
    p_gtk_window_set_default_size(window, window_w, window_h);
    p_g_signal_connect_data(window, "destroy", (GCallback)gtk_destroy_cb,
                            NULL, NULL, 0);

    display = p_spice_display_new(session, 0);
    if (!display) {
        MessageBoxA(NULL, "Failed to create SPICE display widget",
                    "GVT SPICE Viewer", MB_ICONERROR);
        return 2;
    }
    p_gtk_widget_set_size_request(display, 640, 480);
    p_gtk_container_add(window, display);
    p_gtk_widget_show_all(window);

    if (!p_spice_session_connect(session)) {
        MessageBoxA(NULL, "Failed to connect SPICE install console",
                    "GVT SPICE Viewer", MB_ICONERROR);
        return 3;
    }
    p_g_idle_add(gtk_queue_draw_idle, display);
    p_gtk_main();
    if (display_mode_session == session) {
        display_mode_session = NULL;
    }
    if (p_g_object_unref) {
        p_g_object_unref(session);
    }
    return 0;
}

static char *dup_app_dir(void)
{
    char path[MAX_PATH];
    char *slash;
    GetModuleFileNameA(NULL, path, sizeof(path));
    slash = strrchr(path, '\\');
    if (slash) {
        *slash = 0;
    }
    return _strdup(path);
}

static void set_gst_environment(void)
{
    char *app_dir = dup_app_dir();
    char root[MAX_PATH * 2];
    char bin[MAX_PATH * 2];
    char plugins[MAX_PATH * 2];
    char registry[MAX_PATH * 2];
    char old_path[32768];
    char new_path[32768];
    char audio_sink[1024];
    int audio_buffer_us = getenv_int_clamped("GVT_SPICE_AUDIO_BUFFER_US",
                                             120000, 20000, 1000000);
    int audio_latency_us = getenv_int_clamped("GVT_SPICE_AUDIO_LATENCY_US",
                                              30000, 5000, 500000);

    if (!gst_root) {
        snprintf(root, sizeof(root),
                 "%s\\..\\..\\tools\\gstreamer-1.0-mingw-x86_64-1.18.6\\gstreamer\\1.0\\mingw_x86_64",
                 app_dir);
        gst_root = _strdup(root);
    }
    snprintf(bin, sizeof(bin), "%s\\bin", gst_root);
    snprintf(plugins, sizeof(plugins), "%s\\lib\\gstreamer-1.0", gst_root);
    snprintf(registry, sizeof(registry), "%s\\..\\..\\..\\gst-registry-gvt-spice-viewer.bin", gst_root);

    GetEnvironmentVariableA("PATH", old_path, sizeof(old_path));
    snprintf(new_path, sizeof(new_path), "%s;%s", bin, old_path);
    SetEnvironmentVariableA("PATH", new_path);
    SetEnvironmentVariableA("GST_PLUGIN_PATH", plugins);
    SetEnvironmentVariableA("GST_PLUGIN_SYSTEM_PATH_1_0", plugins);
    SetEnvironmentVariableA("GST_REGISTRY", registry);
    if (!env_is_set("SPICE_GST_AUDIOSINK")) {
        snprintf(audio_sink, sizeof(audio_sink),
            "appsrc is-live=1 do-timestamp=0 format=time "
            "caps=\"audio/x-raw,format=S16LE,channels=2,rate=48000,layout=interleaved\" "
            "name=\"appsrc\" ! queue max-size-time=200000000 max-size-buffers=0 max-size-bytes=0 "
            "! audioconvert ! audioresample "
            "! directsoundsink name=\"audiosink\" sync=false async=false "
            "buffer-time=%d latency-time=%d",
            audio_buffer_us, audio_latency_us);
        SetEnvironmentVariableA("SPICE_GST_AUDIOSINK", audio_sink);
        log_line("SPICE audio sink buffer_us=%d latency_us=%d",
                 audio_buffer_us, audio_latency_us);
    }
    free(app_dir);
}

static bool start_gst_receiver(void)
{
    char desc[4096];
    void *error = NULL;
    bool use_h265 = !strcmp(video_codec, "h265") || !strcmp(video_codec, "hevc");
    ULONGLONG t_stage;

    t_stage = viewer_now_ms();
    set_gst_environment();
    log_line("gst receiver set-env dt=%I64ums",
             (unsigned long long)(viewer_now_ms() - t_stage));
    t_stage = viewer_now_ms();
    load_gst_runtime();
    log_line("gst receiver load-runtime dt=%I64ums",
             (unsigned long long)(viewer_now_ms() - t_stage));
    log_line("gst_init");
    t_stage = viewer_now_ms();
    p_gst_init(NULL, NULL);
    log_line("gst receiver gst-init dt=%I64ums",
             (unsigned long long)(viewer_now_ms() - t_stage));

    if (use_h265) {
        snprintf(desc, sizeof(desc),
                 "udpsrc port=%d buffer-size=4194304 "
                 "caps=\"application/x-rtp, media=(string)video, clock-rate=(int)90000, encoding-name=(string)H265, payload=(int)96, ssrc=(uint)2222\" "
                 "! rtpjitterbuffer latency=%d drop-on-latency=%s do-lost=true faststart-min-packets=1 max-dropout-time=200 max-misorder-time=50 "
                 "! rtph265depay ! h265parse ! d3d11h265dec "
                 "! d3d11videosink name=vsink sync=false",
                 video_port, video_latency, video_drop_on_latency ? "true" : "false");
    } else {
        snprintf(desc, sizeof(desc),
                 "udpsrc port=%d buffer-size=4194304 "
                 "caps=\"application/x-rtp, media=(string)video, clock-rate=(int)90000, encoding-name=(string)H264, payload=(int)96, ssrc=(uint)2222\" "
                 "! rtpjitterbuffer latency=%d drop-on-latency=%s do-lost=true faststart-min-packets=1 max-dropout-time=200 max-misorder-time=50 "
                 "! rtph264depay ! h264parse ! d3d11h264dec "
                 "! d3d11videosink name=vsink sync=false",
                 video_port, video_latency, video_drop_on_latency ? "true" : "false");
    }

    t_stage = viewer_now_ms();
    gst_pipeline = p_gst_parse_launch(desc, &error);
    log_line("gst receiver parse-launch dt=%I64ums",
             (unsigned long long)(viewer_now_ms() - t_stage));
    if (!gst_pipeline) {
        log_line("gst_parse_launch failed");
        MessageBoxA(main_hwnd, "Failed to create GStreamer RTP pipeline",
                    "GVT SPICE Viewer", MB_ICONERROR);
        return false;
    }
    gst_sink = p_gst_bin_get_by_name(gst_pipeline, "vsink");
    if (!gst_sink) {
        log_line("gst sink not found");
        MessageBoxA(main_hwnd, "Failed to find GStreamer video sink",
                    "GVT SPICE Viewer", MB_ICONERROR);
        return false;
    }
    p_gst_video_overlay_set_window_handle(gst_sink, (uintptr_t)video_hwnd);
    log_line("gst set window=%p", video_hwnd);
    t_stage = viewer_now_ms();
    log_line("gst set playing ret=%d", p_gst_element_set_state(gst_pipeline, 4));
    log_line("gst receiver set-playing dt=%I64ums",
             (unsigned long long)(viewer_now_ms() - t_stage));
    return true;
}

static void send_position_from_lparam_priority(LPARAM lparam, gint priority,
                                               bool coalesce)
{
    RECT rc;
    int w, h, x, y, sx, sy;
    static unsigned int pos_count;

    if (!input_transport_ready()) {
        if (input_debug()) {
            log_line("input local position drop: no inputs channel");
        }
        return;
    }
    rc = video_rect;
    w = max(1, rc.right - rc.left - 1);
    h = max(1, rc.bottom - rc.top - 1);
    x = max(0, min(w, GET_X_LPARAM(lparam) - rc.left));
    y = max(0, min(h, GET_Y_LPARAM(lparam) - rc.top));
    sx = (int)((int64_t)x * 0x7fff / w);
    sy = (int)((int64_t)y * 0x7fff / h);
    pos_count++;
    if (input_debug() && (pos_count <= 40 || (pos_count % 120) == 0)) {
        log_line("input local position x=%d y=%d scaled=%d,%d client=%dx%d",
                 x, y, sx, sy, w + 1, h + 1);
    }
    if (coalesce) {
        queue_pending_position(sx, sy, button_state);
    } else {
        queue_position_event(sx, sy, button_state, priority);
    }
}

static void send_position_from_lparam(LPARAM lparam)
{
    send_position_from_lparam_priority(lparam, G_PRIORITY_DEFAULT_IDLE, true);
}

static guint scancode_from_lparam(LPARAM lparam)
{
    guint scancode = (HIWORD(lparam) & 0xff);
    if (HIWORD(lparam) & KF_EXTENDED) {
        scancode |= 0x100;
    }
    return scancode;
}

static RECT initial_window_rect(void)
{
    RECT work;
    RECT wr;
    int content_w = source_width;
    int content_h = source_height + TOOLBAR_HEIGHT;
    int max_w;
    int max_h;
    double scale = 1.0;

    SystemParametersInfoA(SPI_GETWORKAREA, 0, &work, 0);
    max_w = max(320, (work.right - work.left) * WINDOW_FIT_PERCENT / 100);
    max_h = max(240, (work.bottom - work.top) * WINDOW_FIT_PERCENT / 100);

    wr.left = 0;
    wr.top = 0;
    wr.right = content_w;
    wr.bottom = content_h;
    AdjustWindowRectEx(&wr, WS_OVERLAPPEDWINDOW, FALSE, 0);

    if (wr.right - wr.left > max_w) {
        scale = (double)max_w / (double)(wr.right - wr.left);
    }
    if ((wr.bottom - wr.top) * scale > max_h) {
        scale = (double)max_h / (double)(wr.bottom - wr.top);
    }
    if (scale < 1.0) {
        content_w = max(320, (int)(content_w * scale));
        content_h = TOOLBAR_HEIGHT +
                    max(180, (int)(source_height * scale));
        wr.left = 0;
        wr.top = 0;
        wr.right = content_w;
        wr.bottom = content_h;
        AdjustWindowRectEx(&wr, WS_OVERLAPPEDWINDOW, FALSE, 0);
    }

    OffsetRect(&wr,
               work.left + ((work.right - work.left) - (wr.right - wr.left)) / 2,
               work.top + ((work.bottom - work.top) - (wr.bottom - wr.top)) / 2);
    return wr;
}

static void layout_children(HWND hwnd)
{
    RECT rc;
    int client_w;
    int client_h;
    int avail_h;
    int video_w;
    int video_h;
    int video_x;
    int video_y;
    int button_w = 64;
    int button_h = 24;

    GetClientRect(hwnd, &rc);
    client_w = max(1, rc.right - rc.left);
    client_h = max(1, rc.bottom - rc.top);
    avail_h = max(1, client_h - TOOLBAR_HEIGHT);

    if ((int64_t)client_w * source_height <= (int64_t)avail_h * source_width) {
        video_w = client_w;
        video_h = (int)((int64_t)client_w * source_height / source_width);
    } else {
        video_h = avail_h;
        video_w = (int)((int64_t)avail_h * source_width / source_height);
    }

    video_x = (client_w - video_w) / 2;
    video_y = TOOLBAR_HEIGHT + (avail_h - video_h) / 2;
    video_rect.left = video_x;
    video_rect.top = video_y;
    video_rect.right = video_x + video_w;
    video_rect.bottom = video_y + video_h;

    if (auto_button) {
        MoveWindow(auto_button, client_w - button_w - 8, 4,
                   button_w, button_h, TRUE);
    }
    if (video_hwnd) {
        MoveWindow(video_hwnd, video_rect.left, video_rect.top,
                   video_w, video_h, TRUE);
    }
}

static void resize_window_to_source(HWND hwnd)
{
    RECT work;
    RECT wr;
    int content_w = source_width;
    int content_h = source_height + TOOLBAR_HEIGHT;
    int max_w;
    int max_h;
    double scale = 1.0;

    if (source_width <= 0 || source_height <= 0) {
        return;
    }

    MONITORINFO mi = { 0 };
    mi.cbSize = sizeof(mi);
    GetMonitorInfoA(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST), &mi);
    work = mi.rcWork;
    max_w = max(320, (work.right - work.left) * WINDOW_FIT_PERCENT / 100);
    max_h = max(240, (work.bottom - work.top) * WINDOW_FIT_PERCENT / 100);

    wr.left = 0;
    wr.top = 0;
    wr.right = content_w;
    wr.bottom = content_h;
    AdjustWindowRectEx(&wr, GetWindowLongA(hwnd, GWL_STYLE), FALSE,
                       GetWindowLongA(hwnd, GWL_EXSTYLE));

    if (wr.right - wr.left > max_w) {
        scale = (double)max_w / (double)(wr.right - wr.left);
    }
    if ((wr.bottom - wr.top) * scale > max_h) {
        scale = (double)max_h / (double)(wr.bottom - wr.top);
    }
    if (scale < 1.0) {
        content_w = max(320, (int)(source_width * scale));
        content_h = TOOLBAR_HEIGHT +
                    max(180, (int)(source_height * scale));
        wr.left = 0;
        wr.top = 0;
        wr.right = content_w;
        wr.bottom = content_h;
        AdjustWindowRectEx(&wr, GetWindowLongA(hwnd, GWL_STYLE), FALSE,
                           GetWindowLongA(hwnd, GWL_EXSTYLE));
    }

    SetWindowPos(hwnd, NULL,
                 work.left + ((work.right - work.left) - (wr.right - wr.left)) / 2,
                 work.top + ((work.bottom - work.top) - (wr.bottom - wr.top)) / 2,
                 wr.right - wr.left, wr.bottom - wr.top,
                 SWP_NOZORDER | SWP_NOACTIVATE);
    layout_children(hwnd);
}

static DWORD WINAPI gst_receiver_thread(LPVOID opaque)
{
    ULONGLONG t0 = viewer_now_ms();

    (void)opaque;
    if (InterlockedExchange(&gst_started, 1) != 0) {
        log_line("gst receiver already started");
        return 0;
    }

    log_line("gst receiver thread begin");
    start_gst_receiver();
    log_line("gst receiver thread ready total=%I64ums",
             (unsigned long long)(viewer_now_ms() - t0));
    return 0;
}

static void start_media_stack(HWND hwnd)
{
    ULONGLONG t0 = viewer_now_ms();
    ULONGLONG t_stage;

    if (InterlockedExchange(&media_started, 1) != 0) {
        log_line("media-stack already started");
        return;
    }

    log_line("media-stack begin");
    t_stage = viewer_now_ms();
    set_gst_environment();
    log_line("media-stack set-gst-env dt=%I64ums",
             (unsigned long long)(viewer_now_ms() - t_stage));
    CreateThread(NULL, 0, spice_thread, NULL, 0, NULL);
    CreateThread(NULL, 0, gst_receiver_thread, NULL, 0, NULL);
    SetWindowTextA(hwnd, "GVT SPICE Viewer - video embedded, waiting for inputs");
    if (auto_size_on_start) {
        PostMessageA(hwnd, WM_COMMAND, ID_AUTO_SIZE, 0);
    }
    log_line("media-stack ready total=%I64ums",
             (unsigned long long)(viewer_now_ms() - t0));
}

static LRESULT CALLBACK wndproc(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam)
{
    switch (msg) {
    case WM_CREATE:
    {
        ULONGLONG t0 = viewer_now_ms();

        main_hwnd = hwnd;
        log_line("WM_CREATE");
        if (!input_lock_ready) {
            InitializeCriticalSection(&input_lock);
            input_lock_ready = true;
        }
        if (!native_input_lock_ready) {
            InitializeCriticalSection(&native_input_lock);
            native_input_lock_ready = true;
        }
        auto_button = CreateWindowExA(0, "BUTTON", "Auto",
                                      WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON,
                                      0, 0, 1, 1, hwnd,
                                      (HMENU)(INT_PTR)ID_AUTO_SIZE,
                                      (HINSTANCE)GetWindowLongPtr(hwnd, GWLP_HINSTANCE),
                                      NULL);
        video_hwnd = CreateWindowExA(0, "STATIC", "",
                                     WS_CHILD | WS_VISIBLE | SS_BLACKRECT,
                                     0, 0, 1, 1, hwnd, NULL,
                                     (HINSTANCE)GetWindowLongPtr(hwnd, GWLP_HINSTANCE),
                                     NULL);
        EnableWindow(video_hwnd, FALSE);
        layout_children(hwnd);
        SetWindowTextA(hwnd, "GVT SPICE Viewer - connecting");
        CreateThread(NULL, 0, stream_control_thread, NULL, 0, NULL);
        log_line("WM_CREATE ready dt=%I64ums",
                 (unsigned long long)(viewer_now_ms() - t0));
        if (!stream_control_enabled) {
            PostMessageA(hwnd, WM_STREAM_READY, 0, 0);
        }
        return 0;
    }
    case WM_STREAM_READY:
        log_line("WM_STREAM_READY connected=%d", (int)wparam);
        start_media_stack(hwnd);
        return 0;
    case WM_SIZE:
        layout_children(hwnd);
        return 0;
    case WM_COMMAND:
        if (LOWORD(wparam) == ID_AUTO_SIZE) {
            resize_window_to_source(hwnd);
            return 0;
        }
        break;
    case WM_MOUSEMOVE:
        send_position_from_lparam(lparam);
        return 0;
    case WM_LBUTTONDOWN:
        if (input_debug()) {
            log_line("input local left down");
        }
        SetFocus(hwnd);
        SetCapture(hwnd);
        button_state |= SPICE_MOUSE_BUTTON_MASK_LEFT;
        send_position_from_lparam_priority(lparam, G_PRIORITY_HIGH, false);
        if (input_transport_ready()) {
            InputEv *ev = calloc(1, sizeof(*ev));
            ev->type = INPUT_EV_BUTTON;
            ev->button = SPICE_MOUSE_BUTTON_LEFT;
            ev->button_state = button_state;
            ev->down = true;
            queue_input_event_priority(ev, G_PRIORITY_HIGH);
        }
        return 0;
    case WM_LBUTTONUP:
        if (input_debug()) {
            log_line("input local left up");
        }
        button_state &= ~SPICE_MOUSE_BUTTON_MASK_LEFT;
        send_position_from_lparam_priority(lparam, G_PRIORITY_HIGH, false);
        if (input_transport_ready()) {
            InputEv *ev = calloc(1, sizeof(*ev));
            ev->type = INPUT_EV_BUTTON;
            ev->button = SPICE_MOUSE_BUTTON_LEFT;
            ev->button_state = button_state;
            ev->down = false;
            queue_input_event_priority(ev, G_PRIORITY_HIGH);
        }
        ReleaseCapture();
        return 0;
    case WM_RBUTTONDOWN:
        if (input_debug()) {
            log_line("input local right down");
        }
        SetFocus(hwnd);
        SetCapture(hwnd);
        button_state |= SPICE_MOUSE_BUTTON_MASK_RIGHT;
        send_position_from_lparam_priority(lparam, G_PRIORITY_HIGH, false);
        if (input_transport_ready()) {
            InputEv *ev = calloc(1, sizeof(*ev));
            ev->type = INPUT_EV_BUTTON;
            ev->button = SPICE_MOUSE_BUTTON_RIGHT;
            ev->button_state = button_state;
            ev->down = true;
            queue_input_event_priority(ev, G_PRIORITY_HIGH);
        }
        return 0;
    case WM_RBUTTONUP:
        if (input_debug()) {
            log_line("input local right up");
        }
        button_state &= ~SPICE_MOUSE_BUTTON_MASK_RIGHT;
        send_position_from_lparam_priority(lparam, G_PRIORITY_HIGH, false);
        if (input_transport_ready()) {
            InputEv *ev = calloc(1, sizeof(*ev));
            ev->type = INPUT_EV_BUTTON;
            ev->button = SPICE_MOUSE_BUTTON_RIGHT;
            ev->button_state = button_state;
            ev->down = false;
            queue_input_event_priority(ev, G_PRIORITY_HIGH);
        }
        ReleaseCapture();
        return 0;
    case WM_MBUTTONDOWN:
        if (input_debug()) {
            log_line("input local middle down");
        }
        SetFocus(hwnd);
        SetCapture(hwnd);
        button_state |= SPICE_MOUSE_BUTTON_MASK_MIDDLE;
        if (input_transport_ready()) {
            InputEv *ev = calloc(1, sizeof(*ev));
            ev->type = INPUT_EV_BUTTON;
            ev->button = SPICE_MOUSE_BUTTON_MIDDLE;
            ev->button_state = button_state;
            ev->down = true;
            queue_input_event_priority(ev, G_PRIORITY_HIGH);
        }
        return 0;
    case WM_MBUTTONUP:
        if (input_debug()) {
            log_line("input local middle up");
        }
        button_state &= ~SPICE_MOUSE_BUTTON_MASK_MIDDLE;
        if (input_transport_ready()) {
            InputEv *ev = calloc(1, sizeof(*ev));
            ev->type = INPUT_EV_BUTTON;
            ev->button = SPICE_MOUSE_BUTTON_MIDDLE;
            ev->button_state = button_state;
            ev->down = false;
            queue_input_event_priority(ev, G_PRIORITY_HIGH);
        }
        ReleaseCapture();
        return 0;
    case WM_MOUSEWHEEL:
        if (input_debug()) {
            log_line("input local wheel delta=%d",
                     GET_WHEEL_DELTA_WPARAM(wparam));
        }
        if (input_transport_ready()) {
            int button = GET_WHEEL_DELTA_WPARAM(wparam) > 0 ?
                         SPICE_MOUSE_BUTTON_UP : SPICE_MOUSE_BUTTON_DOWN;
            InputEv *ev = calloc(1, sizeof(*ev));
            ev->type = INPUT_EV_WHEEL;
            ev->button = button;
            ev->button_state = button_state;
            queue_input_event_priority(ev, G_PRIORITY_HIGH);
        }
        return 0;
    case WM_KEYDOWN:
    case WM_SYSKEYDOWN:
        if (input_debug()) {
            log_line("input local key down vk=0x%lx scan=0x%x repeat=%d",
                     (unsigned long)wparam, scancode_from_lparam(lparam),
                     !!(HIWORD(lparam) & KF_REPEAT));
        }
        if (input_transport_ready() && !(HIWORD(lparam) & KF_REPEAT)) {
            InputEv *ev = calloc(1, sizeof(*ev));
            ev->type = INPUT_EV_KEY;
            ev->scancode = scancode_from_lparam(lparam);
            ev->down = true;
            queue_input_event_priority(ev, G_PRIORITY_HIGH);
        }
        return 0;
    case WM_KEYUP:
    case WM_SYSKEYUP:
        if (input_debug()) {
            log_line("input local key up vk=0x%lx scan=0x%x",
                     (unsigned long)wparam, scancode_from_lparam(lparam));
        }
        if (input_transport_ready()) {
            InputEv *ev = calloc(1, sizeof(*ev));
            ev->type = INPUT_EV_KEY;
            ev->scancode = scancode_from_lparam(lparam);
            ev->down = false;
            queue_input_event_priority(ev, G_PRIORITY_HIGH);
        }
        return 0;
    case WM_DESTROY:
        InterlockedExchange(&shutting_down, 1);
        if (main_loop) {
            p_g_main_loop_quit(main_loop);
        }
        native_input_close();
        stream_control_close();
        if (winsock_ready) {
            WSACleanup();
            winsock_ready = false;
        }
        if (gst_pipeline) {
            p_gst_element_set_state(gst_pipeline, 1);
            if (gst_sink) {
                p_gst_object_unref(gst_sink);
            }
            p_gst_object_unref(gst_pipeline);
        }
        PostQuitMessage(0);
        return 0;
    default:
        return DefWindowProcA(hwnd, msg, wparam, lparam);
    }
    return DefWindowProcA(hwnd, msg, wparam, lparam);
}

static void parse_args(int argc, char **argv)
{
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--video-port") && i + 1 < argc) {
            video_port = atoi(argv[++i]);
        } else if (!strcmp(argv[i], "--video-codec") && i + 1 < argc) {
            video_codec = argv[++i];
        } else if (!strcmp(argv[i], "--stream-control-host") && i + 1 < argc) {
            stream_control_host = argv[++i];
        } else if (!strcmp(argv[i], "--stream-control-port") && i + 1 < argc) {
            stream_control_port = atoi(argv[++i]);
        } else if (!strcmp(argv[i], "--no-stream-control")) {
            stream_control_enabled = false;
        } else if (!strcmp(argv[i], "--latency") && i + 1 < argc) {
            video_latency = atoi(argv[++i]);
        } else if (!strcmp(argv[i], "--drop-on-latency")) {
            video_drop_on_latency = true;
        } else if (!strcmp(argv[i], "--no-drop-on-latency")) {
            video_drop_on_latency = false;
        } else if (!strcmp(argv[i], "--spice-host") && i + 1 < argc) {
            spice_host = argv[++i];
        } else if (!strcmp(argv[i], "--spice-port") && i + 1 < argc) {
            spice_port = argv[++i];
        } else if (!strcmp(argv[i], "--input-host") && i + 1 < argc) {
            native_input_host = argv[++i];
        } else if (!strcmp(argv[i], "--input-port") && i + 1 < argc) {
            native_input_port = atoi(argv[++i]);
        } else if (!strcmp(argv[i], "--native-input")) {
            native_input_enabled = true;
        } else if (!strcmp(argv[i], "--spice-input")) {
            native_input_enabled = false;
        } else if (!strcmp(argv[i], "--spice-runtime") && i + 1 < argc) {
            spice_runtime = argv[++i];
        } else if (!strcmp(argv[i], "--gst-root") && i + 1 < argc) {
            gst_root = argv[++i];
        } else if (!strcmp(argv[i], "--source-width") && i + 1 < argc) {
            int value = atoi(argv[++i]);
            source_width = value > 320 ? value : 320;
        } else if (!strcmp(argv[i], "--source-height") && i + 1 < argc) {
            int value = atoi(argv[++i]);
            source_height = value > 180 ? value : 180;
        } else if (!strcmp(argv[i], "--no-auto-size")) {
            auto_size_on_start = false;
        } else if (!strcmp(argv[i], "--auto-size")) {
            auto_size_on_start = true;
        } else if (!strcmp(argv[i], "--spice-display")) {
            spice_display_mode = true;
        }
    }
}

int WINAPI WinMain(HINSTANCE hinst, HINSTANCE prev, LPSTR cmdline, int show)
{
    WNDCLASSA wc = { 0 };
    MSG msg;
    int argc = 0;
    LPWSTR *wargv = CommandLineToArgvW(GetCommandLineW(), &argc);
    char **argv = calloc(argc, sizeof(char *));

    (void)prev;
    (void)cmdline;
    for (int i = 0; i < argc; i++) {
        int len = WideCharToMultiByte(CP_UTF8, 0, wargv[i], -1, NULL, 0, NULL, NULL);
        argv[i] = calloc(len, 1);
        WideCharToMultiByte(CP_UTF8, 0, wargv[i], -1, argv[i], len, NULL, NULL);
    }
    parse_args(argc, argv);
    if (spice_display_mode) {
        return run_spice_display_mode(argc, argv);
    }

    wc.lpfnWndProc = wndproc;
    wc.hInstance = hinst;
    wc.lpszClassName = "GVTSpiceViewerWindow";
    wc.hCursor = LoadCursor(NULL, IDC_ARROW);
    wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    RegisterClassA(&wc);

    RECT wr = initial_window_rect();
    main_hwnd = CreateWindowExA(0, wc.lpszClassName,
                                "GVT SPICE Viewer - starting",
                                WS_OVERLAPPEDWINDOW | WS_VISIBLE,
                                wr.left, wr.top, wr.right - wr.left,
                                wr.bottom - wr.top, NULL, NULL, hinst, NULL);
    ShowWindow(main_hwnd, (show == SW_SHOWMINIMIZED || show == SW_MINIMIZE ||
                           show == SW_SHOWMINNOACTIVE) ? SW_SHOWNORMAL : show);
    SetForegroundWindow(main_hwnd);
    UpdateWindow(main_hwnd);

    while (GetMessageA(&msg, NULL, 0, 0)) {
        TranslateMessage(&msg);
        DispatchMessageA(&msg);
    }
    return (int)msg.wParam;
}

