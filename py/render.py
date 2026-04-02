import sys
import argparse
from pathlib import Path

from playwright.sync_api import sync_playwright

FONT_PX = 18
LINE_HEIGHT = 1.25
SCALE = 2


def get_extra_css(outer_bg: str, icon_font_url: str) -> str:
    padding_px = 40
    window_radius = 14
    titlebar_height = 36
    title_padding = 9
    title_icon_size = 16
    controls_gap = 2
    btn_width = 36
    btn_height = 28
    btn_radius = 6
    svg_size = 15

    icon_font_css = f"""
    @font-face {{
      font-family: "ImprintNerdSymbols";
      src: url("{icon_font_url}") format("truetype");
      font-display: swap;
    }}
        """

    return f"""
    html, body {{
      margin: 0;
      padding: 0;
    }}

    body {{
      display: inline-block !important;
    }}

    * {{
      font-family: "ImprintNerdSymbols", monospace;
    }}

    #stage {{
      display: inline-block;
      padding: {padding_px}px;
      background: {outer_bg};
    }}

    pre {{
      margin: 0;
      padding: 14px 16px;
      font-size: {FONT_PX}px;
      line-height: {LINE_HEIGHT};
      white-space: pre;
    }}

    #window {{
      display: inline-block;
      border-radius: {window_radius}px;
      overflow: hidden;
      border: 1px solid rgba(0,0,0,.10);
      box-shadow:
        0 20px 40px rgba(0,0,0,.18),
        0 10px 13px rgba(0,0,0,.12);
    }}

    #titlebar {{
      height: {titlebar_height}px;
      display: flex;
      align-items: center;
      padding: 0 {title_padding}px;
      user-select: none;
      border-bottom: 1px solid rgba(0,0,0,.14);
      font-size: {FONT_PX}px;
      line-height: 1.0;
    }}

    #title {{
      flex: 1 1 auto;
      display: flex;
      align-items: center;
      gap: 6px;
      height: 100%;
      transform: translateY(2px);
      text-align: left;
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
      padding: 0 {title_padding}px;
    }}

    #file-icon {{
      flex: 0 0 auto;
      font-size: {title_icon_size}px;
      line-height: 1;
      font-family: "ImprintNerdSymbols";
    }}
    #file-icon:empty {{
      display: none;
    }}

    #controls {{
      flex: 0 0 auto;
      display: flex;
      gap: {controls_gap}px;
    }}

    .ctrlbtn {{
      width: {btn_width}px;
      height: {btn_height}px;
      display: flex;
      align-items: center;
      justify-content: center;
      border-radius: {btn_radius}px;
    }}

    .ctrlbtn svg {{
      width: {svg_size}px;
      height: {svg_size}px;
      opacity: 0.78;
    }}
    {icon_font_css}
    """


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("input_path", type=Path, help="path for the input HTML file.")
    parser.add_argument("output_path", type=Path, help="pth for the output PNG file.")
    parser.add_argument("--title", default="", help="title for the window.")
    parser.add_argument("--icon", default="", help="file icon glyph for the titlebar.")
    parser.add_argument("--icon-color", default="", help="hex for the icon color.")
    parser.add_argument("--background", default="#A5A6F6", help="hex for background.")
    parser.add_argument("--font", default=(Path(__file__).parent.parent / "SymbolsNerdFontMono-Regular.ttf"), help="font to be used.")
    args = parser.parse_args()

    input_path: Path = args.input_path.expanduser()
    output_path: Path = args.output_path.expanduser()

    url = input_path.resolve().as_uri()
    font_url = Path(args.font).expanduser().resolve().as_uri()

    with sync_playwright() as p:
        browser = p.chromium.launch()
        page = browser.new_page(device_scale_factor=SCALE)

        page.goto(url)
        page.add_style_tag(content=get_extra_css(args.background, font_url))

        page.evaluate(
            """
            ({ title, icon, iconColor }) => {
              const pre = document.querySelector("pre");

              const bodyCS = getComputedStyle(document.body);
              const bg = bodyCS.backgroundColor;
              const fg = bodyCS.color;

              const win = document.createElement("div");
              win.id = "window";
              win.style.background = bg;
              win.style.color = fg;

              const titlebar = document.createElement("div");
              titlebar.id = "titlebar";
              titlebar.style.background = bg;
              titlebar.style.color = fg;

              const titleEl = document.createElement("div");
              titleEl.id = "title";
              titleEl.style.color = fg;

              const iconEl = document.createElement("span");
              iconEl.id = "file-icon";
              iconEl.textContent = icon || "";
              iconEl.style.color = iconColor || fg;
              titleEl.appendChild(iconEl);

              const textEl = document.createElement("span");
              textEl.textContent = title;
              titleEl.appendChild(textEl);

              const controls = document.createElement("div");
              controls.id = "controls";

              const mkBtn = (cls, svg) => {
                const b = document.createElement("div");
                b.className = "ctrlbtn " + cls;
                b.style.background = bg;
                b.style.color = fg;
                b.innerHTML = svg;
                return b;
              };

              const svgMin = `<svg viewBox="0 0 12 12" aria-hidden="true"><rect x="2" y="8.5" width="8" height="1.6" fill="currentColor"></rect></svg>`;
              const svgMax = `<svg viewBox="0 0 12 12" aria-hidden="true"><rect x="2.5" y="2.5" width="7" height="7" fill="none" stroke="currentColor" stroke-width="1.4"></rect></svg>`;
              const svgClose = `<svg viewBox="0 0 12 12" aria-hidden="true"><path d="M3 3 L9 9 M9 3 L3 9" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"></path></svg>`;

              controls.appendChild(mkBtn("min", svgMin));
              controls.appendChild(mkBtn("max", svgMax));
              controls.appendChild(mkBtn("close", svgClose));

              titlebar.appendChild(titleEl);
              titlebar.appendChild(controls);

              const stage = document.createElement("div");
              stage.id = "stage";

              document.body.innerHTML = "";

              win.appendChild(titlebar);
              win.appendChild(pre);
              stage.appendChild(win);
              document.body.appendChild(stage);
            }
            """,
            {"title": args.title, "icon": args.icon, "iconColor": args.icon_color},
        )

        stage_element = page.locator("#stage")
        stage_element.screenshot(path=str(output_path))
        browser.close()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
