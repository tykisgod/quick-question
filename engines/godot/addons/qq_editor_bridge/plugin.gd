@tool
extends EditorPlugin

const BRIDGE_VERSION := "1.0.0"
const POLL_INTERVAL_MSEC := 100
const HEARTBEAT_INTERVAL_MSEC := 1000
const PLUGIN_CONFIG_PATH := "res://addons/qq_editor_bridge/plugin.cfg"

var _project_root := ""
var _state_file := ""
var _console_file := ""
var _request_dir := ""
var _response_dir := ""
var _last_poll_msec := 0
var _last_heartbeat_msec := 0
var _request_count := 0
var _last_request_id := ""
var _last_command := ""


func _enter_tree() -> void:
	_project_root = _normalize_dir(ProjectSettings.globalize_path("res://"))
	_state_file = _join_path(_project_root, ".qq/state/qq-godot-editor-bridge.json")
	_console_file = _join_path(_project_root, ".qq/state/qq-godot-editor-console.jsonl")
	_request_dir = _join_path(_project_root, ".qq/state/qq-godot-editor/requests")
	_response_dir = _join_path(_project_root, ".qq/state/qq-godot-editor/responses")
	_ensure_dir(_join_path(_project_root, ".qq/state"))
	_ensure_dir(_request_dir)
	_ensure_dir(_response_dir)
	_append_console("info", "bridge_loaded", {"project_root": _project_root})
	_write_state(true)
	set_process(true)


func _exit_tree() -> void:
	var payload := _build_state_payload(false)
	payload["message"] = "Godot editor bridge stopped"
	_write_json(_state_file, payload)
	_append_console("info", "bridge_unloaded", {})


func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec()
	if now - _last_poll_msec >= POLL_INTERVAL_MSEC:
		_last_poll_msec = now
		_poll_requests()
	if now - _last_heartbeat_msec >= HEARTBEAT_INTERVAL_MSEC:
		_last_heartbeat_msec = now
		_write_state(true)


func _poll_requests() -> void:
	for filename in DirAccess.get_files_at(_request_dir):
		if not filename.ends_with(".json"):
			continue
		_handle_request(_join_path(_request_dir, filename))


func _handle_request(path: String) -> void:
	var payload = _read_json(path)
	var request_id := str(payload.get("requestId", ""))
	var command := str(payload.get("command", ""))
	var args = payload.get("args", {})
	if not (args is Dictionary):
		args = {}

	var response: Dictionary
	if request_id.is_empty() or command.is_empty():
		response = _error_response(request_id, command, "INVALID_REQUEST", "requestId and command are required")
	else:
		response = _dispatch_command(command, args)
		response["requestId"] = request_id
		response["command"] = command
		response["handledAtUnix"] = Time.get_unix_time_from_system()

	_request_count += 1
	_last_request_id = request_id
	_last_command = command
	_write_json(_join_path(_response_dir, "%s.json" % request_id), response)
	DirAccess.remove_absolute(path)
	_append_console("info" if bool(response.get("ok")) else "error", command, {"requestId": request_id, "response": response})


func _dispatch_command(command: String, args: Dictionary) -> Dictionary:
	match command:
		"status":
			return _ok("Editor status loaded", _status_payload())
		"hierarchy":
			return _hierarchy(args)
		"find":
			return _find_nodes(args)
		"inspect":
			return _inspect_node(args)
		"get-selection":
			return _get_selection()
		"list-scenes":
			return _list_scenes(args)
		"list-assets":
			return _list_assets(args)
		"play":
			get_editor_interface().play_current_scene()
			return _ok("Playing current scene", _status_payload())
		"stop":
			get_editor_interface().stop_playing_scene()
			return _ok("Stopped current scene", _status_payload())
		"pause":
			get_tree().paused = not get_tree().paused
			return _ok("Toggled tree pause", {"paused": get_tree().paused})
		"save-scene":
			return _save_scene(args)
		"open-scene":
			return _open_scene(args)
		"new-scene":
			return _new_scene(args)
		"reload-scene":
			return _reload_scene(args)
		"create-node":
			return _create_node(args)
		"instantiate-scene":
			return _instantiate_scene(args)
		"destroy-node":
			return _destroy_node(args)
		"duplicate-node":
			return _duplicate_node(args)
		"set-transform":
			return _set_transform(args)
		"set-parent":
			return _set_parent(args)
		"set-active":
			return _set_active(args)
		"set-property":
			return _set_property(args)
		"add-script":
			return _add_script(args)
		"select-node":
			return _select_node(args)
		"refresh-filesystem":
			get_editor_interface().get_resource_filesystem().scan()
			return _ok("Editor filesystem scan started", {})
		"create-scene-asset":
			return _create_scene_asset(args)
		"create-material":
			return _create_material(args)
		_:
			return _error_response("", command, "UNKNOWN_COMMAND", "Unknown bridge command: %s" % command)


