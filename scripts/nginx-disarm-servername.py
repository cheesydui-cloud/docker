#!/usr/bin/env python3
"""Rename conflicting nginx server_name so this host can own SITE_ADDRESS.

3x-ui / 渡口 often already has server_name docker.example.com. Nginx then
keeps the first block and ignores ours — wrong cert + redirect loops.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

MARKER = "disabled-by-docker-mirror"


def iter_conf_files(nginx_t: str) -> list[Path]:
    files: list[Path] = []
    seen: set[str] = set()
    for line in nginx_t.splitlines():
        line = line.strip()
        if line.startswith("# configuration file ") and line.endswith(":"):
            path = line[len("# configuration file ") : -1].strip()
            if path and path not in seen:
                seen.add(path)
                files.append(Path(path))
    return files


def should_skip(path: Path, our_files: set[str]) -> bool:
    name = path.name
    resolved = str(path)
    if resolved in our_files or name.startswith("docker-mirror"):
        return True
    if f".{MARKER}" in name:
        return True
    return False


def rewrite_server_names(text: str, site: str) -> tuple[str, int]:
    changed = 0
    disabled = f"{site}.{MARKER}"

    def repl_line(match: re.Match[str]) -> str:
        nonlocal changed
        prefix, names, suffix = match.group(1), match.group(2), match.group(3)
        parts = names.split()
        new_parts = []
        line_changed = False
        for part in parts:
            raw = part.rstrip(";")
            if raw == site:
                new_parts.append(disabled)
                line_changed = True
            else:
                new_parts.append(part)
        if line_changed:
            changed += 1
            return f"{prefix}{' '.join(new_parts)}{suffix}"
        return match.group(0)

    text = re.sub(
        r"(?im)^([ \t]*server_name[ \t]+)([^\n#;]+?)([ \t]*;)",
        repl_line,
        text,
    )
    return text, changed


def main() -> int:
    if len(sys.argv) < 3:
        print("usage: nginx-disarm-servername.py <site> <our-conf> [<nginx -T file>]", file=sys.stderr)
        return 2
    site = sys.argv[1].strip().lower()
    our = Path(sys.argv[2]).resolve()
    if not re.fullmatch(r"[a-z0-9.-]+", site):
        print(f"invalid site: {site}", file=sys.stderr)
        return 2

    if len(sys.argv) >= 4:
        dump = Path(sys.argv[3]).read_text(encoding="utf-8", errors="replace")
    else:
        dump = sys.stdin.read()

    our_files = {str(our)}
    touched = 0
    for path in iter_conf_files(dump):
        if should_skip(path, our_files):
            continue
        if not path.is_file():
            continue
        try:
            original = path.read_text(encoding="utf-8", errors="replace")
        except OSError as exc:
            print(f"skip unreadable {path}: {exc}", file=sys.stderr)
            continue
        if site not in original:
            continue
        updated, n = rewrite_server_names(original, site)
        if n == 0 or updated == original:
            continue
        bak = path.with_suffix(path.suffix + f".bak.{MARKER}")
        if not bak.exists():
            bak.write_text(original, encoding="utf-8")
        path.write_text(updated, encoding="utf-8")
        print(f"disarmed {n} server_name in {path}")
        touched += 1
    print(f"disarmed_files={touched}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
