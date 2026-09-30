"""Build local review sheets from accepted native page evidence."""
import argparse
import json
import math
from pathlib import Path
import shutil
from PIL import Image, ImageDraw, ImageFont

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("acceptance", type=Path)
parser.add_argument("output", type=Path)
parser.add_argument("--font", type=Path, required=True)
args = parser.parse_args()
accepted = json.loads(args.acceptance.read_text(encoding="utf-8"))
if accepted["passed"] is not True or accepted["missing"]:
    raise ValueError("Only fully accepted page evidence can be reviewed.")
args.output.mkdir(parents=True, exist_ok=True)
font = ImageFont.truetype(str(args.font), 20)
index, groups = {}, {}
for page, label in accepted["required_pages"].items():
    capture = Path(accepted["evidence"][page]["zh_CN-1860x2480"][0]["capture"])
    target = args.output / f"{page}.png"
    shutil.copyfile(capture, target)
    index[page] = {"label": label, "file": target.name, "source": str(capture)}
    groups.setdefault(page[0], []).append(page)
for group, pages in groups.items():
    columns, width, image_height, row_height, margin = 2, 360, 480, 520, 20
    rows = math.ceil(len(pages) / columns)
    canvas = Image.new("RGB", (columns * width + (columns + 1) * margin, rows * row_height + margin), "#eeeeee")
    draw = ImageDraw.Draw(canvas)
    for position, page in enumerate(pages):
        x, y = margin + position % columns * (width + margin), margin + position // columns * row_height
        draw.text((x, y), page + " " + index[page]["label"], font=font, fill="#111111")
        with Image.open(args.output / index[page]["file"]) as image:
            canvas.paste(image.convert("RGB").resize((width, image_height), Image.Resampling.LANCZOS), (x, y + 32))
    canvas.save(args.output / f"group-{group}.png")
(args.output / "index.json").write_text(json.dumps(index, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(json.dumps({"pages": len(index), "groups": len(groups), "output": str(args.output)}))
