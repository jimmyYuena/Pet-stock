#!/usr/bin/env python3
"""Render the app icon from the in-app StockPetMascot (bull) vector design.
Geometry/colours mirror StockPetMascot in native/StockPet.swift exactly."""
import cairosvg
from PIL import Image, ImageDraw
import io, os

CANVAS = 1024
CONTENT = 824
MARGIN = (CANVAS - CONTENT) // 2
RADIUS = int(CONTENT * 0.2247)

S = 745          # mascot "side" in px
CX = 512
CY = 512 - 28    # nudge up so body/legs don't sit low

def rgb(r, g, b):
    return f"#{round(r*255):02X}{round(g*255):02X}{round(b*255):02X}"

BASE   = rgb(0.96, 0.13, 0.16)   # bull red
DARK   = rgb(0.56, 0.035, 0.06)
OUT    = rgb(0.035, 0.06, 0.13)  # outline
FACE   = rgb(0.025, 0.10, 0.16)  # screen
GLOW   = rgb(0.42, 0.96, 1.0)    # cyan eyes
HORN   = rgb(1.0, 0.83, 0.52)    # gold
MUZ    = rgb(1.0, 0.72, 0.29)    # muzzle
BG1    = rgb(0.12, 0.13, 0.17)
BG2    = rgb(0.045, 0.05, 0.07)
LW = S * 0.025

def X(fx): return CX + fx * S
def Y(fy): return CY + fy * S
def L(f):  return f * S

def rect(fx, fy, fw, fh, rr, fill, stroke=None, deg=0, opacity=1.0):
    x, y, w, h = X(fx) - L(fw)/2, Y(fy) - L(fh)/2, L(fw), L(fh)
    t = f' transform="rotate({deg} {X(fx)} {Y(fy)})"' if deg else ''
    s = f' stroke="{stroke}" stroke-width="{LW}"' if stroke else ''
    o = f' opacity="{opacity}"' if opacity != 1.0 else ''
    return f'<rect x="{x:.2f}" y="{y:.2f}" width="{w:.2f}" height="{h:.2f}" rx="{L(rr):.2f}" ry="{L(rr):.2f}" fill="{fill}"{s}{t}{o}/>'

def capsule(fx, fy, fw, fh, fill, stroke=None, deg=0):
    return rect(fx, fy, fw, fh, min(fw, fh)/2, fill, stroke, deg)

def circle(fx, fy, fd, fill):
    return f'<circle cx="{X(fx):.2f}" cy="{Y(fy):.2f}" r="{L(fd)/2:.2f}" fill="{fill}"/>'

p = []
# ---- background squircle + clip ----
p.append(f'''<defs>
  <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
    <stop offset="0" stop-color="{BG1}"/><stop offset="1" stop-color="{BG2}"/>
  </linearGradient>
  <linearGradient id="red" x1="0" y1="0" x2="1" y2="1">
    <stop offset="0" stop-color="{BASE}"/><stop offset="1" stop-color="{DARK}"/>
  </linearGradient>
  <clipPath id="sq"><rect x="{MARGIN}" y="{MARGIN}" width="{CONTENT}" height="{CONTENT}" rx="{RADIUS}" ry="{RADIUS}"/></clipPath>
</defs>''')
p.append(f'<rect x="{MARGIN}" y="{MARGIN}" width="{CONTENT}" height="{CONTENT}" rx="{RADIUS}" ry="{RADIUS}" fill="url(#bg)"/>')

p.append(f'<g clip-path="url(#sq)">')
# soft shadow under robot
p.append(f'<ellipse cx="{X(0)}" cy="{Y(0.44)}" rx="{L(0.30):.1f}" ry="{L(0.05):.1f}" fill="#000000" opacity="0.28"/>')

# ---- BODY ----
p.append(rect(0, 0.245, 0.43, 0.34, 0.09, "url(#red)", OUT))
for d in (-1, 1):
    p.append(capsule(d*0.255, 0.20, 0.13, 0.27, BASE, OUT, deg=d*15))   # arm
    p.append(rect(d*0.115, 0.395, 0.14, 0.17, 0.04, DARK, OUT))          # leg
# up arrow on body (white, bold) — sits on the chest below the head
ax = X(0)
apex = Y(0.215); bottom = Y(0.345); aw = L(0.058); sw = L(0.034)
p.append(f'<path d="M {ax:.1f} {apex:.1f} L {ax:.1f} {bottom:.1f} '
         f'M {ax:.1f} {apex:.1f} L {ax-aw:.1f} {apex+aw:.1f} '
         f'M {ax:.1f} {apex:.1f} L {ax+aw:.1f} {apex+aw:.1f}" '
         f'stroke="#FFFFFF" stroke-width="{sw:.1f}" fill="none" stroke-linecap="round" stroke-linejoin="round"/>')

# ---- HEAD ----
for d in (-1, 1):   # golden horns
    p.append(capsule(d*0.255, -0.31, 0.115, 0.24, HORN, OUT, deg=d*24))
p.append(rect(0, -0.07, 0.72, 0.53, 0.17, "url(#red)", OUT))        # head shell
p.append(rect(0, -0.055, 0.53, 0.32, 0.105, FACE, OUT))             # face screen
for d in (-1, 1):   # cyan eyes
    p.append(circle(d*0.0975, -0.095, 0.055, GLOW))
p.append(rect(0, 0.018, 0.18, 0.078, 0.035, MUZ))                   # muzzle
for d in (-1, 1):
    p.append(circle(d*0.0385, 0.018, 0.022, DARK))                  # nostrils
p.append('</g>')

svg = (f'<svg xmlns="http://www.w3.org/2000/svg" width="{CANVAS}" height="{CANVAS}" '
       f'viewBox="0 0 {CANVAS} {CANVAS}">' + ''.join(p) + '</svg>')

with open("icon_master.svg", "w") as f:
    f.write(svg)

png = cairosvg.svg2png(bytestring=svg.encode(), output_width=CANVAS, output_height=CANVAS)
master = Image.open(io.BytesIO(png)).convert("RGBA")
master.save("AppIcon.png")           # full 1024 (used as reference/notification source)
master.save("AppIconRounded.png")    # rounded master (already squircle-shaped)

os.makedirs("StockPet.iconset", exist_ok=True)
for name, s in [("icon_16x16",16),("icon_16x16@2x",32),("icon_32x32",32),("icon_32x32@2x",64),
                ("icon_128x128",128),("icon_128x128@2x",256),("icon_256x256",256),
                ("icon_256x256@2x",512),("icon_512x512",512),("icon_512x512@2x",1024)]:
    master.resize((s, s), Image.LANCZOS).save(f"StockPet.iconset/{name}.png")
master.save("StockPet.icns")   # Pillow fallback icns
print("icon generated from mascot geometry")
