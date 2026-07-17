#!/usr/bin/env python3

import os
import plistlib
import re
import subprocess
import struct
import tempfile
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
IGNORED_DIRS = {".git", ".DS_Store", "dist", "build", "__pycache__"}


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
        self.assertEqual("0.2.0", info["CFBundleShortVersionString"])

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

    def test_install_uses_existing_skill_catalog_and_replaces_legacy_client_skills(self):
        with tempfile.TemporaryDirectory() as temporary_home:
            home = Path(temporary_home)
            skills_root = home / "agent-skills" / "09-agent-ops"
            skills_root.mkdir(parents=True)
            for client in (".codex", ".claude"):
                legacy_skill = home / client / "skills" / "agent-pending"
                legacy_skill.mkdir(parents=True)
                (legacy_skill / "SKILL.md").write_text(
                    "legacy skill still writes pending.json\n",
                    encoding="utf-8",
                )

            environment = {
                **os.environ,
                "HOME": temporary_home,
                "AGENT_PENDING_SKIP_LAUNCH": "1",
            }
            subprocess.run(
                [str(ROOT / "scripts" / "install.sh")],
                cwd=ROOT,
                check=True,
                capture_output=True,
                text=True,
                env=environment,
            )

            shared_skill = skills_root / "agent-pending"
            expected = (ROOT / "skill" / "agent-pending" / "SKILL.md").read_text(
                encoding="utf-8"
            )
            self.assertFalse((home / ".agents" / "skills" / "agent-pending").exists())
            for client in (".codex", ".claude"):
                installed_skill = home / client / "skills" / "agent-pending"
                self.assertTrue(installed_skill.is_symlink())
                self.assertEqual(shared_skill.resolve(), installed_skill.resolve())
                self.assertEqual(
                    expected,
                    (installed_skill / "SKILL.md").read_text(encoding="utf-8"),
                )

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
        self.assertIn('@"zh": @"待处理"', source)
        self.assertIn('@"en": @"Action Items"', source)
        self.assertIn('@selector(changeLanguage:)', source)

    def test_app_supports_gui_add_and_outside_click_dismissal(self):
        source = (ROOT / "src" / "AgentPendingApp.m").read_text(encoding="utf-8")
        self.assertIn("APAddButton", source)
        self.assertIn("- (void)addItem", source)
        self.assertIn("applicationDidResignActive", source)
        self.assertIn("activateIgnoringOtherApps", source)

    def test_app_has_full_editor_workspace_copy_and_native_graphite_palette(self):
        source = (ROOT / "src" / "AgentPendingApp.m").read_text(encoding="utf-8")
        self.assertIn("APEditorForm", source)
        self.assertIn("NSTextView *noteView", source)
        self.assertIn('candidate[@"workspace_path"] = workspace;', source)
        self.assertIn('APIconButton(@"doc.on.doc"', source)
        self.assertIn("NSPasteboard.generalPasteboard", source)
        self.assertIn("NSVisualEffectMaterialHeaderView", source)
        self.assertIn("APTechGrayColor", source)
        self.assertIn("dynamicProvider", source)
        self.assertIn("NSColor.controlBackgroundColor", source)
        self.assertIn("row.layer.shadowOpacity", source)
        self.assertNotIn("APLogoOrange", source)
        self.assertNotIn("NSColor.systemBlueColor", source)
        self.assertNotIn("NSColor.systemIndigoColor", source)
        self.assertNotIn("NSColor.systemTealColor", source)
        self.assertNotIn("NSColor.systemPurpleColor", source)

    def test_app_supports_independent_priority_and_drag_order(self):
        source = (ROOT / "src" / "AgentPendingApp.m").read_text(encoding="utf-8")
        cli = (ROOT / "src" / "agent_pending_cli.py").read_text(encoding="utf-8")
        self.assertIn("NSTableViewDataSource", source)
        self.assertIn("registerForDraggedTypes", source)
        self.assertIn("pasteboardWriterForRow", source)
        self.assertIn("reorderItemsWithIdentifiers", source)
        self.assertIn('APText(@"priority_high")', source)
        self.assertIn('APText(@"priority_medium")', source)
        self.assertIn('APText(@"priority_low")', source)
        self.assertIn("moveTopClicked", source)
        self.assertIn("VALID_PRIORITIES", cli)
        self.assertIn('subparsers.add_parser("move"', cli)

    def test_popover_width_adapts_and_priority_uses_graphite_depth_only(self):
        source = (ROOT / "src" / "AgentPendingApp.m").read_text(encoding="utf-8")
        self.assertIn("screenWidth * 0.30", source)
        self.assertIn("MIN(640, MAX(520", source)
        self.assertIn("return 1.00", source)
        self.assertIn("return 0.70", source)
        self.assertIn("return 0.40", source)
        self.assertIn("copy.contentTintColor = priorityColor", source)
        self.assertIn("edit.contentTintColor = priorityColor", source)
        self.assertIn("complete.contentTintColor = priorityColor", source)
        self.assertNotIn("APPriorityBadgeView", source)

    def test_default_build_app_is_hidden_from_launchpad(self):
        build = (ROOT / "scripts" / "build.sh").read_text(encoding="utf-8")
        self.assertIn('$ROOT/build/.artifacts', build)

    def test_demo_is_isolated_from_production_data(self):
        demo = (ROOT / "scripts" / "demo.sh").read_text(encoding="utf-8")
        self.assertIn("mktemp -d", demo)
        self.assertIn('AGENT_PENDING_DATA_DIR="$DEMO_DATA"', demo)
        self.assertIn("trap cleanup", demo)


if __name__ == "__main__":
    unittest.main()
