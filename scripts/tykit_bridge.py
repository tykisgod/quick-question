#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
from contextlib import contextmanager
import uuid
from datetime import datetime, timezone
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from urllib import error as urllib_error
from urllib import request as urllib_request

from qq_bridge_common import BridgeError


ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")
COMPILE_ERROR_RE = re.compile(r".*error CS[0-9]+.*")
TEST_SUMMARY_RE = re.compile(
    r"Total:\s*(?P<total>\d+)\s+Passed:\s*(?P<passed>\d+)\s+"
    r"Failed:\s*(?P<failed>\d+)\s+Skipped:\s*(?P<skipped>\d+)\s+"
    r"Duration:\s*(?P<duration>[0-9.]+)s"
)

REPO_ROOT = Path(__file__).resolve().parent.parent
CAPABILITIES_PATH = Path(__file__).resolve().with_name("tykit_capabilities.json")


@dataclass
class ProjectContext:
    project_dir: Path
    temp_dir: Path
    qq_scripts_dir: Path


TOOL_DEFINITIONS: dict[str, dict[str, Any]] = {
    "unity_health": {
        "title": "Unity Health",
        "description": "Check Unity project discovery, tykit reachability, and available fast paths.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "project_dir": {
                    "type": "string",
                    "description": "Optional Unity project root. If omitted, the server tries --project, TYKIT_PROJECT_DIR, then the current working directory."
                }
            }
        },
        "outputSchema": {
            "type": "object",
            "properties": {
                "ok": {"type": "boolean"},
                "category": {"type": "string"},
                "message": {"type": "string"},
                "project_dir": {"type": "string"},
                "backend": {"type": "string"},
                "port": {"type": "integer"},
                "pid": {"type": "integer"},
                "server_info_file": {"type": "string"},
                "editor_running": {"type": "boolean"},
                "ping_ok": {"type": "boolean"},
                "post_ok": {"type": "boolean"},
                "qq_scripts_available": {"type": "boolean"},
                "tykit_eval_available": {"type": "boolean"},
                "metadata_available": {"type": "boolean"},
                "command_count": {"type": "integer"},
                "warnings": {"type": "array", "items": {"type": "string"}}
            },
            "required": ["ok", "project_dir", "backend", "warnings"]
        }
    },
    "unity_doctor": {
        "title": "Unity Doctor",
        "description": "Diagnose qq direct-path readiness, built-in MCP configuration, third-party MCP coexistence, and the effective provider chosen for each capability.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "project_dir": {
                    "type": "string",
                    "description": "Optional Unity project root. If omitted, the server tries --project, TYKIT_PROJECT_DIR, then the current working directory."
                }
            }
        },
        "outputSchema": {
            "type": "object",
            "properties": {
                "ok": {"type": "boolean"},
                "category": {"type": "string"},
                "message": {"type": "string"},
                "project_dir": {"type": "string"},
                "claude_plugin_enabled": {"type": "boolean"},
                "claude_settings_files": {"type": "array", "items": {"type": "string"}},
                "mcp_config_file": {"type": "string"},
                "mcp_servers": {"type": "array", "items": {"type": "object"}},
                "effective_routes": {"type": "object"},
                "preferred_providers": {"type": "object"},
                "health": {"type": "object"},
                "warnings": {"type": "array", "items": {"type": "string"}}
            },
            "required": ["ok", "project_dir", "message", "effective_routes", "warnings", "health"]
        }
    },
    "unity_compile": {
        "title": "Unity Compile",
        "description": "Compile C# changes. Prefers the local qq fast path, falls back to tykit when the Editor is already open.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "project_dir": {"type": "string"},
                "timeout_sec": {"type": "integer", "minimum": 1},
                "mode": {
                    "type": "string",
                    "enum": ["auto", "editor", "batch"],
                    "description": "Preferred compile mode for the qq fast path."
                }
            }
        },
        "outputSchema": {
            "type": "object",
            "properties": {
                "ok": {"type": "boolean"},
                "state": {"type": "string"},
                "message": {"type": "string"},
                "backend": {"type": "string"},
                "transport": {"type": "string"},
                "duration_sec": {"type": "number"},
                "errors": {"type": "array", "items": {"type": "string"}},
                "log_path": {"type": "string"}
            },
            "required": ["ok", "state", "message", "backend", "transport", "errors"]
        }
    },
    "unity_run_tests": {
        "title": "Unity Run Tests",
        "description": "Run EditMode or PlayMode tests. Prefers the qq fast path and preserves EditMode-then-PlayMode sequencing when mode is omitted.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "project_dir": {"type": "string"},
                "mode": {
                    "type": "string",
                    "enum": ["editmode", "edit", "playmode", "play", "all"]
                },
                "filter": {"type": "string"},
                "assembly_names": {
                    "type": "array",
                    "items": {"type": "string"}
                },
                "timeout_sec": {"type": "integer", "minimum": 1}
            }
        },
        "outputSchema": {
            "type": "object",
            "properties": {
                "ok": {"type": "boolean"},
                "state": {"type": "string"},
                "mode": {"type": "string"},
                "message": {"type": "string"},
                "backend": {"type": "string"},
                "transport": {"type": "string"},
                "total": {"type": "integer"},
                "passed": {"type": "integer"},
                "failed": {"type": "integer"},
                "skipped": {"type": "integer"},
                "duration_sec": {"type": "number"},
                "failures": {"type": "array", "items": {"type": "string"}},
                "phases": {"type": "array", "items": {"type": "object"}}
            },
            "required": ["ok", "state", "mode", "message", "failures"]
        }
    },
    "unity_console": {
        "title": "Unity Console",
        "description": "Read or clear the Unity console buffer exposed by tykit.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "project_dir": {"type": "string"},
                "action": {
                    "type": "string",
                    "enum": ["get", "clear"]
                },
                "count": {"type": "integer", "minimum": 1},
                "filter": {"type": "string"}
            },
            "required": ["action"]
        },
        "outputSchema": {
            "type": "object",
            "properties": {
                "ok": {"type": "boolean"},
                "action": {"type": "string"},
                "message": {"type": "string"},
                "entries": {"type": "array", "items": {"type": "object"}}
            },
            "required": ["ok", "action", "message"]
        }
    },
    "unity_editor": {
        "title": "Unity Editor",
        "description": "Control editor state and scenes: play, stop, pause, save scenes, open scenes, menu items, undo, redo.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "project_dir": {"type": "string"},
                "action": {
                    "type": "string",
                    "enum": ["play", "stop", "pause", "save_scene", "open_scene", "new_scene", "menu", "undo", "redo"]
                },
                "path": {"type": "string"},
                "mode": {"type": "string", "enum": ["single", "additive"]},
                "item": {"type": "string"}
            },
            "required": ["action"]
        },
        "outputSchema": {
            "type": "object",
            "properties": {
                "ok": {"type": "boolean"},
                "action": {"type": "string"},
                "message": {"type": "string"},
                "response": {"type": "object"}
            },
            "required": ["ok", "action", "message"]
        }
    },
    "unity_query": {
        "title": "Unity Query",
        "description": "Read editor state, hierarchy, GameObjects, properties, scenes, assets, and selection.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "project_dir": {"type": "string"},
                "action": {
                    "type": "string",
                    "enum": [
                        "status",
                        "hierarchy",
                        "find",
                        "inspect",
                        "get_properties",
                        "get_selection",
                        "list_scenes",
                        "list_assets"
                    ]
                },
                "depth": {"type": "integer", "minimum": 1},
                "id": {"type": "integer"},
                "name": {"type": "string"},
                "path": {"type": "string"},
                "tag": {"type": "string"},
                "type": {"type": "string"},
                "component": {"type": "string"},
                "filter": {"type": "string"}
            },
            "required": ["action"]
        },
        "outputSchema": {
            "type": "object",
            "properties": {
                "ok": {"type": "boolean"},
                "action": {"type": "string"},
                "message": {"type": "string"},
                "response": {}
            },
            "required": ["ok", "action", "message"]
        }
    },
    "unity_object": {
        "title": "Unity Objects",
        "description": "Create and mutate GameObjects and components, including transforms, parenting, activation, layers, tags, and serialized properties.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "project_dir": {"type": "string"},
                "action": {
                    "type": "string",
                    "enum": [
                        "create",
                        "instantiate",
                        "destroy",
                        "set_transform",
                        "set_parent",
                        "duplicate",
                        "set_active",
                        "set_layer",
                        "set_tag",
                        "add_force",
                        "add_component",
                        "remove_component",
                        "set_property",
                        "select"
                    ]
                },
                "id": {"type": "integer"},
                "name": {"type": "string"},
                "path": {"type": "string"},
                "parent": {"type": ["string", "null"]},
                "parent_id": {"type": "integer"},
                "world_position_stays": {"type": "boolean"},
                "primitive_type": {"type": "string"},
                "prefab": {"type": "string"},
                "position": {"type": "array", "items": {"type": "number"}},
                "rotation": {"type": "array", "items": {"type": "number"}},
                "scale": {"type": "array", "items": {"type": "number"}},
                "force": {"type": "array", "items": {"type": "number"}},
                "mode": {"type": "string"},
                "active": {"type": "boolean"},
                "layer": {},
                "tag": {"type": "string"},
                "component": {"type": "string"},
                "property": {"type": "string"},
                "value": {}
            },
            "required": ["action"]
        },
        "outputSchema": {
            "type": "object",
            "properties": {
                "ok": {"type": "boolean"},
                "action": {"type": "string"},
                "message": {"type": "string"},
                "response": {}
            },
            "required": ["ok", "action", "message"]
        }
    },
    "unity_assets": {
        "title": "Unity Assets",
        "description": "Refresh the AssetDatabase and create prefabs or materials.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "project_dir": {"type": "string"},
                "action": {
                    "type": "string",
                    "enum": ["refresh", "create_prefab", "create_material", "create_physics_material_2d", "list_assets"]
                },
                "source": {"type": "string"},
                "path": {"type": "string"},
                "shader": {"type": "string"},
                "friction": {"type": "number"},
                "bounciness": {"type": "number"},
                "filter": {"type": "string"}
            },
            "required": ["action"]
        },
        "outputSchema": {
            "type": "object",
            "properties": {
                "ok": {"type": "boolean"},
                "action": {"type": "string"},
                "message": {"type": "string"},
                "response": {}
            },
            "required": ["ok", "action", "message"]
        }
    },
    "unity_input": {
        "title": "Unity Input",
        "description": "Simulate simple keyboard and axis input inside Unity.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "project_dir": {"type": "string"},
                "action": {
                    "type": "string",
                    "enum": ["key_down", "key_up", "axis", "release_all"]
                },
                "key": {"type": "string"},
                "axis": {"type": "string"},
                "value": {"type": "number"}
            },
            "required": ["action"]
        },
        "outputSchema": {
            "type": "object",
            "properties": {
                "ok": {"type": "boolean"},
                "action": {"type": "string"},
                "message": {"type": "string"},
                "response": {}
            },
            "required": ["ok", "action", "message"]
        }
    },
    "unity_visual": {
        "title": "Unity Visuals",
        "description": "Adjust colors and material properties, or create procedural sprites.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "project_dir": {"type": "string"},
                "action": {
                    "type": "string",
                    "enum": ["set_color", "set_material_property", "create_sprite"]
                },
                "id": {"type": "integer"},
                "name": {"type": "string"},
                "path": {"type": "string"},
                "property": {"type": "string"},
                "color": {},
                "float_value": {"type": "number"},
                "int_value": {"type": "integer"},
                "vector": {"type": "array", "items": {"type": "number"}},
                "size": {"type": "array", "items": {"type": "number"}},
                "position": {"type": "array", "items": {"type": "number"}},
                "parent": {"type": "string"},
                "sorting_order": {"type": "integer"}
            },
            "required": ["action"]
        },
        "outputSchema": {
            "type": "object",
            "properties": {
                "ok": {"type": "boolean"},
                "action": {"type": "string"},
                "message": {"type": "string"},
                "response": {}
            },
            "required": ["ok", "action", "message"]
        }
    },
    "unity_ui": {
        "title": "Unity UI",
        "description": "Create canvases and common UI primitives like text, image, button, slider, and panel.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "project_dir": {"type": "string"},
                "action": {"type": "string", "enum": ["create_canvas", "create_ui"]},
                "name": {"type": "string"},
                "render_mode": {"type": "string", "enum": ["overlay", "camera", "world"]},
                "type": {"type": "string"},
                "text": {"type": "string"},
                "parent": {"type": "string"},
                "position": {"type": "array", "items": {"type": "number"}},
                "size": {"type": "array", "items": {"type": "number"}},
                "font_size": {"type": "number"},
                "color": {}
            },
            "required": ["action"]
        },
        "outputSchema": {
            "type": "object",
            "properties": {
                "ok": {"type": "boolean"},
                "action": {"type": "string"},
                "message": {"type": "string"},
                "response": {}
            },
            "required": ["ok", "action", "message"]
        }
    },
    "unity_animation": {
        "title": "Unity Animation",
        "description": "Create simple animation clips or update Animator parameters.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "project_dir": {"type": "string"},
                "action": {"type": "string", "enum": ["create_animation", "set_animator"]},
                "id": {"type": "integer"},
                "name": {"type": "string"},
                "clip": {"type": "string"},
                "path": {"type": "string"},
                "loop": {"type": "boolean"},
                "keyframes": {"type": "array", "items": {"type": "object"}},
                "controller": {"type": "string"},
                "parameter": {"type": "string"},
                "float_value": {"type": "number"},
                "int_value": {"type": "integer"},
                "bool_value": {"type": "boolean"},
                "trigger": {"type": "boolean"}
            },
            "required": ["action"]
        },
        "outputSchema": {
            "type": "object",
            "properties": {
                "ok": {"type": "boolean"},
                "action": {"type": "string"},
                "message": {"type": "string"},
                "response": {}
            },
            "required": ["ok", "action", "message"]
        }
    },
    "unity_screenshot": {
        "title": "Unity Screenshot",
        "description": "Capture the Scene or Game view and return the file path.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "project_dir": {"type": "string"},
                "view": {"type": "string", "enum": ["scene", "game"]},
                "width": {"type": "integer", "minimum": 1},
                "height": {"type": "integer", "minimum": 1}
            }
        },
        "outputSchema": {
            "type": "object",
            "properties": {
                "ok": {"type": "boolean"},
                "message": {"type": "string"},
                "path": {"type": "string"},
                "view": {"type": "string"},
                "size": {"type": "integer"}
            },
            "required": ["ok", "message"]
        }
    },
    "unity_batch": {
        "title": "Unity Batch",
        "description": "Execute multiple bridge tool operations sequentially in one MCP round trip.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "operations": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "properties": {
                            "tool": {"type": "string"},
                            "arguments": {"type": "object"}
                        },
                        "required": ["tool"]
                    }
                }
            },
            "required": ["operations"]
        },
        "outputSchema": {
            "type": "object",
            "properties": {
                "ok": {"type": "boolean"},
                "message": {"type": "string"},
                "results": {"type": "array", "items": {"type": "object"}}
            },
            "required": ["ok", "message", "results"]
        }
    },
    "unity_raw_command": {
        "title": "Unity Raw Command",
        "description": "Send an arbitrary tykit command directly. Use this when a dedicated bridge tool does not exist yet.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "project_dir": {"type": "string"},
                "command": {"type": "string"},
                "args": {"type": "object"}
            },
            "required": ["command"]
        },
        "outputSchema": {
            "type": "object",
            "properties": {
                "ok": {"type": "boolean"},
                "command": {"type": "string"},
                "message": {"type": "string"},
                "response": {}
            },
            "required": ["ok", "command", "message"]
        }
    }
}


