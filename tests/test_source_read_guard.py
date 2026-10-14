"""Owned synthetic fixtures prove denial happens before source byte access."""
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS))
from learning_store import LearningStore, _source_metadata


class SourceReadGuardTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.directory = Path(self.temporary.name)

    def tearDown(self):
        self.temporary.cleanup()

    def test_obvious_credential_files_denied_before_open(self):
        names = [".env", ".env.local", "auth.json", "auth(2).json", "auth (3).json", "auth(2) (1).json", "credentials.json",
                 "credentials(2).json", "credential.json", "token.json", "tokens.json", "access_token.json",
                 "refresh-token.json", "secret.json", "passwords.json", "api_key.json", "id_rsa", "id_ed25519",
                 "private_key.json", "private-key.json", "private.pem", "private.key", "key.p12"]
        for name in names:
            with self.subTest(name=name):
                path = self.directory / name
                path.write_text("SYNTHETIC_CREDENTIAL_BYTES_NEVER_READ")
                with patch.object(Path, "open", side_effect=AssertionError("Credential bytes were opened")) as spy:
                    metadata = _source_metadata(str(path), [])
                spy.assert_not_called()
                self.assertEqual(metadata["safety_findings"], ["credential_source_denied"])
                self.assertFalse(metadata["source_available"])
                self.assertEqual(metadata["source_sha256"], "")

    def test_supported_extension_alias_to_credential_is_denied_before_open(self):
        target = self.directory / "auth(2).json"
        target.write_text("SYNTHETIC_CREDENTIAL_BYTES_NEVER_READ")
        alias = self.directory / "desktop-plan.json"
        alias.symlink_to(target)
        with patch.object(Path, "open", side_effect=AssertionError("Symlink opened credential bytes")) as spy:
            metadata = _source_metadata(str(alias), [])
        spy.assert_not_called()
        self.assertEqual(metadata["safety_findings"], ["credential_source_denied"])

    def test_unsupported_file_types_denied_before_open(self):
        for name in ["runtime.sqlite3", "messages.txt", "capture.png", "opaque.bin"]:
            with self.subTest(name=name):
                source = self.directory / name
                source.write_text("OWNED_FIXTURE_BYTES_NEVER_READ")
                with patch.object(Path, "open", side_effect=AssertionError("Unsupported data file was opened")) as spy:
                    metadata = _source_metadata(str(source), [])
                spy.assert_not_called()
                self.assertEqual(metadata["safety_findings"], ["source_extension_not_supported"])

    def test_json_alias_cannot_open_a_runtime_database(self):
        target = self.directory / "runtime.sqlite3"
        target.write_text("OWNED_NON_DATABASE_FIXTURE_NEVER_READ")
        alias = self.directory / "source.json"
        alias.symlink_to(target)
        with patch.object(Path, "open", side_effect=AssertionError("Data alias was opened")) as spy:
            metadata = _source_metadata(str(alias), [])
        spy.assert_not_called()
        self.assertEqual(metadata["safety_findings"], ["source_extension_not_supported"])

    def test_supported_parameterized_source_files_still_register(self):
        cases = {"edit.py": ("def edit(text):\n    return text\n", "python"),
                 "edit.swift": ("func edit(_ text: String) -> String { text }\n", "swift"),
                 "edit.sh": ('#!/bin/sh\nprintf "%s" "$1"\n', "shell"),
                 "auth.py": ("def auth(token):\n    return token\n", "python"),
                 "token.py": ("def token(text):\n    return text\n", "python"),
                 "edit.json": (json.dumps({"format": "desktop_plan/v1", "app": "com.apple.TextEdit",
                                           "parameter_names": ["text"], "steps": [], "postconditions": []}), "json")}
        store = LearningStore(self.directory / "runtime")
        for name, (source, language) in cases.items():
            with self.subTest(name=name):
                path = self.directory / name
                path.write_text(source)
                row = store.register("fixture-task", "com.apple.TextEdit", str(path), ["text"])
                self.assertTrue(row["source_available"])
                self.assertEqual(row["language"], language)
                self.assertEqual(row["source_sha256"], hashlib.sha256(source.encode()).hexdigest())
                self.assertFalse(row["executable"])

    def test_registry_does_not_read_or_copy_denied_source(self):
        source = self.directory / "credentials.json"
        marker = "SYNTHETIC_CREDENTIAL_BYTES_NEVER_READ"
        source.write_text(marker)
        original_open = Path.open
        denied_opens = []
        def guarded_open(path, *args, **kwargs):
            if path == source:
                denied_opens.append(str(path))
                raise AssertionError("Registry opened a denied source")
            return original_open(path, *args, **kwargs)
        store = LearningStore(self.directory / "runtime")
        with patch.object(Path, "open", guarded_open):
            row = store.register("fixture-task", "com.apple.TextEdit", str(source), [])
            summary = store.analyze()
        self.assertEqual(denied_opens, [])
        self.assertEqual(row["status"], "candidate")
        self.assertEqual(summary["candidates"][0]["recommendation"], "use_noncredential_script_source")
        self.assertNotIn(marker, store.path.read_text())


if __name__ == "__main__":
    unittest.main()
