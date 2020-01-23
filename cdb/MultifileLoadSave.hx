package cdb;

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
    public static function getBaseDir(schemaPath: String) : String {
        var pathElements = schemaPath.split("\\").join("/").split("/");
        pathElements.pop();
        return pathElements.join("/") + "/" + MULTIFILE_CDB_DIR;
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
			var dstTable : cdb.Data.SheetData = {
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

	public static function saveMultifileTableContents(data: Data, schemaPath : String) {
		var basePath = getBaseDir(schemaPath);
		
		for (srcTable in data.sheets) {
			var tableIndex : Array<String> = [];

			if (srcTable.lines.length == 0) // don't bother dumping empty tables
				continue;

			var tablePath = basePath + "/" + srcTable.name;
			sys.FileSystem.createDirectory(tablePath);

			// find which column to use as ID
			var idField = null;
			for (column in srcTable.columns) {
				if (column.type == TId) {
					idField = column.name;
					break;
				}
			}
			// Fall back to first column if possible
			if (idField == null) {
				var col0 = srcTable.columns[0];
				if (col0.type == TString || col0.type.match(TRef(_))) {
					idField = col0.name;
				}
			}

			var GROUPS : Array<String> = null;
			if (srcTable.separators != null) {
				GROUPS = [];
				var curSep : String = null;
				var nextSepIdx = 0;
				
				for (rowIdx in 0...srcTable.lines.length) {
					if (nextSepIdx < srcTable.separators.length && srcTable.separators[nextSepIdx] == rowIdx) {
						curSep = srcTable.props.separatorTitles[nextSepIdx];
						sys.FileSystem.createDirectory(tablePath + "/" + curSep);
						nextSepIdx++;
					}
					GROUPS.push(curSep);
				}
			}

			for (rowIdx in 0...srcTable.lines.length) {
				var row = srcTable.lines[rowIdx];

				var rowname : String = null;
				if (idField == null) {
					rowname = StringTools.lpad(Std.string(rowIdx), "0", 4);
				} else {
					rowname = Reflect.field(row, idField);
				}
				if (GROUPS != null && GROUPS[rowIdx] != null)
					rowname = GROUPS[rowIdx] + "/" + rowname;

				var rowpath = tablePath + "/" + rowname + ".row";
				
				tableIndex.push(rowname);

				sys.io.File.saveContent(rowpath, haxe.Json.stringify(row, null, "\t"));
			}

			sys.io.File.saveContent(
				tablePath + "/_table.index",
				haxe.Json.stringify(tableIndex, null, "\t"));
		}
	}
}