QUERY_ACTIONS = {
    "status": ("status", {}),
    "hierarchy": ("hierarchy", {"depth": "depth"}),
    "find": ("find", {"name": "name", "tag": "tag", "type": "type"}),
    "inspect": ("inspect", {"id": "id", "name": "name", "path": "path"}),
    "get_properties": ("get-properties", {"id": "id", "name": "name", "path": "path", "component": "component"}),
    "get_selection": ("get-selection", {}),
    "list_scenes": ("list-scenes", {}),
    "list_assets": ("list-assets", {"filter": "filter", "path": "path"})
}

EDITOR_ACTIONS = {
    "play": ("play", {}),
    "stop": ("stop", {}),
    "pause": ("pause", {}),
    "save_scene": ("save-scene", {}),
    "open_scene": ("open-scene", {"path": "path", "mode": "mode"}),
    "new_scene": ("new-scene", {"path": "path"}),
    "menu": ("menu", {"item": "item"}),
    "undo": ("undo", {}),
    "redo": ("redo", {})
}

OBJECT_ACTIONS = {
    "create": ("create", {"name": "name", "parent": "parent", "primitive_type": "primitiveType", "position": "position"}),
    "instantiate": ("instantiate", {"prefab": "prefab", "name": "name", "parent": "parent", "position": "position"}),
    "destroy": ("destroy", {"id": "id", "name": "name", "path": "path"}),
    "set_transform": ("set-transform", {"id": "id", "name": "name", "path": "path", "position": "position", "rotation": "rotation", "scale": "scale"}),
    "set_parent": ("set-parent", {"id": "id", "name": "name", "path": "path", "parent": "parent", "parent_id": "parentId", "world_position_stays": "worldPositionStays"}),
    "duplicate": ("duplicate", {"id": "id", "name": "name", "path": "path"}),
    "set_active": ("set-active", {"id": "id", "name": "name", "path": "path", "active": "active"}),
    "set_layer": ("set-layer", {"id": "id", "name": "name", "path": "path", "layer": "layer"}),
    "set_tag": ("set-tag", {"id": "id", "name": "name", "path": "path", "tag": "tag"}),
    "add_force": ("add-force", {"id": "id", "name": "name", "path": "path", "force": "force", "mode": "mode"}),
    "add_component": ("add-component", {"id": "id", "name": "name", "path": "path", "component": "component"}),
    "remove_component": ("remove-component", {"id": "id", "name": "name", "path": "path", "component": "component"}),
    "set_property": ("set-property", {"id": "id", "name": "name", "path": "path", "component": "component", "property": "property", "value": "value"}),
    "select": ("select", {"id": "id", "name": "name", "path": "path"})
}

ASSET_ACTIONS = {
    "refresh": ("refresh", {}),
    "create_prefab": ("create-prefab", {"source": "source", "path": "path"}),
    "create_material": ("create-material", {"path": "path", "shader": "shader"}),
    "create_physics_material_2d": ("create-physics-material-2d", {"path": "path", "friction": "friction", "bounciness": "bounciness"}),
    "list_assets": ("list-assets", {"filter": "filter", "path": "path"})
}

