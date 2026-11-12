from PIL import Image, ImageDraw, ImageFilter
import math, sys
S = 4096                      # draw at 4x, downsample for clean edges
OUT = sys.argv[1]
bg = (20, 20, 23)
img = Image.new("RGB", (S, S), bg)
d = ImageDraw.Draw(img)

# subtle panel: a slightly lighter inset plate with a hairline, like an anodised faceplate
# faint top light: barely-there falloff like a matte metal plate (not a decorative gradient)
for yy in range(0, S, 8):
    v = int(6 * max(0.0, 1 - yy / (S * 0.6)))
    d.rectangle([0, yy, S, yy + 8], fill=(bg[0] + v, bg[1] + v, bg[2] + v + 1))

orange = (255, 91, 26)
ring = (196, 196, 202)
dimring = (92, 92, 100)

# 3x3 jack grid
c0, step = S * 0.25, S * 0.25
centers = [[(c0 + i * step, c0 + j * step) for i in range(3)] for j in range(3)]
R_out, R_in = S * 0.072, S * 0.039

def jack(x, y, lit=False, faint=False):
    col = orange if lit else (dimring if faint else ring)
    d.ellipse([x - R_out, y - R_out, x + R_out, y + R_out], fill=col)
    d.ellipse([x - R_in, y - R_in, x + R_in, y + R_in], fill=(12, 12, 14))

start, end = centers[0][0], centers[0][2]          # top-left -> top-right
for j in range(3):
    for i in range(3):
        x, y = centers[j][i]
        if (j, i) in [(0, 0), (0, 2)]:
            continue
        jack(x, y, faint=(j, i) in [(1, 1), (2, 0), (2, 2)])

# patch cable: cubic bezier that sags below the diagonal (gravity), round ends
p0, p3 = start, end
sag = step * 0.5 * 4 / 3          # cubic control offset for a dip of half a row
p1 = (p0[0] + step * 0.35, p0[1] + sag)
p2 = (p3[0] - step * 0.35, p3[1] + sag)
def bez(t):
    a = (1-t)**3; b = 3*(1-t)**2*t; c = 3*(1-t)*t**2; e = t**3
    return (a*p0[0]+b*p1[0]+c*p2[0]+e*p3[0], a*p0[1]+b*p1[1]+c*p2[1]+e*p3[1])
W = S * 0.056
# soft shadow under the cable
sh = Image.new("L", (S, S), 0); sd = ImageDraw.Draw(sh)
for k in range(0, 601):
    x, y = bez(k / 600); sd.ellipse([x - W/2, y - W/2 + S*0.012, x + W/2, y + W/2 + S*0.012], fill=150)
sh = sh.filter(ImageFilter.GaussianBlur(S * 0.012))
img.paste((0, 0, 0), mask=sh)
d = ImageDraw.Draw(img)
for k in range(0, 801):
    x, y = bez(k / 800)
    d.ellipse([x - W/2, y - W/2, x + W/2, y + W/2], fill=orange)

# lit jacks at both ends, drawn over the cable (plugs)
for (x, y) in (start, end):
    d.ellipse([x - R_out*1.12, y - R_out*1.12, x + R_out*1.12, y + R_out*1.12], fill=orange)
    d.ellipse([x - R_in*0.9, y - R_in*0.9, x + R_in*0.9, y + R_in*0.9], fill=(20, 20, 23))
    d.ellipse([x - R_in*0.38, y - R_in*0.38, x + R_in*0.38, y + R_in*0.38], fill=orange)

img = img.resize((1024, 1024), Image.LANCZOS)
img.save(OUT, optimize=True)
for s in (180, 60, 40):
    img.resize((s, s), Image.LANCZOS).save(OUT.replace(".png", f"_{s}.png"))