func _status_payload() -> Dictionary:
	var editor := get_editor_interface()
	var root := editor.get_edited_scene_root()
	var selection := []
	for node in editor.get_selection().get_selected_nodes():
		selection.append(_serialize_node_summary(node))
	return {
		"bridgeVersion": BRIDGE_VERSION,
		"engineVersion": Engine.get_version_info(),
		"pluginEnabled": editor.is_plugin_enabled(PLUGIN_CONFIG_PATH),
		"isPlayingScene": editor.is_playing_scene(),
		"playingScene": editor.get_playing_scene(),
		"openScenes": editor.get_open_scenes(),
		"currentPath": editor.get_current_path(),
		"editedSceneRoot": _serialize_node_summary(root) if root != null else {},
		"selection": selection,
		"filesystemScanning": editor.get_resource_filesystem().is_scanning(),
	}


func _hierarchy(args: Dictionary) -> Dictionary:
	var root := _scene_root()
	if root == null:
		return _error_response("", "hierarchy", "NO_SCENE", "No edited scene is open")
	var depth := int(args.get("depth", 3))
	return _ok("Hierarchy loaded", {"hierarchy": _serialize_hierarchy(root, root, max(depth, 1), 0)})


func _find_nodes(args: Dictionary) -> Dictionary:
	var root := _scene_root()
	if root == null:
		return _error_response("", "find", "NO_SCENE", "No edited scene is open")
	var matches := []
	_collect_matching_nodes(root, root, args, matches)
	return _ok("Found %d matching node(s)" % matches.size(), {"nodes": matches})


func _inspect_node(args: Dictionary) -> Dictionary:
	var node := _resolve_node(str(args.get("path", "")))
	if node == null:
		return _error_response("", "inspect", "NODE_NOT_FOUND", "Node not found")
	return _ok("Node inspected", {"node": _serialize_node_details(node)})


func _get_selection() -> Dictionary:
	var nodes := []
	for node in get_editor_interface().get_selection().get_selected_nodes():
		nodes.append(_serialize_node_details(node))
	return _ok("Selection loaded", {"nodes": nodes})


func _list_scenes(args: Dictionary) -> Dictionary:
	var items := _collect_project_files("res://", str(args.get("filter", "")), [".tscn", ".scn"])
	return _ok("Listed %d scene asset(s)" % items.size(), {"assets": items})


func _list_assets(args: Dictionary) -> Dictionary:
	var items := _collect_project_files("res://", str(args.get("filter", "")), [])
	return _ok("Listed %d asset(s)" % items.size(), {"assets": items})


func _save_scene(args: Dictionary) -> Dictionary:
	var editor := get_editor_interface()
	var path := str(args.get("path", ""))
	if path.is_empty():
		editor.save_scene()
		return _ok("Saved current scene", _status_payload())
	editor.save_scene_as(path, true)
	return _ok("Saved current scene as %s" % path, _status_payload())


func _open_scene(args: Dictionary) -> Dictionary:
	var path := str(args.get("path", ""))
	if path.is_empty():
		return _error_response("", "open-scene", "INVALID_ARGUMENT", "path is required")
	if not ResourceLoader.exists(path):
		return _error_response("", "open-scene", "SCENE_NOT_FOUND", "Scene does not exist: %s" % path)
	get_editor_interface().open_scene_from_path(path)
	return _ok("Opened scene %s" % path, _status_payload())


