# open-tabletop
# Copyright (c) 2020 Benjamin 'drwhut' Beddows
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

extends Node

signal completed(dir_found)
signal importing_file(file)

const ASSET_DIR_PREFIXES = [
	".",
	"..",
	"{DOWNLOADS}/OpenTabletop",
	"{DOCUMENTS}/OpenTabletop",
	"{DESKTOP}/OpenTabletop"
]

const VALID_SCENE_EXTENSIONS = ["glb", "gltf"]

# List taken from:
# https://docs.godotengine.org/en/3.2/getting_started/workflow/assets/importing_images.html
const VALID_TEXTURE_EXTENSIONS = ["bmp", "dds", "exr", "hdr", "jpeg", "jpg",
	"png", "tga", "svg", "svgz", "webp"]

# NOTE: Pieces are stored similarly to the directory structures, but all piece
# types are direct children of the game, i.e. "OpenTabletop/dice/d6" in the
# game directory is _db["OpenTabletop"]["dice/d6"] here.
var _db = {}
var _db_mutex = Mutex.new()

var _import_dir_found = false
var _import_file = ""
var _import_mutex = Mutex.new()
var _import_send_signal = false
var _import_thread = Thread.new()

# From the open_tabletop_import_module:
# https://github.com/drwhut/open_tabletop_import_module
var _importer = TabletopImporter.new()

# Get the list of asset directory paths the game will scan.
# Returns: The list of asset directory paths.
func get_asset_paths() -> Array:
	var out = []
	for prefix in ASSET_DIR_PREFIXES:
		var path = prefix + "/assets"
		path = path.replace("{DOWNLOADS}", OS.get_system_dir(OS.SYSTEM_DIR_DOWNLOADS))
		path = path.replace("{DOCUMENTS}", OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS))
		path = path.replace("{DESKTOP}", OS.get_system_dir(OS.SYSTEM_DIR_DESKTOP))
		out.append(path)
	return out

# Get the piece database.
# Returns: The piece database.
func get_db() -> Dictionary:
	return _db

# Start the importing thread.
func start_importing() -> void:
	if _import_thread.is_active():
		_import_thread.wait_to_finish()
	_import_thread.start(self, "_import_all")

func _ready():
	connect("tree_exiting", self, "_on_exiting_tree")

func _process(delta):
	_import_mutex.lock()
	if _import_send_signal:
		if _import_file.empty():
			emit_signal("completed", _import_dir_found)
		else:
			emit_signal("importing_file", _import_file)
		_import_send_signal = false
	_import_mutex.unlock()

# Import assets from all directories.
# userdata: Ignored, required for it to be run by a thread.
func _import_all(userdata) -> void:
	var dir = Directory.new()
	
	var dir_found = false
	for asset_dir in get_asset_paths():
		if dir.open(asset_dir) == OK:
			dir_found = true
			dir.list_dir_begin(true, true)
			
			var entry = dir.get_next()
			while entry:
				
				if dir.current_is_dir():
					dir.change_dir(entry)
					_import_game_dir(dir)
					dir.change_dir("..")
				
				entry = dir.get_next()
	
	_send_import_signal("", dir_found)

# Import assets from a given game directory.
# dir: The directory to import assets from.
func _import_game_dir(dir: Directory) -> void:
	var game = dir.get_current_dir().get_file()
	
	print("Importing ", game, " from ", dir.get_current_dir(), " ...")
	
	_db_mutex.lock()
	_db[game] = {}
	_db_mutex.unlock()
	
	_import_dir_if_exists(dir, game, "cards", "res://Pieces/Card.tscn")
	
	_import_dir_if_exists(dir, game, "dice/d4", "res://Pieces/Dice/d4.tscn")
	_import_dir_if_exists(dir, game, "dice/d6", "res://Pieces/Dice/d6.tscn")
	_import_dir_if_exists(dir, game, "dice/d8", "res://Pieces/Dice/d8.tscn")
	
	_import_dir_if_exists(dir, game, "pieces/cube", "res://Pieces/Pieces/Cube.tscn")
	_import_dir_if_exists(dir, game, "pieces/custom", "")
	_import_dir_if_exists(dir, game, "pieces/cylinder", "res://Pieces/Pieces/Cylinder.tscn")
	
	_import_dir_if_exists(dir, game, "tokens/cube", "res://Pieces/Tokens/Cube.tscn")
	_import_dir_if_exists(dir, game, "tokens/cylinder", "res://Pieces/Tokens/Cylinder.tscn")

