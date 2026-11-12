#!/usr/bin/env python3
"""Build a Sileo native depiction (JSON) from `control` and `CHANGELOG.md`.

Usage: make_depiction.py <control> <CHANGELOG.md> > depiction.json
"""
import json
import re
import sys


def read_control(path):
    fields, last = {}, None
    for line in open(path, encoding="utf-8").read().splitlines():
        if line[:1] in (" ", "\t") and last:
            fields[last] += "\n" + line.strip()
        elif ":" in line:
            last, value = line.split(":", 1)
            fields[last.strip()] = value.strip()
    return fields


def read_changelog(path):
    entries, current = [], None
    for line in open(path, encoding="utf-8").read().splitlines():
        m = re.match(r"^##\s+(\S+)\s*\|\s*(\S+)\s*$", line)
        if m:
            current = {"version": m.group(1), "date": m.group(2), "items": []}
            entries.append(current)
        elif current and re.match(r"^\s*[-*]\s+", line):
            current["items"].append(re.sub(r"^\s*[-*]\s+", "", line).strip())
    return entries


def main():
    control = read_control(sys.argv[1])
    entries = read_changelog(sys.argv[2])
    if not entries:
        sys.exit("no changelog entries found")

    description = control.get("Description", "").split("\n")
    details = [
        {"class": "DepictionMarkdownView", "markdown": "\n\n".join(d for d in description if d), "useSpacing": True},
        {"class": "DepictionSeparatorView"},
        {"class": "DepictionTableTextView", "title": "当前版本", "text": control["Version"]},
    ]

    changelog = []
    for i, entry in enumerate(entries):
        if i:
            changelog.append({"class": "DepictionSeparatorView"})
        changelog.append({"class": "DepictionHeaderView", "title": entry["version"]})
        changelog.append({
            "class": "DepictionMarkdownView",
            "markdown": "\n".join("- " + item for item in entry["items"]),
            "useSpacing": True,
        })
        changelog.append({"class": "DepictionSubheaderView", "title": "更新日期：" + entry["date"], "useBoldText": False})

    depiction = {
        "minVersion": "0.1",
        "class": "DepictionTabView",
        "tintColor": "#2E9F8E",
        "tabs": [
            {"tabname": "详情", "class": "DepictionStackView", "views": details},
            {"tabname": "更新日志", "class": "DepictionStackView", "views": changelog},
        ],
    }
    json.dump(depiction, sys.stdout, ensure_ascii=False, indent=2)
    print()


main()
