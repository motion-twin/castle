package cdb;

import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import cdb.Data.SheetData;

class MultifileLoadSave {
	
	public static var MULTIFILE_CDB_DIR = "cdb";
	public static var MULTIFILE_FORMAT = "ee-multifile";
	
#if (!macro && heaps)
	public static function getBaseDir(schemaPath: String) : String {
		return MULTIFILE_CDB_DIR;
	}

	public static function readFile(fullPath : String) : String {
		return hxd.Res.loader.exists(fullPath)
			? hxd.Res.load(fullPath).entry.getBytes().toString()
			: null;
	}
#elseif (macro || sys || js)
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
		return sys.FileSystem.exists(fullPath)
			? sys.io.File.getContent(fullPath)
			: null;
	}
#end

	public static function getMonoCDB(path : String) : String {
		return Parser.saveMonofile(Parser.parseFrom(path, false), true);
	}

	public static function parseMultifileContents(data : Data, schemaPath : String) {
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
		trace("SCHEMA SAVED!");
	}

	private static function getSeparatorIndexForRow(table: SheetData, rowIdx: Int, startAt : Int = -1) : Int {
		if (table.separators == null)
			return -1;

		var sepIdx : Int = startAt;

		for (i in (startAt + 1)...table.separators.length) {
			if (table.separators[i] > rowIdx)
				continue;
			sepIdx = i;
		}

		return sepIdx;
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

	public static function nukeContentFiles(schemaPath : String) {
		var baseDir = MultifileLoadSave.getBaseDir(schemaPath);

		if (!FileSystem.exists(baseDir))
			return;

		var frontier = [baseDir];
		var frontierPos = 0;

		// pass 1: delete files
		while (frontierPos < frontier.length) {
			var dir = frontier[frontierPos];
			frontierPos++;

			for (file in FileSystem.readDirectory(dir)) {
				var path = Path.join([dir, file]);
				if (!FileSystem.isDirectory(path)) {
					FileSystem.deleteFile(path);
				} else {
					var subdir = Path.addTrailingSlash(path);
					frontier.push(subdir);
				}
			}
		}

		// pass 2: delete directories
		while (frontier.length > 0) {
			FileSystem.deleteDirectory(frontier.pop());
		}
	}

	public static function saveMultifileTableContents(
		data: Data,
		schemaPath : String,
		dirty : Array<String> = null) // TODO: dirty rows
	{
		for (table in data.sheets) {
			_saveTable(table, schemaPath);
		}
	}

	private static function _saveTable(
		table: SheetData,
		schemaPath: String,
		saveIndex: Bool = true,
		saveRows: Bool = true)
	{
		if (table.lines.length == 0) // don't bother dumping empty tables
			return;

		var tableIndex : Array<String> = [];

		var tablePath = getBaseDir(schemaPath) + "/" + table.name;
		sys.FileSystem.createDirectory(tablePath);

		var idField = getIdField(table);

		var sepIdx = -1;
		for (rowIdx in 0...table.lines.length) {
			var row = table.lines[rowIdx];

			var rowname : String = idField != null
				? Reflect.field(row, idField)
				: StringTools.lpad(Std.string(rowIdx), "0", 4);
			if (rowname.length == 0) {
				rowname = StringTools.lpad(Std.string(rowIdx), "0", 4);
			}
			var sepIdx = getSeparatorIndexForRow(table, rowIdx, sepIdx);
			if (sepIdx >= 0) {
				var sepTitle = table.props.separatorTitles[sepIdx];
				if (sepTitle == "") sepTitle = "__UntitledSeparator" + sepIdx;
				rowname = sepTitle + "/" + rowname;
				sys.FileSystem.createDirectory(tablePath + "/" + table.props.separatorTitles[sepIdx]);
			}

			if (saveIndex) {
				tableIndex.push(rowname);
			}

			if (saveRows) {
				var rowpath = tablePath + "/" + rowname + ".row";
				sys.io.File.saveContent(rowpath, haxe.Json.stringify(row, null, "\t"));	
			}
		}

		if (saveIndex) {
			sys.io.File.saveContent(
				tablePath + "/_table.index",
				haxe.Json.stringify(tableIndex, null, "\t"));
		}
	}

	public static function saveTableIndex(schemaPath: String, table: SheetData) {
		trace("Saving table index: " + table.name);
		_saveTable(table, getBaseDir(schemaPath), true, false);
	}

	public static function saveTableFull(schemaPath: String, table: SheetData) {
		trace("Saving full table: " + table.name);
		_saveTable(table, getBaseDir(schemaPath), true, true);
	}

	public static function getRowPath(schemaPath : String, srcTable : SheetData, rowIdx : Int) {
		var idField = getIdField(srcTable);

		var rowname : String = idField != null
			? Reflect.field(srcTable.lines[rowIdx], idField)
			: StringTools.lpad(Std.string(rowIdx), "0", 4);
		if (rowname.length == 0) {
			rowname = StringTools.lpad(Std.string(rowIdx), "0", 4);
		}

		var sepIdx = getSeparatorIndexForRow(srcTable, rowIdx);
		if (sepIdx >= 0)
			rowname = srcTable.props.separatorTitles[sepIdx] + "/" + rowname;

		var tablePath = getBaseDir(schemaPath) + "/" + srcTable.name;

		return tablePath + "/" + rowname + ".row";
	}

	public static function getNestedRowPath(
		schemaPath : String,
		data : Database,
		pos : NestedRowPos)
	{
		return getRowPath(schemaPath, data.getSheet(pos[0].col).sheet, pos[0].row);
	}

	public static function saveRow(schemaPath : String, table : SheetData, rowIdx : Int) {
		var json = haxe.Json.stringify(table.lines[rowIdx], null, "\t");
		var path = getRowPath(schemaPath, table, rowIdx);
		trace("Saving row: " + path);
		File.saveContent(path, json);
	}

	public static function deleteNestedRowFile(schemaPath : String, data : Database, pos : NestedRowPos) {
		var path = getNestedRowPath(schemaPath, data, pos);
		FileSystem.deleteFile(path);
	}

	public static function deleteRowFile(schemaPath : String, table : SheetData, rowIdx : Int) {
		var path = getRowPath(schemaPath, table, rowIdx);
		FileSystem.deleteFile(path);
	}

	public static function saveNestedRow(schemaPath : String, data : Database, pos : NestedRowPos) {
		var rootRowTable = data.getSheet(pos[0].col).sheet;
		saveRow(schemaPath, rootRowTable, pos[0].row);
	}
}