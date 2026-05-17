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
import urllib.error
import urllib.parse
import urllib.request


DRIVE_FILE_DOWNLOAD_URLS = (
    "https://drive.google.com/uc?export=download&id={file_id}",
    "https://drive.usercontent.google.com/download?id={file_id}&export=download&confirm=t",
)
DRIVE_FOLDER_URL = "https://drive.google.com/drive/folders/{folder_id}"
DRIVE_EMBEDDED_FOLDER_URL = "https://drive.google.com/embeddedfolderview?id={folder_id}#list"
REQUEST_HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
        "(KHTML, like Gecko) Chrome/124.0 Safari/537.36"
    ),
    "Accept": "text/html,application/json,*/*",
}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=pathlib.Path, required=True)
    parser.add_argument("--dest", type=pathlib.Path, required=True)
    parser.add_argument("--drive-file-url", action="append", default=[])
    parser.add_argument("--drive-folder-url", required=True)
    args = parser.parse_args()

    args.dest.parent.mkdir(parents=True, exist_ok=True)
    if args.source.is_file():
        shutil.copy2(args.source, args.dest)
        print(f"runtime_spec={args.dest} source={args.source}")
        return 0

    errors: list[str] = []
    for drive_file_url in args.drive_file_url:
        try:
            file_id = extract_file_id(drive_file_url)
            download_drive_file(file_id, args.dest)
            print(f"runtime_spec={args.dest} source=google-drive/{file_id}")
            return 0
        except (OSError, RuntimeError, ValueError, urllib.error.URLError, json.JSONDecodeError) as exc:
            errors.append(f"{drive_file_url}: {exc}")

    try:
        folder_id = extract_folder_id(args.drive_folder_url)
        specs = find_runtime_specs(folder_id, max_depth=2)
        if not specs:
            for error in errors:
                print(f"Direct Google Drive fallback failed: {error}", file=sys.stderr)
            print("No runtime_spec.json found in Google Drive fallback", file=sys.stderr)
            return 1

        selected = sorted(specs, key=lambda spec: (spec.model_version, spec.path))[-1]
        download_drive_file(selected.file_id, args.dest)
    except (OSError, RuntimeError, ValueError, urllib.error.URLError, json.JSONDecodeError) as exc:
        print(f"Failed to prepare runtime_spec.json from Google Drive fallback: {exc}", file=sys.stderr)
        return 1

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


def extract_file_id(url_or_id: str) -> str:
    match = re.search(r"/file/d/([A-Za-z0-9_-]+)", url_or_id)
    if match:
        return match.group(1)
    parsed = urllib.parse.urlparse(url_or_id)
    query_id = urllib.parse.parse_qs(parsed.query).get("id")
    if query_id:
        return query_id[0]
    if re.fullmatch(r"[A-Za-z0-9_-]+", url_or_id):
        return url_or_id
    raise ValueError(f"cannot extract Google Drive file id from {url_or_id!r}")


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
    items: dict[str, DriveItem] = {}
    urls = (
        DRIVE_FOLDER_URL.format(folder_id=folder_id),
        DRIVE_EMBEDDED_FOLDER_URL.format(folder_id=folder_id),
    )

    for url in urls:
        try:
            decoded = decode_drive_page(fetch_text(url))
        except urllib.error.URLError:
            if items:
                break
            raise
        for item in parse_drive_items(decoded):
            items[item.file_id] = item

    return list(items.values())


def decode_drive_page(page: str) -> str:
    decoded = html.unescape(page)
    return (
        decoded.replace("\\u002f", "/")
        .replace("\\u002F", "/")
        .replace("\\x22", '"')
        .replace('\\"', '"')
    )


def parse_drive_items(decoded: str) -> list[DriveItem]:
    items: dict[str, DriveItem] = {}
    item_pattern = re.compile(
        r'\[\[\[\[\[null,"(?P<id>[A-Za-z0-9_-]{10,})"\]'
        r'.{0,1200}?"(?P<mime>application/(?:json|vnd\.google-apps\.folder))"'
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

    file_link_pattern = re.compile(
        r'https://drive\.google\.com/file/d/(?P<id>[A-Za-z0-9_-]{10,})/[^"]*'
        r'.{0,1200}?(?:aria-label|title|data-tooltip)="(?P<name>[^"]+)"',
        re.DOTALL,
    )
    for match in file_link_pattern.finditer(decoded):
        name = clean_drive_name(match.group("name"))
        if name:
            items[match.group("id")] = DriveItem(
                file_id=match.group("id"),
                mime_type=guess_mime_type(name),
                name=name,
            )

    folder_link_pattern = re.compile(
        r'https://drive\.google\.com/drive/folders/(?P<id>[A-Za-z0-9_-]{10,})[^"]*'
        r'.{0,1200}?(?:aria-label|title|data-tooltip)="(?P<name>[^"]+)"',
        re.DOTALL,
    )
    for match in folder_link_pattern.finditer(decoded):
        name = clean_drive_name(match.group("name"))
        if name and match.group("id") not in items:
            items[match.group("id")] = DriveItem(
                file_id=match.group("id"),
                mime_type="application/vnd.google-apps.folder",
                name=name,
            )

    return list(items.values())


def clean_drive_name(raw_name: str) -> str:
    name = html.unescape(raw_name).strip()
    for prefix in ("Open ", "Download "):
        if name.startswith(prefix):
            name = name[len(prefix) :].strip()
    return name


def guess_mime_type(name: str) -> str:
    if name.endswith(".json"):
        return "application/json"
    return "application/octet-stream"


def model_version_from_path(path: str) -> int:
    match = re.search(r"model_v(\d+)", path)
    return int(match.group(1)) if match else 0


def download_drive_file(file_id: str, dest: pathlib.Path) -> None:
    errors: list[str] = []
    for url_template in DRIVE_FILE_DOWNLOAD_URLS:
        url = url_template.format(file_id=file_id)
        opener = urllib.request.build_opener()
        try:
            data = fetch_bytes(url, opener=opener)
            if is_html(data):
                follow_url = extract_download_link(data, url)
                if follow_url:
                    data = fetch_bytes(follow_url, opener=opener)
            write_valid_json(data, dest)
            return
        except (RuntimeError, urllib.error.URLError, json.JSONDecodeError, OSError) as exc:
            errors.append(f"{url}: {exc}")

    joined_errors = "; ".join(errors)
    raise RuntimeError(f"could not download Google Drive file {file_id}: {joined_errors}")


def is_html(data: bytes) -> bool:
    stripped = data.lstrip()[:128].lower()
    return stripped.startswith((b"<!doctype html", b"<html"))


def extract_download_link(data: bytes, current_url: str) -> str | None:
    decoded = decode_drive_page(data.decode("utf-8", errors="replace"))
    patterns = (
        r'href="(?P<url>https://drive\.usercontent\.google\.com/download[^"]+)"',
        r'href="(?P<url>/uc\?export=download[^"]+)"',
    )
    for pattern in patterns:
        match = re.search(pattern, decoded)
        if match:
            return urllib.parse.urljoin(current_url, html.unescape(match.group("url")))
    return None


def write_valid_json(data: bytes, dest: pathlib.Path) -> None:
    if is_html(data):
        raise RuntimeError("Google Drive returned HTML instead of runtime spec")
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


def fetch_bytes(url: str, *, opener: urllib.request.OpenerDirector | None = None) -> bytes:
    request = urllib.request.Request(url, headers=REQUEST_HEADERS)
    open_url = opener.open if opener else urllib.request.urlopen
    with open_url(request, timeout=60) as response:
        return response.read()


if __name__ == "__main__":
    raise SystemExit(main())
