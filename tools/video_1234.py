"""Double-click to listen for EVID UDP video on port 1234 and display at 10 fps.
First launch installs numpy/opencv-python if missing. ESC exits.
RGB888 or RGB565 (big-endian pixels) is detected by complete-frame size.
"""
import importlib
import socket
import struct
import subprocess
import sys
import threading
import time
from collections import deque

PORT = 1234
FPS = 10
HEADER = struct.Struct("!4sHHIHHHH")
WINDOW = "FPGA video - UDP 1234 - ESC to exit"


def dependencies():
    try:
        return importlib.import_module("numpy"), importlib.import_module("cv2")
    except ImportError:
        print("First launch: installing numpy and opencv-python...")
        subprocess.check_call([
            sys.executable, "-m", "pip", "install", "numpy", "opencv-python"
        ])
        return importlib.import_module("numpy"), importlib.import_module("cv2")


def main():
    np, cv2 = dependencies()
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 16 * 1024 * 1024)
    sock.bind(("0.0.0.0", PORT))
    sock.settimeout(0.1)
    stop = threading.Event()
    lock = threading.Lock()
    latest = [None]
    status = {"packets": 0, "frames": 0, "dropped": 0, "error": ""}

    def receive():
        frames = {}
        source = None
        source_time = 0.0
        while not stop.is_set():
            now = time.monotonic()
            for key in list(frames):
                if now - frames[key][0] > 1.5:
                    status["dropped"] += 1
                    del frames[key]
            try:
                packet, peer = sock.recvfrom(65535)
            except socket.timeout:
                continue
            except OSError as exc:
                if not stop.is_set():
                    status["error"] = str(exc)
                break
            if len(packet) < HEADER.size:
                continue
            magic, w, h, frame, index, count, length, _ = HEADER.unpack_from(packet)
            if (magic != b"EVID" or not 0 < w <= 4096 or not 0 < h <= 2160
                    or not 0 < count <= 32768 or index >= count
                    or not 0 < length <= 1472 or len(packet) != HEADER.size + length):
                continue
            if source != peer:
                if source is not None and now - source_time < 1.5:
                    continue
                source = peer
                frames.clear()
            source_time = now
            status["packets"] += 1
            if frame not in frames:
                if len(frames) >= 3:
                    stale_key = min(frames, key=lambda key: frames[key][0])
                    status["dropped"] += 1
                    del frames[stale_key]
                frames[frame] = [now, w, h, count, {}, 0]
            entry = frames[frame]
            if entry[1:4] != [w, h, count]:
                continue
            if index not in entry[4]:
                entry[4][index] = packet[HEADER.size:]
                entry[5] += length
            if entry[5] > w * h * 3:
                status["dropped"] += 1
                del frames[frame]
                continue
            if len(entry[4]) != count:
                continue
            raw = b"".join(entry[4][i] for i in range(count))
            del frames[frame]
            if len(raw) not in (w * h * 3, w * h * 2):
                status["dropped"] += 1
                continue
            with lock:
                latest[0] = (w, h, raw)
            status["frames"] += 1

    worker = threading.Thread(target=receive, daemon=True)
    worker.start()
    print("Listening on UDP 1234. Display: 10 fps. Press ESC or close the window.")
    print("FPGA destination must be this PC's IPv4 address, UDP port 1234.")
    print("Allow Python through Windows Firewall on your local network.")
    image = np.zeros((540, 960, 3), dtype=np.uint8)
    cv2.putText(image, "Waiting for FPGA EVID UDP packets on port 1234...",
                (30, 260), cv2.FONT_HERSHEY_SIMPLEX, 0.7, (255, 255, 255), 2)
    cv2.namedWindow(WINDOW, cv2.WINDOW_NORMAL)
    cv2.resizeWindow(WINDOW, 960, 540)
    next_show = time.monotonic()
    next_log = next_show + 5
    fps_history = deque(maxlen=20)
    last_render_time = None
    try:
        while True:
            now = time.monotonic()
            if now >= next_show:
                with lock:
                    frame = latest[0]
                    latest[0] = None
                if frame is not None:
                    w, h, raw = frame
                    if len(raw) == w * h * 3:
                        rgb = np.frombuffer(raw, np.uint8).reshape(h, w, 3)
                        image = cv2.cvtColor(rgb, cv2.COLOR_RGB2BGR)
                    else:
                        pixels = np.frombuffer(raw, dtype=">u2").reshape(h, w)
                        image = np.empty((h, w, 3), dtype=np.uint8)
                        r = (pixels >> 11) & 31
                        g = (pixels >> 5) & 63
                        b = pixels & 31
                        image[:, :, 2] = (r << 3) | (r >> 2)
                        image[:, :, 1] = (g << 2) | (g >> 4)
                        image[:, :, 0] = (b << 3) | (b >> 2)
                    if last_render_time is not None:
                        fps_history.append(1.0 / max(now - last_render_time, 1e-3))
                    last_render_time = now
                current_fps = sum(fps_history) / len(fps_history) if fps_history else 0.0
                debug_text = (
                    f"FPS: {current_fps:.1f} | Recv: {status['frames']} | Drop: {status['dropped']}"
                )
                cv2.putText(image, debug_text, (10, 28), cv2.FONT_HERSHEY_SIMPLEX,
                            0.6, (0, 255, 255), 2, cv2.LINE_AA)
                cv2.imshow(WINDOW, image)
                next_show = now + 1.0 / FPS
            if now >= next_log:
                print("Valid packets: {}, complete frames: {}, dropped frames: {}".format(
                    status["packets"], status["frames"], status["dropped"]))
                next_log = now + 5
            if status["error"]:
                raise RuntimeError(status["error"])
            if cv2.waitKey(1) & 0xFF == 27:
                break
            if cv2.getWindowProperty(WINDOW, cv2.WND_PROP_VISIBLE) < 1:
                break
    finally:
        stop.set()
        worker.join(timeout=0.5)
        sock.close()
        cv2.destroyAllWindows()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
    except Exception as exc:
        print("\nUnable to start:", exc)
        print("Check Python/network access, or whether another program uses UDP 1234.")
        input("Press Enter to close...")
