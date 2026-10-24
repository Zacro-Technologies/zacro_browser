"""Build the screenshot guide after final application captures are approved.

Requires ReportLab and Pillow; both are included in the Codex workspace runtime.
Run from any directory: python scripts/create-feature-guide.py
Then render the PDF with Poppler and visually review every page before sharing.
The source captures are embedded whole, without retouching or synthetic UI.
"""

from argparse import ArgumentParser
from pathlib import Path

from PIL import Image
from reportlab.lib.colors import HexColor
from reportlab.lib.styles import ParagraphStyle
from reportlab.pdfgen import canvas
from reportlab.platypus import Paragraph


ROOT = Path(__file__).resolve().parents[1]
PAGES = [
    (
        "workspace.jpg",
        "01 / THE WORKSPACE",
        "Room for the web.",
        "Navigation and the address field live in the sidebar. Icon favorites, folders and "
        "single-line tabs stay close; Library, Spaces and creation share a quiet footer.",
    ),
    (
        "home-dark.jpg",
        "02 / A QUIET START",
        "Start with one thought.",
        "Search, saved destinations and recent pages. The new-tab page keeps familiar places "
        "nearby without repeating favorites already visible in the sidebar.",
    ),
    (
        "focus-mode.jpg",
        "03 / FOCUS",
        "Give the page more room.",
        "Ctrl/Command + Shift + B hides the sidebar without reloading the page. A compact "
        "navigation row keeps the address and sidebar toggle available.",
    ),
    (
        "command-palette.jpg",
        "04 / COMMAND BAR",
        "Move at the speed of a shortcut.",
        "Ctrl/Command + L opens the command bar. Find a tab, enter an address, search the web "
        "or choose a browser action. Escape returns to the page.",
    ),
    (
        "peek.jpg",
        "05 / PEEK",
        "Follow a link. Keep your place.",
        "Alt + click or the link menu opens a live preview. Escape dismisses it. Promote it "
        "to a tab while preserving its draft, scroll position and navigation history.",
    ),
    (
        "split-view.jpg",
        "06 / SPLIT VIEW",
        "Two pages, one workspace.",
        "Compare or reference pages side by side. The address and navigation follow the "
        "focused pane while both pages keep their position and live state.",
    ),
    (
        "bookmarks.jpg",
        "07 / LIBRARY",
        "Find what you left behind.",
        "Bookmarks, history, downloads and archived tabs share one Library entry. Search "
        "within a section, switch sections, or return directly to your browsing.",
    ),
    (
        "appearance-light.jpg",
        "08 / MAKE IT YOURS",
        "Small controls. Useful choices.",
        "Choose appearance, sidebar width and everyday behavior in Settings. Expand details "
        "when needed. Saved custom sidebar widths survive the compact layout update.",
    ),
    (
        "optional-ai.jpg",
        "09 / OPTIONAL AI",
        "Your Codex subscription, in reach.",
        "Connect Codex opens Settings, where Sign in with ChatGPT connects your subscription; "
        "no API-key or separate API billing. This capture is unconnected. Page sharing is explicit. Live account "
        "and inference acceptance remain open. This is a development build: sync, signed "
        "updates and commercial release gates remain unfinished. See README and docs/VALIDATION.md.",
    ),
]


def build(screenshots, output):
    missing = [name for name, *_ in PAGES if not (screenshots / name).is_file()]
    if missing:
        raise FileNotFoundError("Missing final captures: " + ", ".join(missing))

    output.parent.mkdir(parents=True, exist_ok=True)
    width, height = 792, 612  # US Letter, landscape; one intact screenshot per page.
    margin = 32
    doc = canvas.Canvas(str(output), pagesize=(width, height), pageCompression=1)
    doc.setTitle("Zacro 0.4 - Design and Feature Guide")
    doc.setAuthor("Zacro Technologies")
    doc.setSubject("Windows development interface, features and release boundaries")
    body = ParagraphStyle(
        "caption", fontName="Helvetica", fontSize=9, leading=12,
        textColor=HexColor("#4f5c59"), spaceAfter=0,
    )
    background = HexColor("#f7f7f3")
    ink = HexColor("#233a32")
    muted = HexColor("#68766f")

    for index, (filename, label, title, caption) in enumerate(PAGES, start=1):
        doc.setFillColor(background)
        doc.rect(0, 0, width, height, fill=1, stroke=0)

        doc.setFont("Helvetica-Bold", 8)
        doc.setFillColor(muted)
        doc.drawString(margin, height - 27, "ZACRO / INTERFACE 0.4")
        doc.drawRightString(width - margin, height - 27, label)
        doc.setFont("Helvetica", 23)
        doc.setFillColor(ink)
        doc.drawString(margin, height - 57, title)

        paragraph = Paragraph(caption, body)
        _, caption_height = paragraph.wrap(width - 2 * margin, 80)
        caption_bottom = 35
        screenshot_bottom = caption_bottom + caption_height + 16
        screenshot_top = height - 76
        available_width = width - 2 * margin
        available_height = screenshot_top - screenshot_bottom
        path = screenshots / filename
        with Image.open(path) as image:
            image_width, image_height = image.size
        scale = min(available_width / image_width, available_height / image_height)
        draw_width, draw_height = image_width * scale, image_height * scale
        x = (width - draw_width) / 2
        y = screenshot_top - draw_height
        doc.setFillColor(HexColor("#e0e5df"))
        doc.roundRect(x - 1, y - 1, draw_width + 2, draw_height + 2, 5, fill=1, stroke=0)
        doc.drawImage(str(path), x, y, width=draw_width, height=draw_height, mask="auto")
        paragraph.drawOn(doc, margin, caption_bottom)

        doc.setStrokeColor(HexColor("#dce3dc"))
        doc.setLineWidth(0.4)
        doc.line(margin, 26, width - margin, 26)
        doc.setFillColor(muted)
        doc.setFont("Helvetica", 7)
        doc.drawString(margin, 15, "WINDOWS DEVELOPMENT BUILD / ISOLATED LOCAL DEMO / ORIGINAL CAPTURES")
        doc.drawRightString(width - margin, 15, f"{index:02d} / {len(PAGES):02d}")
        doc.showPage()

    doc.save()
    print(output.resolve())


if __name__ == "__main__":
    parser = ArgumentParser(description=__doc__)
    parser.add_argument("--screenshots", type=Path, default=ROOT / "docs/screenshots")
    parser.add_argument(
        "--output", type=Path,
        default=ROOT / "output/pdf/Zacro-0.4-Design-and-Feature-Guide.pdf",
    )
    args = parser.parse_args()
    build(args.screenshots.resolve(), args.output.resolve())
