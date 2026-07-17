#!/usr/bin/env python3

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).parents[1] / "src" / "agent_pending_cli.py"
SPEC = importlib.util.spec_from_file_location("agent_pending_cli", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class PendingStoreTests(unittest.TestCase):
    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.store = MODULE.PendingStore(self.temporary_directory.name)

    def tearDown(self):
        self.temporary_directory.cleanup()

    def test_add_list_and_complete(self):
        first, _ = self.store.add("内容发布", "确认最终封面", "/tmp/project-a")
        second, _ = self.store.add("论文整理", "确认保留章节", "/tmp/project-b")

        items = self.store.list_items()
        self.assertEqual([first["id"], second["id"]], [item["id"] for item in items])
        self.assertEqual(["medium", "medium"], [item["priority"] for item in items])
        self.assertEqual([0, 1], [item["position"] for item in items])

        archived = self.store.complete(first["id"])
        self.assertEqual([second["id"]], [item["id"] for item in self.store.list_items()])
        self.assertEqual(first["id"], archived["id"])
        self.assertEqual(first["id"], self.store.list_archive()[0]["id"])

        restored = self.store.restore(first["id"])
        self.assertEqual(first["id"], restored["id"])
        self.assertEqual(1, restored["position"])
        self.assertEqual([second["id"], first["id"]], [item["id"] for item in self.store.list_items()])
        self.assertEqual(2, len(self.store.list_items()))
        self.assertEqual([], self.store.list_archive())

    def test_priority_is_independent_from_processing_order(self):
        first, _ = self.store.add(
            "高重要事项", "稍后处理", "/tmp/high", priority="high"
        )
        second, _ = self.store.add("普通事项", "先处理", "/tmp/medium")

        self.store.move(second["id"], top=True)
        items = self.store.list_items()

        self.assertEqual([second["id"], first["id"]], [item["id"] for item in items])
        self.assertEqual(["medium", "high"], [item["priority"] for item in items])

    def test_move_before_after_top_and_bottom(self):
        first, _ = self.store.add("一", "一", "/tmp/1")
        second, _ = self.store.add("二", "二", "/tmp/2")
        third, _ = self.store.add("三", "三", "/tmp/3")

        self.store.move(third["id"], top=True)
        self.assertEqual(
            [third["id"], first["id"], second["id"]],
            [item["id"] for item in self.store.list_items()],
        )
        self.store.move(third["id"], after=first["id"])
        self.assertEqual(
            [first["id"], third["id"], second["id"]],
            [item["id"] for item in self.store.list_items()],
        )
        self.store.move(second["id"], before=first["id"])
        self.assertEqual(
            [second["id"], first["id"], third["id"]],
            [item["id"] for item in self.store.list_items()],
        )
        self.store.move(second["id"], bottom=True)
        items = self.store.list_items()
        self.assertEqual([first["id"], third["id"], second["id"]], [item["id"] for item in items])
        self.assertEqual([0, 1, 2], [item["position"] for item in items])

    def test_set_priority_validates_level(self):
        item, _ = self.store.add("事项", "内容", "/tmp/item")
        changed = self.store.set_priority(item["id"], "low")
        self.assertEqual("low", changed["priority"])
        with self.assertRaisesRegex(ValueError, "优先级必须"):
            self.store.set_priority(item["id"], "urgent")

    def test_storage_is_valid_utf8_json(self):
        self.store.add("项目甲", "确认中文记录", "/tmp/项目甲")
        with self.store.data_file.open(encoding="utf-8") as source:
            stored = json.load(source)

        self.assertEqual(1, stored["version"])
        self.assertEqual("项目甲", stored["pending"][0]["title"])
        self.assertEqual("确认中文记录", stored["pending"][0]["note"])

    def test_empty_fields_are_rejected(self):
        with self.assertRaisesRegex(ValueError, "标题不能为空"):
            self.store.add("  ", "确认内容", "/tmp/project")

    def test_hundred_items_remain_readable(self):
        for index in range(100):
            self.store.add(f"项目 {index}", f"确认事项 {index}", f"/tmp/project-{index}")

        self.assertEqual(100, len(self.store.list_items()))

    def test_duplicate_add_is_idempotent_by_default(self):
        first, first_created = self.store.add("发布", "确认文案", "/tmp/project")
        second, second_created = self.store.add("发布", "确认文案", "/tmp/project")

        self.assertTrue(first_created)
        self.assertFalse(second_created)
        self.assertEqual(first["id"], second["id"])
        self.assertEqual(1, len(self.store.list_items()))

    def test_duplicate_can_be_added_explicitly(self):
        self.store.add("发布", "确认文案", "/tmp/project")
        self.store.add("发布", "确认文案", "/tmp/project", allow_duplicate=True)

        self.assertEqual(2, len(self.store.list_items()))

    def test_legacy_list_is_migrated(self):
        self.store.data_directory.mkdir(parents=True, exist_ok=True)
        legacy = [
            {
                "id": "legacy-id",
                "title": "旧事项",
                "note": "确认是否继续",
                "workspace_path": "/tmp/legacy",
                "created_at": "2026-01-01T00:00:00+00:00",
            }
        ]
        self.store.data_file.write_text(json.dumps(legacy), encoding="utf-8")

        self.assertEqual("legacy-id", self.store.list_items()[0]["id"])
        self.assertEqual("medium", self.store.list_items()[0]["priority"])
        self.assertEqual(0, self.store.list_items()[0]["position"])
        with self.store.data_file.open(encoding="utf-8") as source:
            migrated = json.load(source)
        self.assertEqual(1, migrated["version"])
        self.assertEqual([], migrated["archive"])


class PendingCliTests(unittest.TestCase):
    def test_json_add_complete_and_restore_round_trip(self):
        with tempfile.TemporaryDirectory() as data_directory:
            environment = {**os.environ, "AGENT_PENDING_DATA_DIR": data_directory}

            added = subprocess.run(
                [
                    sys.executable,
                    str(MODULE_PATH),
                    "add",
                    "--title",
                    "Release review",
                    "--note",
                    "Approve the final copy",
                    "--workspace",
                    "/tmp/release",
                ],
                check=True,
                capture_output=True,
                text=True,
                env=environment,
            )
            item = json.loads(added.stdout)
            self.assertTrue(item["created"])
            self.assertEqual("medium", item["priority"])

            completed = subprocess.run(
                [sys.executable, str(MODULE_PATH), "complete", item["id"]],
                check=True,
                capture_output=True,
                text=True,
                env=environment,
            )
            self.assertEqual("archived", json.loads(completed.stdout)["status"])

            restored = subprocess.run(
                [sys.executable, str(MODULE_PATH), "restore", item["id"]],
                check=True,
                capture_output=True,
                text=True,
                env=environment,
            )
            self.assertEqual("pending", json.loads(restored.stdout)["status"])

    def test_priority_and_move_commands(self):
        with tempfile.TemporaryDirectory() as data_directory:
            environment = {**os.environ, "AGENT_PENDING_DATA_DIR": data_directory}
            items = []
            for title in ("First", "Second"):
                result = subprocess.run(
                    [
                        sys.executable,
                        str(MODULE_PATH),
                        "add",
                        "--title",
                        title,
                        "--note",
                        "Review",
                        "--workspace",
                        "/tmp/review",
                    ],
                    check=True,
                    capture_output=True,
                    text=True,
                    env=environment,
                )
                items.append(json.loads(result.stdout))

            changed = subprocess.run(
                [
                    sys.executable,
                    str(MODULE_PATH),
                    "priority",
                    items[0]["id"],
                    "high",
                ],
                check=True,
                capture_output=True,
                text=True,
                env=environment,
            )
            self.assertEqual("high", json.loads(changed.stdout)["priority"])

            subprocess.run(
                [
                    sys.executable,
                    str(MODULE_PATH),
                    "move",
                    items[1]["id"],
                    "--top",
                ],
                check=True,
                capture_output=True,
                text=True,
                env=environment,
            )
            listed = subprocess.run(
                [sys.executable, str(MODULE_PATH), "list", "--json"],
                check=True,
                capture_output=True,
                text=True,
                env=environment,
            )
            self.assertEqual(
                [items[1]["id"], items[0]["id"]],
                [item["id"] for item in json.loads(listed.stdout)],
            )


if __name__ == "__main__":
    unittest.main()
