#!/usr/bin/env python3
"""Fetch public ISO 20022 base XSDs required by profile-map.json.

The downloaded schemas are operator-supplied certification inputs. Keep them out
of the signed fixture bundle and source control unless redistribution rights are
reviewed for the target release.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

ISO_SCHEMA_DOWNLOADS = [
    ("admi.002.001.01.xsd", "https://www.iso20022.org/message/10126/download"),
    ("admi.004.001.01.xsd", "https://www.iso20022.org/message/10131/download"),
    ("admi.007.001.01.xsd", "https://www.iso20022.org/message/10181/download"),
    ("admi.011.001.01.xsd", "https://www.iso20022.org/message/10161/download"),
    ("camt.029.001.09.xsd", "https://www.iso20022.org/message/12121/download"),
    ("camt.053.001.08.xsd", "https://www.iso20022.org/message/12736/download"),
    ("camt.054.001.08.xsd", "https://www.iso20022.org/message/12776/download"),
    ("camt.055.001.09.xsd", "https://www.iso20022.org/message/20701/download"),
    ("camt.056.001.08.xsd", "https://www.iso20022.org/message/12856/download"),
    ("camt.110.001.01.xsd", "https://www.iso20022.org/message/22837/download"),
    ("camt.111.001.01.xsd", "https://www.iso20022.org/message/22839/download"),
    ("pacs.002.001.10.xsd", "https://www.iso20022.org/message/14061/download"),
    ("pacs.003.001.08.xsd", "https://www.iso20022.org/message/14101/download"),
    ("pacs.004.001.09.xsd", "https://www.iso20022.org/message/14146/download"),
    ("pacs.008.001.08.xsd", "https://www.iso20022.org/message/14231/download"),
    ("pacs.009.001.08.xsd", "https://www.iso20022.org/message/14271/download"),
    ("pacs.028.001.03.xsd", "https://www.iso20022.org/message/14301/download"),
    ("pain.001.001.09.xsd", "https://www.iso20022.org/message/14346/download"),
    ("pain.002.001.10.xsd", "https://www.iso20022.org/message/14396/download"),
    ("pain.008.001.08.xsd", "https://www.iso20022.org/message/14481/download"),
    ("pain.013.001.10.xsd", "https://www.iso20022.org/message/22697/download"),
    ("pain.014.001.10.xsd", "https://www.iso20022.org/message/22698/download"),
    # the schema-profile codec's families and the business application header, from the
    # public catalogue's direct schema paths
    ("admi.006.001.01.xsd", "https://www.iso20022.org/sites/default/files/documents/messages/admi/schemas/admi.006.001.01.xsd"),
    ("admi.017.001.01.xsd", "https://www.iso20022.org/sites/default/files/documents/messages/admi/schemas/admi.017.001.01.xsd"),
    ("camt.025.001.05.xsd", "https://www.iso20022.org/sites/default/files/documents/messages/camt/schemas/camt.025.001.05.xsd"),
    ("camt.026.001.07.xsd", "https://www.iso20022.org/sites/default/files/documents/messages/camt/schemas/camt.026.001.07.xsd"),
    ("camt.027.001.07.xsd", "https://www.iso20022.org/sites/default/files/documents/messages/camt/schemas/camt.027.001.07.xsd"),
    ("camt.028.001.09.xsd", "https://www.iso20022.org/sites/default/files/documents/messages/camt/schemas/camt.028.001.09.xsd"),
    ("camt.050.001.05.xsd", "https://www.iso20022.org/sites/default/files/documents/messages/camt/schemas/camt.050.001.05.xsd"),
    ("camt.052.001.08.xsd", "https://www.iso20022.org/sites/default/files/documents/messages/camt/schemas/camt.052.001.08.xsd"),
    ("camt.057.001.06.xsd", "https://www.iso20022.org/sites/default/files/documents/messages/camt/schemas/camt.057.001.06.xsd"),
    ("camt.060.001.05.xsd", "https://www.iso20022.org/sites/default/files/documents/messages/camt/schemas/camt.060.001.05.xsd"),
    ("camt.087.001.06.xsd", "https://www.iso20022.org/sites/default/files/documents/messages/camt/schemas/camt.087.001.06.xsd"),
    ("head.001.001.02.xsd", "https://www.iso20022.org/sites/default/files/documents/messages/head/schemas/head.001.001.02.xsd"),
    ("head.002.001.01.xsd", "https://www.iso20022.org/sites/default/files/documents/messages/head/schemas/head.002.001.01.xsd"),
    ("pacs.007.001.10.xsd", "https://www.iso20022.org/sites/default/files/documents/messages/pacs/schemas/pacs.007.001.10.xsd"),
    ("pacs.010.001.04.xsd", "https://www.iso20022.org/sites/default/files/documents/messages/pacs/schemas/pacs.010.001.04.xsd"),
    ("pacs.029.001.02.xsd", "https://www.iso20022.org/sites/default/files/documents/messages/pacs/schemas/pacs.029.001.02.xsd"),
    ("pain.007.001.10.xsd", "https://www.iso20022.org/sites/default/files/documents/messages/pain/schemas/pain.007.001.10.xsd"),
    ("pain.009.001.07.xsd", "https://www.iso20022.org/sites/default/files/documents/messages/pain/schemas/pain.009.001.07.xsd"),
    ("pain.010.001.07.xsd", "https://www.iso20022.org/sites/default/files/documents/messages/pain/schemas/pain.010.001.07.xsd"),
    ("pain.011.001.07.xsd", "https://www.iso20022.org/sites/default/files/documents/messages/pain/schemas/pain.011.001.07.xsd"),
    ("pain.012.001.07.xsd", "https://www.iso20022.org/sites/default/files/documents/messages/pain/schemas/pain.012.001.07.xsd"),
]


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def download(url: str, dest: Path, timeout: int) -> tuple[bool, str]:
    if shutil.which("wget") is None:
        return False, "wget is required for reproducible ISO downloads in this environment"
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_suffix(dest.suffix + ".tmp")
    proc = subprocess.run(
        [
            "wget",
            "-q",
            "-O",
            str(tmp),
            f"--timeout={timeout}",
            "--tries=1",
            "--user-agent=Mozilla/5.0",
            url,
        ],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if proc.returncode != 0:
        tmp.unlink(missing_ok=True)
        return False, (proc.stderr or proc.stdout).strip()
    tmp.replace(dest)
    return True, ""


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out-dir", default="integration-kit/profile-runner/official-schemas/iso-base")
    parser.add_argument("--report", default="integration-kit/profile-runner/iso-base-download-report.json")
    parser.add_argument("--timeout", type=int, default=45)
    parser.add_argument("--skip-existing", action="store_true")
    args = parser.parse_args()

    root = Path.cwd()
    out_dir = root / args.out_dir
    report_path = root / args.report
    rows = []
    failed = 0
    for schema_file, url in ISO_SCHEMA_DOWNLOADS:
        dest = out_dir / schema_file
        status = "downloaded"
        detail = ""
        if args.skip_existing and dest.exists():
            status = "existing"
        else:
            ok, detail = download(url, dest, args.timeout)
            if not ok:
                status = "failed"
                failed += 1
        row = {
            "schemaFile": schema_file,
            "url": url,
            "path": dest.relative_to(root).as_posix(),
            "status": status,
            "detail": detail,
        }
        if dest.exists():
            row["bytes"] = dest.stat().st_size
            row["sha256"] = sha256_file(dest)
        rows.append(row)

    report = {
        "version": "thebes-iso-base-xsd-download-report-v1",
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "source": "ISO 20022 message download endpoints from the public catalogue/archive",
        "schemaCount": len(rows),
        "failedCount": failed,
        "ok": failed == 0,
        "outDir": args.out_dir,
        "schemas": rows,
    }
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(json.dumps({"ok": report["ok"], "schemaCount": len(rows), "failedCount": failed, "report": str(report_path)}, sort_keys=True))
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