func _new_scene(args: Dictionary) -> Dictionary:
	var node_type := str(args.get("node_type", "Node2D"))
	var root = _instantiate_node_type(node_type)
	if root == null:
		return _error_response("", "new-scene", "INVALID_NODE_TYPE", "Unable to instantiate node type: %s" % node_type)
	root.name = str(args.get("name", "Root"))
	var packed := PackedScene.new()
	var pack_error := packed.pack(root)
	if pack_error != OK:
		root.queue_free()
		return _error_response("", "new-scene", "SCENE_PACK_FAILED", "Failed to pack temporary scene")
	var path := str(args.get("path", ""))
	if not path.is_empty():
		_ensure_res_parent_dir(path)
		var save_error := ResourceSaver.save(packed, path)
		root.queue_free()
		if save_error != OK:
			return _error_response("", "new-scene", "SCENE_SAVE_FAILED", "Failed to save scene: %s" % path)
		get_editor_interface().get_resource_filesystem().update_file(path)
		get_editor_interface().open_scene_from_path(path)
		return _ok("Created scene %s" % path, _status_payload())
	root.queue_free()
	return _error_response("", "new-scene", "INVALID_ARGUMENT", "path is required for new-scene")


func _reload_scene(args: Dictionary) -> Dictionary:
	var path := str(args.get("path", ""))
	if path.is_empty():
		var root := _scene_root()
		if root == null or root.scene_file_path.is_empty():
			return _error_response("", "reload-scene", "NO_SCENE", "No saved scene is open")
		path = root.scene_file_path
	get_editor_interface().reload_scene_from_path(path)
	return _ok("Reloaded scene %s" % path, _status_payload())


func _create_node(args: Dictionary) -> Dictionary:
	var parent := _resolve_parent(str(args.get("parent", "")))
	if parent == null:
		return _error_response("", "create-node", "PARENT_NOT_FOUND", "Parent node not found")
	var node_type := str(args.get("node_type", "Node"))
	var node = _instantiate_node_type(node_type)
	if node == null:
		return _error_response("", "create-node", "INVALID_NODE_TYPE", "Unable to instantiate node type: %s" % node_type)
	node.name = str(args.get("name", node_type))
	parent.add_child(node)
	node.owner = _scene_root()
	_apply_transform(node, args)
	_mark_unsaved()
	return _ok("Created node %s" % node.name, {"node": _serialize_node_details(node)})


func _instantiate_scene(args: Dictionary) -> Dictionary:
	var parent := _resolve_parent(str(args.get("parent", "")))
	if parent == null:
		return _error_response("", "instantiate-scene", "PARENT_NOT_FOUND", "Parent node not found")
	var scene_path := str(args.get("scene", ""))
	if scene_path.is_empty():
		return _error_response("", "instantiate-scene", "INVALID_ARGUMENT", "scene is required")
	var packed = ResourceLoader.load(scene_path)
	if packed == null or not (packed is PackedScene):
		return _error_response("", "instantiate-scene", "SCENE_NOT_FOUND", "Unable to load scene: %s" % scene_path)
	var node = packed.instantiate()
	if node == null:
		return _error_response("", "instantiate-scene", "SCENE_INSTANTIATE_FAILED", "Failed to instantiate scene: %s" % scene_path)
	parent.add_child(node)
	node.owner = _scene_root()
	if args.has("name"):
		node.name = str(args.get("name", node.name))
	_apply_transform(node, args)
	_mark_unsaved()
	return _ok("Instantiated scene %s" % scene_path, {"node": _serialize_node_details(node)})


func _destroy_node(args: Dictionary) -> Dictionary:
	var node := _resolve_node(str(args.get("path", "")))
	if node == null or node == _scene_root():
		return _error_response("", "destroy-node", "NODE_NOT_FOUND", "Node not found or root deletion blocked")
	var parent := node.get_parent()
	if parent != null:
		parent.remove_child(node)
	node.queue_free()
	_mark_unsaved()
	return _ok("Destroyed node", {})


