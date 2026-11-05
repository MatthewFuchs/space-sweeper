#!/usr/bin/env python3
"""Builds the website into an output folder for GitHub Pages.

Copies website/ as-is and renders PRIVACY.md into privacy.html using website/privacy.template.html, so the
privacy policy has a single source (PRIVACY.md, which a unit test keeps identical to the in-app policy).

    python3 scripts/build-site.py [--out _site]
"""
import argparse
import html
import re
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def inline(text: str) -> str:
    """Escapes HTML, then renders `code` and [links](url)."""
    text = html.escape(text, quote=False)
    text = re.sub(r"`([^`]+)`", r"<code>\1</code>", text)
    text = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r'<a href="\2">\1</a>', text)
    return text


def markdown_to_html(markdown: str) -> tuple[str, str]:
    """Renders the small Markdown subset PRIVACY.md uses. Returns (title, body html)."""
    title, parts = "", []
    for block in re.split(r"\n\s*\n", markdown.strip()):
        block = block.strip()
        if block.startswith("# "):
            title = block[2:].strip()
        elif block.startswith("## "):
            parts.append(f"<h2>{inline(block[3:].strip())}</h2>")
        else:
            parts.append(f"<p>{inline(' '.join(block.splitlines()))}</p>")
    return title, "\n".join(parts)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", default="_site")
    out = Path(parser.parse_args().out)
    if out.exists():
        shutil.rmtree(out)
    shutil.copytree(ROOT / "website", out, ignore=shutil.ignore_patterns("privacy.template.html", ".DS_Store"))

    title, body = markdown_to_html((ROOT / "PRIVACY.md").read_text(encoding="utf-8"))
    template = (ROOT / "website" / "privacy.template.html").read_text(encoding="utf-8")
    page = template.replace("{{title}}", html.escape(title)).replace("{{content}}", body)
    (out / "privacy.html").write_text(page, encoding="utf-8")
    print(f"Built site in {out}/ ({sum(1 for _ in out.rglob('*') if _.is_file())} files)")


if __name__ == "__main__":
    main()
