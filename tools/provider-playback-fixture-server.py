"""Loopback contract fixture for validating the test harness, NOT real servers."""
import http.server
import json
from pathlib import Path
import threading
import urllib.parse
import uuid


class FixtureServer:
    def __init__(self, root):
        self.root = Path(root)
        self.token = "synthetic-" + uuid.uuid4().hex
        self.media_requests = 0
        self.cleanup_requests = 0
        owner = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def send(self, data, content_type="application/json"):
                first, last = 0, len(data) - 1
                status = 200
                byte_range = self.headers.get("Range", "")
                if byte_range.startswith("bytes="):
                    a, _, b = byte_range[6:].partition("-")
                    first, last = int(a or 0), min(int(b) if b else last, last)
                    status = 206
                self.send_response(status)
                self.send_header("Content-Type", content_type)
                self.send_header("Accept-Ranges", "bytes")
                if status == 206:
                    self.send_header("Content-Range", f"bytes {first}-{last}/{len(data)}")
                self.send_header("Content-Length", str(last - first + 1))
                self.send_header("Connection", "close")
                self.end_headers()
                if self.command != "HEAD":
                    try:
                        self.wfile.write(data[first:last + 1])
                    except (BrokenPipeError, ConnectionResetError):
                        # AVPlayer routinely cancels its speculative/range reads.
                        pass

            def reply(self, value):
                self.send(json.dumps(value).encode())

            def handle_request(self):
                path = urllib.parse.urlsplit(self.path)
                query = dict(urllib.parse.parse_qsl(path.query))
                provided = list(query.values()) + list(self.headers.values())
                if not any(owner.token in value for value in provided):
                    self.send_error(401)
                    return
                body = {}
                if self.headers.get("Content-Length"):
                    raw = self.rfile.read(int(self.headers["Content-Length"]))
                    body = json.loads(raw) if raw else {}
                endpoint = path.path
                codec = query.get("VideoCodec", "h264")
                if "videoCodec=hevc" in query.get("X-Plex-Client-Profile-Extra", ""):
                    codec = "hevc"
                if codec != "h264":
                    self.send_error(400)
                    return
                if endpoint == "/api/v2/catalog/items/movie":
                    self.reply({
                        "content_id": "movie", "type": "movie", "title": "Synthetic fixture", "position_seconds": 0,
                        "versions": [{"file_id": "version", "resolution": "360p", "codec_video": "h264", "codec_audio": "aac",
                                      "container": "mp4", "file_size": (owner.root / "source.mp4").stat().st_size,
                                      "duration": 90, "bitrate": 4128,
                                      "video_tracks": [{"codec": "h264", "width": 640, "height": 360}]}],
                    })
                elif endpoint == "/api/v2/playback/capabilities":
                    self.reply({"installation_id": "fixture", "protocol_versions": [3],
                                "features": ["fixed_media_file_v1"], "deliveries": ["original_http", "server_transcode_hls"],
                                "state": "available", "allowed": True})
                elif endpoint == "/api/v2/playback/start":
                    session = str(uuid.uuid4())
                    converting = body.get("quality_preference") != "original"
                    path = f"/api/v2/playback/transcode/{session}/master.m3u8" if converting else f"/api/v2/stream/{session}"
                    self.reply({"protocol_version": 3, "outcome": "playable", "session_id": session,
                                "playback_plan": {"protocol_version": 3, "delivery": "server_transcode_hls" if converting else "original_http",
                                                  "effective_media_file_id": "version",
                                                  "stream": {"url": path + "?st=synthetic-session", "headers": {}, "header_refresh": "none"},
                                                  "timeline": {"source_start_seconds": 0, "player_start_seconds": 0,
                                                               "timeline_offset_seconds": 0, "can_seek_anywhere": True},
                                                  "subtitle": {"mode": "none", "inventory": []}}})
                elif endpoint.startswith("/api/v2/playback/") and self.command in ("POST", "DELETE"):
                    if self.command == "DELETE":
                        owner.cleanup_requests += 1
                    self.reply({"outcome": "stopped" if self.command == "DELETE" else "applied"})
                elif endpoint.startswith("/api/v2/stream/"):
                    owner.media_requests += 1
                    self.send((owner.root / "source.mp4").read_bytes(), "video/mp4")
                elif endpoint.endswith("/PlaybackInfo"):
                    source = {
                        "Id": "version", "Container": "mp4", "SupportsDirectPlay": True,
                        "SupportsTranscoding": True, "Bitrate": 4_128_000, "RunTimeTicks": 900_000_000,
                        "MediaStreams": [
                            {"Index": 0, "Type": "Video", "Codec": "h264", "Width": 640, "Height": 360},
                            {"Index": 1, "Type": "Audio", "Codec": "aac", "Channels": 2, "Language": "eng", "IsDefault": True},
                        ],
                    }
                    if body.get("EnableDirectPlay") is False:
                        profiles = body.get("DeviceProfile", {}).get("TranscodingProfiles", [])
                        requested = next((p.get("VideoCodec") for p in profiles if p.get("Type") == "Video"), "h264")
                        codec = "hevc" if requested == "hevc" else "h264"
                        if codec != "h264":
                            self.send_error(400)
                            return
                        source["TranscodingUrl"] = f"/Videos/movie/master.m3u8?VideoCodec={codec}&AudioCodec=aac"
                    self.reply({"PlaySessionId": uuid.uuid4().hex, "MediaSources": [source]})
                elif endpoint.endswith("/Users/user/Items/movie"):
                    self.reply({"Id": "movie", "Name": "Synthetic fixture", "Type": "Movie", "RunTimeTicks": 900_000_000})
                elif endpoint.endswith("/library/metadata/movie"):
                    self.reply({"MediaContainer": {"Metadata": [{
                        "ratingKey": "movie", "title": "Synthetic fixture", "type": "movie", "duration": 90000,
                        "Media": [{"id": 7, "container": "mp4", "videoCodec": "h264", "audioCodec": "aac",
                                   "bitrate": 4128, "width": 640, "height": 360,
                                   "Part": [{"id": 8, "key": "/library/parts/8/file.mp4", "Stream": [
                                       {"id": 1, "streamType": 2, "codec": "aac", "channels": 2,
                                        "languageCode": "eng", "default": True}
                                   ]}]}]
                    }]}})
                elif endpoint.endswith("/decision"):
                    self.reply({"MediaContainer": {"generalDecisionCode": 1001, "transcodeDecisionCode": 1001,
                                                   "Metadata": [{"Media": [{"container": "mp4", "videoCodec": codec}]}]}})
                elif endpoint.endswith("/ActiveEncodings") or endpoint.endswith("/universal/stop"):
                    owner.cleanup_requests += 1
                    self.reply({})
                elif endpoint.endswith(".m3u8"):
                    owner.media_requests += 1
                    if endpoint.endswith(("master.m3u8", "start.m3u8")):
                        text = '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=800000,CODECS="avc1.64001e,mp4a.40.2"\n'
                        text += f"/media/{codec}/main.m3u8?api_key={owner.token}\n"
                    else:
                        text = (owner.root / "hls/media.m3u8").read_text()
                        lines = []
                        for line in text.splitlines():
                            if line.startswith("#EXT-X-MAP:"):
                                line = f'#EXT-X-MAP:URI="/media/{codec}/init.mp4?api_key={owner.token}"'
                            elif line and not line.startswith("#"):
                                line = f"/media/{codec}/{line}?api_key={owner.token}"
                            lines.append(line)
                        text = "\n".join(lines) + "\n"
                    self.send(text.encode(), "application/vnd.apple.mpegurl")
                elif endpoint.startswith("/media/"):
                    owner.media_requests += 1
                    name = Path(endpoint).name
                    self.send((owner.root / "hls" / name).read_bytes(), "video/mp4")
                elif "/Videos/movie/stream" in endpoint or endpoint.endswith("/library/parts/8/file.mp4"):
                    owner.media_requests += 1
                    self.send((owner.root / "source.mp4").read_bytes(), "video/mp4")
                elif endpoint.endswith("/identity"):
                    self.reply({"MediaContainer": {"machineIdentifier": "fixture"}})
                elif "/Sessions/Playing" in endpoint or endpoint.endswith("/:/timeline"):
                    self.reply({})
                else:
                    self.send_error(404)

            do_GET = handle_request
            do_HEAD = handle_request
            do_POST = handle_request
            do_DELETE = handle_request

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever)

    def start(self):
        self.thread.start()
        return f"http://127.0.0.1:{self.server.server_port}"

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
