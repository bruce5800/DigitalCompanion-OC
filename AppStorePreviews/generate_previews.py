#!/usr/bin/env python3
"""Compose App Store-ready screenshots from deterministic simulator captures."""

from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont


ROOT = Path(__file__).resolve().parent
PHONE_DIR = ROOT / "zh-Hans" / "iPhone"
VISION_DIR = ROOT / "zh-Hans" / "VisionPro"
ICON_PATH = ROOT.parent / "DigitalCompanionPhone" / "Assets.xcassets" / "AppIcon.appiconset" / "AppIcon1024.png"
FONT_PATH = "/System/Library/Fonts/Hiragino Sans GB.ttc"


def font(size: int, bold: bool = False) -> ImageFont.FreeTypeFont:
    # TTC index 1 is the heavier face on current macOS; fall back gracefully.
    try:
        return ImageFont.truetype(FONT_PATH, size=size, index=1 if bold else 0)
    except OSError:
        return ImageFont.truetype("/System/Library/Fonts/STHeiti Medium.ttc", size=size)


def vertical_gradient(size: tuple[int, int], top: tuple[int, int, int], bottom: tuple[int, int, int]) -> Image.Image:
    width, height = size
    image = Image.new("RGB", size)
    pixels = image.load()
    for y in range(height):
        t = y / max(height - 1, 1)
        color = tuple(round(a + (b - a) * t) for a, b in zip(top, bottom))
        for x in range(width):
            pixels[x, y] = color
    return image


def rounded_icon(size: int) -> Image.Image:
    icon = Image.open(ICON_PATH).convert("RGBA").resize((size, size), Image.Resampling.LANCZOS)
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, size, size), radius=round(size * 0.23), fill=255)
    icon.putalpha(mask)
    return icon


def rounded_card(source: Image.Image, size: tuple[int, int], radius: int) -> Image.Image:
    fitted = source.convert("RGB").resize(size, Image.Resampling.LANCZOS).convert("RGBA")
    mask = Image.new("L", size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, size[0], size[1]), radius=radius, fill=255)
    fitted.putalpha(mask)
    return fitted


def draw_brand(draw: ImageDraw.ImageDraw, canvas: Image.Image, x: int, y: int, icon_size: int, text_color: tuple[int, int, int], name: str):
    canvas.alpha_composite(rounded_icon(icon_size), (x, y))
    draw.text((x + icon_size + 24, y + icon_size // 2), name, font=font(round(icon_size * 0.38), True), fill=text_color, anchor="lm")


def compose_phone(source_name: str, output_name: str, headline: str, subtitle: str):
    width, height = 1320, 2868
    canvas = vertical_gradient((width, height), (255, 246, 235), (247, 169, 170)).convert("RGBA")
    draw = ImageDraw.Draw(canvas)
    ink = (91, 49, 44)
    draw_brand(draw, canvas, 88, 74, 92, ink, "炉边·随身")
    draw.multiline_text((88, 224), headline, font=font(78, True), fill=ink, spacing=12)
    draw.text((90, 424), subtitle, font=font(34), fill=(126, 79, 72))

    source = Image.open(PHONE_DIR / source_name)
    card_size = (1120, round(source.height * 1120 / source.width))
    x, y = 100, 540
    shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    shadow_draw = ImageDraw.Draw(shadow)
    shadow_draw.rounded_rectangle((x, y + 18, x + card_size[0], y + card_size[1] + 18), radius=72, fill=(103, 52, 47, 60))
    shadow = shadow.filter(ImageFilter.GaussianBlur(28))
    canvas.alpha_composite(shadow)
    canvas.alpha_composite(rounded_card(source, card_size, 68), (x, y))
    canvas.convert("RGB").save(PHONE_DIR / output_name, quality=96)


def compose_vision(source_name: str, output_name: str, headline: str, subtitle: str):
    source = Image.open(VISION_DIR / source_name).convert("RGBA")
    canvas = source.copy()

    # Warm translucent title card; preserves the actual spatial UI and environment.
    panel = Image.new("RGBA", source.size, (0, 0, 0, 0))
    panel_draw = ImageDraw.Draw(panel)
    panel_draw.rounded_rectangle((150, 130, 1760, 680), radius=72, fill=(255, 242, 226, 226), outline=(255, 255, 255, 150), width=3)
    shadow = Image.new("RGBA", source.size, (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle((150, 150, 1760, 700), radius=72, fill=(71, 40, 37, 65))
    shadow = shadow.filter(ImageFilter.GaussianBlur(30))
    canvas.alpha_composite(shadow)
    canvas.alpha_composite(panel)

    draw = ImageDraw.Draw(canvas)
    ink = (91, 49, 44)
    draw_brand(draw, canvas, 220, 190, 96, ink, "炉边")
    draw.multiline_text((220, 340), headline, font=font(86, True), fill=ink, spacing=12)
    draw.text((222, 565), subtitle, font=font(38), fill=(126, 79, 72))
    canvas.convert("RGB").save(VISION_DIR / output_name, quality=96)


def main():
    phone_specs = [
        ("01-chat-raw.png", "01-listens.png", "随时有人，\n认真听你说", "从一句“今天有点累”开始。"),
        ("02-chat-sg-raw.png", "02-thinks-with-you.png", "不只回应，\n也陪你理清思绪", "把压力拆小一点，把下一步看清一点。"),
        ("03-chat-xo-raw.png", "03-small-joys.png", "把平凡日子，\n聊成小期待", "不同性格，陪你度过不同心情。"),
        ("04-profile-raw.png", "04-your-avatar.png", "选择属于你的样子", "原创头像，让每一次对话更像你。"),
        ("05-memory-raw.png", "05-remembers.png", "越聊越懂你", "记住你的偏好，也珍藏共同经历。"),
    ]
    for spec in phone_specs:
        compose_phone(*spec)

    vision_specs = [
        ("01-chat-clean.png", "01-spatial-chat.png", "让陪伴，\n出现在你的空间里", "聊天窗口自然融入熟悉的房间。"),
        ("02-immersive-oc-raw.png", "02-companion-oc.png", "她不只在屏幕里", "原创角色来到你面前，陪伴更有存在感。"),
        ("03-immersive-sg-raw.png", "03-companion-sg.png", "不同性格，\n都能来到你身边", "选择此刻最适合你的陪伴。"),
        ("04-immersive-xo-raw.png", "04-companion-xo.png", "在熟悉的房间，\n自然地聊一会儿", "空间计算，让陪伴成为生活的一部分。"),
        ("05-gesture-guide-raw.png", "05-gesture-interaction.png", "挥挥手，\n她就会回应", "握拳说话、挥手招呼，用手势自然互动。"),
        ("06-avatar-studio-raw.png", "06-character-workshop.png", "在角色工坊，\n设计她的样子", "发型、服饰、发色与声线，由你选择。"),
        ("07-movement-mode-raw.png", "07-movement-modes.png", "静止、跟随、\n自主切换", "选择此刻适合的角色行动方式。"),
    ]
    for spec in vision_specs:
        compose_vision(*spec)


if __name__ == "__main__":
    main()
