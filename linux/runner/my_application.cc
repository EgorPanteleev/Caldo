#include "my_application.h"

#include <cstdio>

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Where the window's size is kept from one run to the next: beside the
// database, as `width height maximized`.
static gchar* window_file() {
  return g_build_filename(g_get_user_data_dir(), APPLICATION_ID, "window",
                          nullptr);
}

// The size the window was last left at. The first time, wide enough for the
// desktop's layout — the sidebar, a month and the day beside it — on any
// laptop.
static void read_window(gint* width, gint* height, gint* maximized) {
  *width = 1240;
  *height = 780;
  *maximized = 0;
  g_autofree gchar* path = window_file();
  g_autofree gchar* text = nullptr;
  if (!g_file_get_contents(path, &text, nullptr, nullptr)) return;
  gint w = 0, h = 0, m = 0;
  if (sscanf(text, "%d %d %d", &w, &h, &m) >= 2 && w >= 340 && h >= 560 &&
      w <= 16384 && h <= 16384) {
    *width = w;
    *height = h;
    *maximized = m != 0;
  }
}

// Called as the window is closed: notes its size for the next opening. A
// maximized window keeps the size it had before it was, to go back to.
static gboolean save_window(GtkWidget* widget, GdkEvent* event, gpointer data) {
  GtkWindow* window = GTK_WINDOW(widget);
  gint width, height, maximized;
  read_window(&width, &height, &maximized);
  maximized = gtk_window_is_maximized(window);
  if (!maximized) gtk_window_get_size(window, &width, &height);
  g_autofree gchar* path = window_file();
  g_autofree gchar* dir = g_path_get_dirname(path);
  g_mkdir_with_parents(dir, 0700);
  g_autofree gchar* text =
      g_strdup_printf("%d %d %d\n", width, height, maximized);
  g_file_set_contents(path, text, -1, nullptr);
  return FALSE;
}

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);

  // One Caldo at a time: two would each put up every reminder, and write to
  // one database between them. Started again while it is running, it is
  // this one that is brought to the front.
  GList* windows = gtk_application_get_windows(GTK_APPLICATION(application));
  if (windows != nullptr) {
    gtk_window_present(GTK_WINDOW(windows->data));
    return;
  }

  // The app is dark out of the box, and a pale title bar over true black is
  // a band of light across the top of it.
  g_object_set(gtk_settings_get_default(),
               "gtk-application-prefer-dark-theme", TRUE, nullptr);

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
    gtk_header_bar_set_title(header_bar, "Caldo");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "Caldo");
  }

  // The size it was closed at. It can be made any other, down to a small
  // phone's and no further, and narrow it is the phone's app.
  gint width, height, maximized;
  read_window(&width, &height, &maximized);
  gtk_window_set_default_size(window, width, height);
  if (maximized) gtk_window_maximize(window);
  g_signal_connect(window, "delete-event", G_CALLBACK(save_window), nullptr);
  GdkGeometry smallest;
  smallest.min_width = 340;
  smallest.min_height = 560;
  gtk_window_set_geometry_hints(window, nullptr, &smallest, GDK_HINT_MIN_SIZE);

  // The icon beside the program, for a window manager that draws one of its
  // own accord. A desktop that goes by the installed entry instead (GNOME,
  // anything on Wayland) finds it through `com.igor.caldo.desktop`.
  g_autofree gchar* exe = g_file_read_link("/proc/self/exe", nullptr);
  if (exe != nullptr) {
    g_autofree gchar* dir = g_path_get_dirname(exe);
    g_autofree gchar* icon = g_build_filename(dir, "data", "caldo.png", nullptr);
    if (g_file_test(icon, G_FILE_TEST_EXISTS)) {
      gtk_window_set_icon_from_file(window, icon, nullptr);
    }
  }

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
                                     G_APPLICATION_DEFAULT_FLAGS, nullptr));
}
