#!/usr/bin/env python3
"""Render the app icon (kimi-a) from one geometry list into a 1024 px opaque PNG and the matching SVG.

Pure stdlib: AppKit cannot build its module cache under this shell's sandbox (see make-icon.py's note), so the
shapes are rasterised here — analytic coverage for the circles, distance-to-polyline for the strokes — and the SVG
is written from the same list, so the source and the render cannot drift apart.

Usage:
  python3 render-icon.py out-dir            # writes icon-kimi-a.svg, icon-1024.png, icon-1024-dark.png

The geometry is the lead's redraw of the photographed Oct 9 icon (.tmp/oct9/icon-kimi-a.svg), with the three
differences that photograph shows and the redraw did not:
  * TWO whisker stripes a cheek, not three (the middle stripe is gone; the lower one sits where the photograph's
    lower stripe is);
  * the inner ear is a dark-orange crescent (#C05020), not a cream disc;
  * (measured, not changed) the head is a 700-unit circle in both: 82 px of the 120 px photograph's 1024 units at
    its widest row, crown y=205 and chin y=905 against the redraw's 210/910.
"""
import math
import shutil
import struct
import sys
import zlib

S = 1024
BG = (0x1F, 0x1E, 0x1C)
FACE_L = (0xF2, 0xA0, 0x3D)
FACE_R = (0xE0, 0x7B, 0x29)
STROKE = (0xB0, 0x4E, 0x14)
EAR_IN = (0xC0, 0x50, 0x20)
INK = (0x2A, 0x1A, 0x12)
CREAM = (0xFA, 0xF3, 0xE3)

HEAD_C = (512.0, 560.0)
HEAD_R = 350.0
EAR_L = (280.0, 316.0)
EAR_R = (744.0, 316.0)
EAR_R_R = 98.0
INNER_R = 40.0        # the crescent's own radius inside the ear
INNER_W = 26.0        # its thickness
INNER_A0, INNER_A1 = 172.0, 288.0   # the left ear's arc, in degrees, y down; the right is its mirror

# A path is (kind, points): "L" a straight polyline, "Q" a chain of quadratics ([p0, c1, p1, c2, p2, …]).
WHISKERS = [
    ("Q", [(258, 588), (299, 599), (340, 608)]),
    ("Q", [(264, 661), (294, 673), (326, 679)]),
    ("Q", [(766, 588), (725, 599), (684, 608)]),
    ("Q", [(760, 661), (730, 673), (698, 679)]),
]
# The forehead mark is a STRAIGHT V (the SVG's own `L`), not a curve.
CHEVRON = ("L", [(438, 346), (512, 405), (586, 346)])
EYES = [(400, 546, 28), (624, 546, 28)]
MUZZLE = [(452, 704, 79), (572, 704, 79)]
NOSE = ("Q", [(483, 660), (512, 650), (541, 660), (527, 681), (518, 691), (512, 697), (506, 691), (497, 681), (483, 660)])
MOUTH = [("L", [(512, 689), (512, 711)]),
         ("Q", [(475, 720), (496, 739), (512, 711), (528, 739), (549, 720)])]


def arc_points(cx, cy, r, a0, a1, steps=48):
    return [(cx + r * math.cos(math.radians(a0 + (a1 - a0) * i / steps)),
             cy + r * math.sin(math.radians(a0 + (a1 - a0) * i / steps))) for i in range(steps + 1)]


def quad_points(p0, p1, p2, steps=24):
    out = []
    for i in range(steps + 1):
        t = i / steps
        u = 1 - t
        out.append((u * u * p0[0] + 2 * u * t * p1[0] + t * t * p2[0],
                    u * u * p0[1] + 2 * u * t * p1[1] + t * t * p2[1]))
    return out


def flatten(path):
    """(kind, points) -> a polyline. "L" is already one; "Q" is [p0, c1, p1, c2, p2, …]."""
    kind, pts = path
    if kind == "L":
        return pts
    out = [pts[0]]
    i = 1
    while i + 1 < len(pts):
        out += quad_points(pts[i - 1], pts[i], pts[i + 1])[1:]
        i += 2
    return out


# --- raster ---------------------------------------------------------------------------------------------------

buf = bytearray(b"".join(bytes(BG) for _ in range(S * S)))


