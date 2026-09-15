"""Build a portable before/after comparison from two native screenshot galleries."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil

from PIL import Image, ImageDraw, ImageFont


PRIMARY_SCENES = [
    ("bookshelf-finishing-default", "书架", "观察封面、阅读位置和书架操作的层级。"),
    ("bookstore-expanded-recommendations", "书城", "观察封面辨识、分类入口和每屏浏览密度。"),
    ("native-search", "搜索", "观察主搜索入口、漫画 ID 入口与空历史的区别。"),
    ("native-chapters", "章节", "观察操作分组、在读标记、状态说明与可见章节数量。"),
    ("native-downloads", "下载", "观察任务状态、主要操作及副本身份是否容易辨认。"),
    ("native-account", "账户与设置", "观察账户状态、设置分组和常用维护操作。"),
    ("review-reader-reader-page-fit", "原生阅读器", "观察阅读画面与宿主控件是否保持清晰、完整。"),
]

STATE_SCENES = [
    ("review-supplement-chapters-selection-empty", "章节 · 尚未选择下载", "观察不可用主动作与可执行操作的视觉区别。"),
    ("review-supplement-chapters-selection-selected", "章节 · 已选择下载", "观察选择标记、已选数量和下载入口。"),
    ("review-supplement-search-results", "搜索 · 结果列表", "观察结果行的可点击范围、信息层级和分页。"),
    ("review-supplement-search-no-results", "搜索 · 无结果", "观察无结果说明是否明确，并提供合适的下一步。"),
    ("native-purchase", "购买 · 单章确认", "观察具体章节、金额和确认操作是否清楚。"),
    ("native-purchase-batch", "购买 · 批量确认", "观察批量范围、金额和范围变化说明的层级。"),
    ("native-purchase-low-balance", "购买 · 余额不足", "观察余额不足提示和可用的后续操作。"),
    ("native-purchase-unknown", "购买 · 结果待确认", "观察结果未知时的状态说明和核对入口。"),
    ("native-account-pending", "账户 · 待确认购买", "观察未完成的购买记录是否容易发现。"),
    ("qr-login-qr-waiting", "登录 · 等待扫码", "观察二维码、登录步骤与辅助操作的顺序。"),
    ("qr-login-qr-account-reauthentication", "账户 · 需要重新登录", "观察登录失效原因与恢复入口是否清楚。"),
    ("download-recovery-recovery-options", "下载 · 恢复选项", "观察恢复方式之间的区别和需要满足的前提。"),
    ("download-recovery-error-content-changed", "下载 · 内容已变化", "观察恢复限制、已存内容与新版本选择的说明。"),
    ("version-replacement-old-and-new-versions", "下载 · 新旧副本", "观察新旧版本的关联、已存图片与主要操作。"),
    ("review-supplement-download-remove-confirmation", "下载 · 移除确认", "观察漫画、章节、副本身份和删除后果是否明确。"),
    ("review-supplement-downloads-empty", "下载 · 暂无任务", "观察空态说明、创建下载的入口和分页是否合理。"),
    ("review-reader-reader-menu", "阅读器 · 插件菜单", "观察菜单分组、当前状态与常用入口。"),
    ("review-reader-reader-next-locked", "阅读器 · 下一章待解锁", "观察下一章信息、报价入口与返回阅读的操作。"),
    ("review-reader-reader-error-network", "阅读器 · 网络错误", "观察错误原因、重试与返回路径是否清楚。"),
    ("bookshelf-finishing-confirmed-empty", "书架 · 暂无内容", "观察空书架说明及进入书城、搜索的下一步。"),
]

RESOLUTIONS = ("600x800", "480x640")
OVERVIEW_SCENES = ("native-chapters", "native-account", "bookstore-expanded-recommendations")
STATIC_FILES = ("comparison.html", "comparison.css", "comparison.js", "build_comparison.py")


def read_manifest(root: Path) -> dict:
    value = json.loads((root / "manifest.json").read_text(encoding="utf-8"))
    if not isinstance(value, dict) or not isinstance(value.get("screens"), list):
        raise ValueError("The gallery manifest must contain a screens array: " + str(root))
    return value


def safe_path(root: Path, relative: str) -> Path:
    if Path(relative).is_absolute():
        raise ValueError("Screenshot paths must be relative to the gallery: " + relative)
    path = (root / relative).resolve()
    if path != root and root not in path.parents:
        raise ValueError("A screenshot path escapes its gallery: " + relative)
    if not path.is_file():
        raise ValueError("A screenshot file is missing: " + str(path))
    return path


def variant_map(screen: dict) -> dict:
    result = {}
    for variant in screen.get("variants", []):
        key = (variant.get("locale"), variant.get("resolution"))
        if key in result:
            raise ValueError("A scene has duplicate locale/size variants: " + str(screen.get("id")))
        result[key] = variant
    return result


def provenance(manifest: dict) -> dict:
    source = manifest.get("provenance") or {}
    return {
        "generatedAt": manifest.get("generatedAt"),
        "capturedAt": source.get("captureFinishedAt") or source.get("captureStartedAt"),
        "runtimeVersion": source.get("runtimeVersion"),
        "revision": source.get("revision"),
        "captureMethod": source.get("captureMethod", "KOReader native framebuffer"),
        "syntheticData": source.get("syntheticData", True),
    }


def image_record(root: Path, variant: dict, display_src: str) -> dict:
    path = safe_path(root, variant["src"])
    with Image.open(path) as image:
        width, height = image.size
    return {
        "src": display_src,
        "width": width,
        "height": height,
        "sourcePath": variant["src"],
        "capturePath": variant.get("capturePath"),
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
    }


def resolve_font(argument: Path | None) -> Path | None:
    if argument is not None:
        if not argument.is_file():
            raise ValueError("The supplied CJK font does not exist: " + str(argument))
        return argument
    configured = os.environ.get("UI_REVIEW_FONT")
    if configured:
        return resolve_font(Path(configured))
    for value in (
        "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
        "/usr/share/fonts/truetype/noto/NotoSansCJK-Regular.ttc",
        "/usr/share/fonts/truetype/wqy/wqy-microhei.ttc",
        "C:/Windows/Fonts/msyh.ttc",
    ):
        path = Path(value)
        if path.is_file():
            return path
    return None


def fit_text(draw, text: str, font, maximum: int) -> str:
    if draw.textbbox((0, 0), text, font=font)[2] <= maximum:
        return text
    while text and draw.textbbox((0, 0), text + "…", font=font)[2] > maximum:
        text = text[:-1]
    return text + "…"


def render_overview(after_root: Path, scenes: list[dict], font_path: Path | None) -> dict | None:
    if font_path is None:
        return None
    by_id = {scene["id"]: scene for scene in scenes}
    selected = []
    for scene_id in OVERVIEW_SCENES:
        scene = by_id.get(scene_id)
        pair = next((item for item in scene["pairs"] if item["resolution"] == "600x800"), None) if scene else None
        if pair:
            selected.append((scene, pair))
    if len(selected) < 2:
        return None

    # Each 600 by 800 source is pasted at its original pixel size, without cropping.
    margin, gap, image_width, image_height = 30, 24, 600, 800
    width = 2 * margin + 2 * image_width + gap
    header_height, row_height, footer_height = 112, 928, 38
    canvas = Image.new("RGB", (width, header_height + row_height * len(selected) + footer_height), "#e9eef3")
    draw = ImageDraw.Draw(canvas)
    heading = ImageFont.truetype(str(font_path), 27)
    body = ImageFont.truetype(str(font_path), 17)
    utility = ImageFont.truetype(str(font_path), 12)
    draw.text((margin, 22), "BiliComics · 原生界面优化前后", font=heading, fill="#152436")
    draw.text((margin, 66), "同一场景 · 简体中文 · 600 × 800 原始截图 · KOReader 原生渲染 / 合成数据", font=body, fill="#546477")
    for index, (scene, pair) in enumerate(selected):
        top = header_height + row_height * index
        draw.text((margin, top), scene["title"], font=heading, fill="#152436")
        draw.text((margin, top + 41), fit_text(draw, scene["id"], utility, width - margin * 2), font=utility, fill="#546477")
        for side, column in (("before", 0), ("after", 1)):
            left = margin + column * (image_width + gap)
            draw.text((left, top + 62), "优化前" if side == "before" else "优化后", font=body, fill="#152436")
            source = safe_path(after_root, pair[side]["src"])
            with Image.open(source) as image:
                canvas.paste(image.convert("RGB"), (left, top + 92))
            draw.rectangle((left - 1, top + 91, left + image_width, top + 92 + image_height), outline="#aebcca", width=1)
    draw.text((margin, canvas.height - 27), "完整对照与原图：comparison.html · 测试内容可能随夹具更新而变化", font=utility, fill="#546477")
    filename = "overview-comparison.png"
    canvas.save(after_root / filename, optimize=True)
    return {"src": filename, "width": canvas.width, "height": canvas.height, "sceneIds": [scene["id"] for scene, _pair in selected]}


def build(before_root: Path, after_root: Path, font_path: Path | None = None) -> dict:
    before_root, after_root = before_root.resolve(), after_root.resolve()
    if before_root == after_root:
        raise ValueError("The before and after gallery directories must be different.")
    before = read_manifest(before_root)
    after = read_manifest(after_root)
    before_scenes = {scene["id"]: scene for scene in before["screens"]}
    after_scenes = {scene["id"]: scene for scene in after["screens"]}
    group_titles = {group["id"]: group["title"] for group in after.get("groups", [])}
    scenes, skipped, copied = [], [], set()
    for primary, choices in ((True, PRIMARY_SCENES), (False, STATE_SCENES)):
        for scene_id, title, focus in choices:
            left, right = before_scenes.get(scene_id), after_scenes.get(scene_id)
            if left is None or right is None:
                skipped.append({"sceneId": scene_id, "reason": "missing_before_scene" if left is None else "missing_after_scene"})
                continue
            before_variants, after_variants = variant_map(left), variant_map(right)
            pairs = []
            for resolution in RESOLUTIONS:
                key = ("zh_CN", resolution)
                left_variant, right_variant = before_variants.get(key), after_variants.get(key)
                if left_variant is None or right_variant is None:
                    skipped.append({"sceneId": scene_id, "resolution": resolution, "reason": "missing_matched_variant"})
                    continue
                original_before = safe_path(before_root, left_variant["src"])
                relative_before = Path("before") / original_before.relative_to(before_root)
                left_record = image_record(before_root, left_variant, relative_before.as_posix())
                relative_after = safe_path(after_root, right_variant["src"]).relative_to(after_root).as_posix()
                right_record = image_record(after_root, right_variant, relative_after)
                expected_width, expected_height = (int(value) for value in resolution.split("x"))
                if any((record["width"], record["height"]) != (expected_width, expected_height) for record in (left_record, right_record)):
                    skipped.append({"sceneId": scene_id, "resolution": resolution, "reason": "actual_image_dimensions_do_not_match"})
                    continue
                destination = after_root / relative_before
                destination.parent.mkdir(parents=True, exist_ok=True)
                if destination.as_posix() not in copied:
                    shutil.copy2(original_before, destination)
                    copied.add(destination.as_posix())
                pairs.append({"locale": "zh_CN", "resolution": resolution, "width": expected_width, "height": expected_height, "before": left_record, "after": right_record})
            if pairs:
                group = right.get("group", left.get("group", ""))
                scenes.append({"id": scene_id, "title": title, "focus": focus, "primary": primary, "group": group, "groupTitle": group_titles.get(group, "其他页面"), "pairs": pairs})
    if not scenes:
        raise ValueError("No selected Chinese scenes have matching 600x800 or 480x640 screenshots.")

    data = {
        "schemaVersion": 1,
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "before": provenance(before),
        "after": provenance(after),
        "sceneCount": len(scenes),
        "pairCount": sum(len(scene["pairs"]) for scene in scenes),
        "copiedBeforeCount": len(copied),
        "matchingPolicy": "Exact scene identifier, Simplified Chinese locale, and actual pixel dimensions; no image substitution or cropping.",
        "scenes": scenes,
        "skipped": skipped,
        "overview": render_overview(after_root, scenes, resolve_font(font_path)),
    }
    payload = json.dumps(data, ensure_ascii=False, indent=2)
    (after_root / "comparison-data.js").write_text("window.UI_REVIEW_COMPARISON = " + payload + ";\n", encoding="utf-8")
    (after_root / "comparison-manifest.json").write_text(payload + "\n", encoding="utf-8")
    source_root = Path(__file__).resolve().parent
    for filename in STATIC_FILES:
        if (source_root / filename).resolve() != (after_root / filename).resolve():
            shutil.copy2(source_root / filename, after_root / filename)
    return data


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--before", type=Path, required=True, help="The baseline gallery containing manifest.json and original screenshot files.")
    parser.add_argument("--after", type=Path, required=True, help="The generated optimized gallery; comparison assets and selected baseline images are added here.")
    parser.add_argument("--font", type=Path, help="Optional CJK font for the native-size comparison sheet; also accepts UI_REVIEW_FONT.")
    args = parser.parse_args()
    data = build(args.before, args.after, args.font)
    print(json.dumps({"scenes": data["sceneCount"], "pairs": data["pairCount"], "copied_before": data["copiedBeforeCount"], "overview_generated": data["overview"] is not None, "skipped": len(data["skipped"]), "output": str(args.after.resolve())}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
