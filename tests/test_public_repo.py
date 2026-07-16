#!/usr/bin/env python3

import plistlib
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[1]
TEXT_SUFFIXES = {"", ".md", ".py", ".sh", ".yml", ".yaml", ".plist", ".in"}
PRIVATE_MARKERS = (
    "/Users/" + "george",
    "guoguang" + "35@",
    "Decision" + "OS",
    "Nu" + "wa",
)
IGNORED_DIRS = {".git", "dist", "build", "__pycache__"}


class PublicRepositoryTests(unittest.TestCase):
    def test_text_files_contain_no_private_markers(self):
        violations = []
        for path in ROOT.rglob("*"):
            relative = path.relative_to(ROOT)
            if any(part in IGNORED_DIRS for part in relative.parts):
                continue
            if not path.is_file() or path.suffix not in TEXT_SUFFIXES:
                continue
            content = path.read_text(encoding="utf-8")
            for marker in PRIVATE_MARKERS:
                if marker in content:
                    violations.append(f"{path.relative_to(ROOT)}: {marker}")
        self.assertEqual([], violations)

    def test_runtime_data_is_not_in_repository(self):
        forbidden = {"pending.json", "pending.lock", "store.json", "store.lock"}
        found = [path.name for path in ROOT.rglob("*") if path.name in forbidden]
        self.assertEqual([], found)

    def test_bundle_identity_and_version(self):
        with (ROOT / "Resources" / "Info.plist").open("rb") as source:
            info = plistlib.load(source)
        self.assertEqual("io.github.georgedu.agent-pending", info["CFBundleIdentifier"])
        self.assertEqual("0.1.0", info["CFBundleShortVersionString"])

    def test_skill_is_explicit_only(self):
        metadata = (ROOT / "skill" / "agent-pending" / "agents" / "openai.yaml").read_text(
            encoding="utf-8"
        )
        instructions = (ROOT / "skill" / "agent-pending" / "SKILL.md").read_text(
            encoding="utf-8"
        )
        self.assertIn("allow_implicit_invocation: false", metadata)
        self.assertIn("Never trigger", instructions)
        self.assertIn("one item", instructions.lower())


if __name__ == "__main__":
    unittest.main()
