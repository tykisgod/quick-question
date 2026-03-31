extends SceneTree

var findings: Array[String] = []


func _init() -> void:
    _scan_dir("res://")
    if findings.is_empty():
        print(JSON.stringify({
            "ok": true,
            "finding_count": 0,
        }))
        quit(0)
        return

    for item in findings:
        push_error(item)

    print(JSON.stringify({
        "ok": false,
        "finding_count": findings.size(),
        "findings": findings,
    }))
    quit(1)


func _scan_dir(path: String) -> void:
    var dir := DirAccess.open(path)
    if dir == null:
        findings.append("Failed to open directory: %s" % path)
        return

    dir.list_dir_begin()
    var entry := dir.get_next()
    while entry != "":
        if entry == "." or entry == ".." or entry == ".git" or entry == ".godot":
            entry = dir.get_next()
            continue

        var full_path := path.path_join(entry)
        if dir.current_is_dir():
            if entry != "bin" and entry != "obj":
                _scan_dir(full_path)
        elif _should_validate(entry):
            var resource := ResourceLoader.load(full_path, "", ResourceLoader.CACHE_MODE_IGNORE)
            if resource == null:
                findings.append("Failed to load resource: %s" % full_path)
        entry = dir.get_next()
    dir.list_dir_end()


func _should_validate(name: String) -> bool:
    return (
        name.ends_with(".gd")
        or name.ends_with(".gdshader")
        or name.ends_with(".gdshaderinc")
        or name.ends_with(".tscn")
        or name.ends_with(".scn")
        or name.ends_with(".tres")
        or name.ends_with(".res")
    )
