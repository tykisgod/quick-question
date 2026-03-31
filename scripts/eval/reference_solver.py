#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


TASK_FIXES: dict[str, list[dict[str, str]]] = {
    "policy-fix-find-object-of-type": [
        {
            "path": "Assets/Scripts/EnemyTracker.cs",
            "content": "using UnityEngine;\n\npublic class Enemy : MonoBehaviour {}\n\npublic class EnemyTracker : MonoBehaviour\n{\n    [SerializeField] private Enemy[] enemies = System.Array.Empty<Enemy>();\n\n    void Update()\n    {\n        foreach (var enemy in enemies)\n        {\n        }\n    }\n}\n",
        }
    ],
    "policy-fix-hot-path-caching": [
        {
            "path": "Assets/Scripts/PlayerLocator.cs",
            "content": "using UnityEngine;\n\npublic class PlayerLocator : MonoBehaviour\n{\n    private Rigidbody cachedBody;\n\n    void Awake()\n    {\n        cachedBody = GetComponent<Rigidbody>();\n    }\n\n    void Update()\n    {\n        if (gameObject.CompareTag(\"Player\"))\n        {\n            cachedBody.velocity = Vector3.zero;\n        }\n    }\n}\n",
        }
    ],
}


def write_text(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Deterministic reference solver for qq benchmark fixtures")
    parser.add_argument("--project", required=True, help="Benchmark fixture root")
    parser.add_argument("--task-id", required=True, help="Benchmark task identifier")
    parser.add_argument("--prompt-file", help="Optional prompt file written by the harness")
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()

    project_dir = Path(args.project).resolve()
    specs = TASK_FIXES.get(args.task_id)
    if not specs:
        print(json.dumps({"ok": False, "error": f"unsupported task_id: {args.task_id}"}, ensure_ascii=False), file=sys.stderr)
        return 2

    for spec in specs:
        write_text(project_dir / spec["path"], spec["content"])

    payload = {
        "ok": True,
        "task_id": args.task_id,
        "project_dir": str(project_dir),
        "prompt_file": str(Path(args.prompt_file).resolve()) if args.prompt_file else "",
        "files_written": [spec["path"] for spec in specs],
    }
    print(json.dumps(payload, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
