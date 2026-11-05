#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include <errno.h>
#include <stdio.h>
#include <unistd.h>

#include "flutter/generated_plugin_registrant.h"

// Is there a display server to connect to?
//
// Without one GTK just prints "cannot open display" and exits, which tells
// someone who came in over SSH nothing. Check up front and explain how to use
// the command line instead.
static gboolean aurora_has_display() {
  return g_getenv("WAYLAND_DISPLAY") != nullptr ||
         g_getenv("DISPLAY") != nullptr;
}

// Hand this invocation to the aurora-cli next to this executable. On success
// this does NOT return (execv replaces the process).
//
// The test is deliberately blunt: any argument means command line. The GUI
// accepts no arguments itself (nor does Exec in the .desktop file), so there is
// no ambiguity and no verb table to maintain -- new subcommands just work.
static void aurora_exec_cli(gchar** argv, int* exit_status) {
  g_autofree gchar* exe = g_file_read_link("/proc/self/exe", nullptr);
  g_autofree gchar* dir = exe != nullptr ? g_path_get_dirname(exe) : nullptr;
  g_autofree gchar* cli =
      dir != nullptr ? g_build_filename(dir, "aurora-cli", nullptr) : nullptr;

  if (cli != nullptr && g_file_test(cli, G_FILE_TEST_IS_EXECUTABLE)) {
    // Copy argv and replace argv[0] there instead of modifying the caller's
    // array: g_application_run g_strfreev's it after local_command_line
    // returns, and cli is g_autofree'd, so storing it in that array would be a
    // double free.
    guint count = g_strv_length(argv);
    g_autofree gchar** cli_argv = g_new0(gchar*, count + 1);
    cli_argv[0] = cli;
    for (guint i = 1; i < count; i++) {
      cli_argv[i] = argv[i];
    }
    execv(cli, cli_argv);
    // Reaching this point means execv itself failed (permissions, ENOEXEC, ...).
    fprintf(stderr, "aurora: cannot execute %s: %s\n", cli, g_strerror(errno));
  } else {
    fprintf(stderr, "aurora: command-line program not found (expected at %s). Please reinstall Aurora.\n",
            cli != nullptr ? cli : "<executable directory>/aurora-cli");
  }
  *exit_status = 127;
}

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "aurora");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "aurora");
  }

  gtk_window_set_default_size(window, 1280, 720);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);

  // Both branches must come before g_application_register(): that call
  // triggers GtkApplication's startup, i.e. gtk_init, which is where "cannot
  // open display" comes from when there is no display server.
  if (g_strv_length(*arguments) > 1) {
    aurora_exec_cli(*arguments, exit_status);
    return TRUE;
  }
  if (!aurora_has_display()) {
    // fputs rather than g_printerr: the latter converts UTF-8 to the current
    // locale's encoding, and SSH sessions are often LANG=C. Writing the bytes
    // directly is always correct.
    fputs(
        "aurora: no graphical environment (neither DISPLAY nor WAYLAND_DISPLAY is set).\n"
        "Use the command line from a terminal:\n"
        "  aurora connect       connect\n"
        "  aurora status        show status\n"
        "  aurora disconnect    disconnect\n"
        "  aurora help          all options\n",
        stderr);
    *exit_status = 1;
    return TRUE;
  }

  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_NON_UNIQUE, nullptr));
}