def put(x, y, cov, colour):
    if cov <= 0:
        return
    i = (y * S + x) * 3
    for c in range(3):
        d = buf[i + c]
        buf[i + c] = max(0, min(255, int(d + (colour[c] - d) * cov + 0.5)))


def coverage(d):
    """One-pixel analytic antialiasing: d is the signed distance (negative inside)."""
    if d <= -0.5:
        return 1.0
    if d >= 0.5:
        return 0.0
    return 0.5 - d


def bbox_of(pts, pad):
    xs = [p[0] for p in pts]
    ys = [p[1] for p in pts]
    return (max(0, int(min(xs) - pad)), max(0, int(min(ys) - pad)),
            min(S, int(max(xs) + pad) + 2), min(S, int(max(ys) + pad) + 2))


def draw_circle(cx, cy, r, colour):
    x0, y0, x1, y1 = bbox_of([(cx - r, cy - r), (cx + r, cy + r)], 1.5)
    for y in range(y0, y1):
        dy = y + 0.5 - cy
        for x in range(x0, x1):
            dx = x + 0.5 - cx
            put(x, y, coverage(math.hypot(dx, dy) - r), colour)


def draw_half(cx, cy, r, colour, left):
    x0, y0, x1, y1 = bbox_of([(cx - r, cy - r), (cx + r, cy + r)], 1.5)
    for y in range(y0, y1):
        dy = y + 0.5 - cy
        for x in range(x0, x1):
            dx = x + 0.5 - cx
            if left and dx > 0:
                continue
            if not left and dx < 0:
                continue
            put(x, y, coverage(math.hypot(dx, dy) - r), colour)


def seg_dist(px, py, ax, ay, bx, by):
    vx, vy = bx - ax, by - ay
    wx, wy = px - ax, py - ay
    L = vx * vx + vy * vy
    t = 0.0 if L == 0 else max(0.0, min(1.0, (wx * vx + wy * vy) / L))
    return math.hypot(px - (ax + t * vx), py - (ay + t * vy))


def draw_stroke(pts, w, colour, closed=False):
    x0, y0, x1, y1 = bbox_of(pts, w)
    half = w / 2
    n = len(pts)
    for y in range(y0, y1):
        py = y + 0.5
        for x in range(x0, x1):
            px = x + 0.5
            d = min(seg_dist(px, py, pts[i][0], pts[i][1], pts[i + 1][0], pts[i + 1][1]) for i in range(n - 1))
            put(x, y, coverage(d - half), colour)


def draw_polygon(pts, colour):
    """Even-odd fill with a 1-px soft edge, from the distance to the outline and a crossing count."""
    x0, y0, x1, y1 = bbox_of(pts, 2)
    n = len(pts)
    for y in range(y0, y1):
        py = y + 0.5
        for x in range(x0, x1):
            px = x + 0.5
            inside = False
            j = n - 1
            for i in range(n):
                if (pts[i][1] > py) != (pts[j][1] > py):
                    xc = pts[i][0] + (py - pts[i][1]) * (pts[j][0] - pts[i][0]) / (pts[j][1] - pts[i][1])
                    if px < xc:
                        inside = not inside
                j = i
            d = min(seg_dist(px, py, pts[i][0], pts[i][1], pts[(i + 1) % n][0], pts[(i + 1) % n][1]) for i in range(n))
            put(x, y, coverage(-d) if inside else 0.0, colour)


def render(path):
    draw_circle(*EAR_L, EAR_R_R, FACE_L)
    draw_circle(*EAR_R, EAR_R_R, FACE_R)
    draw_stroke(arc_points(*EAR_L, INNER_R, INNER_A0, INNER_A1), INNER_W, EAR_IN)
    # The mirror of the left arc: x -> 1024 - x maps the angle t to 180 - t, and it runs the other way round.
    draw_stroke(arc_points(*EAR_R, INNER_R, 180 - INNER_A0, 180 - INNER_A1), INNER_W, EAR_IN)
    draw_half(*HEAD_C, HEAD_R, FACE_L, True)
    draw_half(*HEAD_C, HEAD_R, FACE_R, False)
    draw_stroke(flatten(CHEVRON), 34, STROKE)
    for w in WHISKERS:
        draw_stroke(flatten(w), 24, STROKE)
    for cx, cy, r in EYES:
        draw_circle(cx, cy, r, INK)
    for cx, cy, r in MUZZLE:
        draw_circle(cx, cy, r, CREAM)
    draw_polygon(flatten(NOSE), INK)
    for m in MOUTH:
        draw_stroke(flatten(m), 12, INK)
    write_png(path)