# Import a directory of assets, but only if the directory exists.
# current_dir: The current working directory.
# game: The name of the game.
# type: The type of the asset.
# scene: The path of the scene to use for the asset. If blank, it is assumed
# we are importing scenes.
func _import_dir_if_exists(current_dir: Directory, game: String, type: String,
	scene: String) -> void:
	
	var new_dir = Directory.new()
	if new_dir.open(current_dir.get_current_dir() + "/" + type) == OK:
		
		# If the configuration file exists for this directory, try and load it.
		var config_path = new_dir.get_current_dir() + "/config.cfg"
		var config = ConfigFile.new()
		var config_err = config.load(config_path)
		
		if config_err == OK:
			print("Loaded: " + config_path)
		elif config_err == ERR_FILE_NOT_FOUND:
			pass
		else:
			push_warning("Failed to load: " + config_path + " (error " + str(config_err) + ")")
		
		var files = []
		
		new_dir.list_dir_begin(true, true)
		
		var file = new_dir.get_next()
		while file:
			if not _get_file_config_value(config, file, "ignore", false):
				var file_path = new_dir.get_current_dir() + "/" + file
				# Make sure that scenes are imported last, since they can
				# depend on other files like textures and binary files.
				if VALID_SCENE_EXTENSIONS.has(file_path.get_extension()):
					files.push_back(file_path)
				else:
					files.push_front(file_path)
			
			file = new_dir.get_next()
		
		for file_path in files:
			var import_err = _import_asset(file_path, game, type, scene, config)
			if import_err:
				print("Failed to import: ", file_path, " (error ", import_err, ")")
		
		if _db.has(game):
			if _db[game].has(type):
				var array: Array = _db[game][type]
				array.sort_custom(self, "_sort_pieces")
		
		var is_stackable = false
		if scene:
			var piece: Piece = load(scene).instance()
			if piece is StackablePiece:
				is_stackable = true
			piece.free()
		
		if is_stackable:
			var stack_config_path = new_dir.get_current_dir() + "/stacks.cfg"
			var stack_config = ConfigFile.new()
			var stack_config_err = stack_config.load(stack_config_path)
			
			if stack_config_err == OK:
				_import_stack_config(stack_config, game, type, scene)
				print("Loaded: " + stack_config_path)
			elif stack_config_err == ERR_FILE_NOT_FOUND:
				pass
			else:
				push_warning("Failed to load: " + stack_config_path + " (error " + str(stack_config_err) + ")")

# Add a piece entry to the database.
# game: The name of the game.
# type: The type of the assets.
# entry: The entry to add.
func _add_entry_to_db(game: String, type: String, entry: Dictionary) -> void:
	_db_mutex.lock()
	
	if not _db.has(game):
		_db[game] = {}
	
	if not _db[game].has(type):
		_db[game][type] = []
	
	_db[game][type].push_back(entry)
	_db_mutex.unlock()
	
	print("Added: ", game, "/", type, "/", entry.name)

# Get the directory of a game's type in the user://assets directory.
# Returns: The directory as a Directory object.
# game: The name of the game.
# type: The type of the asset.
func _get_asset_dir(game: String, type: String) -> Directory:
	var dir = Directory.new()
	var dir_error = dir.open("user://")
	
	if dir_error == OK:
		var path = "assets/" + game + "/" + type
		dir.make_dir_recursive(path)
		dir.change_dir(path)
	else:
		print("Cannot open user:// directory (error ", dir_error, ")")
	
	return dir

# Get an asset's config value. It will search the config file with wildcards
# from right to left (e.g. Card -> Car* -> Ca* -> C* -> *).
# Returns: The config value. If it doesn' exists, returns default.
# config: The config file to query.
# section: The section to query (this is the value that is wildcarded).
# key: The key to query.
# default: The default value to return if the value doesn't exist.
func _get_file_config_value(config: ConfigFile, section: String, key: String, default):
	var next_section = section
	
	if section.length() == 0:
		return default
	
	var take_away = 1
	if section.ends_with("*"):
		take_away += 1
	
	var new_len = max(section.length() - take_away, 0)
	
	next_section = section.substr(0, new_len)
	if section != "*":
		next_section += "*"
	
	return config.get_value(section, key, _get_file_config_value(config, next_section, key, default))

# Given a file path, get the file name without the extension.
# Returns: The file name of file_path without the extension.
# file_path: The file path.
func _get_file_without_ext(file_path: String) -> String:
	var file = file_path.get_file()
	return file.substr(0, file.length() - file.get_extension().length() - 1)