INPUT_ACTIONS = {
    "key_down": ("input-key-down", {"key": "key"}),
    "key_up": ("input-key-up", {"key": "key"}),
    "axis": ("input-axis", {"axis": "axis", "value": "value"}),
    "release_all": ("input-release-all", {})
}

VISUAL_ACTIONS = {
    "set_color": ("set-color", {"id": "id", "name": "name", "path": "path", "color": "color"}),
    "set_material_property": ("set-material-property", {"id": "id", "name": "name", "path": "path", "property": "property", "color": "color", "float_value": "float", "int_value": "int", "vector": "vector"}),
    "create_sprite": ("create-sprite", {"name": "name", "color": "color", "size": "size", "position": "position", "parent": "parent", "sorting_order": "sortingOrder"})
}

UI_ACTIONS = {
    "create_canvas": ("create-canvas", {"name": "name", "render_mode": "renderMode"}),
    "create_ui": ("create-ui", {"type": "type", "name": "name", "text": "text", "parent": "parent", "position": "position", "size": "size", "font_size": "fontSize", "color": "color"})
}

ANIMATION_ACTIONS = {
    "create_animation": ("create-animation", {"id": "id", "name": "name", "path": "path", "clip": "clip", "loop": "loop", "keyframes": "keyframes"}),
    "set_animator": ("set-animator", {"id": "id", "name": "name", "path": "path", "controller": "controller", "parameter": "parameter", "float_value": "float", "int_value": "int", "bool_value": "bool", "trigger": "trigger"})
}

SCREENSHOT_ACTIONS = {
    "default": ("screenshot", {"view": "view", "width": "width", "height": "height"})
}

FULL_PROFILE_EXTRAS = {
    "unity_input",
    "unity_visual",
    "unity_ui",
    "unity_animation",
    "unity_screenshot",
}


def load_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def strip_ansi(text: str) -> str:
    return ANSI_RE.sub("", text)


def unique_strings(items: list[str]) -> list[str]:
    seen: set[str] = set()
    ordered: list[str] = []
    for item in items:
        if item not in seen:
            seen.add(item)
            ordered.append(item)
    return ordered


def pretty_json(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True)


