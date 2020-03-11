package cdb;

import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import cdb.Data.SheetData;

class MultifileLoadSave {

#if EDITOR
	private static var lastStateOnDisk : Map<String, String> = new Map<String, String>();
	private static var saveStateOnDisk : Map<String, String> = null;
#end
	
	public static var MULTIFILE_CDB_DIR = "cdb";
	public static var MULTIFILE_FORMAT = "ee-multifile";
	
#if (!macro && heaps && !cdbForceNativeFileAccess)
	public static function getBaseDir(schemaPath: String) : String {
		return MULTIFILE_CDB_DIR;
	}

	public static function readFile(fullPath : String) : String {
		return hxd.Res.loader.exists(fullPath)
			? hxd.Res.load(fullPath).entry.getBytes().toString()
			: null;
	}
#else
	private inline static function intmax(a:Int, b:Int) : Int {
		return a > b ? a : b;
	}

	public static function getBaseDir(schemaPath: String) : String {
		var lastSlash = intmax(schemaPath.lastIndexOf("/"), schemaPath.lastIndexOf("\\"));
		if (lastSlash < 0)
			return MULTIFILE_CDB_DIR;
		else
			return haxe.io.Path.join([schemaPath.substr(0, lastSlash), MULTIFILE_CDB_DIR]);
	}

	public static function readFile(fullPath : String) : String {
		var contents = sys.FileSystem.exists(fullPath)
			? sys.io.File.getContent(fullPath)
			: null;
#if EDITOR
		lastStateOnDisk.set(fullPath, contents);
#end
		return contents;
	}
#end

	public static function getMonoCDB(path : String, compact: Bool = true, legacyFormat: Bool = false) : String {
		var data = Parser.parseFrom(path, false);
		return Parser.saveMonofile(data, compact, legacyFormat);
	}

	public static function parseMultifileContents(data : Data, schemaPath : String) {
#if EDITOR
		lastStateOnDisk.clear();
#end

		var basePath = getBaseDir(schemaPath);

		for (table in data.sheets) {
			table.lines = [];
			table.separators = [];
			table.props.separatorTitles = [];

			var tablePath = basePath + "/" + table.name;

			var indexJson = readFile(tablePath + "/_table.index");
			if (indexJson == null) // table has no contents, that's OK
				continue;

			var index : Array<String> = haxe.Json.parse(indexJson);

			var csep = null;

			for (i in 0...index.length) {
				var rowSubpath = index[i];
				
				var pathParts = rowSubpath.split('/');

				if (pathParts.length != 1 && pathParts.length != 2)
					throw "illegal row identifier in index: " + rowSubpath;

				if (pathParts.length == 2 && csep != pathParts[0]) {
					csep = pathParts[0];
					table.separators.push(i);
					table.props.separatorTitles.push(csep);
				}

				var row = haxe.Json.parse(readFile(tablePath + "/" + rowSubpath + ".row"));

				table.lines.push(row);
			}
		}
	}

	public static function saveMultifileRootSchema(data: Data, schemaPath: String) {
		var schema : Data = {
			format : MULTIFILE_FORMAT,
			customTypes : [],
			compress : false,
			sheets : [],
		};

		for (srcTable in data.sheets) {
			var dstTable : SheetData = {
				name : srcTable.name,
				columns : [],
				lines : [],
				separators : [],
				props : Reflect.copy(srcTable.props),
			};
			schema.sheets.push(dstTable);

			Reflect.deleteField(dstTable, "lines");
			Reflect.deleteField(dstTable, "separators");
			Reflect.deleteField(dstTable.props, "separatorTitles");

			for (srcColumn in srcTable.columns) {
				var dstColumn = Reflect.copy(srcColumn);
				dstTable.columns.push(dstColumn);

				dstColumn.typeStr = cdb.Parser.saveType(srcColumn.type);
				Reflect.deleteField(dstColumn, "type");
			}
		}

		sys.io.File.saveContent(schemaPath, haxe.Json.stringify(schema, null, "\t"));
	}

