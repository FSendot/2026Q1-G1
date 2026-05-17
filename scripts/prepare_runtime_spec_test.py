#!/usr/bin/env python3
"""Tests for scripts/prepare_runtime_spec.py."""

from __future__ import annotations

import pathlib
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(pathlib.Path(__file__).parent))

import prepare_runtime_spec


class PrepareRuntimeSpecTest(unittest.TestCase):
    def test_extract_file_id_from_drive_file_url(self) -> None:
        file_id = prepare_runtime_spec.extract_file_id(
            "https://drive.google.com/file/d/1Gut3LFjfYVpIEHJIXkzztcfZ6o-CRAwX/view?usp=sharing"
        )

        self.assertEqual(file_id, "1Gut3LFjfYVpIEHJIXkzztcfZ6o-CRAwX")

    def test_direct_drive_file_fallback_writes_valid_json(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            dest = pathlib.Path(temp_dir) / "runtime_spec.json"
            with mock.patch.object(
                prepare_runtime_spec,
                "fetch_bytes",
                return_value=b'{"model_version":"model_v1"}',
            ):
                prepare_runtime_spec.download_drive_file("drive-file-id", dest)

            self.assertEqual(dest.read_text(), '{"model_version":"model_v1"}')

    def test_drive_folder_parser_accepts_escaped_slashes(self) -> None:
        page = (
            r'[[[[[null,"folder123456"]]'
            r' "application\u002fvnd.google-apps.folder"'
            r' [[["model_v1",null,true]]]'
        )

        items = prepare_runtime_spec.parse_drive_items(prepare_runtime_spec.decode_drive_page(page))

        self.assertEqual(len(items), 1)
        self.assertEqual(items[0].file_id, "folder123456")
        self.assertEqual(items[0].name, "model_v1")
        self.assertTrue(items[0].is_folder)


if __name__ == "__main__":
    unittest.main()
