/*
 * Copyright (c) 2015, Nicolas Cannasse
 *
 * Permission to use, copy, modify, and/or distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
 * SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR
 * IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 */
package cdb;

class Parser {

	public static function saveType( t : Data.ColumnType, legacyIntNames : Bool = false ) : String {
		var baseName : String = null;

		if (legacyIntNames) {
			baseName = Std.string(Type.enumIndex(t));
		} else {
			baseName = switch(t) {
				case TId		: "Id";
				case TString	: "String";
				case TBool		: "Bool";
				case TInt		: "Int";
				case TFloat		: "Float";
				case TEnum(_)	: "Enum";
				case TRef(_)	: "Ref";
				case TImage		: "Image";
				case TList		: "List";
				case TCustom(_)	: "Custom";
				case TFlags(_)	: "Flags";
				case TColor		: "Color";
				case TLayer(_)	: "Layer";
				case TFile		: "File";
				case TTilePos	: "TilePos";
				case TTileLayer	: "TileLayer";
				case TDynamic	: "Dynamic";
				case TProperties: "Properties";
			}
		}

		return switch( t ) {
			case TRef(_), TCustom(_), TLayer(_):
				baseName + ":" + Type.enumParameters(t)[0];
			case TEnum(values), TFlags(values):
				baseName + ":" + values.join(",");
			case TId, TString, TList, TInt, TImage, TFloat, TBool, TColor, TFile, TTilePos, TTileLayer, TDynamic, TProperties:
				baseName;
			};
	}

	public static function getType( str : String ) : Data.ColumnType {
		var colonIndex = str.indexOf(":");
		var afterColon : String = null;
		if (colonIndex > 0) {
			afterColon = str.substr(colonIndex + 1);
			str = str.substr(0, colonIndex);
		}

		return switch( str ) {
		case "0","Id"			: TId;
		case "1","String"		: TString;
		case "2","Bool"			: TBool;
		case "3","Int"			: TInt;
		case "4","Float"		: TFloat;
		case "5","Enum"			: TEnum(afterColon.split(","));
		case "6","Ref"			: TRef(afterColon);
		case "7","Image"		: throw "TImage is unsupported."; //TImage;
		case "8","List"			: TList;
		case "9","Custom"		: throw "TCustom is unsupported.";// TCustom(afterColon);
		case "10","Flags"		: TFlags(afterColon.split(","));
		case "11","Color"		: TColor;
		case "12","Layer"		: throw "TLayer is unsupported.";//TLayer(afterColon);
		case "13","File"		: TFile;
		case "14","TilePos"		: TTilePos;
		case "15","TileLayer"	: TTileLayer;
		case "16","Dynamic"		: TDynamic;
		case "17","Properties"	: TProperties;
		default: throw "Unknown type " + str;
		}
	}

	// sys.ssl.Digest isn't available in macro mode.
#if !macro
	public static function getHash(path : String) : String {
		var b : haxe.io.Bytes = haxe.io.Bytes.ofString(MultifileLoadSave.getMonoCDB(path));
#if (hlps || hlxbo)
		return haxe.crypto.Sha256.make(b).toHex();
#else
		return sys.ssl.Digest.make(b, SHA256).toHex();
#end
	}
#end

	public static function parseJson(content: String, editMode : Bool) : Data {
		if( content == null ) throw "CDB content is null";
		var data : Data = haxe.Json.parse(content);
		if (data.format == MultifileLoadSave.MULTIFILE_FORMAT) {
			throw "cannot use parseJson on a multifile cdb, use parseFrom instead";
		}
		postProcessParsedData(data, editMode);
		return data;
	}

	public static function parseFrom(schemaPath : String, editMode : Bool) : Data {
//		Sys.println("parseFrom: " + schemaPath); // printCallstack
		var content = MultifileLoadSave.readFile(schemaPath);
		if( content == null ) throw "CDB content is null";
		var data : Data = haxe.Json.parse(content);
		if (data.format == MultifileLoadSave.MULTIFILE_FORMAT) {
			MultifileLoadSave.parseMultifileContents(data, schemaPath);
		}
		return postProcessParsedData(data, editMode);
	}

