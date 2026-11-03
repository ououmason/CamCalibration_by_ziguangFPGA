#!/usr/bin/env python3
"""Receive FPGA EVID UDP packets and display RGB frames.

Usage: python host_video_receiver.py --port 5001
Requires: Python 3, numpy, opencv-python.
"""
import argparse
import socket
import struct
import cv2
import numpy as np

MAGIC = b"EVID"
HEADER = struct.Struct("!4sHHIHHHH")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bind", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=5001)
    ap.add_argument("--window", default="HDMI undistorted")
    args = ap.parse_args()
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind((args.bind, args.port))
    frames = {}
    print(f"listening on UDP {args.bind}:{args.port}")
    while True:
        packet, _ = sock.recvfrom(65535)
        if len(packet) < HEADER.size or packet[:4] != MAGIC:
            continue
        magic, w, h, frame, index, count, payload_len, _ = HEADER.unpack_from(packet)
        payload = packet[HEADER.size:HEADER.size + payload_len]
        entry = frames.setdefault(frame, [w, h, count, {}])
        entry[3][index] = payload
        if len(entry[3]) != count:
            continue
        raw = b"".join(entry[3][i] for i in range(count))
        expected = w * h * 3
        if len(raw) >= expected:
            image = np.frombuffer(raw[:expected], np.uint8).reshape((h, w, 3))
            cv2.imshow(args.window, cv2.cvtColor(image, cv2.COLOR_RGB2BGR))
            if cv2.waitKey(1) & 0xff == 27:
                break
        del frames[frame]
        for old in list(frames):
            if old < frame - 2:
                del frames[old]
    cv2.destroyAllWindows()

if __name__ == "__main__":
    main()
