#!/usr/bin/env python3
import gpiod, datetime, struct, os, fcntl, time, signal, sys, mmap
import threading, queue, socket, json, urllib.request, base64
from gpiod.line import Direction, Edge, Bias, Value
from gpiod.edge_event import EdgeEvent

TLMM_PINS = [85, 88, 91, 109, 169, 170]

def configure_hardware_pullups():
    try:
        with open('/dev/mem', 'r+b') as f:
            mm = mmap.mmap(f.fileno(), 0x200000, offset=0x0f100000)
            changed = False
            for p in TLMM_PINS:
                off = p * 0x1000
                cfg = struct.unpack('<I', mm[off:off+4])[0]
                # bits 1:0: 0=no pull, 1=pull down, 2=keeper, 3=pull up
                if (cfg & 3) != 3:
                    mm[off:off+4] = struct.pack('<I', (cfg & ~3) | 3)
                    changed = True
            mm.close()
            if changed:
                print('[HARDWARE] TLMM hardware pull-up registers configured successfully.', flush=True)
    except Exception as e:
        print(f'[HARDWARE WARNING] Could not configure TLMM registers via /dev/mem: {e}', flush=True)

# Hardware TLMM pull-ups MUST be set directly via MMIO on SM8550
configure_hardware_pullups()

UI_SET_EVBIT   = 0x40045564
UI_SET_KEYBIT  = 0x40045565
UI_DEV_CREATE  = 0x5501
UI_DEV_DESTROY = 0x5502
UI_DEV_SETUP   = 0x405c5503

EV_SYN = 0x00
EV_KEY = 0x01
SYN_REPORT = 0x00

BTN_C = 0x132              # 306 - Right Paddle (R4)
BTN_Z = 0x135              # 309 - Left Paddle (L4)
BTN_TRIGGER_HAPPY1 = 0x2c0 # 704 - L4
BTN_TRIGGER_HAPPY2 = 0x2c1 # 705 - R4

# Setup pure Gamepad uinput device for paddles (no keyboard keys so games never switch layouts)
uinput_fd = os.open('/dev/uinput', os.O_WRONLY | os.O_NONBLOCK)
fcntl.ioctl(uinput_fd, UI_SET_EVBIT, EV_KEY)
for k in [BTN_C, BTN_Z, BTN_TRIGGER_HAPPY1, BTN_TRIGGER_HAPPY2]:
    fcntl.ioctl(uinput_fd, UI_SET_KEYBIT, k)

setup = struct.pack('HHHH80sI', 0x03, 0x28de, 0x11ff, 0x01, b'AYANEO Hardware Aux Keys', 0)
fcntl.ioctl(uinput_fd, UI_DEV_SETUP, setup)
fcntl.ioctl(uinput_fd, UI_DEV_CREATE)

def emit_key(code, val):
    ev = struct.pack('qqHHi', 0, 0, EV_KEY, code, val)
    os.write(uinput_fd, ev)

def sync():
    syn = struct.pack('qqHHi', 0, 0, EV_SYN, SYN_REPORT, 0)
    os.write(uinput_fd, syn)

# Steam CEF Client for instant overlay toggle without keyboard injection
class SteamCEFClient:
    def __init__(self, port=8080):
        self.port = port
        self.sock = None

    def connect(self):
        try:
            req = urllib.request.Request(f"http://127.0.0.1:{self.port}/json")
            with urllib.request.urlopen(req, timeout=0.4) as resp:
                tabs = json.loads(resp.read().decode())
            target = next((t for t in tabs if "SharedJSContext" in t.get("title", "")), None)
            if not target:
                return False
            ws_url = target["webSocketDebuggerUrl"]
            host_port, path = ws_url[5:].split("/", 1)
            host, port = host_port.split(":")
            self.sock = socket.create_connection((host, int(port)), timeout=0.8)
            key = base64.b64encode(b"0123456789abcdef").decode()
            hdr = (
                f"GET /{path} HTTP/1.1\r\n"
                f"Host: {host}:{port}\r\n"
                "Upgrade: websocket\r\n"
                "Connection: Upgrade\r\n"
                f"Sec-WebSocket-Key: {key}\r\n"
                "Sec-WebSocket-Version: 13\r\n\r\n"
            )
            self.sock.sendall(hdr.encode())
            resp = b""
            while b"\r\n\r\n" not in resp:
                chunk = self.sock.recv(1024)
                if not chunk:
                    self.sock = None
                    return False
                resp += chunk
            return True
        except Exception:
            self.sock = None
            return False

    def eval(self, expr):
        if not self.sock and not self.connect():
            return None
        data = json.dumps({"id": 1, "method": "Runtime.evaluate", "params": {"expression": expr}}).encode()
        length = len(data)
        frame = bytearray([0x81])
        if length <= 125:
            frame.append(0x80 | length)
        elif length <= 65535:
            frame.extend([0x80 | 126] + list(struct.pack("!H", length)))
        else:
            frame.extend([0x80 | 127] + list(struct.pack("!Q", length)))
        mask = b"\x01\x02\x03\x04"
        frame.extend(mask)
        frame.extend(bytearray(b ^ mask[i % 4] for i, b in enumerate(data)))
        try:
            self.sock.sendall(frame)
            hdr = self.sock.recv(2)
            if not hdr or len(hdr) < 2:
                self.sock = None
                return None
            l = hdr[1] & 0x7f
            if l == 126:
                l = struct.unpack("!H", self.sock.recv(2))[0]
            elif l == 127:
                l = struct.unpack("!Q", self.sock.recv(8))[0]
            payload = b""
            while len(payload) < l:
                chunk = self.sock.recv(l - len(payload))
                if not chunk: break
                payload += chunk
            return json.loads(payload.decode())
        except Exception:
            self.sock = None
            return None

    def toggle_menu(self, menu_id):
        # 1 = Steam Main Menu (left), 2 = Quick Access Menu (right)
        expr = f"SteamUIStore.WindowStore.GamepadUIMainWindowInstance.MenuStore.ToggleSideMenu({menu_id})"
        return self.eval(expr)