class TykitBridge:
    def __init__(self, default_project_dir: str | None = None, profile: str | None = None, capabilities_path: Path | None = None):
        self._config = load_json(capabilities_path or CAPABILITIES_PATH)
        self.supported_protocol_versions = self._config["protocolVersions"]
        self.profile = profile or self._config["defaultProfile"]
        if self.profile not in self._config["profiles"]:
            raise BridgeError(
                "INVALID_PROFILE",
                f"Unknown MCP profile: {self.profile}",
                {"supported": sorted(self._config["profiles"].keys())},
            )
        self.default_project_dir = Path(default_project_dir).resolve() if default_project_dir else None
        self._command_catalog_cache: dict[str, list[dict[str, Any]] | None] = {}

    def list_tools(self) -> list[dict[str, Any]]:
        tool_names = self._config["profiles"][self.profile]
        tools: list[dict[str, Any]] = []
        catalog = self.try_default_command_catalog()
        for tool_name in tool_names:
            base = dict(TOOL_DEFINITIONS[tool_name])
            base["name"] = tool_name
            base["annotations"] = self._config["toolAnnotations"].get(tool_name, {})
            if catalog:
                base["description"] = self.enrich_tool_description(tool_name, base["description"], catalog)
            tools.append(base)
        return tools

    def call_tool(self, tool_name: str, arguments: dict[str, Any] | None = None) -> dict[str, Any]:
        args = arguments or {}
        if tool_name not in {tool["name"] for tool in self.list_tools()}:
            raise BridgeError("UNKNOWN_TOOL", f"Unknown tool: {tool_name}")

        if tool_name == "unity_health":
            return self.health(args.get("project_dir"))
        if tool_name == "unity_doctor":
            return self.doctor(args.get("project_dir"))
        if tool_name == "unity_compile":
            return self.compile(args)
        if tool_name == "unity_run_tests":
            return self.run_tests(args)
        if tool_name == "unity_console":
            return self.console(args)
        if tool_name == "unity_editor":
            return self.action_tool(args, EDITOR_ACTIONS, "action", "unity_editor")
        if tool_name == "unity_query":
            return self.action_tool(args, QUERY_ACTIONS, "action", "unity_query")
        if tool_name == "unity_object":
            return self.object_tool(args)
        if tool_name == "unity_assets":
            return self.action_tool(args, ASSET_ACTIONS, "action", "unity_assets")
        if tool_name == "unity_input":
            return self.action_tool(args, INPUT_ACTIONS, "action", "unity_input")
        if tool_name == "unity_visual":
            return self.action_tool(args, VISUAL_ACTIONS, "action", "unity_visual")
        if tool_name == "unity_ui":
            return self.action_tool(args, UI_ACTIONS, "action", "unity_ui")
        if tool_name == "unity_animation":
            return self.action_tool(args, ANIMATION_ACTIONS, "action", "unity_animation")
        if tool_name == "unity_screenshot":
            return self.action_tool({"action": "default", **args}, SCREENSHOT_ACTIONS, "action", "unity_screenshot")
        if tool_name == "unity_batch":
            return self.batch(args)
        if tool_name == "unity_raw_command":
            return self.raw_command(args)
        raise BridgeError("UNKNOWN_TOOL", f"Unsupported tool handler: {tool_name}")

    def health(self, project_dir: str | None = None) -> dict[str, Any]:
        try:
            ctx = self.resolve_project(project_dir)
        except BridgeError as exc:
            return {
                **exc.to_result(),
                "project_dir": project_dir or "",
                "backend": "unavailable",
                "server_info_file": "",
                "warnings": [],
            }

        warnings: list[str] = []
        qq_scripts_available = self.has_project_fast_path(ctx)
        tykit_eval_available = self.find_tykit_eval(ctx.project_dir) is not None
        metadata_available = False
        command_count = 0
        if not qq_scripts_available:
            warnings.append("qq fast-path scripts are not installed in this project")
        if not tykit_eval_available:
            warnings.append("tykit unity-eval.sh not found; compile fallback will rely on direct HTTP")

        try:
            info = self.read_tykit_info(ctx.project_dir)
        except BridgeError as exc:
            return {
                **exc.to_result(),
                "project_dir": str(ctx.project_dir),
                "backend": "unavailable",
                "server_info_file": "",
                "editor_running": (ctx.project_dir / "Temp" / "UnityLockfile").exists(),
                "ping_ok": False,
                "post_ok": False,
                "qq_scripts_available": qq_scripts_available,
                "tykit_eval_available": tykit_eval_available,
                "metadata_available": metadata_available,
                "command_count": command_count,
                "warnings": warnings,
            }
        if info is None:
            warnings.append("No tykit or eval server metadata file found in Temp/")
            return {
                "ok": False,
                "project_dir": str(ctx.project_dir),
                "backend": "unavailable",
                "server_info_file": "",
                "editor_running": (ctx.project_dir / "Temp" / "UnityLockfile").exists(),
                "ping_ok": False,
                "post_ok": False,
                "qq_scripts_available": qq_scripts_available,
                "tykit_eval_available": tykit_eval_available,
                "metadata_available": metadata_available,
                "command_count": command_count,
                "warnings": warnings,
                "message": "tykit metadata not found",
                "category": "TYKIT_INFO_MISSING",
            }

        ping_ok = False
        post_ok = False
        backend = "tykit"
        try:
            self.http_ping(info["port"])
            ping_ok = True
        except BridgeError as exc:
            warnings.append(exc.message)

        try:
            self.http_post(info["port"], "compile-status")
            post_ok = True
        except BridgeError as exc:
            warnings.append(exc.message)

        if ping_ok and post_ok:
            catalog = self.get_command_catalog(ctx.project_dir)
            metadata_available = bool(catalog)
            command_count = len(catalog or [])
            if not metadata_available:
                warnings.append("describe-commands metadata unavailable; bridge is using local fallback schemas")

        return {
            "ok": ping_ok and post_ok,
            "project_dir": str(ctx.project_dir),
            "backend": backend if ping_ok else "unavailable",
            "port": info.get("port"),
            "pid": info.get("pid"),
            "server_info_file": info.get("_info_file", ""),
            "editor_running": ping_ok or self.is_pid_alive(info.get("pid")) or (ctx.project_dir / "Temp" / "UnityLockfile").exists(),
            "ping_ok": ping_ok,
            "post_ok": post_ok,
            "qq_scripts_available": qq_scripts_available,
            "tykit_eval_available": tykit_eval_available,
            "metadata_available": metadata_available,
            "command_count": command_count,
            "warnings": warnings,
            "message": "tykit reachable" if ping_ok and post_ok else "tykit partially unavailable",
            "category": "OK" if ping_ok and post_ok else "TYKIT_UNHEALTHY",
        }

    def doctor(self, project_dir: str | None = None) -> dict[str, Any]:
        try:
            ctx = self.resolve_project(project_dir)
        except BridgeError as exc:
            return {
                **exc.to_result(),
                "project_dir": project_dir or "",
                "claude_plugin_enabled": False,
                "claude_settings_files": [],
                "mcp_config_file": "",
                "mcp_servers": [],
                "effective_routes": {},
                "preferred_providers": self._config.get("preferredProviders", {}),
                "health": {},
                "warnings": [],
            }

        health = self.health(str(ctx.project_dir))
        settings_files, claude_plugin_enabled = self.inspect_claude_plugin_state(ctx.project_dir)
        mcp_path = ctx.project_dir / ".mcp.json"
        mcp_servers, mcp_warnings = self.inspect_mcp_servers(ctx.project_dir, mcp_path)
        effective_routes = self.compute_effective_routes(health, mcp_servers)

        warnings = list(mcp_warnings)
        warnings.extend(health.get("warnings") or [])
        if not claude_plugin_enabled:
            warnings.append("qq plugin is not enabled in .claude/settings.json or .claude/settings.local.json")
        built_in_servers = [item for item in mcp_servers if item.get("provider") == "tykit_mcp"]
        if not built_in_servers:
            warnings.append("Built-in qq Unity MCP bridge is not configured in .mcp.json")
        elif any(item.get("location") != "project-local" for item in built_in_servers):
            warnings.append("Built-in qq Unity MCP bridge is configured, but it does not point at the project-local scripts/qq_mcp.py")
        if any(item.get("provider") in {"mcp_unity", "unity_mcp"} for item in mcp_servers):
            warnings.append("Third-party Unity MCP servers are configured; qq should still prefer the built-in qq Unity bridge")

        ok = bool(health.get("ok")) and bool(built_in_servers)
        category = "OK" if ok and claude_plugin_enabled else "WARN"
        message = "qq direct path and built-in Unity bridge are ready"
        if not ok:
            message = "qq routing needs attention"
        elif not claude_plugin_enabled:
            message = "Built-in qq Unity bridge is ready, but the qq plugin is not enabled"

        return {
            "ok": ok and claude_plugin_enabled,
            "category": category,
            "message": message,
            "project_dir": str(ctx.project_dir),
            "claude_plugin_enabled": claude_plugin_enabled,
            "claude_settings_files": [str(path) for path in settings_files],
            "mcp_config_file": str(mcp_path),
            "mcp_servers": mcp_servers,
            "effective_routes": effective_routes,
            "preferred_providers": self._config.get("preferredProviders", {}),
            "health": health,
            "warnings": unique_strings(warnings),
        }

    def compile(self, args: dict[str, Any]) -> dict[str, Any]:
        ctx = self.resolve_project(args.get("project_dir"))
        timeout_sec = int(args.get("timeout_sec") or 15)
        mode = str(args.get("mode") or "auto")
        started_at = datetime.now(timezone.utc)

        if self.has_project_fast_path(ctx):
            result = self.compile_via_project_script(ctx, timeout_sec, mode)
            if result.get("ok") or not self.should_fallback_compile(result):
                return result

        eval_script = self.find_tykit_eval(ctx.project_dir)
        if eval_script is not None:
            try:
                result = self.compile_via_eval(ctx, timeout_sec, eval_script)
                self.persist_result_record(ctx, "compile", "unity_compile", started_at, result, args)
                return result
            except BridgeError:
                pass

        try:
            result = self.compile_via_http(ctx, timeout_sec)
        except BridgeError as exc:
            self.persist_error_record(ctx, "compile", "unity_compile", started_at, exc, "tykit", "tykit-http", args)
            raise
        self.persist_result_record(ctx, "compile", "unity_compile", started_at, result, args)
        return result

    def run_tests(self, args: dict[str, Any]) -> dict[str, Any]:
        ctx = self.resolve_project(args.get("project_dir"))
        timeout_sec = int(args.get("timeout_sec") or 180)
        requested_mode = self.normalize_test_mode(args.get("mode"))
        filter_value = args.get("filter")
        assemblies = args.get("assembly_names") or []
        assembly_arg = ";".join(str(item) for item in assemblies if str(item).strip())
        started_at = datetime.now(timezone.utc)

        with self.exclusive_project_test_run(ctx):
            self.ensure_editor_edit_mode(ctx)
            if self.has_project_fast_path(ctx):
                result = self.run_tests_via_project_script(ctx, requested_mode, filter_value, assembly_arg, timeout_sec)
                if result.get("ok") or not self.should_fallback_tests(result):
                    self.persist_result_record(ctx, "test", "unity_run_tests", started_at, result, args)
                    return result

            try:
                result = self.run_tests_via_http(ctx, requested_mode, filter_value, assembly_arg, timeout_sec)
            except BridgeError as exc:
                self.persist_error_record(ctx, "test", "unity_run_tests", started_at, exc, "tykit", "tykit-http", args)
                raise
            self.persist_result_record(ctx, "test", "unity_run_tests", started_at, result, args)
            return result

    def console(self, args: dict[str, Any]) -> dict[str, Any]:
        ctx = self.resolve_project(args.get("project_dir"))
        action = str(args.get("action") or "").strip()
        if action not in {"get", "clear"}:
            raise BridgeError("INVALID_ARGUMENT", "unity_console.action must be 'get' or 'clear'")

        info = self.require_tykit(ctx.project_dir)
        if action == "get":
            response = self.http_post(
                info["port"],
                "console",
                {
                    "count": int(args.get("count") or 50),
                    **({"filter": args["filter"]} if args.get("filter") else {}),
                },
            )
            entries = response.get("data") or []
            return {
                "ok": True,
                "action": action,
                "message": f"Retrieved {len(entries)} console entries",
                "entries": entries,
            }

        response = self.http_post(info["port"], "clear-console")
        return {
            "ok": True,
            "action": action,
            "message": self.response_message(response, "Console cleared"),
            "entries": [],
        }

    def action_tool(self, args: dict[str, Any], mapping: dict[str, tuple[str, dict[str, str]]], action_key: str, tool_name: str) -> dict[str, Any]:
        ctx = self.resolve_project(args.get("project_dir"))
        action = str(args.get(action_key) or "").strip()
        if action not in mapping:
            raise BridgeError("INVALID_ARGUMENT", f"{tool_name}.{action_key} is invalid", {"supported": sorted(mapping)})

        command_name, arg_map = mapping[action]
        info = self.require_tykit(ctx.project_dir)
        command_args = self.project_command_args(args, arg_map)
        response = self.http_post(info["port"], command_name, command_args)
        return {
            "ok": True,
            "action": action,
            "message": self.response_message(response, f"{tool_name} action completed"),
            "response": response.get("data"),
        }

    def object_tool(self, args: dict[str, Any]) -> dict[str, Any]:
        if "value" in args and not isinstance(args.get("value"), str):
            coerced = args["value"]
            args = dict(args)
            if isinstance(coerced, (dict, list)):
                args["value"] = json.dumps(coerced, ensure_ascii=False)
            else:
                args["value"] = str(coerced)
        return self.action_tool(args, OBJECT_ACTIONS, "action", "unity_object")

    def batch(self, args: dict[str, Any]) -> dict[str, Any]:
        operations = args.get("operations")
        if not isinstance(operations, list) or not operations:
            raise BridgeError("INVALID_ARGUMENT", "unity_batch.operations must be a non-empty array")

        results: list[dict[str, Any]] = []
        any_errors = False
        available_tools = {tool["name"] for tool in self.list_tools()}
        for index, operation in enumerate(operations):
            if not isinstance(operation, dict):
                results.append({"ok": False, "index": index, "message": "Operation must be an object"})
                any_errors = True
                continue

            tool_name = operation.get("tool")
            if tool_name == "unity_batch":
                results.append({"ok": False, "index": index, "message": "unity_batch cannot recursively call itself"})
                any_errors = True
                continue
            if tool_name not in available_tools:
                results.append({"ok": False, "index": index, "message": f"Tool not exposed in current profile: {tool_name}"})
                any_errors = True
                continue

            try:
                result = self.call_tool(tool_name, operation.get("arguments") or {})
                results.append({"index": index, "tool": tool_name, "result": result})
                any_errors = any_errors or not bool(result.get("ok", False))
            except BridgeError as exc:
                any_errors = True
                results.append({"index": index, "tool": tool_name, "result": exc.to_result()})

        return {
            "ok": not any_errors,
            "message": f"Executed {len(results)} batch operation(s)",
            "results": results,
        }

    def raw_command(self, args: dict[str, Any]) -> dict[str, Any]:
        ctx = self.resolve_project(args.get("project_dir"))
        command = str(args.get("command") or "").strip()
        if not command:
            raise BridgeError("INVALID_ARGUMENT", "unity_raw_command.command is required")
        if command == "batch":
            raise BridgeError("INVALID_ARGUMENT", "Use unity_batch instead of raw batch commands")

        info = self.require_tykit(ctx.project_dir)
        catalog = self.get_command_catalog(ctx.project_dir)
        if catalog:
            known = {item.get("name") for item in catalog}
            if command not in known:
                raise BridgeError(
                    "INVALID_ARGUMENT",
                    f"Unknown tykit command: {command}",
                    {"knownCommands": sorted(name for name in known if isinstance(name, str))},
                )
        response = self.http_post(info["port"], command, args.get("args") or {})
        return {
            "ok": True,
            "command": command,
            "message": self.response_message(response, f"Executed raw command: {command}"),
            "response": response.get("data"),
        }

    def resolve_project(self, project_dir: str | None = None) -> ProjectContext:
        candidate = None
        if project_dir:
            candidate = Path(project_dir).expanduser()
        elif self.default_project_dir:
            candidate = self.default_project_dir
        elif os.environ.get("TYKIT_PROJECT_DIR"):
            candidate = Path(os.environ["TYKIT_PROJECT_DIR"]).expanduser()
        else:
            candidate = self.find_project_from_cwd()

        if candidate is None:
            raise BridgeError("PROJECT_NOT_FOUND", "No Unity project detected. Pass --project or project_dir.")

        resolved = candidate.resolve()
        if not self.is_unity_project(resolved):
            raise BridgeError(
                "PROJECT_NOT_FOUND",
                f"Not a Unity project: {resolved}",
                {"required": "ProjectSettings/ProjectVersion.txt"},
            )

        return ProjectContext(
            project_dir=resolved,
            temp_dir=resolved / "Temp",
            qq_scripts_dir=resolved / "scripts",
        )

    def find_project_from_cwd(self) -> Path | None:
        current = Path.cwd().resolve()
        for path in [current, *current.parents]:
            if self.is_unity_project(path):
                return path
        return None

    def try_default_command_catalog(self) -> list[dict[str, Any]] | None:
        try:
            ctx = self.resolve_project(None)
        except BridgeError:
            return None
        return self.get_command_catalog(ctx.project_dir)

    def inspect_claude_plugin_state(self, project_dir: Path) -> tuple[list[Path], bool]:
        settings_files = [
            project_dir / ".claude" / "settings.json",
            project_dir / ".claude" / "settings.local.json",
        ]
        existing = [path for path in settings_files if path.is_file()]
        enabled = False
        for path in existing:
            data = self.load_optional_json(path)
            enabled_plugins = data.get("enabledPlugins") if isinstance(data, dict) else None
            if isinstance(enabled_plugins, dict) and enabled_plugins.get("qq@quick-question-marketplace") is True:
                enabled = True
        return existing, enabled

    def inspect_mcp_servers(self, project_dir: Path, mcp_path: Path) -> tuple[list[dict[str, Any]], list[str]]:
        if not mcp_path.is_file():
            return [], ["No .mcp.json found in the project root"]

        data = self.load_optional_json(mcp_path)
        warnings: list[str] = []
        if not isinstance(data, dict):
            return [], [f"Failed to parse {mcp_path.name} as JSON"]

        raw_servers = data.get("mcpServers")
        if not isinstance(raw_servers, dict):
            return [], [f"{mcp_path.name} does not contain an mcpServers object"]

        servers: list[dict[str, Any]] = []
        for name, raw in raw_servers.items():
            if not isinstance(raw, dict):
                continue
            command = str(raw.get("command") or "")
            raw_args = raw.get("args") or []
            args = [str(item) for item in raw_args] if isinstance(raw_args, list) else []
            provider, location = self.classify_mcp_server(project_dir, name, command, args)
            servers.append(
                {
                    "name": str(name),
                    "provider": provider,
                    "location": location,
                    "command": command,
                    "args": args,
                }
            )
        return servers, warnings

    def classify_mcp_server(self, project_dir: Path, name: str, command: str, args: list[str]) -> tuple[str, str]:
        lowered = " ".join([name, command, *args]).lower()
        if any(self.is_project_local_bridge_arg(project_dir, arg) for arg in args):
            return "tykit_mcp", "project-local"
        if "scripts/qq_mcp.py" in lowered or "quick-question/scripts/qq_mcp.py" in lowered:
            return "tykit_mcp", "repo-local"
        if "scripts/tykit_mcp.py" in lowered or "quick-question/scripts/tykit_mcp.py" in lowered:
            return "tykit_mcp", "repo-local"
        if "qq_mcp.py" in lowered or "tykit_mcp.py" in lowered:
            return "tykit_mcp", "external"
        if "mcp-unity" in lowered or "mcp_unity" in lowered:
            return "mcp_unity", "third-party"
        if "unity-mcp" in lowered or "unity_mcp" in lowered:
            return "unity_mcp", "third-party"
        return "unknown", "unknown"

    @staticmethod
    def is_project_local_bridge_arg(project_dir: Path, value: str) -> bool:
        normalized = value.replace("\\", "/")
        if normalized in {"scripts/qq_mcp.py", "./scripts/qq_mcp.py"}:
            return True
        if normalized in {"scripts/tykit_mcp.py", "./scripts/tykit_mcp.py"}:
            return True
        try:
            path = Path(value).expanduser().resolve()
        except OSError:
            return False
        return path in {
            (project_dir / "scripts" / "qq_mcp.py").resolve(),
            (project_dir / "scripts" / "tykit_mcp.py").resolve(),
        }

    def compute_effective_routes(self, health: dict[str, Any], mcp_servers: list[dict[str, Any]]) -> dict[str, Any]:
        preferred = self._config.get("preferredProviders", {})
        routes: dict[str, Any] = {}
        for capability, order in preferred.items():
            selected = None
            for provider in order:
                if self.provider_available(capability, provider, health, mcp_servers):
                    selected = provider
                    break
            routes[capability] = {
                "selected": selected or "unavailable",
                "preferred": order,
                "reason": self.provider_reason(capability, selected, health, mcp_servers),
            }
        return routes

    def provider_available(self, capability: str, provider: str, health: dict[str, Any], mcp_servers: list[dict[str, Any]]) -> bool:
        health_ok = bool(health.get("ok"))
        qq_scripts_available = bool(health.get("qq_scripts_available"))
        providers = {str(item.get("provider")) for item in mcp_servers}
        if provider == "tykit_direct":
            if capability in {"compile", "tests.run"}:
                return qq_scripts_available
            if capability == "diagnostics":
                return qq_scripts_available or health_ok
            if capability in {"console.read", "console.clear", "scene.query"}:
                return health_ok
            return False
        if provider == "tykit_mcp":
            return health_ok and "tykit_mcp" in providers
        if provider in {"mcp_unity", "unity_mcp"}:
            return provider in providers
        if provider == "raw_tykit":
            return health_ok
        return False

    def provider_reason(self, capability: str, provider: str | None, health: dict[str, Any], mcp_servers: list[dict[str, Any]]) -> str:
        if provider is None:
            return "No configured backend satisfies this capability"
        if provider == "tykit_direct":
            if capability == "diagnostics":
                return "Project-local qq scripts and/or direct tykit health checks are available"
            if capability in {"compile", "tests.run"}:
                return "Project-local qq scripts are installed, so direct fast-path scripts win"
            return "tykit is healthy, so direct HTTP is available"
        if provider == "tykit_mcp":
            built_in = next((item for item in mcp_servers if item.get("provider") == "tykit_mcp"), None)
            location = built_in.get("location") if built_in else "configured"
            return f"Built-in tykit MCP is configured ({location}) and tykit is healthy"
        if provider == "mcp_unity":
            return "mcp-unity is configured as a compatible fallback"
        if provider == "unity_mcp":
            return "Unity-MCP is configured as a compatible fallback"
        if provider == "raw_tykit":
            return "tykit is healthy, so raw HTTP fallback remains available"
        return f"Selected provider: {provider}"

    @staticmethod
    def load_optional_json(path: Path) -> dict[str, Any] | None:
        try:
            with path.open("r", encoding="utf-8") as handle:
                data = json.load(handle)
        except (OSError, json.JSONDecodeError):
            return None
        return data if isinstance(data, dict) else None

    @staticmethod
    def is_unity_project(path: Path) -> bool:
        return (path / "ProjectSettings" / "ProjectVersion.txt").is_file()

    @staticmethod
    def is_pid_alive(pid: Any) -> bool:
        if not isinstance(pid, int):
            return False
        try:
            os.kill(pid, 0)
            return True
        except OSError:
            return False

    @staticmethod
    def response_message(response: dict[str, Any], fallback: str) -> str:
        data = response.get("data")
        if isinstance(data, str) and data:
            return data
        return fallback

    def has_project_fast_path(self, ctx: ProjectContext) -> bool:
        compile_script = ctx.qq_scripts_dir / "unity-compile-smart.sh"
        test_script = ctx.qq_scripts_dir / "unity-test.sh"
        return compile_script.is_file() and test_script.is_file()

    @staticmethod
    def test_lock_path(ctx: ProjectContext) -> Path:
        return ctx.temp_dir / "tykit-bridge.test.lock"

    def ensure_editor_edit_mode(self, ctx: ProjectContext, timeout_sec: int = 30) -> None:
        info = self.read_tykit_info(ctx.project_dir)
        if info is None:
            return

        port = info.get("port")
        if not isinstance(port, int):
            return

        try:
            status = self.http_post(port, "status").get("data") or {}
        except BridgeError:
            return

        if not bool(status.get("isPlaying")) and not bool(status.get("isPaused")):
            return

        self.http_post(port, "stop")
        start = time.time()
        while time.time() - start < timeout_sec:
            current = self.http_post(port, "status").get("data") or {}
            if not bool(current.get("isPlaying")) and not bool(current.get("isPaused")):
                return
            time.sleep(0.5)

        raise BridgeError(
            "EDITOR_BUSY",
            "Unity Editor did not return to Edit Mode before running tests",
            {"timeout_sec": timeout_sec, "projectDir": str(ctx.project_dir)},
        )

    @staticmethod
    def read_lock_payload(path: Path) -> dict[str, Any] | None:
        try:
            with path.open("r", encoding="utf-8") as handle:
                data = json.load(handle)
        except (OSError, json.JSONDecodeError):
            return None
        return data if isinstance(data, dict) else None

    @contextmanager
    def exclusive_project_test_run(self, ctx: ProjectContext):
        lock_path = self.test_lock_path(ctx)
        lock_path.parent.mkdir(parents=True, exist_ok=True)
        payload = {
            "pid": os.getpid(),
            "startedAt": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
            "projectDir": str(ctx.project_dir),
        }

        while True:
            try:
                fd = os.open(str(lock_path), os.O_CREAT | os.O_EXCL | os.O_WRONLY)
            except FileExistsError:
                existing = self.read_lock_payload(lock_path)
                existing_pid = existing.get("pid") if isinstance(existing, dict) else None
                if self.is_pid_alive(existing_pid):
                    raise BridgeError(
                        "TEST_BUSY",
                        "Another unity_run_tests call is already active for this project",
                        {
                            "lockFile": str(lock_path),
                            "ownerPid": existing_pid,
                            "ownerStartedAt": existing.get("startedAt"),
                            "projectDir": existing.get("projectDir") or str(ctx.project_dir),
                        },
                    )
                try:
                    lock_path.unlink()
                except FileNotFoundError:
                    continue
                except OSError as exc:
                    raise BridgeError(
                        "TEST_BUSY",
                        "A stale unity_run_tests lock exists and could not be cleared",
                        {"lockFile": str(lock_path), "error": str(exc)},
                    )
                continue
            except OSError as exc:
                raise BridgeError(
                    "TEST_BUSY",
                    "Failed to acquire the unity_run_tests lock for this project",
                    {"lockFile": str(lock_path), "error": str(exc)},
                )

            try:
                with os.fdopen(fd, "w", encoding="utf-8") as handle:
                    json.dump(payload, handle, ensure_ascii=False)
                break
            except OSError:
                try:
                    os.close(fd)
                except OSError:
                    pass
                try:
                    lock_path.unlink()
                except OSError:
                    pass
                raise

        try:
            yield
        finally:
            existing = self.read_lock_payload(lock_path)
            if not existing or existing.get("pid") == os.getpid():
                try:
                    lock_path.unlink()
                except FileNotFoundError:
                    pass
                except OSError:
                    pass

    def find_tykit_eval(self, project_dir: Path) -> Path | None:
        embedded = project_dir / "Packages" / "com.tyk.tykit" / "Scripts~" / "unity-eval.sh"
        if embedded.is_file():
            return embedded
        package_cache = project_dir / "Library" / "PackageCache"
        if package_cache.is_dir():
            for candidate in sorted(package_cache.glob("**/unity-eval.sh")):
                if "com.tyk.tykit" in candidate.as_posix():
                    return candidate
        return None

    def read_tykit_info(self, project_dir: Path) -> dict[str, Any] | None:
        candidates = [
            project_dir / "Temp" / "tykit.json",
            project_dir / "Temp" / "eval_server.json",
        ]
        for info_path in candidates:
            if not info_path.is_file():
                continue
            try:
                with info_path.open("r", encoding="utf-8") as handle:
                    data = json.load(handle)
                if isinstance(data, dict):
                    data["_info_file"] = str(info_path)
                return data
            except (OSError, json.JSONDecodeError) as exc:
                raise BridgeError("TYKIT_INFO_INVALID", f"Failed to read {info_path}", {"error": str(exc)})
        return None

    def require_tykit(self, project_dir: Path) -> dict[str, Any]:
        info = self.read_tykit_info(project_dir)
        if info is None:
            raise BridgeError(
                "TYKIT_INFO_MISSING",
                "No tykit or eval server metadata file found. Open the Unity project so tykit can start.",
            )
        port = info.get("port")
        if not isinstance(port, int):
            raise BridgeError("TYKIT_INFO_INVALID", "Server metadata file is missing a valid port")
        self.http_ping(port)
        return info

    def get_command_catalog(self, project_dir: Path) -> list[dict[str, Any]] | None:
        cache_key = str(project_dir)
        if cache_key in self._command_catalog_cache:
            return self._command_catalog_cache[cache_key]

        try:
            info = self.require_tykit(project_dir)
            response = self.http_post(info["port"], "describe-commands")
            data = response.get("data")
            if isinstance(data, list):
                self._command_catalog_cache[cache_key] = data
                return data
        except BridgeError:
            pass

        self._command_catalog_cache[cache_key] = None
        return None

    def http_ping(self, port: int) -> dict[str, Any]:
        try:
            req = urllib_request.Request(f"http://localhost:{port}/ping", method="GET")
            with urllib_request.urlopen(req, timeout=5) as resp:
                return json.loads(resp.read().decode("utf-8"))
        except (OSError, urllib_error.URLError, urllib_error.HTTPError, json.JSONDecodeError) as exc:
            raise BridgeError("TYKIT_PING_FAILED", f"tykit /ping failed on port {port}", {"error": str(exc)})

    def http_post(self, port: int, command: str, args: dict[str, Any] | None = None, timeout: int = 15) -> dict[str, Any]:
        payload = json.dumps({"command": command, "args": args or {}}, ensure_ascii=False).encode("utf-8")
        req = urllib_request.Request(
            f"http://localhost:{port}/",
            data=payload,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        try:
            with urllib_request.urlopen(req, timeout=timeout) as resp:
                raw = json.loads(resp.read().decode("utf-8"))
        except urllib_error.HTTPError as exc:
            body = exc.read().decode("utf-8", errors="replace")
            try:
                parsed = json.loads(body)
                message = parsed.get("error") or body
            except json.JSONDecodeError:
                message = body
            raise BridgeError("COMMAND_FAILED", f"tykit command failed: {command}", {"status": exc.code, "error": message})
        except (OSError, urllib_error.URLError, json.JSONDecodeError) as exc:
            raise BridgeError("TYKIT_POST_FAILED", f"tykit POST failed for command: {command}", {"error": str(exc)})

        if not raw.get("success", False):
            raise BridgeError("COMMAND_FAILED", f"tykit command failed: {command}", {"error": raw.get("error")})
        return raw

    def enrich_tool_description(self, tool_name: str, description: str, catalog: list[dict[str, Any]]) -> str:
        command_names: list[str] = []
        if tool_name == "unity_query":
            command_names = [item[0] for item in QUERY_ACTIONS.values()]
        elif tool_name == "unity_editor":
            command_names = [item[0] for item in EDITOR_ACTIONS.values()]
        elif tool_name == "unity_object":
            command_names = [item[0] for item in OBJECT_ACTIONS.values()]
        elif tool_name == "unity_assets":
            command_names = [item[0] for item in ASSET_ACTIONS.values()]
        elif tool_name == "unity_input":
            command_names = [item[0] for item in INPUT_ACTIONS.values()]
        elif tool_name == "unity_visual":
            command_names = [item[0] for item in VISUAL_ACTIONS.values()]
        elif tool_name == "unity_ui":
            command_names = [item[0] for item in UI_ACTIONS.values()]
        elif tool_name == "unity_animation":
            command_names = [item[0] for item in ANIMATION_ACTIONS.values()]
        elif tool_name == "unity_screenshot":
            command_names = [item[0] for item in SCREENSHOT_ACTIONS.values()]
        elif tool_name == "unity_raw_command":
            return f"{description} Unity metadata reports {len(catalog)} registered command(s)."

        if not command_names:
            return description

        available = []
        catalog_map = {item.get("name"): item for item in catalog if isinstance(item, dict)}
        for name in command_names:
            descriptor = catalog_map.get(name)
            if descriptor:
                summary = descriptor.get("summary")
                available.append(f"{name}" if not summary else f"{name}: {summary}")
            else:
                available.append(name)
        return f"{description} Underlying tykit commands: {'; '.join(available)}."

    def run_shell(self, command: list[str], cwd: Path, env: dict[str, str] | None = None, timeout_sec: int | None = None) -> subprocess.CompletedProcess[str]:
        merged_env = os.environ.copy()
        if env:
            merged_env.update(env)
        try:
            return subprocess.run(
                command,
                cwd=str(cwd),
                env=merged_env,
                text=True,
                capture_output=True,
                timeout=timeout_sec,
                check=False,
            )
        except FileNotFoundError as exc:
            raise BridgeError("COMMAND_FAILED", f"Command not found: {command[0]}", {"error": str(exc)})
        except subprocess.TimeoutExpired as exc:
            raise BridgeError("COMMAND_TIMEOUT", f"Command timed out: {' '.join(command)}", {"timeout_sec": timeout_sec, "output": strip_ansi((exc.stdout or "") + (exc.stderr or ""))})

    @staticmethod
    def iso_timestamp(value: datetime | None = None) -> str:
        return (value or datetime.now(timezone.utc)).isoformat(timespec="microseconds").replace("+00:00", "Z")

    @staticmethod
    def save_json(path: Path, value: dict[str, Any]) -> None:
        with path.open("w", encoding="utf-8") as handle:
            json.dump(value, handle, ensure_ascii=False, indent=2, sort_keys=True)
            handle.write("\n")

    @staticmethod
    def append_jsonl(path: Path, value: dict[str, Any]) -> None:
        with path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(value, ensure_ascii=False, sort_keys=True))
            handle.write("\n")

    def runtime_dirs(self, project_dir: Path) -> dict[str, Path]:
        root = project_dir / ".qq"
        runs = root / "runs"
        state = root / "state"
        telemetry = root / "telemetry"
        for path in (runs, state, telemetry):
            path.mkdir(parents=True, exist_ok=True)
        return {"root": root, "runs": runs, "state": state, "telemetry": telemetry}

    @staticmethod
    def result_status(result: dict[str, Any]) -> str:
        state = str(result.get("state") or "").strip().lower()
        if state in {"passed", "failed", "blocked", "warning", "skipped", "running", "pending"}:
            return state
        return "passed" if result.get("ok") else "failed"

    @staticmethod
    def bridge_error_status(exc: BridgeError) -> str:
        category = exc.category.upper()
        if "TIMEOUT" in category or "BLOCK" in category:
            return "blocked"
        return "failed"

    def persist_runtime_record(
        self,
        ctx: ProjectContext,
        stage: str,
        command: str,
        started_at: datetime,
        status: str,
        backend: str,
        transport: str,
        summary: str,
        failure_category: str = "",
        extra: dict[str, Any] | None = None,
    ) -> None:
        finished = datetime.now(timezone.utc)
        duration_ms = max(0, int((finished - started_at).total_seconds() * 1000))
        run_id = uuid.uuid4().hex[:12]
        dirs = self.runtime_dirs(ctx.project_dir)
        timestamp = started_at.strftime("%Y%m%dT%H%M%SZ")
        path = dirs["runs"] / f"{timestamp}-{stage}-{run_id}.json"

        record: dict[str, Any] = {
            "run_id": run_id,
            "command": command,
            "stage": stage,
            "status": status,
            "backend": backend,
            "transport": transport,
            "started_at": self.iso_timestamp(started_at),
            "finished_at": self.iso_timestamp(finished),
            "duration_ms": duration_ms,
            "failure_category": failure_category,
            "summary": summary,
            "artifacts": {},
            "details": {},
            "record_path": str(path.relative_to(ctx.project_dir)),
        }
        if extra:
            record.update(extra)

        self.save_json(path, record)
        self.save_json(dirs["state"] / "latest.json", record)
        self.save_json(dirs["state"] / f"{stage}.json", record)
        self.append_jsonl(
            dirs["telemetry"] / "events.jsonl",
            {
                "event_type": "finish",
                "timestamp": self.iso_timestamp(finished),
                "run_id": run_id,
                "stage": stage,
                "command": command,
                "status": status,
                "backend": backend,
                "transport": transport,
                "failure_category": failure_category,
                "duration_ms": duration_ms,
                "summary": summary,
                "record_path": record["record_path"],
            },
        )

    def persist_result_record(
        self,
        ctx: ProjectContext,
        stage: str,
        command: str,
        started_at: datetime,
        result: dict[str, Any],
        args: dict[str, Any] | None = None,
    ) -> None:
        details = {"args": args or {}}
        for key in ("errors", "failures", "phases"):
            value = result.get(key)
            if value:
                details[key] = value

        artifacts: dict[str, Any] = {}
        if result.get("log_path"):
            artifacts["log_path"] = result["log_path"]

        extra: dict[str, Any] = {
            "details": details,
            "artifacts": artifacts,
        }
        for key in ("state", "mode", "total", "passed", "failed", "skipped", "duration_sec", "errors", "failures"):
            if key in result:
                extra[key] = result[key]

        self.persist_runtime_record(
            ctx=ctx,
            stage=stage,
            command=command,
            started_at=started_at,
            status=self.result_status(result),
            backend=str(result.get("backend") or ""),
            transport=str(result.get("transport") or ""),
            summary=str(result.get("message") or f"{stage} completed"),
            failure_category=str(result.get("category") or ""),
            extra=extra,
        )

    def persist_error_record(
        self,
        ctx: ProjectContext,
        stage: str,
        command: str,
        started_at: datetime,
        exc: BridgeError,
        backend: str,
        transport: str,
        args: dict[str, Any] | None = None,
    ) -> None:
        self.persist_runtime_record(
            ctx=ctx,
            stage=stage,
            command=command,
            started_at=started_at,
            status=self.bridge_error_status(exc),
            backend=backend,
            transport=transport,
            summary=exc.message,
            failure_category=exc.category,
            extra={"details": {"args": args or {}, **exc.details}},
        )

    def compile_via_project_script(self, ctx: ProjectContext, timeout_sec: int, mode: str) -> dict[str, Any]:
        script = ctx.qq_scripts_dir / "unity-compile-smart.sh"
        command = ["bash", str(script), "--timeout", str(timeout_sec)]
        if mode == "editor":
            command.append("--editor")
        elif mode == "batch":
            command.append("--batch")

        result = self.run_shell(command, ctx.project_dir, timeout_sec=timeout_sec + 90)
        output = strip_ansi(result.stdout + result.stderr)
        errors = unique_strings(COMPILE_ERROR_RE.findall(output))
        duration = self.extract_duration(output)
        log_path = self.extract_log_path(output)

        if result.returncode == 0:
            return {
                "ok": True,
                "state": "passed",
                "message": "Compilation successful via qq fast path",
                "backend": "tykit",
                "transport": "qq-script",
                "duration_sec": duration,
                "errors": [],
                **({"log_path": log_path} if log_path else {}),
            }

        category = "COMPILE_FAILED" if errors else "COMPILE_TIMEOUT"
        return {
            "ok": False,
            "state": "failed" if errors else "error",
            "category": category,
            "message": output.strip().splitlines()[-1] if output.strip() else "Compilation failed",
            "backend": "tykit",
            "transport": "qq-script",
            "duration_sec": duration,
            "errors": errors,
            **({"log_path": log_path} if log_path else {}),
        }

    def compile_via_eval(self, ctx: ProjectContext, timeout_sec: int, eval_script: Path) -> dict[str, Any]:
        self.require_tykit(ctx.project_dir)
        env = {"UNITY_PROJECT_DIR": str(ctx.project_dir)}
        result = self.run_shell(["bash", str(eval_script), "--compile", str(timeout_sec)], ctx.project_dir, env=env, timeout_sec=timeout_sec + 60)
        output = strip_ansi(result.stdout + result.stderr)
        errors = unique_strings(COMPILE_ERROR_RE.findall(output))

        if result.returncode == 0:
            return {
                "ok": True,
                "state": "passed",
                "message": "Compilation successful via tykit unity-eval.sh",
                "backend": "tykit",
                "transport": "tykit-eval",
                "duration_sec": self.extract_duration(output),
                "errors": [],
            }

        if result.returncode in {1, 2}:
            return {
                "ok": False,
                "state": "failed" if errors else "error",
                "category": "COMPILE_FAILED" if errors else "COMPILE_TIMEOUT",
                "message": output.strip().splitlines()[-1] if output.strip() else "Compilation failed",
                "backend": "tykit",
                "transport": "tykit-eval",
                "duration_sec": self.extract_duration(output),
                "errors": errors,
            }

        raise BridgeError("COMMAND_FAILED", "unity-eval compile failed unexpectedly", {"returncode": result.returncode, "output": output})

    def compile_via_http(self, ctx: ProjectContext, timeout_sec: int) -> dict[str, Any]:
        info = self.require_tykit(ctx.project_dir)
        port = info["port"]
        before = self.http_post(port, "get-compile-result").get("data") or {}
        before_timestamp = before.get("timestamp")

        self.http_post(port, "trigger-refresh")
        start = time.time()
        saw_compiling = False

        while time.time() - start < timeout_sec:
            status = self.http_post(port, "compile-status").get("data") or {}
            if status.get("isCompiling"):
                saw_compiling = True

            args = {"afterTimestamp": before_timestamp} if before_timestamp else {}
            current = self.http_post(port, "get-compile-result", args).get("data") or {}
            state = current.get("state")
            if state in {"success", "failed"}:
                errors = list(current.get("errors") or [])
                return {
                    "ok": state == "success",
                    "state": "passed" if state == "success" else "failed",
                    "message": "Compilation successful via tykit HTTP" if state == "success" else "Compilation failed via tykit HTTP",
                    "backend": "tykit",
                    "transport": "tykit-http",
                    "duration_sec": float(current.get("duration") or 0.0),
                    "errors": errors,
                }

            if not saw_compiling and time.time() - start >= 5:
                latest = self.http_post(port, "get-compile-result").get("data") or {}
                latest_state = latest.get("state")
                if latest_state in {"success", "failed"}:
                    errors = list(latest.get("errors") or [])
                    return {
                        "ok": latest_state == "success",
                        "state": "passed" if latest_state == "success" else "failed",
                        "message": "No new compile detected after refresh; returning latest known compile result",
                        "backend": "tykit",
                        "transport": "tykit-http",
                        "duration_sec": float(latest.get("duration") or 0.0),
                        "errors": errors,
                    }
            time.sleep(0.5)

        raise BridgeError("COMPILE_TIMEOUT", f"Timed out waiting for compilation after {timeout_sec}s")

    def run_tests_via_project_script(self, ctx: ProjectContext, mode: str, filter_value: Any, assembly_arg: str, timeout_sec: int) -> dict[str, Any]:
        modes = ["editmode", "playmode"] if mode == "all" else [mode]
        phases: list[dict[str, Any]] = []
        total = passed = failed = skipped = 0
        duration_total = 0.0

        for phase_mode in modes:
            phase = self.run_single_test_script(ctx, phase_mode, filter_value, assembly_arg, timeout_sec)
            phases.append(phase)
            total += phase.get("total", 0)
            passed += phase.get("passed", 0)
            failed += phase.get("failed", 0)
            skipped += phase.get("skipped", 0)
            duration_total += phase.get("duration_sec", 0.0)
            if not phase.get("ok", False):
                if mode == "all" and phase_mode == "editmode":
                    break

        final_ok = all(phase.get("ok", False) for phase in phases)
        failures = [failure for phase in phases for failure in phase.get("failures", [])]
        final_state = "passed" if final_ok else "failed"
        return {
            "ok": final_ok,
            "state": final_state,
            "mode": mode,
            "message": "Tests passed via qq fast path" if final_ok else "Tests failed via qq fast path",
            "backend": "tykit",
            "transport": "qq-script",
            "total": total,
            "passed": passed,
            "failed": failed,
            "skipped": skipped,
            "duration_sec": duration_total,
            "failures": failures,
            "phases": phases,
        }

    def run_single_test_script(self, ctx: ProjectContext, mode: str, filter_value: Any, assembly_arg: str, timeout_sec: int) -> dict[str, Any]:
        script = ctx.qq_scripts_dir / "unity-test.sh"
        command = ["bash", str(script), mode, "--timeout", str(timeout_sec)]
        if filter_value:
            command.extend(["--filter", str(filter_value)])
        if assembly_arg:
            command.extend(["--assembly", assembly_arg])

        result = self.run_shell(command, ctx.project_dir, timeout_sec=timeout_sec + 240)
        output = strip_ansi(result.stdout + result.stderr)
        summary = self.parse_test_summary(output)
        failures = self.parse_test_failures(output)
        phase_ok = result.returncode == 0 and summary["failed"] == 0

        return {
            "mode": mode,
            "ok": phase_ok,
            "state": "passed" if phase_ok else "failed",
            "message": "Phase passed" if phase_ok else (output.strip().splitlines()[-1] if output.strip() else "Phase failed"),
            "total": summary["total"],
            "passed": summary["passed"],
            "failed": summary["failed"],
            "skipped": summary["skipped"],
            "duration_sec": summary["duration"],
            "failures": failures,
        }

    def run_tests_via_http(self, ctx: ProjectContext, mode: str, filter_value: Any, assembly_arg: str, timeout_sec: int) -> dict[str, Any]:
        modes = ["editmode", "playmode"] if mode == "all" else [mode]
        phases: list[dict[str, Any]] = []
        total = passed = failed = skipped = 0
        duration_total = 0.0

        for phase_mode in modes:
            phase = self.run_single_http_test(ctx, phase_mode, filter_value, assembly_arg, timeout_sec)
            phases.append(phase)
            total += phase.get("total", 0)
            passed += phase.get("passed", 0)
            failed += phase.get("failed", 0)
            skipped += phase.get("skipped", 0)
            duration_total += phase.get("duration_sec", 0.0)
            if not phase.get("ok", False) and mode == "all" and phase_mode == "editmode":
                break

        final_ok = all(phase.get("ok", False) for phase in phases)
        failures = [failure for phase in phases for failure in phase.get("failures", [])]
        return {
            "ok": final_ok,
            "state": "passed" if final_ok else "failed",
            "mode": mode,
            "message": "Tests passed via tykit HTTP" if final_ok else "Tests failed via tykit HTTP",
            "backend": "tykit",
            "transport": "tykit-http",
            "total": total,
            "passed": passed,
            "failed": failed,
            "skipped": skipped,
            "duration_sec": duration_total,
            "failures": failures,
            "phases": phases,
        }

    def run_single_http_test(self, ctx: ProjectContext, mode: str, filter_value: Any, assembly_arg: str, timeout_sec: int) -> dict[str, Any]:
        info = self.require_tykit(ctx.project_dir)
        port = info["port"]
        args: dict[str, Any] = {"mode": mode}
        if filter_value:
            args["filter"] = str(filter_value)
        if assembly_arg:
            args["assemblyNames"] = assembly_arg

        run = self.http_post(port, "run-tests", args).get("data") or {}
        run_id = run.get("runId")
        if not run_id:
            raise BridgeError("TEST_FAILED", "tykit did not return a test run ID")

        start = time.time()
        while time.time() - start < timeout_sec:
            poll = self.http_post(port, "get-test-result", {"runId": run_id}).get("data") or {}
            state = str(poll.get("state") or "")
            if state in {"passed", "failed"}:
                return {
                    "mode": mode,
                    "ok": state == "passed",
                    "state": state,
                    "message": f"{mode} tests {state}",
                    "total": int(poll.get("total") or 0),
                    "passed": int(poll.get("passed") or 0),
                    "failed": int(poll.get("failed") or 0),
                    "skipped": int(poll.get("skipped") or 0),
                    "duration_sec": float(poll.get("duration") or 0.0),
                    "failures": list(poll.get("failures") or []),
                }
            time.sleep(1.0)

        raise BridgeError("TEST_TIMEOUT", f"Timed out waiting for {mode} tests after {timeout_sec}s")

    @staticmethod
    def normalize_test_mode(value: Any) -> str:
        raw = str(value or "all").strip().lower()
        if raw in {"", "all"}:
            return "all"
        if raw in {"edit", "editmode"}:
            return "editmode"
        if raw in {"play", "playmode"}:
            return "playmode"
        raise BridgeError("INVALID_ARGUMENT", f"Unsupported test mode: {value}")

    @staticmethod
    def project_command_args(arguments: dict[str, Any], mapping: dict[str, str]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for source_key, target_key in mapping.items():
            if source_key in arguments and arguments[source_key] is not None:
                result[target_key] = arguments[source_key]
        return result

    @staticmethod
    def extract_duration(output: str) -> float | None:
        matches = re.findall(r"\((?P<duration>[0-9.]+)s", output)
        if matches:
            try:
                return float(matches[-1])
            except ValueError:
                return None
        return None

    @staticmethod
    def extract_log_path(output: str) -> str | None:
        match = re.search(r"Full log:\s*(?P<path>.+)", output)
        return match.group("path").strip() if match else None

    @staticmethod
    def parse_test_summary(output: str) -> dict[str, Any]:
        match = None
        for candidate in TEST_SUMMARY_RE.finditer(output):
            match = candidate
        if match is None:
            return {"total": 0, "passed": 0, "failed": 0, "skipped": 0, "duration": 0.0}
        return {
            "total": int(match.group("total")),
            "passed": int(match.group("passed")),
            "failed": int(match.group("failed")),
            "skipped": int(match.group("skipped")),
            "duration": float(match.group("duration")),
        }

    @staticmethod
    def parse_test_failures(output: str) -> list[str]:
        failures: list[str] = []
        for line in output.splitlines():
            stripped = line.strip()
            if not stripped:
                continue
            if stripped.startswith("Log:"):
                continue
            if "error CS" in stripped:
                failures.append(stripped)
                continue
            if stripped.startswith("✗"):
                failures.append(stripped[1:].strip())
                continue
            if stripped.startswith("Failed tests:"):
                continue
            if line.startswith("  ") and "Total:" not in stripped and "Passed:" not in stripped and "Failed:" not in stripped:
                failures.append(stripped)
        return unique_strings(failures)

    @staticmethod
    def should_fallback_compile(result: dict[str, Any]) -> bool:
        if result.get("ok"):
            return False
        if result.get("errors"):
            return False
        if result.get("category") == "COMPILE_TIMEOUT":
            return True
        message = str(result.get("message") or "").lower()
        return any(
            marker in message
            for marker in (
                "tykit.json not found",
                "eval_server.json not found",
                "tykit unreachable",
                "is unity editor running",
                "command timed out",
            )
        )

    @staticmethod
    def should_fallback_tests(result: dict[str, Any]) -> bool:
        if result.get("ok"):
            return False
        if result.get("failed") or result.get("failures"):
            return False
        message = str(result.get("message") or "").lower()
        return any(
            marker in message
            for marker in (
                "timed out",
                "tykit unreachable",
                "failed to start tests",
                "metadata",
                "not found",
            )
        ) or int(result.get("total") or 0) == 0

    def tool_result(self, structured: dict[str, Any], is_error: bool | None = None) -> dict[str, Any]:
        error_flag = bool(structured.get("ok") is False) if is_error is None else is_error
        message = structured.get("message") or structured.get("category") or "tykit operation completed"
        return {
            "content": [{"type": "text", "text": f"{message}\n\n{pretty_json(structured)}"}],
            "structuredContent": structured,
            "isError": error_flag,
        }


def main() -> int:
    parser = argparse.ArgumentParser(description="tykit bridge helper")
    parser.add_argument("--project", help="Unity project root")
    parser.add_argument("--profile", choices=["standard", "full"], help="Tool profile to expose")
    parser.add_argument("--doctor", action="store_true", help="Print doctor diagnostics for the target project")
    parser.add_argument("--health", action="store_true", help="Print health diagnostics for the target project")
    parser.add_argument("--tool", choices=sorted(TOOL_DEFINITIONS), help="Call one bridge tool directly")
    parser.add_argument("--arguments", help="JSON object passed to --tool")
    args = parser.parse_args()

    try:
        bridge = TykitBridge(
            default_project_dir=args.project or os.environ.get("TYKIT_PROJECT_DIR"),
            profile=args.profile or os.environ.get("TYKIT_PROFILE"),
        )
        if args.doctor:
            print(pretty_json(bridge.doctor(args.project)))
            return 0
        if args.health:
            print(pretty_json(bridge.health(args.project)))
            return 0
        if args.tool:
            tool_args: dict[str, Any] = {}
            if args.arguments:
                parsed = json.loads(args.arguments)
                if not isinstance(parsed, dict):
                    raise BridgeError("INVALID_ARGUMENT", "--arguments must decode to a JSON object")
                tool_args = parsed
            print(pretty_json(bridge.call_tool(args.tool, tool_args)))
            return 0

        print(pretty_json({"tools": bridge.list_tools()}))
        return 0
    except BridgeError as exc:
        print(pretty_json(exc.to_result()))
        return 1
    except json.JSONDecodeError as exc:
        print(pretty_json(BridgeError("INVALID_ARGUMENT", "--arguments must be valid JSON", {"error": str(exc)}).to_result()))
        return 1


if __name__ == "__main__":
    sys.exit(main())
