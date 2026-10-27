"""Build the six-page 0.7 guide after final application captures are approved.

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
        "Room for the page.",
        "Navigation stays in the sidebar; the application logo, sidebar-toggle button and favorite status dots "
        "leave the chrome. Closing a favorite keeps its destination. Inactive favorites can sleep while "
        "active pages, drafts, media, downloads and live login callbacks remain protected.",
    ),
    (
        "palette.jpg",
        "02 / COMMAND PALETTE",
        "Find it. Do it.",
        "Filter tabs, Spaces, bookmarks, history and actions in one palette. Use @ for tabs, # for Spaces, "
        "or / for commands. Only the page blurs, inside its existing rounded frame; "
        "the sidebar remains usable. Opening the palette never creates a disposable tab.",
    ),
    (
        "onboarding.jpg",
        "03 / KEYBOARD WORKFLOW",
        "Learn it. Make it yours.",
        "The five-step welcome tour introduces the command bar, sidebar, Spaces, favorites and settings. "
        "Every displayed shortcut is directly editable with conflict checks and a reset control. "
        "The same bindings drive menus and commands; the tour can be reopened at any time.",
    ),
    (
        "settings.jpg",
        "04 / BROWSER PANELS",
        "Part of the browser.",
        "Library, Settings and the assistant belong to the Space-colored window, with their own divider "
        "and compact section navigation. Sidebar and panel widths share a 220 ms ease without spring "
        "overshoot. Library keeps the real page visible at its original rendering scale.",
    ),
    (
        "compact.jpg",
        "05 / COMPACT WINDOWS",
        "A smaller footprint.",
        "The window supports sizes down to 560 by 420 logical pixels. Opening a browser panel makes room "
        "by temporarily hiding the sidebar, while retaining its saved width and visibility preference. "
        "Short dialogs and command results scroll to keep their controls reachable.",
    ),
    (
        "spaces.jpg",
        "06 / SPACES",
        "Everything in its place.",
        "Right-click a Space or press Shift-F10 for its contextual actions. Sideways gestures reveal the "
        "neighboring Space's actual favorites, folders and tabs without a redundant name badge. "
        "Still captures do not establish motion quality; physical Mac and live Google acceptance remain open.",
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
    doc.setTitle("Zacro 0.7 - Design and Feature Guide")
    doc.setAuthor("Zacro Technologies")
    doc.setSubject("Zacro 0.7 compact windows, browser panels, editable keyboard onboarding and Space navigation")
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
        doc.drawString(margin, height - 27, "ZACRO / INTERFACE 0.7")
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
        doc.setFillColor(HexColor("#e2dbe1"))
        doc.roundRect(x - 1, y - 1, draw_width + 2, draw_height + 2, 5, fill=1, stroke=0)
        doc.drawImage(str(path), x, y, width=draw_width, height=draw_height, mask="auto")
        paragraph.drawOn(doc, margin, caption_bottom)

        doc.setStrokeColor(HexColor("#ded5dd"))
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
    parser.add_argument("--screenshots", type=Path, default=ROOT / "docs/screenshots/0.7")
    parser.add_argument(
        "--output", type=Path,
        default=ROOT / "output/pdf/Zacro-0.7-Design-and-Feature-Guide.pdf",
    )
    args = parser.parse_args()
    build(args.screenshots.resolve(), args.output.resolve())
