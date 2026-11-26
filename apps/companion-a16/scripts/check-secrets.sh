#!/bin/bash
# Scan the extracted package. Only report the category, never the matching data.
set -euo pipefail

if [[ $# != 1 || ! -d $1 ]]; then
  echo "usage: $0 <extracted package directory>" >&2
  exit 1
fi

"${PYTHON:-python3}" -I - "$1" <<'PY'
import re
import sys
from pathlib import Path

private_key = rb"BEGIN [^\r\n\x00]*PRIVATE KEY"
github_token = rb"(?<![A-Za-z0-9_])(?:ghp_|github_pat_)[A-Za-z0-9_]{20,}"
binary_checks = (
    ("PEM private key", private_key),
    ("GitHub token", github_token),
)
text_checks = binary_checks + (
    ("PEM certificate", rb"BEGIN CERTIFICATE"),
    ("GitHub OAuth token", rb"(?<![A-Za-z0-9_])gho_[A-Za-z0-9_]{20,}"),
    ("xcode.auth value", rb"""\bxcode\.auth["']?\s*[:=]\s*["']?[^\s"',}\]]"""),
)
email_check = ("personal email", rb"[A-Z0-9.!#$%&'*+/=?^_`{|}~-]+@(?:icloud|me|gmail)\.[A-Z]{2,}\b")
credential_extensions = {".p12", ".pfx", ".pem", ".key", ".cer", ".mobileprovision"}
binary_extensions = {".exe", ".dll", ".otf"}
findings = set()
file_count = 0

root = Path(sys.argv[1])
entries = list(root.iterdir())
# The portable ZIP wraps the package in a single directory.
package = root
if len(entries) == 1 and (entries[0] / "licenses").is_dir():
    package = entries[0]
licenses = package / "licenses"

for path in root.rglob("*"):
    extension = path.suffix.lower()
    if extension in credential_extensions:
        findings.add("credential file extension")
    if not path.is_file():
        continue
    file_count += 1
    data = path.read_bytes()
    if licenses in path.parents:
        # Preserve published author addresses in the third-party notices.
        checks = text_checks
    elif extension in binary_extensions:
        checks = binary_checks
    else:
        checks = text_checks + (email_check,)
    # Scan raw bytes and UTF-16 strings, including strings at odd offsets in PE files.
    findings.update(label for label, pattern in checks if re.search(pattern, data, re.IGNORECASE))
    if b"\x00" in data:
        for encoding in ("utf-16-le", "utf-16-be"):
            for offset in (0, 1):
                decoded = data[offset:].decode(encoding, errors="replace").encode()
                findings.update(
                    label for label, pattern in checks if re.search(pattern, decoded, re.IGNORECASE)
                )

if not file_count:
    sys.exit("check-secrets: extracted package is empty")
if findings:
    sys.exit("check-secrets: " + ", ".join(sorted(findings)))
print(f"check-secrets: {file_count} files passed")
PY
