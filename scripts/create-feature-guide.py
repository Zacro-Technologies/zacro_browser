"""Build the eight-page 0.9 guide after final application captures are approved.

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
    ("workspace.jpg", "01 / THE WORKSPACE", "A place for everything.",
     "Balanced profile-wide Favorites sit above saved Space pins and Today tabs. The saved destination "
     "survives navigation and closing. A slash marks a navigated pin; its favicon returns home. Replace Pin "
     "saves the current page. Today tabs archive after 12 idle hours by default, with per-profile controls."),
    ("library-menu.jpg", "02 / LIBRARY", "Choose where to go.",
     "Library first offers named destinations in a compact menu. Arrow keys, typeahead and Escape keep "
     "it usable without a pointer. Opening the chooser leaves the live page visible, without capturing "
     "or changing its rendering scale."),
    ("library.jpg", "03 / BROWSER PANELS", "One continuous window.",
     "A borderless panel shares the window material. Search, flat rows and date groups keep "
     "saved resources easy to scan. Drag either rail edge to resize, or focus the separator and use "
     "arrow keys. Native page bounds follow the change without reloading."),
    ("palette.jpg", "04 / KEYBOARD WORKFLOW", "Find it. Then act.",
     "Find tabs, folders, Spaces, bookmarks, history and commands. Tab opens a result's actions and "
     "destination choices; Escape steps back. A configured site keyword followed by Tab enters Site Search. "
     "The palette casts a layered shadow without blurring, dimming or changing the page underneath."),
    ("space-theme.jpg", "05 / PERSONALIZATION", "Make room for your world.",
     "Choose from 38 Space icons, circular color swatches, grain from 0-200 and window tint from 0-100. "
     "Space colors blend with swipe progress. Supported systems use acrylic or vibrancy with OS blur. "
     "Text and webpages remain opaque. Accessibility preferences can force opaque chrome."),
    ("peek.jpg", "06 / PEEK", "Follow a link, stay here.",
     "Shift-click a link to open Peek. Its 180ms entrance and 120ms exit move the live page without scaling. Promote "
     "it without replacing the document, or dismiss it to return. Links from a saved pin to another hostname can "
     "also Peek; forms, redirects and explicit window semantics retain native behavior."),
    ("dark.jpg", "07 / DARK APPEARANCE", "Selection you can see.",
     "Selected rows and command results have a distinct fill, outline and accent edge. Focus remains "
     "visible in high contrast. Browser panels share the window's material, while the content page retains "
     "its own colors and rounded frame."),
    ("compact.jpg", "08 / COMPACT WINDOWS", "A smaller footprint.",
     "The layout supports 560 by 420 logical pixels. Panels make room for a usable page and retain saved "
     "sidebar preferences. These original Windows captures use an instrumented local demo. Physical Mac "
     "input, live providers and commercial release gates remain open; Google account login is still blocked."),
]


def build(screenshots, output):
    missing = [name for name, *_ in PAGES if not (screenshots / name).is_file()]
    if missing:
        raise FileNotFoundError("Missing final captures: " + ", ".join(missing))

    output.parent.mkdir(parents=True, exist_ok=True)
    width, height = 792, 612  # US Letter, landscape; one intact screenshot per page.
    margin = 32
    doc = canvas.Canvas(str(output), pagesize=(width, height), pageCompression=1)
    doc.setTitle("Zacro 0.9 - Design and Feature Guide")
    doc.setAuthor("Zacro Technologies")
    doc.setSubject("Zacro 0.9 balanced Favorites, Space pins, Today archive, continuous themes and Peek motion")
    body = ParagraphStyle(
        "caption", fontName="Helvetica", fontSize=9, leading=12,
        textColor=HexColor("#5f5661"), spaceAfter=0,
    )
    background = HexColor("#f7f4f3")
    ink = HexColor("#342c35")
    muted = HexColor("#766b77")

    for index, (filename, label, title, caption) in enumerate(PAGES, start=1):
        doc.setFillColor(background)
        doc.rect(0, 0, width, height, fill=1, stroke=0)

        doc.setFont("Helvetica-Bold", 8)
        doc.setFillColor(muted)
        doc.drawString(margin, height - 27, "ZACRO / INTERFACE 0.9")
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
        scale = min(available_width / image_width, available_height / image_height, 0.65)
        draw_width, draw_height = image_width * scale, image_height * scale
        x = (width - draw_width) / 2
        y = screenshot_top - draw_height
        if image_width < 900:
            y = screenshot_bottom + (available_height - draw_height) / 2
        doc.setFillColor(HexColor("#e2dbe1"))
        doc.roundRect(x - 1, y - 1, draw_width + 2, draw_height + 2, 5, fill=1, stroke=0)
        doc.drawImage(str(path), x, y, width=draw_width, height=draw_height, mask="auto")
        paragraph.drawOn(doc, margin, caption_bottom)

        doc.setStrokeColor(HexColor("#ded5dd"))
        doc.setLineWidth(0.4)
        doc.line(margin, 26, width - margin, 26)
        doc.setFillColor(muted)
        doc.setFont("Helvetica", 7)
        doc.drawString(margin, 15, "WINDOWS DEVELOPMENT BUILD / INSTRUMENTED LOCAL DEMO / ORIGINAL CAPTURES")
        doc.drawRightString(width - margin, 15, f"{index:02d} / {len(PAGES):02d}")
        doc.showPage()

    doc.save()
    print(output.resolve())


if __name__ == "__main__":
    parser = ArgumentParser(description=__doc__)
    parser.add_argument("--screenshots", type=Path, default=ROOT / "docs/screenshots/0.9")
    parser.add_argument(
        "--output", type=Path,
        default=ROOT / "output/pdf/Zacro-0.9-Design-and-Feature-Guide.pdf",
    )
    args = parser.parse_args()
    build(args.screenshots.resolve(), args.output.resolve())
