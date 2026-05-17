#!/usr/bin/env python3
"""Prepare the Go runtime spec used by the processor Docker image."""

from __future__ import annotations

import argparse
import html
import json
import pathlib
import re
import shutil
import sys
import tempfile
import urllib.parse
import urllib.request


DRIVE_FILE_DOWNLOAD_URL = "https://drive.google.com/uc?export=download&id={file_id}"
DRIVE_FOLDER_URL = "https://drive.google.com/drive/folders/{folder_id}"
USER_AGENT = "Mozilla/5.0 fraud-detector-terraform model-prep"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=pathlib.Path, required=True)
    parser.add_argument("--dest", type=pathlib.Path, required=True)
    parser.add_argument("--drive-folder-url", required=True)
    args = parser.parse_args()

    args.dest.parent.mkdir(parents=True, exist_ok=True)
    if args.source.is_file():
        shutil.copy2(args.source, args.dest)
        print(f"runtime_spec={args.dest} source={args.source}")
        return 0

    folder_id = extract_folder_id(args.drive_folder_url)
    specs = find_runtime_specs(folder_id, max_depth=2)
    if not specs:
        print("No runtime_spec.json found in Google Drive fallback", file=sys.stderr)
        return 1

    selected = sorted(specs, key=lambda spec: (spec.model_version, spec.path))[-1]
    download_drive_file(selected.file_id, args.dest)
    print(f"runtime_spec={args.dest} source=google-drive/{selected.path}")
    return 0


class RuntimeSpec:
    def __init__(self, *, file_id: str, path: str, model_version: int) -> None:
        self.file_id = file_id
        self.path = path
        self.model_version = model_version


class DriveItem:
    def __init__(self, *, file_id: str, name: str, mime_type: str) -> None:
        self.file_id = file_id
        self.name = name
        self.mime_type = mime_type

    @property
    def is_folder(self) -> bool:
        return self.mime_type == "application/vnd.google-apps.folder"


def extract_folder_id(url_or_id: str) -> str:
    match = re.search(r"/folders/([A-Za-z0-9_-]+)", url_or_id)
    if match:
        return match.group(1)
    parsed = urllib.parse.urlparse(url_or_id)
    query_id = urllib.parse.parse_qs(parsed.query).get("id")
    if query_id:
        return query_id[0]
    if re.fullmatch(r"[A-Za-z0-9_-]+", url_or_id):
        return url_or_id
    raise ValueError(f"cannot extract Google Drive folder id from {url_or_id!r}")


def find_runtime_specs(folder_id: str, *, max_depth: int) -> list[RuntimeSpec]:
    specs: list[RuntimeSpec] = []
    visit_folder(folder_id, "", max_depth, specs)
    return specs


def visit_folder(folder_id: str, prefix: str, depth: int, specs: list[RuntimeSpec]) -> None:
    for item in list_drive_folder(folder_id):
        path = f"{prefix}/{item.name}" if prefix else item.name
        if item.name == "runtime_spec.json":
            specs.append(
                RuntimeSpec(
                    file_id=item.file_id,
                    path=path,
                    model_version=model_version_from_path(path),
                )
            )
            continue
        if depth > 0 and item.is_folder and re.fullmatch(r"model_v\d+", item.name):
            visit_folder(item.file_id, path, depth - 1, specs)


def list_drive_folder(folder_id: str) -> list[DriveItem]:
    page = fetch_text(DRIVE_FOLDER_URL.format(folder_id=folder_id))
    decoded = html.unescape(page)
    items: dict[str, DriveItem] = {}

    item_pattern = re.compile(
        r'\[\[\[\[\[null,"(?P<id>[A-Za-z0-9_-]{10,})"\]'
        r'.{0,800}?"(?P<mime>application/(?:json|vnd\.google-apps\.folder))"'
        r'.{0,4000}?\[\[\["(?P<name>[^"]+)",null,true\]\]\]',
        re.DOTALL,
    )
    for match in item_pattern.finditer(decoded):
        file_id = match.group("id")
        items[file_id] = DriveItem(
            file_id=file_id,
            mime_type=match.group("mime"),
            name=match.group("name"),
        )

    return list(items.values())


def model_version_from_path(path: str) -> int:
    match = re.search(r"model_v(\d+)", path)
    return int(match.group(1)) if match else 0


def download_drive_file(file_id: str, dest: pathlib.Path) -> None:
    url = DRIVE_FILE_DOWNLOAD_URL.format(file_id=file_id)
    data = fetch_bytes(url)
    if data.lstrip().startswith((b"<!DOCTYPE html", b"<html")):
        raise RuntimeError(f"Google Drive returned HTML instead of runtime spec for file {file_id}")

    with tempfile.NamedTemporaryFile(dir=dest.parent, delete=False) as temp_file:
        temp_file.write(data)
        temp_path = pathlib.Path(temp_file.name)

    try:
        with temp_path.open("rb") as file_obj:
            json.load(file_obj)
        temp_path.replace(dest)
    finally:
        if temp_path.exists():
            temp_path.unlink()


def fetch_text(url: str) -> str:
    return fetch_bytes(url).decode("utf-8", errors="replace")


def fetch_bytes(url: str) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=60) as response:
        return response.read()


if __name__ == "__main__":
    raise SystemExit(main())