# Import an asset. If it has already been imported before, and it's contents
# have not changed, it is not reimported, but the piece entry is still added to
# the database.
# Returns: An Error.
# from: The file path of the asset.
# game: The name of the game to import the asset to.
# type: The type of the asset to import to.
# scene: The scene path to associate with the asset. If blank, it is assumed
# the asset is a scene.
# config: The configuration file for the asset's directory.
func _import_asset(from: String, game: String, type: String, scene: String,
	config: ConfigFile) -> int:
	
	_send_import_signal(from, true)
	
	var dir = _get_asset_dir(game, type)
	
	var to = dir.get_current_dir() + "/" + from.get_file()
	var import_err = _import_file(from, to)
	
	if not (import_err == OK or import_err == ERR_ALREADY_EXISTS):
		return import_err
	
	# Converting from g -> kg -> (Ns^2/cm, since game units are in cm) = x10.
	var desc = _get_file_config_value(config, from.get_file(), "desc", "")
	var mass = 10 * _get_file_config_value(config, from.get_file(), "mass", 1.0)
	var scale = _get_file_config_value(config, from.get_file(), "scale", Vector3(1, 1, 1))
	
	if VALID_SCENE_EXTENSIONS.has(to.get_extension()):
		var entry = {
			"description": desc,
			"mass": mass,
			"name": _get_file_without_ext(to),
			"scale": scale,
			"scene_path": to,
			"texture_path": null
		}
		_add_entry_to_db(game, type, entry)
	elif scene and VALID_TEXTURE_EXTENSIONS.has(to.get_extension()):
		var entry = {
			"description": desc,
			"mass": mass,
			"name": _get_file_without_ext(to),
			"scale": scale,
			"scene_path": scene,
			"texture_path": to
		}
		_add_entry_to_db(game, type, entry)
	
	return OK

# Import a generic file.
# Returns: An Error.
# from: The file path of the file to import.
# to: The path of where to copy the file to.
func _import_file(from: String, to: String) -> int:
	var copy_err = _importer.copy_file(from, to)
	
	if copy_err:
		return copy_err
	
	if VALID_SCENE_EXTENSIONS.has(from.get_extension()):
		return _importer.import_scene(to)
	elif VALID_TEXTURE_EXTENSIONS.has(from.get_extension()):
		return _importer.import_texture(to)
	else:
		return OK

# Import a stack configuration file.
# stack_config: The stack config file.
# game: The name of the game.
# type: The type of the assets.
# scene: The scene to associate with the assets.
func _import_stack_config(stack_config: ConfigFile, game: String, type: String,
	scene: String) -> void:
	
	for stack_name in stack_config.get_sections():
		var desc = stack_config.get_value(stack_name, "desc", "")
		var items = stack_config.get_value(stack_name, "items")
		if items and items is Array:
			
			var masses = []
			var texture_paths = []
			var scale = null
			for item in items:
				var mass = 1.0
			
				# We know everything but the scale of the piece at this point.
				# So, we need to scan through the DB to find the texture, then
				# see what the scale of that texture's piece is.
				if not scale:
					if _db.has(game):
						if _db[game].has(type) and _db[game][type] is Array:
							var piece_entry = null
							
							for piece in _db[game][type]:
								if piece.has("texture_path") and piece.texture_path is String:
									if piece.texture_path.ends_with(item):
										piece_entry = piece
										break
							
							if piece_entry and piece_entry.has("scale"):
								scale = piece_entry.scale
								if piece_entry.has("mass"):
									mass = piece_entry["mass"]
							else:
								print("Could not determine scale of ", item)
				
				# TODO: Check the file exists.
				masses.push_back(mass)
				var texture_path = "user://assets/" + game + "/" + type + "/" + item
				texture_paths.push_back(texture_path)
			
			if scale:
				var stack_entry = {
					"description": desc,
					"masses": masses,
					"name": stack_name,
					"scale": scale,
					"scene_path": scene,
					"texture_paths": texture_paths
				}
				_add_entry_to_db(game, "stacks", stack_entry)
			else:
				print("Could not determine scale of stack ", stack_name)

# Send a signal from the importing thread.
# file: The file we are currently importing - if blank, send the completed
# signal.
# dir_found: Whether an asset directory was found.
func _send_import_signal(file: String, dir_found: bool) -> void:
	_import_mutex.lock()
	_import_dir_found = dir_found
	_import_file = file
	_import_send_signal = true
	_import_mutex.unlock()

# Function used to sort an array of piece entries.
func _sort_pieces(a: Dictionary, b: Dictionary) -> bool:
	return a["name"] < b["name"]

func _on_exiting_tree() -> void:
	if _import_thread.is_active():
		_import_thread.wait_to_finish()
