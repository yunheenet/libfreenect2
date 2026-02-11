#!/usr/bin/env python3

import argparse
import socket
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class FrameStore:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._cv = threading.Condition(self._lock)
        self._jpeg = None
        self._seq = 0

    def set_frame(self, jpeg: bytes) -> None:
        with self._cv:
            self._jpeg = jpeg
            self._seq += 1
            self._cv.notify_all()

    def wait_next(self, last_seq: int, timeout: float):
        with self._cv:
            ok = self._cv.wait_for(lambda: self._seq != last_seq, timeout=timeout)
            if not ok:
                return None, last_seq
            return self._jpeg, self._seq


def make_handler(store: FrameStore):
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):  # noqa: N802
            if self.path == "/":
                body = (
                    "<html><body style='margin:0;background:#111;color:#eee;font-family:monospace'>"
                    "<div style='padding:8px'>Kinect Stream (ProtonectSR UDP -> MJPEG)</div>"
                    "<img src='/stream.mjpg' style='display:block;width:100vw;height:calc(100vh - 36px);object-fit:contain'>"
                    "</body></html>"
                ).encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return

            if self.path == "/health":
                self.send_response(200)
                self.send_header("Content-Type", "text/plain; charset=utf-8")
                self.end_headers()
                self.wfile.write(b"ok\n")
                return

            if self.path != "/stream.mjpg":
                self.send_error(404)
                return

            self.send_response(200)
            self.send_header("Age", "0")
            self.send_header("Cache-Control", "no-cache, private")
            self.send_header("Pragma", "no-cache")
            self.send_header("Content-Type", "multipart/x-mixed-replace; boundary=frame")
            self.end_headers()

            last_seq = -1
            try:
                while True:
                    jpeg, last_seq = store.wait_next(last_seq, timeout=2.0)
                    if jpeg is None:
                        continue

                    self.wfile.write(b"--frame\r\n")
                    self.wfile.write(b"Content-Type: image/jpeg\r\n")
                    self.wfile.write(("Content-Length: %d\r\n\r\n" % len(jpeg)).encode("ascii"))
                    self.wfile.write(jpeg)
                    self.wfile.write(b"\r\n")
            except (BrokenPipeError, ConnectionResetError):
                return

        def log_message(self, fmt, *args):  # noqa: A003
            return

    return Handler


def recv_exact_frame(sock: socket.socket, total_packets: int, timeout_s: float):
    payload = bytearray()
    deadline = time.time() + timeout_s
    for _ in range(total_packets):
        remaining = deadline - time.time()
        if remaining <= 0:
            return None
        sock.settimeout(remaining)
        try:
            packet, _ = sock.recvfrom(65535)
        except socket.timeout:
            return None
        payload.extend(packet)
    return bytes(payload)


def receiver_loop(
    sock: socket.socket,
    store: FrameStore,
    max_packets: int,
    frame_timeout_ms: int,
    stop_event: threading.Event,
):
    frame_timeout_s = max(frame_timeout_ms, 1) / 1000.0
    received = 0
    last_log = time.time()

    sock.settimeout(1.0)
    while not stop_event.is_set():
        try:
            header, _ = sock.recvfrom(64)
        except socket.timeout:
            continue
        except OSError:
            return

        if len(header) < 4:
            continue

        total_packets = int.from_bytes(header[:4], byteorder="little", signed=False)
        if total_packets <= 0 or total_packets > max_packets:
            continue

        frame = recv_exact_frame(sock, total_packets, frame_timeout_s)
        if not frame:
            continue

        store.set_frame(frame)
        received += 1

        now = time.time()
        if now - last_log >= 1.0:
            print(f"[bridge] frames={received}")
            last_log = now


def main():
    parser = argparse.ArgumentParser(description="Bridge ProtonectSR UDP packets into MJPEG HTTP stream.")
    parser.add_argument("--bind", default="127.0.0.1", help="Bind address for UDP and HTTP servers.")
    parser.add_argument("--udp-port", type=int, default=10000, help="UDP port that ProtonectSR streams to.")
    parser.add_argument("--http-port", type=int, default=18080, help="HTTP port for MJPEG stream.")
    parser.add_argument("--max-packets", type=int, default=4096, help="Upper bound to reject bad packet headers.")
    parser.add_argument(
        "--frame-timeout-ms",
        type=int,
        default=400,
        help="Timeout while collecting one frame payload after header.",
    )
    args = parser.parse_args()

    store = FrameStore()
    stop_event = threading.Event()

    udp_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        udp_sock.bind((args.bind, args.udp_port))
    except OSError as exc:
        print(f"[bridge] failed to bind UDP {args.bind}:{args.udp_port}: {exc}")
        return 1
    print(f"[bridge] UDP listening on {args.bind}:{args.udp_port}")

    recv_thread = threading.Thread(
        target=receiver_loop,
        args=(udp_sock, store, args.max_packets, args.frame_timeout_ms, stop_event),
        daemon=True,
    )

    try:
        server = ThreadingHTTPServer((args.bind, args.http_port), make_handler(store))
    except OSError as exc:
        print(f"[bridge] failed to bind HTTP {args.bind}:{args.http_port}: {exc}")
        udp_sock.close()
        return 1

    recv_thread.start()
    print(f"[bridge] HTTP MJPEG available at http://{args.bind}:{args.http_port}/")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        stop_event.set()
        server.shutdown()
        udp_sock.close()

    return 0

if __name__ == "__main__":
    raise SystemExit(main())