func _duplicate_node(args: Dictionary) -> Dictionary:
	var node := _resolve_node(str(args.get("path", "")))
	if node == null:
		return _error_response("", "duplicate-node", "NODE_NOT_FOUND", "Node not found")
	var parent := node.get_parent()
	if parent == null:
		return _error_response("", "duplicate-node", "INVALID_STATE", "Node has no parent")
	var clone = node.duplicate()
	if clone == null:
		return _error_response("", "duplicate-node", "DUPLICATE_FAILED", "Failed to duplicate node")
	parent.add_child(clone)
	clone.owner = _scene_root()
	if args.has("name"):
		clone.name = str(args.get("name", clone.name))
	_mark_unsaved()
	return _ok("Duplicated node", {"node": _serialize_node_details(clone)})


func _set_transform(args: Dictionary) -> Dictionary:
	var node := _resolve_node(str(args.get("path", "")))
	if node == null:
		return _error_response("", "set-transform", "NODE_NOT_FOUND", "Node not found")
	_apply_transform(node, args)
	_mark_unsaved()
	return _ok("Updated node transform", {"node": _serialize_node_details(node)})


func _set_parent(args: Dictionary) -> Dictionary:
	var node := _resolve_node(str(args.get("path", "")))
	var parent := _resolve_parent(str(args.get("parent", "")))
	if node == null or parent == null or node == _scene_root():
		return _error_response("", "set-parent", "NODE_NOT_FOUND", "Node or parent not found")
	var old_parent := node.get_parent()
	if old_parent != null:
		old_parent.remove_child(node)
	parent.add_child(node)
	node.owner = _scene_root()
	_mark_unsaved()
	return _ok("Updated node parent", {"node": _serialize_node_details(node)})


func _set_active(args: Dictionary) -> Dictionary:
	var node := _resolve_node(str(args.get("path", "")))
	if node == null:
		return _error_response("", "set-active", "NODE_NOT_FOUND", "Node not found")
	var active := bool(args.get("active", true))
	node.process_mode = Node.PROCESS_MODE_INHERIT if active else Node.PROCESS_MODE_DISABLED
	if node is CanvasItem:
		node.visible = active
	_mark_unsaved()
	return _ok("Updated node active state", {"node": _serialize_node_details(node), "active": active})


func _set_property(args: Dictionary) -> Dictionary:
	var node := _resolve_node(str(args.get("path", "")))
	var property := str(args.get("property", ""))
	if node == null:
		return _error_response("", "set-property", "NODE_NOT_FOUND", "Node not found")
	if property.is_empty():
		return _error_response("", "set-property", "INVALID_ARGUMENT", "property is required")
	node.set(property, args.get("value"))
	_mark_unsaved()
	return _ok("Updated property %s" % property, {"node": _serialize_node_details(node)})


func _add_script(args: Dictionary) -> Dictionary:
	var node := _resolve_node(str(args.get("path", "")))
	var script_path := str(args.get("script_path", ""))
	if node == null:
		return _error_response("", "add-script", "NODE_NOT_FOUND", "Node not found")
	if script_path.is_empty():
		return _error_response("", "add-script", "INVALID_ARGUMENT", "script_path is required")
	var script = ResourceLoader.load(script_path)
	if script == null:
		return _error_response("", "add-script", "SCRIPT_NOT_FOUND", "Unable to load script: %s" % script_path)
	node.set_script(script)
	_mark_unsaved()
	return _ok("Attached script %s" % script_path, {"node": _serialize_node_details(node)})


func _select_node(args: Dictionary) -> Dictionary:
	var node := _resolve_node(str(args.get("path", "")))
	if node == null:
		return _error_response("", "select-node", "NODE_NOT_FOUND", "Node not found")
	var selection := get_editor_interface().get_selection()
	selection.clear()
	selection.add_node(node)
	get_editor_interface().edit_node(node)
	return _ok("Selected node", {"node": _serialize_node_details(node)})


