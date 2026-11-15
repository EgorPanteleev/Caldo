"""A stand-in for the desktop's notification server, for tool/desktop/try.sh.

The session try.sh makes has no server to show a reminder, and the real one
belongs to the desk this is being tried at. This one writes what it is sent
to notifd.log in the directory named by CALDO_TRY_DIR, and presses a button
when asked: write the button's key (done, snooze-15, snooze-60, or default
for a click on the notification itself) into a file called `press` there,
and it is pressed on the newest notification.
"""
import os, json, time
from gi.repository import Gio, GLib
HERE = os.environ.get('CALDO_TRY_DIR') or os.path.dirname(os.path.abspath(__file__))
LOG = os.path.join(HERE, 'notifd.log'); PRESS = os.path.join(HERE, 'press')
XML = """<node><interface name='org.freedesktop.Notifications'>
<method name='Notify'><arg type='s' direction='in'/><arg type='u' direction='in'/><arg type='s' direction='in'/><arg type='s' direction='in'/><arg type='s' direction='in'/><arg type='as' direction='in'/><arg type='a{sv}' direction='in'/><arg type='i' direction='in'/><arg type='u' direction='out'/></method>
<method name='CloseNotification'><arg type='u' direction='in'/></method>
<method name='GetCapabilities'><arg type='as' direction='out'/></method>
<method name='GetServerInformation'><arg type='s' direction='out'/><arg type='s' direction='out'/><arg type='s' direction='out'/><arg type='s' direction='out'/></method>
<signal name='ActionInvoked'><arg type='u'/><arg type='s'/></signal>
<signal name='NotificationClosed'><arg type='u'/><arg type='u'/></signal>
</interface></node>"""
state = {'n': 0, 'conn': None, 'last': 0}
def log(*a):
    with open(LOG, 'a') as f: f.write(time.strftime('%H:%M:%S ') + ' '.join(str(x) for x in a) + '\n')
def call(conn, sender, path, iface, method, params, inv):
    if method == 'Notify':
        app, rep, icon, summary, body, actions, hints, timeout = params.unpack()
        state['n'] += 1; nid = rep or state['n']; state['last'] = nid
        log('NOTIFY', nid, json.dumps({'summary': summary, 'body': body, 'actions': actions, 'icon': icon}))
        inv.return_value(GLib.Variant('(u)', (nid,)))
    elif method == 'CloseNotification':
        log('CLOSE', params.unpack()[0]); inv.return_value(None)
    elif method == 'GetCapabilities':
        inv.return_value(GLib.Variant('(as)', (['actions', 'body', 'sound'],)))
    else:
        inv.return_value(GLib.Variant('(ssss)', ('fake', 'test', '1', '1.2')))
def bus(conn, name):
    state['conn'] = conn
    conn.register_object('/org/freedesktop/Notifications', Gio.DBusNodeInfo.new_for_xml(XML).interfaces[0], call, None, None)
def poll():
    if os.path.exists(PRESS) and state['last']:
        key = open(PRESS).read().strip(); os.remove(PRESS); log('PRESS', state['last'], key)
        state['conn'].emit_signal(None, '/org/freedesktop/Notifications', 'org.freedesktop.Notifications', 'ActionInvoked', GLib.Variant('(us)', (state['last'], key)))
    return True
Gio.bus_own_name(Gio.BusType.SESSION, 'org.freedesktop.Notifications', 0, bus, None, None)
GLib.timeout_add(300, poll); log('up'); GLib.MainLoop().run()
