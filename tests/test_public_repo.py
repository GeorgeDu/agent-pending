#!/usr/bin/env python3

import plistlib
import re
import struct
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

    def test_bilingual_readmes_are_linked_and_screenshot_is_present(self):
        chinese = (ROOT / "README.md").read_text(encoding="utf-8")
        english = (ROOT / "README.en.md").read_text(encoding="utf-8")
        screenshot = ROOT / "docs" / "images" / "agent-pending-zh.png"

        self.assertIn("README.en.md", chinese)
        self.assertIn("README.md", english)
        self.assertIn("docs/images/agent-pending-zh.png", chinese)
        self.assertTrue(screenshot.is_file())

        with screenshot.open("rb") as image:
            self.assertEqual(b"\x89PNG\r\n\x1a\n", image.read(8))
            image.read(8)
            pixel_width, _ = struct.unpack(">II", image.read(8))
        displayed_width = int(
            re.search(r'agent-pending-zh\.png" width="(\d+)"', chinese).group(1)
        )
        self.assertGreaterEqual(pixel_width, displayed_width * 2)
        self.assertIn(f'width="{displayed_width}"', english)

    def test_app_has_chinese_default_and_english_ui(self):
        source = (ROOT / "src" / "AgentPendingApp.m").read_text(encoding="utf-8")
        self.assertIn('return [saved isEqualToString:@"en"] ? @"en" : @"zh";', source)
        self.assertIn('@"zh": @"待确认"', source)
        self.assertIn('@"en": @"Pending"', source)
        self.assertIn('@selector(changeLanguage:)', source)

    def test_demo_is_isolated_from_production_data(self):
        demo = (ROOT / "scripts" / "demo.sh").read_text(encoding="utf-8")
        self.assertIn("mktemp -d", demo)
        self.assertIn('AGENT_PENDING_DATA_DIR="$DEMO_DATA"', demo)
        self.assertIn("trap cleanup", demo)


if __name__ == "__main__":
    unittest.main()
