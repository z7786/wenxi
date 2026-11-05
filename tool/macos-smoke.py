"""Exercise the bundled helper and observe a macOS app's first main frame."""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import plistlib
import subprocess
import time
import tempfile
import threading


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--app', required=True)
args = parser.parse_args()
app = Path(args.app).resolve()
root = Path(__file__).resolve().parent.parent
metadata = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
helper = app / 'Contents/MacOS/asterlink_gopeed'
query = '\n'.join(json.dumps({'seq': index, 'method': method, 'args': values})
                  for index, (method, values) in enumerate([
                      ('version', {}), ('freeSpace', {'path': str(root / '.local')})], 1)) + '\n'
result = subprocess.run([str(helper)], input=query, capture_output=True, text=True, timeout=20, check=True)
responses = [json.loads(line) for line in result.stdout.splitlines() if line.strip()]
assert len(responses) == 2 and not any(value.get('error') for value in responses)
assert responses[0]['result']['protocol'] == 1
assert responses[0]['result']['ed2k'] and responses[0]['result']['parserHttp2']
assert responses[1]['result']['bytes'] > 0
executable = app / 'Contents/MacOS' / metadata['CFBundleExecutable']
logs = Path.home() / 'Library/Application Support' / metadata['CFBundleIdentifier'] / 'AsterLink/diagnostics'
started = time.time()
captured = root / '.local/macos-launch.log'
ready = False
with captured.open('wb') as output:
    process = subprocess.Popen([str(executable)], stdout=output, stderr=output)
    try:
        deadline = time.monotonic() + 45
        while time.monotonic() < deadline:
            assert process.poll() is None, 'macOS app exited before showing its main page'
            for file in logs.rglob('*.jsonl') if logs.exists() else []:
                if file.stat().st_mtime < started:
                    continue
                text = file.read_text(encoding='utf-8', errors='replace')
                assert 'app.initialize_failed' not in text
                if 'app.main_frame' in text:
                    ready = True
                    break
            if ready:
                break
            time.sleep(.5)
        assert ready, 'macOS app did not record a main frame within 45 seconds'
    finally:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()

# Open two real playback processes through the same protocol used by the app.
# A small local Y4M fixture exercises decoding without an external cloud account.
progress = {}
with tempfile.TemporaryDirectory(prefix='asterlink-playback-') as temporary:
    movie = Path(temporary) / 'sample.y4m'
    with movie.open('wb') as output:
        output.write(b'YUV4MPEG2 W160 H90 F30:1 Ip A1:1 C420jpeg\n')
        frame = bytes([100]) * (160 * 90) + bytes([128]) * (160 * 90 // 2)
        for _ in range(360):
            output.write(b'FRAME\n' + frame)

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            self.respond({'url': movie.as_uri(), 'title': 'macOS playback smoke',
                          'positionMs': 0, 'preferences': {},
                          'videoGeometry': {'width': 160, 'height': 90}})

        def do_POST(self):
            body = bytearray()
            if self.headers.get('Transfer-Encoding', '').lower() == 'chunked':
                while True:
                    size = int(self.rfile.readline(128).split(b';', 1)[0], 16)
                    assert len(body) + size < 16384
                    if size == 0:
                        assert self.rfile.readline(128) == b'\r\n'
                        break
                    body.extend(self.rfile.read(size))
                    assert self.rfile.read(2) == b'\r\n'
            else:
                length = int(self.headers.get('Content-Length', 0))
                assert 0 < length < 16384
                body.extend(self.rfile.read(length))
            progress.setdefault(self.path, []).append(json.loads(body))
            self.respond({})

        def respond(self, value):
            data = json.dumps(value).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)

    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    players = []
    playback_passed = False
    with (root / '.local/macos-playback.log').open('wb') as output:
        try:
            for index in range(2):
                endpoint = f'http://127.0.0.1:{server.server_port}/window{index}'
                players.append(subprocess.Popen([str(executable), '--asterlink-player-window', endpoint],
                                                stdout=output, stderr=output))
            deadline = time.monotonic() + 35
            while time.monotonic() < deadline:
                assert all(player.poll() is None for player in players), (
                    'Independent playback process exited: codes=' + str([player.poll() for player in players]) +
                    ', ready=' + str({path: len(values) for path, values in progress.items()}))
                if all(any(state.get('positionMs', 0) > 500 and state.get('durationMs', 0) > 1000
                           for state in progress.get(f'/window{index}', [])) for index in range(2)):
                    playback_passed = True
                    break
                time.sleep(.5)
            else:
                raise AssertionError('Two independent players did not decode and advance playback')
        finally:
            for player in players:
                player.terminate()
                try:
                    player.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    player.kill()
                    player.wait()
            server.shutdown()
            server.server_close()
    if not playback_passed:
        print((root / '.local/macos-playback.log').read_text(errors='replace')[-8000:])

print('macOS smoke passed: native helper, free disk space, startup, two independent windows and video decoding')
