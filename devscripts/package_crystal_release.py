#!/usr/bin/env python3
"""Package cr-dlp Crystal release artifacts.

This script is intentionally small and dependency-free. It stages the Crystal
binary under both `cr-dlp` and `yt-dlp` names, produces an archive for humans,
copies the raw executable for the self-updater, and writes an update manifest
understood by `CrDlp::Updater`.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import shutil
import tarfile
import tempfile
import zipfile
from pathlib import Path


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def host_platform() -> str:
    system = platform.system().lower()
    if system.startswith("win"):
        return "windows"
    if system == "darwin":
        return "macos"
    return "linux"


def host_arch() -> str:
    machine = platform.machine().lower()
    if machine in {"amd64", "x64", "x86_64"}:
        return "x86_64"
    if machine in {"arm64", "aarch64"}:
        return "aarch64"
    return machine or "unknown"


def archive_directory(source: Path, destination: Path) -> None:
    if destination.suffix == ".zip":
        with zipfile.ZipFile(destination, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            for path in source.rglob("*"):
                if path.is_file():
                    archive.write(path, path.relative_to(source.parent))
        return

    with tarfile.open(destination, "w:gz") as archive:
        archive.add(source, arcname=source.name)


def stage_payload(binary: Path, stage: Path, executable_suffix: str) -> None:
    stage.mkdir(parents=True, exist_ok=True)
    cr_dlp = stage / f"cr-dlp{executable_suffix}"
    yt_dlp = stage / f"yt-dlp{executable_suffix}"
    shutil.copy2(binary, cr_dlp)
    shutil.copy2(binary, yt_dlp)
    if not executable_suffix:
        cr_dlp.chmod(0o755)
        yt_dlp.chmod(0o755)

    for candidate in ("README.md", "LICENSE", "UNLICENSE", "CRYSTAL_PORT.md"):
        path = Path(candidate)
        if path.exists():
            shutil.copy2(path, stage / path.name)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=Path, help="Built cr-dlp executable")
    parser.add_argument("--out-dir", default=Path("dist"), type=Path, help="Artifact output directory")
    parser.add_argument("--version", default=None, help="Version string for artifact names and manifest")
    parser.add_argument("--platform", default=host_platform(), help="Manifest platform value")
    parser.add_argument("--arch", default=host_arch(), help="Manifest arch value")
    parser.add_argument("--channel", default="stable", help="Manifest channel value")
    parser.add_argument("--tag", default="latest", help="Manifest tag value")
    parser.add_argument("--base-url", default="", help="URL prefix for manifest artifact URLs")
    parser.add_argument("--manifest-signature", type=Path, help="Detached base64 RSA/SHA-256 manifest signature")
    args = parser.parse_args()

    binary = args.binary
    if not binary.exists():
        parser.error(f"binary does not exist: {binary}")

    version = args.version or os.environ.get("CR_DLP_VERSION") or "0.1.0-dev"
    suffix = ".exe" if args.platform == "windows" else ""
    stem = f"cr-dlp-{version}-{args.platform}-{args.arch}"
    args.out_dir.mkdir(parents=True, exist_ok=True)

    executable_artifact = args.out_dir / f"{stem}{suffix}"
    shutil.copy2(binary, executable_artifact)
    if not suffix:
        executable_artifact.chmod(0o755)

    archive_name = f"{stem}.zip" if args.platform == "windows" else f"{stem}.tar.gz"
    archive_path = args.out_dir / archive_name
    with tempfile.TemporaryDirectory(prefix="cr-dlp-package-") as temp:
        stage = Path(temp) / stem
        stage_payload(binary, stage, suffix)
        archive_directory(stage, archive_path)

    base_url = args.base_url.rstrip("/")
    artifact_url = f"{base_url}/{executable_artifact.name}" if base_url else executable_artifact.name
    manifest = {
        "version": version,
        "channel": args.channel,
        "tag": args.tag,
        "artifacts": [
            {
                "name": executable_artifact.name,
                "platform": args.platform,
                "arch": args.arch,
                "url": artifact_url,
                "sha256": sha256(executable_artifact),
                "size": executable_artifact.stat().st_size,
            }
        ],
        "archives": [
            {
                "name": archive_path.name,
                "sha256": sha256(archive_path),
                "size": archive_path.stat().st_size,
            }
        ],
    }
    manifest_path = args.out_dir / "update-manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    if args.manifest_signature:
        signature_path = Path(f"{manifest_path}.sig")
        if args.manifest_signature.resolve() != signature_path.resolve():
            shutil.copy2(args.manifest_signature, signature_path)

    print(executable_artifact)
    print(archive_path)
    print(manifest_path)
    if args.manifest_signature:
        print(f"{manifest_path}.sig")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
