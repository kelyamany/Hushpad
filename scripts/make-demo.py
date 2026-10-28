# Builds the README demo (docs/images/demo.svg): four slides that crossfade on a loop, with retina
# screenshots as WebP and the captions as real text in the app's fonts. Much sharper and smaller than a GIF.
#
# Usage: python3 -I scripts/make-demo.py <snapshot-folder> docs/images/demo.svg
# The snapshot folder holds the demo-mode window captures (see docs/DEVELOPMENT.md › Screenshots):
# nub-2-window.png, notes-0-main.png, transcript-0-main.png and list-0-main.png.
# Needs cwebp (brew install webp) and uv, which runs fonttools to subset the fonts.
import base64, subprocess, sys, tempfile
from pathlib import Path

frames, out = Path(sys.argv[1]), Path(sys.argv[2])
fonts = Path(__file__).resolve().parent.parent / "HushpadKit/Sources/HushpadUI/Fonts"
work = Path(tempfile.mkdtemp())
W, H, SHOT_H = 960, 830, 1520 * 960 / 1918
INK, BG = "#1c2b4d", "#f4f5f8"
TITLE, TAGLINE = "Hushpad", "Meeting notes that stay on your Mac."
CAPTIONS = [
    "A call starts. One click and you're taking notes.",
    "Afterwards: what was decided, and who does what.",
    "Every word transcribed on your Mac. Audio never leaves it.",
    "All your meetings, as plain files you keep.",
]

def data(path, mime):
    return f"data:{mime};base64," + base64.b64encode(path.read_bytes()).decode()

def webp(src, name, *args):
    dst = work / f"{name}.webp"
    subprocess.run(["cwebp", "-quiet", "-m", "6", *args, str(src), "-o", str(dst)], check=True)
    return data(dst, "image/webp")

def subset(font, name, text):
    dst = work / f"{name}.woff2"
    subprocess.run(["uvx", "--from", "fonttools[woff]", "pyftsubset", str(font), f"--text={text}",
                    "--flavor=woff2", f"--output-file={dst}", "--layout-features=kern,liga"], check=True)
    return data(dst, "font/woff2")

sans = subset(fonts / "HankenGrotesk.ttf", "sans", "".join(CAPTIONS) + TAGLINE)
serif = subset(fonts / "IBMPlexSerif-Regular.ttf", "serif", TITLE)
nub = webp(frames / "nub-2-window.png", "nub", "-lossless")
# The captures are 2360 px wide; the first 442 px are the sidebar, which they can't render.
shots = [webp(frames / f"{n}-0-main.png", n, "-q", "90", "-crop", "442", "0", "1918", "1520")
         for n in ("notes", "transcript", "list")]

def caption(text):
    return f'<text class="c" x="{W / 2}" y="{H - 30}" text-anchor="middle">{text.replace("&", "&amp;")}</text>'

slides = [
    f'<image href="{nub}" x="{W - 300}" y="197" width="300" height="375"/>'
    f'<text class="t" x="110" y="360">{TITLE}</text>'
    f'<text class="g" x="114" y="408">{TAGLINE}</text>' + caption(CAPTIONS[0])
] + [f'<rect width="{W}" height="{H}" fill="{BG}"/><image href="{s}" x="0" y="0" width="{W}" height="{SHOT_H:.1f}"/>'
     + caption(c) for s, c in zip(shots, CAPTIONS[1:])]

# 5 s per slide, 0.6 s fades. Each slide fades in over the one below it; the first one never moves, so the
# loop fades the last slide out to reveal it again.
keyframes = """
@keyframes s1{0%,22%{opacity:0}25%,50%{opacity:1}50.01%,100%{opacity:0}}
@keyframes s2{0%,47%{opacity:0}50%,75%{opacity:1}75.01%,100%{opacity:0}}
@keyframes s3{0%,72%{opacity:0}75%,97%{opacity:1}100%{opacity:0}}"""

groups = [f'<g>{slides[0]}</g>'] + [
    f'<g class="s{" still" if i == 1 else ""}" style="animation-name:s{i}">{body}</g>'
    for i, body in enumerate(slides[1:], 1)]

svg = f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" role="img" aria-label="Hushpad in action: a call starts and Hushpad offers to take notes; the notes list decisions and action items; the transcript shows who said what; all meetings in one list. Every meeting shown is invented.">
<style>
@font-face{{font-family:Sans;src:url({sans}) format("woff2")}}
@font-face{{font-family:Serif;src:url({serif}) format("woff2")}}
text{{fill:{INK}}}
.c{{font:26px Sans,system-ui,sans-serif}}
.t{{font:72px Serif,Georgia,serif}}
.g{{font:28px Sans,system-ui,sans-serif;fill-opacity:.65}}
.s{{opacity:0;animation:20s ease-in-out infinite}}
{keyframes.strip()}
@media (prefers-reduced-motion:reduce){{.s{{animation:none}}.still{{opacity:1}}}}
</style>
<clipPath id="card"><rect width="{W}" height="{H}" rx="14"/></clipPath>
<g clip-path="url(#card)">
<rect width="{W}" height="{H}" fill="{BG}"/>
{chr(10).join(groups)}
</g>
</svg>
"""
out.write_text(svg)
print(f"{out}: {out.stat().st_size / 1e6:.2f} MB")
