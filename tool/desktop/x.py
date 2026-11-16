"""Sends a mouse and keys to the Caldo that tool/desktop/try.sh has running, on
its display. Needs python-xlib (a venv will do: pip install python-xlib).

  x.py click X Y            x.py wheel X Y N       (N notches; negative is up)
  x.py rclick X Y           x.py type TEXT
  x.py move X Y             x.py key NAME [ctrl]   (Return, Escape; n ctrl)
  x.py drag X1 Y1 X2 Y2 [STEPS] [HOLD_MS] [PAUSE_MS]
  x.py resize W H

HOLD_MS is how long the button is down before it moves: 700 picks a card up.
PAUSE_MS is how long it rests before letting go. Left out, the drag lets go
while still moving, which is a fling; anything over 40 is taken for a stop,
and a pager let go at rest short of half way goes back where it was.
With no window manager the keys go to whatever window the pointer is over,
so `move` onto a file dialog before typing a path into it.
"""
import os, sys, time
from Xlib import X, XK, display
from Xlib.ext import xtest
d = display.Display(os.environ.get('CALDO_TRY_DISPLAY', ':99'))
def move(x, y): xtest.fake_input(d, X.MotionNotify, x=int(float(x)), y=int(float(y))); d.sync()
def btn(n, down): xtest.fake_input(d, X.ButtonPress if down else X.ButtonRelease, n); d.sync()
def key(sym, shift=False, ctrl=False):
    code = d.keysym_to_keycode(sym)
    held = [d.keysym_to_keycode(m) for m, on in ((XK.XK_Shift_L, shift), (XK.XK_Control_L, ctrl)) if on]
    for m in held: xtest.fake_input(d, X.KeyPress, m)
    xtest.fake_input(d, X.KeyPress, code); xtest.fake_input(d, X.KeyRelease, code)
    for m in held: xtest.fake_input(d, X.KeyRelease, m)
    d.sync()
a = sys.argv[1:]
if a[0] == 'click':
    move(a[1], a[2]); time.sleep(0.05); btn(1, True); time.sleep(0.06); btn(1, False)
elif a[0] == 'rclick':
    move(a[1], a[2]); time.sleep(0.05); btn(3, True); time.sleep(0.06); btn(3, False)
elif a[0] == 'move':
    move(a[1], a[2])
elif a[0] == 'drag':
    x1, y1, x2, y2 = map(float, a[1:5]); steps = int(a[5]) if len(a) > 5 else 12; hold = int(a[6]) if len(a) > 6 else 0
    move(x1, y1); time.sleep(0.05); btn(1, True); time.sleep(hold / 1000 + 0.03)
    for i in range(1, steps + 1):
        move(x1 + (x2 - x1) * i / steps, y1 + (y2 - y1) * i / steps); time.sleep(0.016)
    time.sleep(float(a[7]) / 1000 if len(a) > 7 else 0.004); btn(1, False)
elif a[0] == 'type':
    names = {'/': 'slash', '-': 'minus', '.': 'period', '_': 'underscore', ':': 'colon', ' ': 'space'}
    for ch in a[1]:
        key(XK.string_to_keysym(names.get(ch, ch)), shift=ch.isupper() or ch in '_:'); time.sleep(0.03)
elif a[0] == 'key':
    key(XK.string_to_keysym(a[1]), ctrl='ctrl' in a[2:])
elif a[0] == 'wheel':
    move(a[1], a[2]); n = int(a[3])
    for _ in range(abs(n)):
        b = 5 if n > 0 else 4; btn(b, True); btn(b, False); time.sleep(0.03)
elif a[0] == 'resize':
    for w in d.screen().root.query_tree().children:
        g = w.get_geometry()
        if g.width > 200 and w.get_attributes().map_state == X.IsViewable:
            w.configure(x=0, y=0, width=int(a[1]), height=int(a[2]))
    d.sync()
d.close()