func _create_scene_asset(args: Dictionary) -> Dictionary:
	var path := str(args.get("path", ""))
	if path.is_empty():
		return _error_response("", "create-scene-asset", "INVALID_ARGUMENT", "path is required")
	var source_path := str(args.get("source", ""))
	var scene := PackedScene.new()
	var pack_error := OK
	if not source_path.is_empty():
		var node := _resolve_node(source_path)
		if node == null:
			return _error_response("", "create-scene-asset", "NODE_NOT_FOUND", "Source node not found")
		pack_error = scene.pack(node)
	else:
		var node_type := str(args.get("node_type", "Node2D"))
		var temp_root = _instantiate_node_type(node_type)
		if temp_root == null:
			return _error_response("", "create-scene-asset", "INVALID_NODE_TYPE", "Unable to instantiate node type: %s" % node_type)
		temp_root.name = str(args.get("name", "Root"))
		pack_error = scene.pack(temp_root)
		temp_root.queue_free()
	if pack_error != OK:
		return _error_response("", "create-scene-asset", "SCENE_PACK_FAILED", "Failed to pack scene asset")
	_ensure_res_parent_dir(path)
	var save_error := ResourceSaver.save(scene, path)
	if save_error != OK:
		return _error_response("", "create-scene-asset", "SCENE_SAVE_FAILED", "Failed to save scene: %s" % path)
	get_editor_interface().get_resource_filesystem().update_file(path)
	return _ok("Created scene asset %s" % path, {"path": path})


func _create_material(args: Dictionary) -> Dictionary:
	var path := str(args.get("path", ""))
	if path.is_empty():
		return _error_response("", "create-material", "INVALID_ARGUMENT", "path is required")
	var material_type := str(args.get("material_type", "StandardMaterial3D"))
	var material: Resource = null
	match material_type:
		"CanvasItemMaterial":
			material = CanvasItemMaterial.new()
		"ShaderMaterial":
			material = ShaderMaterial.new()
			var shader_path := str(args.get("shader", ""))
			if not shader_path.is_empty():
				var shader = ResourceLoader.load(shader_path)
				if shader != null:
					material.shader = shader
		_:
			material = StandardMaterial3D.new()
	_ensure_res_parent_dir(path)
	var save_error := ResourceSaver.save(material, path)
	if save_error != OK:
		return _error_response("", "create-material", "MATERIAL_SAVE_FAILED", "Failed to save material: %s" % path)
	get_editor_interface().get_resource_filesystem().update_file(path)
	return _ok("Created material %s" % path, {"path": path, "type": material_type})


func _scene_root() -> Node:
	return get_editor_interface().get_edited_scene_root()


func _resolve_parent(path: String) -> Node:
	if path.is_empty():
		return _scene_root()
	return _resolve_node(path)


func _resolve_node(path: String) -> Node:
	var root := _scene_root()
	if root == null:
		return null
	var trimmed := path.strip_edges()
	if trimmed.is_empty() or trimmed == "." or trimmed == root.name:
		return root
	var node = root.get_node_or_null(NodePath(trimmed))
	if node != null:
		return node
	for candidate in root.find_children("*", "", true, false):
		if _relative_node_path(candidate, root) == trimmed:
			return candidate
	return null


func _instantiate_node_type(node_type: String) -> Node:
	if node_type.is_empty():
		return Node.new()
	if ClassDB.class_exists(node_type) and ClassDB.can_instantiate(node_type):
		var node = ClassDB.instantiate(node_type)
		if node is Node:
			return node
	return null


