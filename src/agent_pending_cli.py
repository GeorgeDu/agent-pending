#!/usr/bin/env python3

import argparse
import fcntl
import json
import os
import sys
import tempfile
import uuid
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path

DEFAULT_DATA_DIRECTORY = (
    Path.home() / "Library" / "Application Support" / "Agent Pending"
)


class PendingStore:
    def __init__(self, data_directory=None):
        configured = data_directory or os.environ.get("AGENT_PENDING_DATA_DIR")
        self.data_directory = Path(configured) if configured else DEFAULT_DATA_DIRECTORY
        self.data_file = self.data_directory / "store.json"
        self.lock_file = self.data_directory / "store.lock"

    @contextmanager
    def locked(self):
        self.data_directory.mkdir(parents=True, exist_ok=True)
        with self.lock_file.open("a+", encoding="utf-8") as lock:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
            try:
                yield
            finally:
                fcntl.flock(lock.fileno(), fcntl.LOCK_UN)

    def list_items(self):
        with self.locked():
            items = self._read_unlocked()["pending"]
        return sorted(items, key=lambda item: item["created_at"])

    def list_archive(self):
        with self.locked():
            items = self._read_unlocked()["archive"]
        return sorted(items, key=lambda item: item["completed_at"], reverse=True)

    def add(self, title, note, workspace_path, allow_duplicate=False):
        item = {
            "id": str(uuid.uuid4()),
            "title": required(title, "标题"),
            "note": required(note, "待处理内容"),
            "workspace_path": required(workspace_path, "工作区路径"),
            "created_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        }
        with self.locked():
            store = self._read_unlocked()
            if not allow_duplicate:
                for existing in store["pending"]:
                    if all(
                        existing[field] == item[field]
                        for field in ("title", "note", "workspace_path")
                    ):
                        return existing, False
            store["pending"].append(item)
            self._write_unlocked(store)
        return item, True

    def complete(self, item_id):
        with self.locked():
            store = self._read_unlocked()
            index = next(
                (
                    index
                    for index, item in enumerate(store["pending"])
                    if item["id"] == item_id
                ),
                None,
            )
            if index is None:
                raise ValueError(f"找不到待确认事项：{item_id}")
            item = dict(store["pending"].pop(index))
            item["completed_at"] = datetime.now(timezone.utc).isoformat(
                timespec="seconds"
            )
            store["archive"].append(item)
            self._write_unlocked(store)
        return item

    def restore(self, item_id):
        with self.locked():
            store = self._read_unlocked()
            index = next(
                (
                    index
                    for index, item in enumerate(store["archive"])
                    if item["id"] == item_id
                ),
                None,
            )
            if index is None:
                raise ValueError(f"找不到已归档事项：{item_id}")
            item = dict(store["archive"].pop(index))
            item.pop("completed_at", None)
            store["pending"].append(item)
            self._write_unlocked(store)
        return item

    def _read_unlocked(self):
        if not self.data_file.exists():
            store = self._empty_store()
            self._write_unlocked(store)
            return store
        with self.data_file.open(encoding="utf-8") as source:
            content = source.read().strip()
        if not content:
            store = self._empty_store()
            self._write_unlocked(store)
            return store
        data = json.loads(content)
        if isinstance(data, list):
            data = {"version": 1, "pending": data, "archive": []}
            self._write_unlocked(data)
        if not isinstance(data, dict) or data.get("version") != 1:
            raise ValueError("store.json 必须使用版本 1 的对象结构")
        if not isinstance(data.get("pending"), list) or not isinstance(
            data.get("archive"), list
        ):
            raise ValueError("store.json 的 pending 和 archive 必须是数组")
        return data

    @staticmethod
    def _empty_store():
        return {"version": 1, "pending": [], "archive": []}

    def _write_unlocked(self, store):
        self.data_directory.mkdir(parents=True, exist_ok=True)
        descriptor, temporary_path = tempfile.mkstemp(
            dir=self.data_directory,
            prefix="pending-",
            suffix=".json",
            text=True,
        )
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8") as target:
                json.dump(store, target, ensure_ascii=False, indent=2, sort_keys=True)
                target.write("\n")
                target.flush()
                os.fsync(target.fileno())
            os.replace(temporary_path, self.data_file)
        finally:
            if os.path.exists(temporary_path):
                os.unlink(temporary_path)


def required(value, field):
    clean = value.strip()
    if not clean:
        raise ValueError(f"{field}不能为空")
    return clean


def build_parser():
    parser = argparse.ArgumentParser(prog="agent-pending")
    subparsers = parser.add_subparsers(dest="command", required=True)

    add_parser = subparsers.add_parser("add", help="新增一条待确认事项")
    add_parser.add_argument("--title", required=True)
    add_parser.add_argument("--note", required=True)
    add_parser.add_argument("--workspace", required=True)
    add_parser.add_argument("--allow-duplicate", action="store_true")

    list_parser = subparsers.add_parser("list", help="查看当前事项")
    list_parser.add_argument("--json", action="store_true")

    complete_parser = subparsers.add_parser("complete", help="完成并归档事项")
    complete_parser.add_argument("item_id")

    archive_parser = subparsers.add_parser("archive", help="查看已完成事项")
    archive_parser.add_argument("--json", action="store_true")

    restore_parser = subparsers.add_parser("restore", help="恢复已归档事项")
    restore_parser.add_argument("item_id")
    return parser


def main(argv=None, data_directory=None):
    args = build_parser().parse_args(argv)
    store = PendingStore(data_directory=data_directory)

    if args.command == "add":
        item, created = store.add(
            args.title,
            args.note,
            args.workspace,
            allow_duplicate=args.allow_duplicate,
        )
        payload = {**item, "created": created}
        print(json.dumps(payload, ensure_ascii=False, sort_keys=True))
    elif args.command == "list":
        items = store.list_items()
        if args.json:
            print(json.dumps(items, ensure_ascii=False, indent=2, sort_keys=True))
        elif not items:
            print("没有待确认事项")
        else:
            for item in items:
                print(
                    "\t".join(
                        [item["id"], item["title"], item["note"], item["workspace_path"]]
                    )
                )
    elif args.command == "complete":
        item = store.complete(args.item_id)
        print(json.dumps({**item, "status": "archived"}, ensure_ascii=False))
    elif args.command == "archive":
        items = store.list_archive()
        if args.json:
            print(json.dumps(items, ensure_ascii=False, indent=2, sort_keys=True))
        elif not items:
            print("没有已归档事项")
        else:
            for item in items:
                print(
                    "\t".join(
                        [item["id"], item["title"], item["note"], item["workspace_path"]]
                    )
                )
    elif args.command == "restore":
        item = store.restore(args.item_id)
        print(json.dumps({**item, "status": "pending"}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"错误：{error}", file=sys.stderr)
        raise SystemExit(1)
