"""Generate original MJPEG + embedded styled ASS subtitle regression media.

Requires Pillow only to regenerate; no external footage or subtitle content.
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


style = '''[Script Info]
ScriptType: v4.00+
PlayResX: 320
PlayResY: 180
[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Arial,18,&H0000FF00,&H0000FF00,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,0,0,2,0,0,8,1
[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
'''
header = element('1A45DFA3', element('4286', 1) + element('42F7', 1)
                 + element('42F2', 4) + element('42F3', 8)
                 + element('4282', 'matroska') + element('4287', 4) + element('4285', 2))
info = element('1549A966', element('2AD7B1', 1000000) + element('4489', 5000.0)
               + element('4D80', 'AsterLink ASS fixture') + element('5741', 'AsterLink ASS fixture'))
video = element('AE', element('D7', 1) + element('73C5', 1) + element('83', 1)
                + element('86', 'V_MJPEG') + element('E0', element('B0', 320) + element('BA', 180)))
subtitle = element('AE', element('D7', 2) + element('73C5', 2) + element('83', 17)
                   + element('86', 'S_TEXT/ASS') + element('63A2', style)
                   + element('536E', 'Original green ASS dialogue') + element('88', 1))
frame = io.BytesIO()
Image.new('RGB', (320, 180), (18, 38, 76)).save(frame, 'JPEG', quality=70)
parts = [element('E7', 0)]
for timestamp in range(0, 5000, 100):
    parts.append(element('A3', vint(1) + struct.pack('>h', timestamp) + b'\x80' + frame.getvalue()))
    if timestamp == 0:
        packet = b'0,0,Default,,0,0,0,,Embedded ASS'
        parts.append(element('A0', element('A1', vint(2) + b'\x00\x00\x00' + packet)
                             + element('9B', 4000)))
media = header + element('18538067', info + element('1654AE6B', video + subtitle)
                         + element('1F43B675', b''.join(parts)))
target = Path(__file__).resolve().parents[2] / 'test/fixtures/player-ass.mkv'
target.write_bytes(media)
print(f'Generated {target.name}: {len(media)} bytes')