func _apply_transform(node: Node, args: Dictionary) -> void:
	if node is Node2D:
		if args.has("position") and args["position"] is Array and args["position"].size() >= 2:
			node.position = Vector2(float(args["position"][0]), float(args["position"][1]))
		if args.has("rotation") and args["rotation"] is Array and args["rotation"].size() >= 1:
			node.rotation_degrees = float(args["rotation"][0])
		if args.has("scale") and args["scale"] is Array and args["scale"].size() >= 2:
			node.scale = Vector2(float(args["scale"][0]), float(args["scale"][1]))
	elif node is Node3D:
		if args.has("position") and args["position"] is Array and args["position"].size() >= 3:
			node.position = Vector3(float(args["position"][0]), float(args["position"][1]), float(args["position"][2]))
		if args.has("rotation") and args["rotation"] is Array and args["rotation"].size() >= 3:
			node.rotation_degrees = Vector3(float(args["rotation"][0]), float(args["rotation"][1]), float(args["rotation"][2]))
		if args.has("scale") and args["scale"] is Array and args["scale"].size() >= 3:
			node.scale = Vector3(float(args["scale"][0]), float(args["scale"][1]), float(args["scale"][2]))
	elif node is Control:
		if args.has("position") and args["position"] is Array and args["position"].size() >= 2:
			node.position = Vector2(float(args["position"][0]), float(args["position"][1]))
		if args.has("scale") and args["scale"] is Array and args["scale"].size() >= 2:
			node.scale = Vector2(float(args["scale"][0]), float(args["scale"][1]))


func _collect_matching_nodes(node: Node, root: Node, args: Dictionary, out: Array) -> void:
	if _matches_node(node, args):
		out.append(_serialize_node_summary(node))
	for child in node.get_children():
		_collect_matching_nodes(child, root, args, out)


func _matches_node(node: Node, args: Dictionary) -> bool:
	var name_filter := str(args.get("name", ""))
	if not name_filter.is_empty() and name_filter.to_lower() not in node.name.to_lower():
		return false
	var type_filter := str(args.get("type", ""))
	if not type_filter.is_empty() and type_filter != node.get_class():
		return false
	var group_filter := str(args.get("group", ""))
	if not group_filter.is_empty() and not node.is_in_group(group_filter):
		return false
	var path_filter := str(args.get("path", ""))
	if not path_filter.is_empty() and path_filter.to_lower() not in _relative_node_path(node, _scene_root()).to_lower():
		return false
	var generic_filter := str(args.get("filter", ""))
	if not generic_filter.is_empty():
		var blob := "%s %s %s" % [node.name, node.get_class(), _relative_node_path(node, _scene_root())]
		if generic_filter.to_lower() not in blob.to_lower():
			return false
	return true


func _serialize_hierarchy(node: Node, root: Node, max_depth: int, depth: int) -> Dictionary:
	var payload := _serialize_node_summary(node)
	if depth >= max_depth:
		payload["children"] = []
		return payload
	var children := []
	for child in node.get_children():
		children.append(_serialize_hierarchy(child, root, max_depth, depth + 1))
	payload["children"] = children
	return payload


func _serialize_node_summary(node: Node) -> Dictionary:
	if node == null:
		return {}
	var root := _scene_root()
	return {
		"name": node.name,
		"type": node.get_class(),
		"path": _relative_node_path(node, root) if root != null else str(node.get_path()),
		"childCount": node.get_child_count(),
	}


func _serialize_node_details(node: Node) -> Dictionary:
	var payload := _serialize_node_summary(node)
	payload["sceneFilePath"] = node.scene_file_path
	payload["owner"] = _relative_node_path(node.owner, _scene_root()) if node.owner != null and _scene_root() != null else ""
	payload["processMode"] = int(node.process_mode)
	payload["visible"] = node.visible if node is CanvasItem else null
	payload["groups"] = node.get_groups()
	if node is Node2D:
		payload["position"] = [node.position.x, node.position.y]
		payload["rotationDegrees"] = node.rotation_degrees
		payload["scale"] = [node.scale.x, node.scale.y]
	elif node is Node3D:
		payload["position"] = [node.position.x, node.position.y, node.position.z]
		payload["rotationDegrees"] = [node.rotation_degrees.x, node.rotation_degrees.y, node.rotation_degrees.z]
		payload["scale"] = [node.scale.x, node.scale.y, node.scale.z]
	elif node is Control:
		payload["position"] = [node.position.x, node.position.y]
		payload["scale"] = [node.scale.x, node.scale.y]
	return payload


func _relative_node_path(node: Node, root: Node) -> String:
	if node == null:
		return ""
	if root == null or node == root:
		return "."
	return str(root.get_path_to(node))


