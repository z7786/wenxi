"""Generate original MJPEG + embedded PGS bitmap subtitle regression media.

Requires Pillow only to regenerate. The green rectangle is deliberately not
text: this verifies a bitmap decoder rather than libass/font rendering.
"""
import io
from pathlib import Path
import struct
from PIL import Image


def vint(value):
    for length in range(1, 9):
        if value < (1 << (7 * length)) - 1:
            return ((1 << (7 * length)) | value).to_bytes(length, 'big')
    raise ValueError(value)


def element(identifier, content):
    if isinstance(content, str):
        content = content.encode('utf-8')
    if isinstance(content, int):
        content = content.to_bytes(max(1, (content.bit_length() + 7) // 8), 'big')
    if isinstance(content, float):
        content = struct.pack('>d', content)
    return bytes.fromhex(identifier) + vint(len(content)) + content


def segment(kind, payload):
    return bytes([kind]) + struct.pack('>H', len(payload)) + payload


def composition(number, state, visible):
    # Video size, frame rate, composition number/state, palette, object count.
    payload = struct.pack('>HHBHBBBB', 320, 180, 0x10, number, state, 0, 0, int(visible))
    if visible:
        payload += struct.pack('>HBBHH', 0, 0, 0, 100, 140)
    return segment(0x16, payload)


# PGS RLE: each row contains 120 pixels using palette entry 1, then EOL.
rle = b'\x00\xc0\x78\x01\x00\x00' * 24
object_payload = struct.pack('>HBB', 0, 0, 0xc0)
object_payload += (len(rle) + 4).to_bytes(3, 'big')
object_payload += struct.pack('>HH', 120, 24) + rle
bitmap = composition(0, 0x80, True)
bitmap += segment(0x17, struct.pack('>BBHHHH', 1, 0, 100, 140, 120, 24))
# Limited-range BT.709 Y/Cr/Cb approximates bright green.
bitmap += segment(0x14, bytes([0, 0, 0, 16, 128, 128, 0, 1, 173, 26, 42, 255]))
bitmap += segment(0x15, object_payload) + segment(0x80, b'')
clear = composition(1, 0, False) + segment(0x80, b'')

header = element('1A45DFA3', element('4286', 1) + element('42F7', 1)
                 + element('42F2', 4) + element('42F3', 8)
                 + element('4282', 'matroska') + element('4287', 4) + element('4285', 2))
info = element('1549A966', element('2AD7B1', 1000000) + element('4489', 5000.0)
               + element('4D80', 'AsterLink PGS fixture') + element('5741', 'AsterLink PGS fixture'))
video = element('AE', element('D7', 1) + element('73C5', 1) + element('83', 1)
                + element('86', 'V_MJPEG') + element('E0', element('B0', 320) + element('BA', 180)))
subtitle = element('AE', element('D7', 2) + element('73C5', 2) + element('83', 17)
                   + element('86', 'S_HDMV/PGS') + element('536E', 'Original green PGS bitmap')
                   + element('22B59C', 'eng') + element('88', 1))
frame = io.BytesIO()
Image.new('RGB', (320, 180), (18, 38, 76)).save(frame, 'JPEG', quality=70)
parts = [element('E7', 0)]
for timestamp in range(0, 5000, 100):
    parts.append(element('A3', vint(1) + struct.pack('>h', timestamp) + b'\x80' + frame.getvalue()))
    if timestamp in (0, 4000):
        payload = bitmap if timestamp == 0 else clear
        parts.append(element('A3', vint(2) + struct.pack('>h', timestamp) + b'\x80' + payload))
media = header + element('18538067', info + element('1654AE6B', video + subtitle)
                         + element('1F43B675', b''.join(parts)))
target = Path(__file__).resolve().parents[2] / 'test/fixtures/player-pgs.mkv'
target.write_bytes(media)
print(f'Generated {target.name}: {len(media)} bytes')