menu_queue = queue.Queue()

def cef_worker():
    client = SteamCEFClient()
    while True:
        try:
            menu_id = menu_queue.get()
            client.toggle_menu(menu_id)
            menu_queue.task_done()
        except Exception:
            pass

worker_thread = threading.Thread(target=cef_worker, daemon=True)
worker_thread.start()

chip = gpiod.Chip('/dev/gpiochip4')

# Keep peripheral power rails high
pwr_settings = gpiod.LineSettings(
    direction=Direction.OUTPUT,
    output_value=Value.ACTIVE
)
pwr_req = chip.request_lines(
    consumer='ayaneo_pwr',
    config={(52, 124): pwr_settings}
)

# Button lines with kernel pull-up and hardware debouncing
btn_settings = gpiod.LineSettings(
    direction=Direction.INPUT,
    bias=Bias.PULL_UP,
    edge_detection=Edge.BOTH,
    debounce_period=datetime.timedelta(milliseconds=25)
)
btn_req = chip.request_lines(
    consumer='ayaneo_keys',
    config={(85, 88, 91, 109, 169, 170): btn_settings}
)

running = True
def sig_handler(signum, frame):
    global running
    running = False

signal.signal(signal.SIGTERM, sig_handler)
signal.signal(signal.SIGINT, sig_handler)

print('AYANEO Keys Service v7.0 (TLMM MMIO PullUp + CEF Direct) running.', flush=True)

# Flush any startup transitional edges
if btn_req.wait_edge_events(timeout=datetime.timedelta(milliseconds=50)):
    btn_req.read_edge_events()

try:
    last_pullup_check = time.time()
    while running:
        if btn_req.wait_edge_events(timeout=datetime.timedelta(seconds=1)):
            for ev in btn_req.read_edge_events():
                p = ev.line_offset
                is_press = (ev.event_type == EdgeEvent.Type.FALLING_EDGE)
                action_str = 'PRESSED' if is_press else 'RELEASED'
                print(f'[EVENT] GPIO {p} -> {action_str}', flush=True)

                if is_press:
                    if p == 85:          # AYA button -> Steam QAM (Quick Access / Right Menu)
                        menu_queue.put(2)
                    elif p == 169:       # '=' button -> Steam Main Menu (Left Menu)
                        menu_queue.put(1)
                    elif p == 91:        # LC button -> Left Paddle (L4)
                        emit_key(BTN_TRIGGER_HAPPY1, 1)
                        emit_key(BTN_Z, 1)
                        sync()
                    elif p in (88, 170): # RC button -> Right Paddle (R4)
                        emit_key(BTN_TRIGGER_HAPPY2, 1)
                        emit_key(BTN_C, 1)
                        sync()
                else:
                    if p == 91:
                        emit_key(BTN_TRIGGER_HAPPY1, 0)
                        emit_key(BTN_Z, 0)
                        sync()
                    elif p in (88, 170):
                        emit_key(BTN_TRIGGER_HAPPY2, 0)
                        emit_key(BTN_C, 0)
                        sync()

        # Periodic check every 10 seconds to ensure TLMM hardware registers stay pulled up across sleep/wake
        now = time.time()
        if now - last_pullup_check > 10:
            configure_hardware_pullups()
            last_pullup_check = now
finally:
    btn_req.release()
    pwr_req.release()
    chip.close()
    fcntl.ioctl(uinput_fd, UI_DEV_DESTROY)
    os.close(uinput_fd)
    print('AYANEO Keys Service stopped cleanly.', flush=True)
