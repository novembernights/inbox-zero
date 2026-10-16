#!/usr/bin/env python3
"""Conservative source-release guardrail; no network, imports of app code, or writes.

This is not a comprehensive secret detector. Findings print locations, never values.
Run from any directory. --require-history-free is for the initial source archive.
"""
import argparse
import json
from pathlib import Path
import re
import struct
import sys
import xml.etree.ElementTree as ET
import zlib

ROOT = Path(__file__).resolve().parents[1]
BAD_DIRS = {"xcuserdata", ".derived", "DerivedData", "artifacts", ".venv", "__pycache__", ".vercel", ".codex", ".agents"}
BAD_SUFFIXES = {".pem", ".key", ".p8", ".p12", ".mobileprovision", ".ipa", ".log", ".sqlite", ".db", ".eml", ".mbox", ".ttf", ".otf", ".mp4", ".jpg", ".jpeg", ".xcuserstate"}
PATTERNS = {
    "private-key material": re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
    "provider credential": re.compile(r"\b(?:AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|AIza[0-9A-Za-z_-]{30,}|sk-[A-Za-z0-9_-]{24,})\b"),
    "JWT-like credential": re.compile(r"\beyJ[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{12,}\b"),
    "configured OAuth application": re.compile(r"\b\d{8,}-[a-z0-9]+\.apps\.googleusercontent\.com|com\.googleusercontent\.apps\.\d{8,}-[a-z0-9]+"),
    "host user path": re.compile(r"/(?:Users|home)/[A-Za-z0-9_.-]+/|[A-Z]:\\Users\\[^\\]+\\"),
    "literal bearer credential": re.compile(r'(?i)["\']Bearer [A-Za-z0-9_-]{24,}["\']'),
}
EMAIL = re.compile(r"\b[A-Za-z0-9._%+-]+@([A-Za-z0-9.-]+\.[A-Za-z]{2,})\b")


def check(root, history_free=False):
    findings = []
    checked = 0
    def flag(path, reason, line=None):
        suffix = f":{line}" if line else ""
        findings.append(f"{path}{suffix}: {reason}")
    for p in sorted(root.rglob("*")):
        rel = p.relative_to(root)
        if ".git" in rel.parts:
            if history_free and rel.parts == (".git",):
                flag(rel, "Git metadata must not be in the initial archive")
            continue
        if p.is_symlink():
            flag(rel, "symlink is not allowed in this source release")
            continue
        if p.is_dir():
            if p.name in BAD_DIRS or p.suffix in {".app", ".appex", ".xcarchive", ".xcresult"}:
                flag(rel, "local state or build-output directory")
            continue
        checked += 1
        if p.suffix.lower() in BAD_SUFFIXES or p.name in {".DS_Store", "Local.xcconfig"} or (p.name.startswith(".env") and p.name != ".env.example"):
            flag(rel, "private, local, or unreviewed file type")
        raw = p.read_bytes()
        if p.suffix == ".png":
            if raw[:8] != b"\x89PNG\r\n\x1a\n":
                flag(rel, "invalid PNG signature")
                continue
            offset = 8
            ended = False
            while offset + 12 <= len(raw):
                size = struct.unpack(">I", raw[offset:offset+4])[0]
                chunk = raw[offset:offset+size+12]
                kind = chunk[4:8]
                if len(chunk) != size + 12:
                    flag(rel, "truncated PNG")
                    break
                if kind not in {b"IHDR", b"PLTE", b"IDAT", b"IEND", b"tRNS"}:
                    flag(rel, "PNG contains metadata or unreviewed chunks")
                if (zlib.crc32(chunk[4:-4]) & 0xffffffff) != struct.unpack(">I", chunk[-4:])[0]:
                    flag(rel, "invalid PNG checksum")
                offset += len(chunk)
                if kind == b"IEND":
                    ended = True
                    break
            if not ended or offset != len(raw):
                flag(rel, "PNG contains missing terminator or appended data")
            continue
        try:
            text = raw.decode("utf-8")
        except UnicodeDecodeError:
            flag(rel, "unreviewed binary file")
            continue
        for label, pattern in PATTERNS.items():
            for match in pattern.finditer(text):
                flag(rel, label, text.count("\n", 0, match.start()) + 1)
        # Upstream legal notices are preserved verbatim, including required contacts.
        if "third-party-licenses" not in rel.parts:
            for match in EMAIL.finditer(text):
                domain = match.group(1).lower()
                if domain not in {"example.com", "example.org", "example.net"} and not domain.endswith(".example") and match.group(0) != "you@icloud.com":
                    flag(rel, "non-example email address", text.count("\n", 0, match.start()) + 1)
        if p.name == "project.pbxproj":
            for match in re.finditer(r"(?:DEVELOPMENT_TEAM|GMAIL_CLIENT_ID|GMAIL_REDIRECT_SCHEME|PUSH_RELAY_[A-Z_]+)\s*=\s*([^;]+);", text):
                value = match.group(1).strip().strip('"')
                if value and not value.startswith("$("):
                    flag(rel, "configured developer identity or integration", text.count("\n", 0, match.start()) + 1)
        try:
            if p.suffix == ".json" or p.name == "Package.resolved":
                json.loads(text)
            if p.suffix in {".plist", ".entitlements", ".svg", ".xcscheme", ".xcworkspacedata"}:
                node = ET.fromstring(text)
                if p.suffix == ".xcscheme" and node.findall(".//EnvironmentVariable"):
                    flag(rel, "scheme contains launch environment values")
        except (ValueError, ET.ParseError):
            flag(rel, "invalid structured file")
    return checked, findings


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--require-history-free", action="store_true")
    args = parser.parse_args()
    count, issues = check(ROOT, args.require_history_free)
    if issues:
        print("\n".join(issues))
        print(f"FAIL: {len(issues)} finding(s); {count} files checked. Values withheld.")
        sys.exit(1)
    print(f"PASS: {count} files checked; no configured identities, non-example emails, forbidden artifacts, or recognized secret patterns found.")
    print("This automated check does not guarantee the absence of every possible secret or personal detail.")