	private static function postProcessParsedData(data : Data, editMode: Bool) : Data {
		for( s in data.sheets )
			for( c in s.columns ) {
				c.type = getType(c.typeStr);
				c.typeStr = null;
			}
		for( t in data.customTypes )
			for( c in t.cases )
				for( a in c.args ) {
					a.type = getType(a.typeStr);
					a.typeStr = null;
				}
		if( editMode ) {
			// resolve separators
			for( s in data.sheets ) {
				if( s.separators == null ) {
					var idField = null;
					for( c in s.columns )
						if( c.type == TId ) {
							idField = c.name;
							break;
						}
					var indexMap = new Map();
					for( i in 0...s.lines.length ) {
						var l = s.lines[i];
						var id : String = Reflect.field(l, idField);
						if( id != null ) indexMap.set(id, i);
					}
					var ids : Array<Dynamic> = Reflect.field(s,"separatorIds");
					s.separators = [for( i in ids ) if( Std.is(i,Int) ) (i:Int) else indexMap.get(i)];
					Reflect.deleteField(s, "separatorIds");
				}
			}
		}
		return data;
	}

	public static function saveMultifile( data : Data, outPath : String ) {
		MultifileLoadSave.saveMultifileTableContents(data, outPath);
		MultifileLoadSave.saveMultifileRootSchema(data, outPath);
	}

	public static function saveMonofile(
		data : Data,
		compact : Bool = false,
		legacyFormat : Bool = false ) : String
	{
		var formatBackup = data.format;
		var save = [];
		var seps = [];
		
		// --------------------------------------------------------------------
		// 1. Pre-process tables and types before serialization

		data.format = legacyFormat ? "legacy-monofile" : "ee-monofile";

		for( s in data.sheets ) {
			var idField = null;
			for( c in s.columns ) {
				if( c.type == TId && idField == null ) idField = c.name;
				save.push(c.type);
				if( c.typeStr == null )
					c.typeStr = cdb.Parser.saveType(c.type, legacyFormat);
				Reflect.deleteField(c, "type");
			}

			// remap separators based on indexes
			// (only if we don't care about maintaining compatibility with legacy format)
			var oldSeps = null;
			if( !legacyFormat && idField != null && s.separators.length > 0 ) {
				var uniqueIDs = true;
				var uids = new Map();
				for( l in s.lines ) {
					var id : String = Reflect.field(l, idField);
					if( id != null ) {
						if( uids.get(id) ) {
							uniqueIDs = false;
							break;
						}
						uids.set(id, true);
					}
				}
				if( uniqueIDs ) {
					Reflect.setField(s,"separatorIds",[for( i in s.separators ) {
						var id = s.lines[i] != null ? Reflect.field(s.lines[i], idField) : null;
						id == null || id == "" ? (i : Dynamic) : (id : Dynamic);
					}]);
					oldSeps = s.separators;
					Reflect.deleteField(s,"separators");
				}
			}
			seps.push(oldSeps);

			// Legacy format compat: 
			if (legacyFormat && s.props.hasIndex) {
				for (rowIdx in 0...s.lines.length) {
					Reflect.setField(s.lines[rowIdx], "index", rowIdx);
				}
			}
		}

		for( t in data.customTypes ) {
			for( c in t.cases ) {
				for( a in c.args ) {
					save.push(a.type);
					if( a.typeStr == null ) a.typeStr = cdb.Parser.saveType(a.type);
					Reflect.deleteField(a, "type");
				}
			}
		}
		
		// --------------------------------------------------------------------
		// 2. Serialize

		var str = haxe.Json.stringify(data, null, compact ? null : "\t");

		// --------------------------------------------------------------------
		// 3. Restore table/type attributes modified in step 1

		data.format = formatBackup;

		for( s in data.sheets ) {
			for( c in s.columns ) {
				c.type = save.shift();
			}
			
			var oldSeps = seps.shift();
			if( oldSeps != null ) {
				s.separators = oldSeps;
				Reflect.deleteField(s,"separatorIds");
			}

			if (legacyFormat && s.props.hasIndex) {
				for (l in s.lines) {
					Reflect.deleteField(l, "index");
				}
			}
		}

		for( t in data.customTypes ) {
			for( c in t.cases ) {
				for( a in c.args ) {
					a.type = save.shift();
				}
			}
		}

		// --------------------------------------------------------------------

		return str;
	}

}