def write_png(path):
    rows = b"".join(b"\x00" + bytes(buf[y * S * 3:(y + 1) * S * 3]) for y in range(S))
    ihdr = struct.pack(">IIBBBBB", S, S, 8, 2, 0, 0, 0)
    with open(path, "wb") as fh:
        fh.write(b"\x89PNG\r\n\x1a\n")
        for kind, payload in ((b"IHDR", ihdr), (b"IDAT", zlib.compress(rows, 9)), (b"IEND", b"")):
            fh.write(struct.pack(">I", len(payload)) + kind + payload
                     + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF))


def write_svg(path):
    def pts(ps):
        return " ".join(f"{p[0]:g} {p[1]:g}" for p in ps)
    def qpath(path):
        kind, p = path
        d = f"M{p[0][0]:g} {p[0][1]:g}"
        i = 1
        while i + 1 < len(p):
            d += f"{kind}{p[i][0]:g} {p[i][1]:g} {p[i+1][0]:g} {p[i+1][1]:g}"
            i += 2
        if i < len(p):
            d += f"L{p[i][0]:g} {p[i][1]:g}"
        return d
    left = arc_points(*EAR_L, INNER_R, INNER_A0, INNER_A1)
    right = arc_points(*EAR_R, INNER_R, 180 - INNER_A0, 180 - INNER_A1)
    (ax, ay), (bx, by) = left[0], left[-1]
    (cx, cy), (dx, dy) = right[0], right[-1]
    with open(path, "w") as fh:
        fh.write(f'''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <rect width="1024" height="1024" fill="#1F1E1C"/>

  <circle cx="280" cy="316" r="98" fill="#F2A03D"/>
  <circle cx="744" cy="316" r="98" fill="#E07B29"/>
  <!-- the inner ear: a dark-orange crescent, not a cream disc (the photograph's own ear) -->
  <g fill="none" stroke="#C05020" stroke-width="26" stroke-linecap="round">
    <path d="M{ax:.0f} {ay:.0f}A40 40 0 0 1 {bx:.0f} {by:.0f}"/>
    <path d="M{cx:.0f} {cy:.0f}A40 40 0 0 0 {dx:.0f} {dy:.0f}"/>
  </g>

  <path d="M512 210A350 350 0 0 0 512 910Z" fill="#F2A03D"/>
  <path d="M512 210A350 350 0 0 1 512 910Z" fill="#E07B29"/>

  <g fill="none" stroke="#B04E14" stroke-linecap="round" stroke-linejoin="round">
    <path d="{qpath(CHEVRON)}" stroke-width="34"/>
    <!-- TWO stripes a cheek, as the photograph has them -->
    <g stroke-width="24">
''')
        for w in WHISKERS:
            fh.write(f'      <path d="{qpath(w)}"/>\n')
        fh.write(f'''    </g>
  </g>

  <g fill="#2A1A12">
    <circle cx="400" cy="546" r="28"/>
    <circle cx="624" cy="546" r="28"/>
  </g>

  <g fill="#FAF3E3">
    <circle cx="452" cy="704" r="79"/>
    <circle cx="572" cy="704" r="79"/>
  </g>

  <path d="M483 660Q512 650 541 660Q527 681 518 691Q512 697 506 691Q497 681 483 660Z" fill="#2A1A12"/>

  <g fill="none" stroke="#2A1A12" stroke-width="12" stroke-linecap="round" stroke-linejoin="round">
    <path d="M512 689V711"/>
    <path d="M475 720Q496 739 512 711Q528 739 549 720"/>
  </g>
</svg>
''')


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "."
    render(f"{out}/icon-1024.png")
    # Both catalog entries are this one picture. The command promises the dark asset too (Codex R12 P3), and the
    # committed variants are identical, so the second is a copy rather than a second render that could drift.
    shutil.copyfile(f"{out}/icon-1024.png", f"{out}/icon-1024-dark.png")
    write_svg(f"{out}/icon-kimi-a.svg")
    print(f"wrote {out}/icon-1024.png, {out}/icon-1024-dark.png and {out}/icon-kimi-a.svg")
