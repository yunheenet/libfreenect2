#!/usr/bin/env python3

import argparse
import signal
import socket
import subprocess
import time
from typing import Optional


class RtspBridge:
    def __init__(
        self,
        udp_bind: str,
        udp_port: int,
        rtsp_url: str,
        fps: int,
        encoder: str,
        rtsp_transport: str,
        gop: int,
        video_bitrate: str,
        x264_preset: str,
        max_packets: int,
        frame_timeout_ms: int,
    ) -> None:
        self.udp_bind = udp_bind
        self.udp_port = udp_port
        self.rtsp_url = rtsp_url
        self.fps = fps
        self.encoder = encoder
        self.rtsp_transport = rtsp_transport
        self.gop = gop
        self.video_bitrate = video_bitrate
        self.x264_preset = x264_preset
        self.max_packets = max_packets
        self.frame_timeout_ms = frame_timeout_ms
        self.ffmpeg: Optional[subprocess.Popen] = None
        self.stop = False

    def _ffmpeg_cmd(self):
        cmd = [
            "ffmpeg",
            "-hide_banner",
            "-loglevel",
            "warning",
            "-nostdin",
            "-fflags",
            "nobuffer",
            "-f",
            "mjpeg",
            "-r",
            str(self.fps),
            "-i",
            "pipe:0",
            "-an",
            "-c:v",
            self.encoder,
            "-flags",
            "+global_header+low_delay",
            "-pix_fmt",
            "yuv420p",
            "-profile:v",
            "baseline",
            "-g",
            str(self.gop),
            "-bf",
            "0",
        ]

        if self.video_bitrate:
            cmd += [
                "-b:v",
                self.video_bitrate,
                "-maxrate",
                self.video_bitrate,
                "-bufsize",
                self.video_bitrate,
            ]

        if self.encoder == "libx264":
            cmd += [
                "-preset",
                self.x264_preset,
                "-tune",
                "zerolatency",
                "-x264-params",
                f"keyint={self.gop}:min-keyint={self.gop}:scenecut=0:rc-lookahead=0:sync-lookahead=0",
            ]
        elif self.encoder == "h264_videotoolbox":
            cmd += ["-realtime", "true", "-prio_speed", "true", "-max_ref_frames", "1"]

        cmd += [
            "-f",
            "rtsp",
            "-rtsp_transport",
            self.rtsp_transport,
            "-muxdelay",
            "0.01",
            "-muxpreload",
            "0",
            self.rtsp_url,
        ]
        return cmd

    def _start_ffmpeg(self) -> None:
        if self.ffmpeg is not None and self.ffmpeg.poll() is None:
            return

        cmd = self._ffmpeg_cmd()
        print("[bridge] starting ffmpeg:", " ".join(cmd))
        self.ffmpeg = subprocess.Popen(
            cmd,
            stdin=subprocess.PIPE,
            stdout=subprocess.DEVNULL,
            stderr=None,
        )

    def _stop_ffmpeg(self) -> None:
        if self.ffmpeg is None:
            return

        try:
            if self.ffmpeg.stdin:
                self.ffmpeg.stdin.close()
        except OSError:
            pass

        try:
            self.ffmpeg.terminate()
            self.ffmpeg.wait(timeout=2.0)
        except Exception:
            try:
                self.ffmpeg.kill()
            except Exception:
                pass

        self.ffmpeg = None

    def _recv_frame(self, sock: socket.socket) -> Optional[bytes]:
        try:
            header, _ = sock.recvfrom(64)
        except socket.timeout:
            return None

        if len(header) < 4:
            return None

        total_packets = int.from_bytes(header[:4], byteorder="little", signed=False)
        if total_packets <= 0 or total_packets > self.max_packets:
            return None

        payload = bytearray()
        deadline = time.time() + (max(self.frame_timeout_ms, 1) / 1000.0)
        for _ in range(total_packets):
            timeout = deadline - time.time()
            if timeout <= 0:
                return None
            sock.settimeout(timeout)
            try:
                packet, _ = sock.recvfrom(65535)
            except socket.timeout:
                return None
            payload.extend(packet)

        data = bytes(payload)
        if len(data) < 2 or data[0] != 0xFF or data[1] != 0xD8:
            return None
        return data

    def run(self) -> int:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            sock.bind((self.udp_bind, self.udp_port))
        except OSError as exc:
            print(f"[bridge] failed to bind UDP {self.udp_bind}:{self.udp_port}: {exc}")
            return 1

        sock.settimeout(1.0)
        print(f"[bridge] UDP listening on {self.udp_bind}:{self.udp_port}")
        print(f"[bridge] RTSP publish url: {self.rtsp_url}")

        frames = 0
        last_log = time.time()

        try:
            while not self.stop:
                frame = self._recv_frame(sock)
                if frame is None:
                    continue

                if self.ffmpeg is None or self.ffmpeg.poll() is not None:
                    self._start_ffmpeg()

                if self.ffmpeg is None or self.ffmpeg.stdin is None:
                    continue

                try:
                    self.ffmpeg.stdin.write(frame)
                    self.ffmpeg.stdin.flush()
                    frames += 1
                except BrokenPipeError:
                    self._stop_ffmpeg()
                    continue

                now = time.time()
                if now - last_log >= 1.0:
                    print(f"[bridge] frames={frames}")
                    last_log = now
        finally:
            sock.close()
            self._stop_ffmpeg()

        return 0


def parse_args():
    parser = argparse.ArgumentParser(description="Bridge ProtonectSR custom UDP stream into H.264 RTSP.")
    parser.add_argument("--udp-bind", default="127.0.0.1", help="UDP bind address for ProtonectSR packets.")
    parser.add_argument("--udp-port", type=int, default=10000, help="UDP port for ProtonectSR packets.")
    parser.add_argument("--rtsp-url", required=True, help="RTSP publish url. Example: rtsp://127.0.0.1:8554/kinect")
    parser.add_argument("--fps", type=int, default=30, help="Nominal input FPS.")
    parser.add_argument(
        "--encoder",
        default="h264_videotoolbox",
        choices=["h264_videotoolbox", "libx264"],
        help="H.264 encoder to use.",
    )
    parser.add_argument(
        "--rtsp-transport",
        default="tcp",
        choices=["tcp", "udp"],
        help="Transport between ffmpeg publisher and RTSP server.",
    )
    parser.add_argument("--gop", type=int, default=15, help="GOP size (lower can reduce latency).")
    parser.add_argument(
        "--video-bitrate",
        default="8M",
        help="Target bitrate for encoder (e.g. 6M, 10M). Empty string disables explicit bitrate.",
    )
    parser.add_argument(
        "--x264-preset",
        default="ultrafast",
        help="x264 preset when encoder=libx264.",
    )
    parser.add_argument("--max-packets", type=int, default=4096, help="Upper bound for packet header validation.")
    parser.add_argument("--frame-timeout-ms", type=int, default=400, help="Timeout to gather one frame.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    bridge = RtspBridge(
        udp_bind=args.udp_bind,
        udp_port=args.udp_port,
        rtsp_url=args.rtsp_url,
        fps=args.fps,
        encoder=args.encoder,
        rtsp_transport=args.rtsp_transport,
        gop=args.gop,
        video_bitrate=args.video_bitrate,
        x264_preset=args.x264_preset,
        max_packets=args.max_packets,
        frame_timeout_ms=args.frame_timeout_ms,
    )

    def _stop(_sig, _frame):
        bridge.stop = True

    signal.signal(signal.SIGINT, _stop)
    signal.signal(signal.SIGTERM, _stop)
    return bridge.run()


if __name__ == "__main__":
    raise SystemExit(main())
