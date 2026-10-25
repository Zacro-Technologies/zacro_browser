"""Build the five-page 0.6 guide after final application captures are approved.

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
        "A compact sidebar, equal page gutters and individual Space icons keep the workspace legible. "
        "Favorites show whether their pages are loaded, sleeping or closed. Closing a favorite keeps its pin; "
        "inactive favorites can sleep without disturbing active pages, drafts, media or downloads.",
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
        "space-theme.jpg",
        "03 / SPACE MATERIALS",
        "Make a Space your own.",
        "Choose an icon, two custom colors, gradient balance, grain, opacity and blur. "
        "Preview changes live, then save or cancel. Glass blends the Space colors within the window. "
        "The interface preserves readable contrast and follows reduced-transparency preferences.",
    ),
    (
        "ai-workflow.jpg",
        "04 / OPTIONAL AI",
        "A clear question. Chosen pages.",
        "Summarize, explain, compare or research from the palette. Review the page context and edit "
        "the prepared question before sending. Remove shared pages, edit or retry questions, "
        "and copy answers with sources. Live provider-account acceptance remains pending.",
    ),
    (
        "customization.jpg",
        "05 / PERSONAL PREFERENCES",
        "Comfort, down to the details.",
        "Adjust tab density, page inset, corner radius, animation speed and the idle-favorite timer. "
        "Space swipes follow displacement until release; sidebar motion supports quick reversals. "
        "Keyboard shortcuts remain editable. This is a development build with open release gates.",
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
    doc.setTitle("Zacro 0.6 - Design and Feature Guide")
    doc.setAuthor("Zacro Technologies")
    doc.setSubject("Zacro 0.6 Windows development interface, Space materials, favorite lifecycle and reviewed AI context")
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
        doc.drawString(margin, height - 27, "ZACRO / INTERFACE 0.6")
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
    parser.add_argument("--screenshots", type=Path, default=ROOT / "docs/screenshots/0.6")
    parser.add_argument(
        "--output", type=Path,
        default=ROOT / "output/pdf/Zacro-0.6-Design-and-Feature-Guide.pdf",
    )
    args = parser.parse_args()
    build(args.screenshots.resolve(), args.output.resolve())