func _collect_project_files(base_path: String, filter_text: String, extensions: Array) -> Array:
	var items := []
	_collect_project_files_recursive(base_path, filter_text.to_lower(), extensions, items)
	return items


func _collect_project_files_recursive(current_path: String, filter_text: String, extensions: Array, items: Array) -> void:
	for directory in DirAccess.get_directories_at(current_path):
		if directory in [".git", ".godot", ".qq"]:
			continue
		_collect_project_files_recursive(_join_res(current_path, directory), filter_text, extensions, items)
	for filename in DirAccess.get_files_at(current_path):
		var res_path := _join_res(current_path, filename)
		if not extensions.is_empty():
			var matched := false
			for ext in extensions:
				if filename.ends_with(ext):
					matched = true
					break
			if not matched:
				continue
		if not filter_text.is_empty() and filter_text not in res_path.to_lower():
			continue
		items.append({"path": res_path, "type": get_editor_interface().get_resource_filesystem().get_file_type(res_path)})


func _build_state_payload(running: bool) -> Dictionary:
	var editor := get_editor_interface()
	return {
		"ok": true,
		"running": running,
		"bridgeVersion": BRIDGE_VERSION,
		"engineVersion": Engine.get_version_info(),
		"projectRoot": _project_root,
		"pluginEnabled": editor.is_plugin_enabled(PLUGIN_CONFIG_PATH),
		"lastHeartbeatUnix": Time.get_unix_time_from_system(),
		"requestCount": _request_count,
		"lastRequestId": _last_request_id,
		"lastCommand": _last_command,
		"openScenes": editor.get_open_scenes(),
		"playingScene": editor.get_playing_scene(),
		"selectionCount": editor.get_selection().get_selected_nodes().size(),
	}


func _write_state(running: bool) -> void:
	_write_json(_state_file, _build_state_payload(running))


func _ok(message: String, data: Dictionary) -> Dictionary:
	return {
		"ok": true,
		"message": message,
		"data": data,
	}


func _error_response(request_id: String, command: String, category: String, message: String) -> Dictionary:
	return {
		"ok": false,
		"requestId": request_id,
		"command": command,
		"category": category,
		"message": message,
		"data": {},
	}


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var handle := FileAccess.open(path, FileAccess.READ)
	if handle == null:
		return {}
	var payload = JSON.parse_string(handle.get_as_text())
	return payload if payload is Dictionary else {}


func _write_json(path: String, payload: Dictionary) -> void:
	_ensure_dir(path.get_base_dir())
	var handle := FileAccess.open(path, FileAccess.WRITE)
	if handle == null:
		return
	handle.store_string(JSON.stringify(payload, "\t") + "\n")


func _append_console(level: String, event: String, payload: Dictionary) -> void:
	_ensure_dir(_console_file.get_base_dir())
	var record := {
		"timeUnix": Time.get_unix_time_from_system(),
		"level": level,
		"event": event,
		"payload": payload,
	}
	var mode := FileAccess.READ_WRITE if FileAccess.file_exists(_console_file) else FileAccess.WRITE
	var handle = FileAccess.open(_console_file, mode)
	if handle == null:
		return
	handle.seek_end()
	handle.store_string(JSON.stringify(record) + "\n")


func _ensure_dir(path: String) -> void:
	if path.is_empty():
		return
	DirAccess.make_dir_recursive_absolute(path)


func _ensure_res_parent_dir(res_path: String) -> void:
	var absolute := ProjectSettings.globalize_path(res_path).get_base_dir()
	DirAccess.make_dir_recursive_absolute(absolute)


func _mark_unsaved() -> void:
	get_editor_interface().mark_scene_as_unsaved()


func _join_path(base: String, relative: String) -> String:
	if base.ends_with("/"):
		return base + relative
	return base + "/" + relative


func _join_res(base: String, relative: String) -> String:
	if base.ends_with("/"):
		return base + relative
	return base + "/" + relative


func _normalize_dir(path: String) -> String:
	return path.rstrip("/")
