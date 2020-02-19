/*
 * Copyright (c) 2015-2017, Nicolas Cannasse
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
import cdb.Data;

typedef SheetIndex = { id : String, disp : String, ico : cdb.Types.TilePos, obj : Dynamic }

class Sheet {

	public var base(default,null) : Database;
	public var sheet : cdb.Data.SheetData;

	public var index : Map<String,SheetIndex>;
	public var all : Array<SheetIndex>;
	public var name(get, never) : String;
	public var columns(get, never) : Array<cdb.Data.Column>;
	public var props(get, never) : cdb.Data.SheetProps;
	public var lines(get, never) : Array<Dynamic>;
	public var separators(get, never) : Array<Int>;

	var path : String;
	public var parent : { sheet : Sheet, column : Int, line : Int };

	public function new(base, sheet, ?path, ?parent) {
		this.base = base;
		this.sheet = sheet;
		this.path = path;
		this.parent = parent;
	}

	inline function get_lines() return sheet.lines;
	inline function get_props() return sheet.props;
	inline function get_columns() return sheet.columns;
	inline function get_name() return sheet.name;
	inline function get_separators() return sheet.separators;

	public inline function isLevel() {
		return sheet.props.level != null;
	}

	public inline function getSub( c : Column ) {
		return base.getSheet(name + "@" + c.name);
	}

	public function getNestedPos(rowIndex : Int) : NestedRowPos {
		var pos : NestedRowPos;
		var colName : String;
		if (parent == null) {
			pos = [];
			colName = name;
		}
		else {
			colName = parent.sheet.columns[parent.column].name;
			pos = parent.sheet.getNestedPos(parent.line);

			// properties are just a cell containing a "tuple", they're not a sub-table, so cut the hierarchy here
			if (parent.sheet.columns[parent.column].type == TProperties) {
				return pos;
			}
		}
		pos.push({col: colName, row: rowIndex});
		return pos;
	}

	public function getParent() {
		if( !sheet.props.hide )
			return null;
		var parts = sheet.name.split("@");
		var colName = parts.pop();
		return { s : base.getSheet(parts.join("@")), c : colName };
	}

	public function getLines() : Array<Dynamic> {
		var p = getParent();
		if( p == null ) return sheet.lines;

		if( p.s.isLevel() && p.c == "tileProps" ) {
			// level tileprops
			var all = [];
			var sets = p.s.props.level.tileSets;
			for( f in Reflect.fields(sets) ) {
				var t : cdb.Data.TilesetProps = Reflect.field(sets, f);
				if( t.props == null ) continue;
				for( p in t.props )
					if( p != null )
						all.push(p);
			}
			return all;
		}

		var all = [];
		if( sheet.props.isProps ) {
			// properties
			for( obj in p.s.getLines() ) {
				var v : Dynamic = Reflect.field(obj, p.c);
				if( v != null )
					all.push(v);
			}
		} else {
			// lists
			for( obj in p.s.getLines() ) {
				var v : Array<Dynamic> = Reflect.field(obj, p.c);
				if( v != null )
					for( v in v )
						all.push(v);
			}
		}
		return all;
	}

	public function getObjects() : Array<{ path : Array<Dynamic>, indexes : Array<Int> }> {
		var p = getParent();
		if( p == null )
			return [for( i in 0...sheet.lines.length ) { path : [sheet.lines[i]], indexes : [i] }];
		var all = [];
		for( obj in p.s.getObjects() ) {
			var v : Array<Dynamic> = Reflect.field(obj.path[obj.path.length-1], p.c);
			if( v != null )
				for( i in 0...v.length ) {
					var sobj = v[i];
					var p = obj.path.copy();
					var idx = obj.indexes.copy();
					p.push(sobj);
					idx.push(i);
					all.push({ path : p, indexes : idx });
				}
		}
		return all;
	}

	public function newLine( ?index : Int ) {
		var o = {
		};
		for( c in sheet.columns ) {
			var d = base.getDefault(c);
			if( d != null )
				Reflect.setField(o, c.name, d);
		}
		if( index == null )
			sheet.lines.push(o);
		else {
			for( i in 0...sheet.separators.length ) {
				var s = sheet.separators[i];
				if( s > index ) sheet.separators[i] = s + 1;
			}
			sheet.lines.insert(index + 1, o);
			changeLineOrder([for( i in 0...sheet.lines.length ) i <= index ? i : i + 1]);
		}
		return o;
	}

	// warning, the path format is kind of misleading
	// e.g. "loreRoom@examinables:18@events:7" actually means: 18th loreRoom, 7th examinable, events table
	public function getPath() {
		return path == null ? sheet.name : path;
	}

	public function hasColumn( name : String, ?types : Array<ColumnType> ) {
		for( c in columns )
			if( c.name == name ) {
				if( types != null ) {
					for( t in types )
						if( c.type.equals(t) )
							return true;
					return false;
				}
				return true;
			}
		return false;
	}

#if EDITOR
	public function moveLine( opStack : OperationStack, index : Int, delta : Int ) : Null<Int> {
		if (sheet == null || delta == 0)
			return null;

		if( delta < 0 ) {
			// Find whether there's a separator ABOVE the row that we're moving up.
			// If so, move the separator BELOW the row instead of modifying the row's position.
			for( i in 0...sheet.separators.length )
				if( sheet.separators[i] == index ) {
					// If there's several separators for the same index, take the last one.
					var i = i;
					while( i < sheet.separators.length - 1 && sheet.separators[i+1] == index )
						i++;

					// Move separator down one notch and finish
					opStack.push(new ops.SeparatorMove(this, i, sheet.separators[i] + 1));
					return index;
				}

			if( index <= 0 )
				return null;
		} else if (delta > 0) {
			// Find whether there's a separator BELOW the row that we're moving down.
			// If so, move the separator ABOVE the row instead of modifying the row's position.
			for( i in 0...sheet.separators.length )
				if( sheet.separators[i] == index + 1 ) {
					// Move separator up one notch and finish
					opStack.push(new ops.SeparatorMove(this, i, sheet.separators[i] - 1));
					return index;
				}

			if (index >= sheet.lines.length - 1)
				return null;
		} else {
			return null;
		}
		
		var nested = getNestedPos(index);
		opStack.push(new ops.RowMove(nested, index+delta));

		return index + delta;
	}

	public function deleteLine( index : Int ) {

		var arr = [for( i in 0...sheet.lines.length ) if( i < index ) i else i - 1];
		arr[index] = -1;
		changeLineOrder(arr);

		sheet.lines.splice(index, 1);

		var prev = -1, toRemove : Null<Int> = null;
		for( i in 0...sheet.separators.length ) {
			var s = sheet.separators[i];
			if( s > index ) {
				if( prev == s ) toRemove = i;
				sheet.separators[i] = s - 1;
			} else
				prev = s;
		}
		// prevent duplicates
		if( toRemove != null ) {
			sheet.separators.splice(toRemove, 1);
			if( sheet.props.separatorTitles != null ) sheet.props.separatorTitles.splice(toRemove, 1);
		}
	}

	public function deleteColumn( cname : String ) {
		for( c in sheet.columns )
			if( c.name == cname ) {
				sheet.columns.remove(c);
				for( o in getLines() )
					Reflect.deleteField(o, c.name);
				if( sheet.props.displayColumn == c.name ) {
					sheet.props.displayColumn = null;
					sync();
				}
				if( sheet.props.displayIcon == c.name ) {
					sheet.props.displayIcon = null;
					sync();
				}
				if( c.type == TList || c.type == TProperties )
					base.deleteSheet(getSub(c));
				return true;
			}
		return false;
	}

	public function addColumn( c : Column, ?index : Int ) {
		// create
		for( c2 in sheet.columns )
			if( c2.name == c.name )
				return "Column already exists";
			else if( c2.type == TId && c.type == TId )
				return "Only one ID allowed";
		if( c.name == "index" && sheet.props.hasIndex )
			return "Sheet already has an index";
		if( c.name == "group" && sheet.props.hasGroup )
			return "Sheet already has a group";
		if( index == null )
			sheet.columns.push(c);
		else
			sheet.columns.insert(index, c);
		for( i in getLines() ) {
			var def = base.getDefault(c);
			if( def != null ) Reflect.setField(i, c.name, def);
		}
		if( c.type == TList || c.type == TProperties ) {
			// create an hidden sheet for the model
			base.createSubSheet(this, c);
		}
		return null;
	}
#end

	public function getDefaults() {
		var props = {};
		for( c in columns ) {
			var d = base.getDefault(c);
			if( d != null )
				Reflect.setField(props, c.name, d);
		}
		return props;
	}

	public function objToString( obj : Dynamic, esc = false ) {
		if( obj == null )
			return "null";
		var fl = [];
		for( c in sheet.columns ) {
			var v = Reflect.field(obj, c.name);
			if( v == null ) continue;
			fl.push(c.name + " : " + colToString(c, v, esc));
		}
		if( fl.length == 0 )
			return "{}";
		return "{ " + fl.join(", ") + " }";
	}

	public function colToString( c : Column, v : Dynamic, esc = false ) {
		if( v == null )
			return "null";
		switch( c.type ) {
		case TList:
			var a : Array<Dynamic> = v;
			if( a.length == 0 ) return "[]";
			var s = getSub(c);
			return "[ " + [for( v in a ) s.objToString(v, esc)].join(", ") + " ]";
		default:
			return base.valToString(c.type, v, esc);
		}
	}

	// returns true if we need to save the full db
	// false if no modifications
	//public static function changeLineOrder( remap : Array<Int>, base : Database, sheetName : String  ) : Bool {
	public function changeLineOrder( remap : Array<Int> ) : Bool {
		var anyModifications : Bool = false;

		for( s in base.sheets )
			for( c in s.columns )
				switch( c.type ) {
				case TLayer(t) if( t == sheet.name ):
					for( obj in s.getLines() ) {
						var ldat : cdb.Types.Layer<Int> = Reflect.field(obj, c.name);
						if( ldat == null || ldat == cast "" ) continue;
						var d = ldat.decode([for( i in 0...256 ) i]);
						for( i in 0...d.length ) {
							var r = remap[d[i]];
							if( r < 0 ) r = 0; // removed
							d[i] = r;
						}
						ldat = cdb.Types.Layer.encode(d, base.compress);
						Reflect.setField(obj, c.name, ldat);
						anyModifications = false;
					}
				default:
				}
		
		return anyModifications;
	}

	public function getReferences( index : Int ) {
		var id = null;
		for( c in sheet.columns ) {
			switch( c.type ) {
			case TId:
				id = Reflect.field(sheet.lines[index], c.name);
				break;
			default:
			}
		}
		if( id == "" || id == null )
			return null;

		var results = [];
		for( s in base.sheets ) {
			for( c in s.columns )
				switch( c.type ) {
				case TRef(sname) if( sname == sheet.name ):
					var sheets = [];
					var p = { s : s, c : c.name, id : null };
					while( true ) {
						for( c in p.s.columns )
							switch( c.type ) {
							case TId: p.id = c.name; break;
							default:
							}
						sheets.unshift(p);
						var p2 = p.s.getParent();
						if( p2 == null ) break;
						p = { s : p2.s, c : p2.c, id : null };
					}
					for( o in s.getObjects() ) {
						var obj = o.path[o.path.length - 1];
						if( Reflect.field(obj, c.name) == id )
							results.push({ s : sheets, o : o });
					}
				case TCustom(tname):
					// todo : lookup in custom types
				default:
				}
		}
		return results;
	}

	function sortById( a : SheetIndex, b : SheetIndex ) {
		return if( a.disp > b.disp ) 1 else -1;
	}

	public function rename( name : String ) {
		@:privateAccess base.smap.remove(this.name);
		sheet.name = name;
		@:privateAccess base.smap.set(name, this);
	}

	public function sync() {
		index = new Map();
		all = [];
		var cid = null;
		var lines = getLines();
		for( c in columns )
			if( c.type == TId ) {
				for( l in lines ) {
					var v = Reflect.field(l, c.name);
					if( v != null && v != "" ) {
						var disp = v;
						var ico = null;
						if( props.displayColumn != null ) {
							disp = Reflect.field(l, props.displayColumn);
							if( disp == null || disp == "" ) disp = "#"+v;
						}
						if( props.displayIcon != null )
							ico = Reflect.field(l, props.displayIcon);
						var o = { id : v, disp:disp, ico:ico, obj : l };
						if( index.get(v) == null )
							index.set(v, o);
						all.push(o);
					}
				}
				all.sort(sortById);
				break;
			}
		@:privateAccess base.smap.set(name, this);
	}

}