	private static function getIdField(table: SheetData) {
		// find which column to use as ID
		for (column in table.columns) {
			if (column.type == TId) {
				return column.name;
			}
		}

		// Fall back to first column if possible
		var col0 = table.columns[0];
		if (col0.type == TString || col0.type.match(TRef(_))) {
			return col0.name;
		}

		return null;
	}

#if EDITOR
	// Delete any files/directories under MULTIFILE_CDB_DIR
	// that aren't keys in saveStateOnDisk.
	public static function nukeZombieFiles(data : Database, schemaPath : String)
	{
		var baseDir = MultifileLoadSave.getBaseDir(schemaPath);

		var frontier = [baseDir];
		var frontierPos = 0;

		// pass 1: delete files
		while (frontierPos < frontier.length) {
			var dir = frontier[frontierPos];
			frontierPos++;

			var fileCount = 0;

			for (file in FileSystem.readDirectory(dir)) {
				var path = Path.join([dir, file]);
				if (FileSystem.isDirectory(path)) {
					var subdir = Path.addTrailingSlash(path);
					frontier.push(subdir);
				} else if (!lastStateOnDisk.exists(path)) {
					trace("Nuke file: " + path);
					FileSystem.deleteFile(path);
				}
			}
		}

		// pass 2: delete directories
		while (frontier.length > 0) {
			var dir = frontier.pop();
			if (FileSystem.readDirectory(dir).length == 0) {
				trace("Nuke dir: " + dir);
				FileSystem.deleteDirectory(dir);
			}
		}
	}
#end

	public static function saveMultifileTableContents(data: Data, schemaPath : String)
	{
#if EDITOR
		saveStateOnDisk = new Map<String, String>();
#end

		for (table in data.sheets) {
			_saveTable(table, schemaPath);
		}

#if EDITOR
		lastStateOnDisk = saveStateOnDisk;
		saveStateOnDisk = null;
#end
	}

	private static function _saveTable(table: SheetData, schemaPath: String)
	{
		if (table.lines.length == 0) // don't bother dumping empty tables
			return;

		var tableIndex : Array<String> = [];

		var tablePath = getBaseDir(schemaPath) + "/" + table.name;
		sys.FileSystem.createDirectory(tablePath);

		var idField = getIdField(table);

		var sepIdx = -1;
		var sepTitle = null;
		for (rowIdx in 0...table.lines.length) {
			var row = table.lines[rowIdx];

			var rowname = "";
			if (idField != null) {
				rowname = Reflect.field(row, idField);
			}
			if (rowname.length == 0) {
				rowname = StringTools.lpad(Std.string(rowIdx), "0", 4);
			}
			
			// Check for new separator
			if (table.separators != null) {
				var newSepIdx = sepIdx;
				for (i in (sepIdx + 1)...table.separators.length) {
					if (table.separators[i] > rowIdx)
						break;
					newSepIdx = i;
				}

				if (newSepIdx != sepIdx) {
					sepIdx = newSepIdx;
					sepTitle = table.props.separatorTitles[sepIdx];
					if (sepTitle == "") sepTitle = "__UntitledSeparator" + sepIdx;
					var dirPath = tablePath + "/" + sepTitle;
					if (!sys.FileSystem.exists(dirPath))
						sys.FileSystem.createDirectory(dirPath);
				}
			}

			if (sepTitle != null) {
				rowname = sepTitle + "/" + rowname;
			}

			// For saving index at the end
			tableIndex.push(rowname);

			// Save row file
			var rowpath = tablePath + "/" + rowname + ".row";

			writeIfDiff(rowpath, haxe.Json.stringify(row, null, "\t"));
		}

		// Save index
		writeIfDiff(tablePath + "/_table.index", haxe.Json.stringify(tableIndex, null, "\t"));
	}

	// Write string to file if absent or different from lastStateOnDisk
	private static function writeIfDiff(path : String, contents : String) {
#if EDITOR
		saveStateOnDisk.set(path, contents);

		if (lastStateOnDisk.get(path) == contents) {
			return;
		}
#end

		sys.io.File.saveContent(path, contents);
	}
}
