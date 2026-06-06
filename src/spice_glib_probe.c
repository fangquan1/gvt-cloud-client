/*
 * Tiny dynamic-link probe for the installed VirtViewer/spice-gtk runtime.
 *
 * It intentionally avoids compile-time GTK/SPICE headers.  The goal is to
 * verify whether the SPICE inputs channel is usable while QEMU keeps
 * -spice display=none and video stays on the separate gvt-stream RTP path.
 */
#include <windows.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>

#define SPICE_CHANNEL_MAIN 1
#define SPICE_CHANNEL_INPUTS 3
#define SPICE_MOUSE_MODE_CLIENT 2

typedef void *gpointer;
typedef int gboolean;
typedef unsigned int guint;
typedef int gint;

typedef void (*GCallback)(void);
typedef void (*GClosureNotify)(gpointer data, void *closure);

static HMODULE glib, gobject, spice;

static void *(*p_spice_session_new)(void);
static gboolean (*p_spice_session_connect)(void *session);
static void *(*p_spice_audio_get)(void *session, void *context);
static const char *(*p_spice_channel_type_to_string)(gint type);
static void (*p_spice_inputs_channel_position)(void *channel, gint x, gint y,
                                               gint display, gint button_state);

static void (*p_g_object_set)(gpointer object, const char *first_property_name, ...);
static void (*p_g_object_get)(gpointer object, const char *first_property_name, ...);
static unsigned long (*p_g_signal_connect_data)(gpointer instance,
                                                const char *detailed_signal,
                                                GCallback c_handler,
                                                gpointer data,
                                                GClosureNotify destroy_data,
                                                int connect_flags);
static void *(*p_g_main_loop_new)(void *context, gboolean is_running);
static void (*p_g_main_loop_run)(void *loop);
static void (*p_g_main_loop_quit)(void *loop);
static guint (*p_g_timeout_add)(guint interval, gboolean (*function)(gpointer),
                                gpointer data);

static void *main_loop;
static void *inputs_channel;

static void *sym(HMODULE module, const char *name)
{
    void *ptr = (void *)GetProcAddress(module, name);

    if (!ptr) {
        fprintf(stderr, "missing symbol: %s\n", name);
        ExitProcess(2);
    }
    return ptr;
}

static void load_runtime(const char *runtime)
{
    SetDllDirectoryA(runtime);
    glib = LoadLibraryA("libglib-2.0-0.dll");
    gobject = LoadLibraryA("libgobject-2.0-0.dll");
    spice = LoadLibraryA("libspice-client-glib-2.0-8.dll");
    if (!glib || !gobject || !spice) {
        fprintf(stderr, "failed to load runtime DLLs from %s\n", runtime);
        ExitProcess(2);
    }

    p_spice_session_new = sym(spice, "spice_session_new");
    p_spice_session_connect = sym(spice, "spice_session_connect");
    p_spice_audio_get = sym(spice, "spice_audio_get");
    p_spice_channel_type_to_string = sym(spice, "spice_channel_type_to_string");
    p_spice_inputs_channel_position =
        sym(spice, "spice_inputs_channel_position");

    p_g_object_set = sym(gobject, "g_object_set");
    p_g_object_get = sym(gobject, "g_object_get");
    p_g_signal_connect_data = sym(gobject, "g_signal_connect_data");

    p_g_main_loop_new = sym(glib, "g_main_loop_new");
    p_g_main_loop_run = sym(glib, "g_main_loop_run");
    p_g_main_loop_quit = sym(glib, "g_main_loop_quit");
    p_g_timeout_add = sym(glib, "g_timeout_add");
}

static gboolean send_probe_motion(gpointer data)
{
    (void)data;
    if (inputs_channel) {
        printf("sending inputs position probe via SPICE inputs channel\n");
        p_spice_inputs_channel_position(inputs_channel, 0x4000, 0x4000, 0, 0);
    } else {
        printf("inputs channel not seen before timeout\n");
    }
    p_g_main_loop_quit(main_loop);
    return 0;
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
    printf("channel-new type=%d(%s) id=%d\n", type, name ? name : "?", id);

    if (type == SPICE_CHANNEL_INPUTS) {
        inputs_channel = channel;
    }
}

int main(int argc, char **argv)
{
    const char *runtime = "C:\\Program Files\\VirtViewer v11.0-256\\bin";
    const char *host = "192.168.0.188";
    const char *port = "5900";
    void *session;
    void *audio;

    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);

    if (argc > 1) {
        runtime = argv[1];
    }
    if (argc > 2) {
        host = argv[2];
    }
    if (argc > 3) {
        port = argv[3];
    }

    load_runtime(runtime);
    session = p_spice_session_new();
    p_g_object_set(session, "host", host, "port", port, NULL);
    p_g_signal_connect_data(session, "channel-new", (GCallback)channel_new,
                            NULL, NULL, 0);

    audio = p_spice_audio_get(session, NULL);
    printf("spice audio object=%p\n", audio);

    main_loop = p_g_main_loop_new(NULL, 0);
    if (!p_spice_session_connect(session)) {
        fprintf(stderr, "spice_session_connect returned false\n");
        return 3;
    }

    p_g_timeout_add(5000, send_probe_motion, NULL);
    p_g_main_loop_run(main_loop);
    printf("probe done inputs_channel=%p\n", inputs_channel);
    return inputs_channel ? 0 : 4;
}
