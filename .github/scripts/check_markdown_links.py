"""Check the relative links and images of every tracked Markdown file (standard library only).

Usage (from the repository root):  python .github/scripts/check_markdown_links.py

Verifies that each target exists with the exact upper/lower case (GitHub is case sensitive), that
`#anchors` match a heading, that every README.es.md has an English README.md next to it and that both
link to each other. Absolute URLs are not requested, so the check is fast and never flaky.
"""

from __future__ import annotations

import re
import subprocess
import sys
import unicodedata
from functools import lru_cache
from pathlib import Path
from urllib.parse import unquote

ROOT = Path(__file__).resolve().parents[2]
LINK = re.compile(r"!?\[(?:[^\[\]]|\[[^\[\]]*\]\([^()]*\)|\[[^\[\]]*\])*\]\(\s*<?((?:[^()<>\s]|\([^()\s]*\))+)>?(?:\s+\"[^\"]*\")?\s*\)")
INNER_IMAGE = re.compile(r"!\[[^\]]*\]\(([^()\s]+)\)")
HTML_SRC = re.compile(r"<(?:img|a)\b[^>]*?\b(?:src|href)=\"([^\"]+)\"")
EXTERNAL = re.compile(r"^(?:[a-z][a-z0-9+.-]*:|//)", re.I)


def tracked() -> tuple[set[str], set[str]]:
    out = subprocess.run(["git", "-c", "core.quotepath=off", "ls-files", "-co", "--exclude-standard"],
                         cwd=ROOT, check=True, capture_output=True).stdout.decode("utf-8")
    files = {f for f in out.splitlines() if (ROOT / f).exists()}
    folders = {"."}
    for f in files:
        folders.update(p.as_posix() for p in Path(f).parents)
    return files, folders


def without_code(text: str) -> str:
    text = re.sub(r"^ {0,3}(```|~~~).*?^ {0,3}\1[^\n]*$", "", text, flags=re.M | re.S)
    return re.sub(r"(`+)(?!`).+?(?<!`)\1(?!`)", "", text)


def slug(heading: str) -> str:
    heading = re.sub(r"!?\[([^\]]*)\]\([^)]*\)", r"\1", heading)
    heading = re.sub(r"[*`]|(?<!\w)_|_(?!\w)", "", heading).strip().lower()
    kept = [c for c in heading if c in "-_ " or unicodedata.category(c)[0] in "LN" or unicodedata.category(c) == "Mn"]
    return "".join(kept).replace(" ", "-")


@lru_cache(maxsize=None)
def anchors(path: Path) -> frozenset[str]:
    text = path.read_text(encoding="utf-8")
    body = re.sub(r"^ {0,3}(```|~~~).*?^ {0,3}\1[^\n]*$", "", text, flags=re.M | re.S)
    found: dict[str, int] = {}
    names = set(re.findall(r"<a\b[^>]*\b(?:id|name)=\"([^\"]+)\"", body))
    for title in re.findall(r"^ {0,3}#{1,6}\s+(.+?)\s*#*\s*$", body, flags=re.M):
        s = slug(title)
        names.add(s if s not in found else f"{s}-{found[s]}")
        found[s] = found.get(s, 0) + 1
    return frozenset(names)


def is_template(rel: str) -> bool:
    return "plantilla" in rel.lower()


def main() -> int:
    files, folders = tracked()
    problems: list[str] = []
    checked = 0
    for rel in sorted(f for f in files if f.lower().endswith(".md") and not is_template(f)):
        path = ROOT / rel
        text = without_code(path.read_text(encoding="utf-8"))
        targets = [m.group(1) for m in LINK.finditer(text)] + INNER_IMAGE.findall(text) + HTML_SRC.findall(text)
        for target in dict.fromkeys(targets):
            if EXTERNAL.match(target):
                continue
            checked += 1
            raw, _, anchor = target.partition("#")
            if raw:
                base = ROOT if raw.startswith("/") else path.parent
                dest = Path(base / unquote(raw.split("?")[0]).lstrip("/")).resolve()
                try:
                    inside = dest.relative_to(ROOT).as_posix()
                except ValueError:
                    problems.append(f"{rel}: {target} leaves the repository")
                    continue
                if inside not in files and inside not in folders:
                    problems.append(f"{rel}: {target} does not exist")
                    continue
            else:
                dest = path
            if anchor and dest.suffix.lower() == ".md" and unquote(anchor).lower() not in anchors(dest):
                problems.append(f"{rel}: {target} has no matching heading")

    for rel in sorted(f for f in files if f == "README.es.md" or f.endswith("/README.es.md")):
        english = rel[: -len("README.es.md")] + "README.md"
        if english not in files:
            problems.append(f"{rel}: English README.md is missing")
            continue
        if "(README.es.md)" not in (ROOT / english).read_text(encoding="utf-8")[:400]:
            problems.append(f"{english}: no language selector to README.es.md")
        if "(README.md)" not in (ROOT / rel).read_text(encoding="utf-8")[:1200]:
            problems.append(f"{rel}: no language selector to README.md")

    for p in problems:
        print(f"::error::{p}")
    print(f"{checked} relative links checked, {len(problems)} problems")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
