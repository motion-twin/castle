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
import ops.FullSnapshot;
import cdb.Data;
import cdb.Sheet;

import js.jquery.Helper.*;
import js.jquery.JQuery;
import js.node.webkit.Menu;
import js.node.webkit.MenuItem;
import js.node.webkit.MenuItemType;

private typedef Cursor = {
	s : Sheet,
	x : Int,
	y : Int,
	?select : { x : Int, y : Int },
	?onchange : Void -> Void,
}

class K {
	public static inline var INSERT = 45;
	public static inline var DELETE = 46;
	public static inline var LEFT = 37;
	public static inline var UP = 38;
	public static inline var RIGHT = 39;
	public static inline var DOWN = 40;
	public static inline var ESC = 27;
	public static inline var TAB = 9;
	public static inline var SPACE = 32;
	public static inline var ENTER = 13;
	public static inline var F2 = 113;
	public static inline var F3 = 114;
	public static inline var F4 = 115;
	public static inline var NUMPAD_ADD = 107;
	public static inline var NUMPAD_SUB = 109;
	public static inline var NUMPAD_DIV = 111;
}

class Main extends Model {

	static var UID = 0;

	public var window : js.node.webkit.Window;
	var viewSheet : Sheet;
	var mousePos : { x : Int, y : Int };
	var typesStr : String;
	var clipboard : {
		text : String,
		data : Array<Dynamic>,
		schema : Array<Column>,
	};
	var cursor : Cursor;
	var checkCursor : Bool;
	var sheetCursors : Map<String, Cursor>;
	var colProps : { sheet : String, ref : Column, index : Null<Int> };
	var levels : Array<Level>;
	var level : Level;
	var mcompress : MenuItem;
	var pages : JqPages;

	var macEditMenu : MenuItem;
	var editMenu : Menu;

	public static function getCallstackString(skip:Int = 1) {
		var cs = haxe.CallStack.callStack();
		var str = "===CALLSTACK===";
		for (si in cs) {
			if (skip > 0) {
				skip--;
				continue;
			}
			switch (si) {
				case FilePos(junk, file, line, column):
				{
					if (file.lastIndexOf("/") >= 0)
						file = file.substr(file.lastIndexOf("/") + 1);
					str += "\n    " + file + ":" + line;
				}
				default: str += "\nunknown stack trace item";
			}
		};
		return str;
	}

	function new() {
		super();
		window = js.node.webkit.Window.get();
		window.on("resize", onResize);
		window.on("focus", function(_) js.node.webkit.App.clearCache());
		window.zoomLevel = prefs.zoomLevel;
		initMenu();
		levels = [];
		mousePos = { x : 0, y : 0 };
		sheetCursors = new Map();
		window.window.addEventListener("keydown", onKey);
		window.window.addEventListener("keypress", onKeyPress);
		window.window.addEventListener("keyup", onKeyUp);
		window.window.addEventListener("mousemove", onMouseMove);
		window.window.addEventListener("dragover", function(e : js.html.Event) { e.preventDefault(); return false; });
		window.window.addEventListener("drop", onDragDrop);
		J(".modal").keypress(function(e) e.stopPropagation()).keydown(function(e) e.stopPropagation());
		J("#search input").keydown(function(e) {
			if( e.keyCode == 27 ) {
				J("#search i").click();
				return;
			}
		}).keyup(function(_) {
			searchFilter(JTHIS.val());
		});
		J("#search i").click(function(_) {
			searchFilter(null);
			J("#search").toggle();
		});
		cursor = {
			s : null,
			x : 0,
			y : 0,
		};
		pages = new JqPages(this);

		load(true);
	}

	//-------------------------------------------------------------------------
	// Snapshot

	function prepSnapshot(operationName : String = "unknown operation") {
		return new ops.FullSnapshot().setPreviousState(this);
	}

	function commitSnapshot(op: FullSnapshot) {
		op.setCurrentState(this);
		opStack.pushNoApply(op);
		refresh();
	}

	function rollbackSnapshot(op) {
		op.rollback(this);
	}

	//-------------------------------------------------------------------------

	function doDeleteSelectedRow() {
		J(".selected.deletable").change();
		if( cursor.s == null )
			return;

		var op = prepSnapshot();
		if( cursor.s.props.isProps ) {
			var l = getLine(cursor.s, cursor.y);
			if( l != null )
				Reflect.deleteField(cursor.s.lines[0], l.attr("colName"));
		} else if( cursor.x < 0 ) {
			var s = getSelection();
			var y = s.y2;
			while( y >= s.y1 ) {
				cursor.s.deleteLine(y);
				y--;
			}
			cursor.y = s.y1;
			cursor.select = null;
		} else {
			var s = getSelection();
			for( y in s.y1...s.y2 + 1 ) {
				var obj = cursor.s.lines[y];
				for( x in s.x1...s.x2+1 ) {
					var c = cursor.s.columns[x];
					var def = base.getDefault(c);
					if( def == null )
						Reflect.deleteField(obj, c.name);
					else
						Reflect.setField(obj, c.name, def);
				}
			}
		}

		commitSnapshot(op);
	}

	function doCopy() {
		if (cursor.s == null) {
			return;
		}

		var s = getSelection();
		var data = [];
		for (y in s.y1...s.y2+1) {
			var obj = cursor.s.lines[y];
			var out = {};
			for( x in s.x1...s.x2+1 ) {
				var c = cursor.s.columns[x];
				var v = Reflect.field(obj, c.name);
				if( v != null )
					Reflect.setField(out, c.name, v);
			}
			data.push(out);
		}

		setClipBoard([for( x in s.x1...s.x2+1 ) cursor.s.columns[x]], data);
	}

	function doPaste() {
		if( cursor.s == null || clipboard == null || js.node.webkit.Clipboard.getInstance().get("text")  != clipboard.text )
			return;

		var snapshot = prepSnapshot();

		var sheet = cursor.s;
		var posX = cursor.x < 0 ? 0 : cursor.x;
		var posY = cursor.y < 0 ? 0 : cursor.y;

		for (obj1 in clipboard.data) {
			if (posY == sheet.lines.length) {
				sheet.newLine();
			}

			var obj2 = sheet.lines[posY];
			for (cid in 0...clipboard.schema.length) {
				var c1 = clipboard.schema[cid];
				var c2 = sheet.columns[cid + posX];

				if (c2 == null) {
					continue;
				}

				var f = base.getConvFunction(c1.type, c2.type);
				var v : Dynamic = Reflect.field(obj1, c1.name);

				if (f == null) {
					v = base.getDefault(c2);
				} else {
					// make a deep copy to erase references
					if (v != null) {
						v = haxe.Json.parse(haxe.Json.stringify(v));
					}
					if (f.f != null) {
						v = f.f(v);
					}
				}

				if (v == null && !c2.opt) {
					v = base.getDefault(c2);
				}

				if (v == null) {
					Reflect.deleteField(obj2, c2.name);
				} else {
					Reflect.setField(obj2, c2.name, v);
				}
			}

			posY++;
		}

		sheet.sync();

		//refresh();
		//save();
		commitSnapshot(snapshot);
	}

	function openTableReferencedBySelectedCell() {
		if (cursor.s == null || cursor.x < 0)
			return;

		var c = cursor.s.columns[cursor.x];
		var id = Reflect.field(cursor.s.lines[cursor.y], c.name);

		switch( c.type ) {
		case TRef(s):
			var sd = base.getSheet(s);
			if( sd != null ) {
				var k = sd.index.get(id);
				if( k != null ) {
					var index = Lambda.indexOf(sd.lines, k.obj);
					if( index >= 0 ) {
						sheetCursors.set(s, { s : sd, x : 0, y : index } );
						selectSheet(sd);
					}
				}
			}
		default: // no-op
			window.window.alert("Can't go to reference because\nthe selected cell isn't a reference type.");
		}
	}

	//-------------------------------------------------------------------------

	function searchFilter( filter : String ) {
		if( filter == "" ) filter = null;
		if( filter != null ) filter = filter.toLowerCase();

		var lines = J("table.sheet tr").not(".head");
		lines.removeClass("filtered");
		if( filter != null ) {
			for( t in lines ) {
				if( t.textContent.toLowerCase().indexOf(filter) < 0 )
					t.classList.add("filtered");
			}
			while( lines.length > 0 ) {
				lines = lines.filter(".list").not(".filtered").prev();
				lines.removeClass("filtered");
			}
		}
	}

	function onResize(_) {
		if( level != null ) level.onResize();
		pages.onResize();
	}

	function onMouseMove( e : js.html.MouseEvent ) {
		mousePos.x = e.clientX;
		mousePos.y = e.clientY;
	}

	function onDragDrop( e : js.html.DragEvent ) {
		e.preventDefault();
		for ( i in 0...e.dataTransfer.files.length ) {
			var file = e.dataTransfer.files[i];
			if (haxe.io.Path.extension(file.name) == "cdb") {
				prefs.curFile = untyped file.path;
				load();
			}
		}
	}

	function setClipBoard( schema : Array<Column>, data : Array<Dynamic> ) {
		clipboard = {
			text : Std.string([for( o in data ) cursor.s.objToString(o,true)]),
			data : data,
			schema : schema,
		};
		js.node.webkit.Clipboard.getInstance().set(clipboard.text, "text");
	}

	function moveCursor( dx : Int, dy : Int, shift : Bool, ctrl : Bool ) {
		if( cursor.s == null )
			return;
		if( cursor.x == -1 && ctrl ) {
			if( dy != 0 ) {
				var newIndex = cursor.s.moveLine(opStack, cursor.y, dy);
				setCursor(cursor.s, -1, newIndex);
			}
			updateCursor();
			return;
		}
		if( dx < 0 && cursor.x >= 0 )
			cursor.x--;
		if( dy < 0 && cursor.y > 0 )
			cursor.y--;
		if( dx > 0 && cursor.x < cursor.s.columns.length - 1 )
			cursor.x++;
		if( dy > 0 && cursor.y < cursor.s.lines.length - 1 )
			cursor.y++;
		cursor.select = null;
		updateCursor();
	}

	function isInput() {
		return js.Browser.document.activeElement != null && js.Browser.document.activeElement.nodeName == "INPUT";
	}

	function onKeyPress( e : js.html.KeyboardEvent ) {
		if( !e.ctrlKey && !isInput() ) {
			var c = J(".cursor").not(".edit");
			if( c.length>0 ) {
				if( e.keyCode==K.ENTER )
					e.preventDefault();
				c.dblclick();
			}
		}
	}

	function getSelection() {
		if( cursor.s == null )
			return null;
		var x1 = if( cursor.x < 0 ) 0 else cursor.x;
		var x2 = if( cursor.x < 0 ) cursor.s.columns.length-1 else if( cursor.select != null ) cursor.select.x else x1;
		var y1 = cursor.y;
		var y2 = if( cursor.select != null ) cursor.select.y else y1;
		if( x2 < x1 ) {
			var tmp = x2;
			x2 = x1;
			x1 = tmp;
		}
		if( y2 < y1 ) {
			var tmp = y2;
			y2 = y1;
			y1 = tmp;
		}
		return { x1 : x1, x2 : x2, y1 : y1, y2 : y2 };
	}

	function isInCDB() {
		return !isInLevel() && pages.curPage < 0;
	}

	function isInLevel() {
		return level != null;
	}

	function onKey( e : js.html.KeyboardEvent ) {
		var ctrlDown = e.ctrlKey;
		if(Sys.systemName().indexOf("Mac") != -1) {
			ctrlDown = e.metaKey;
		}

		if( isInput() )
			return;

		var inCDB = level == null && pages.curPage < 0;

		switch( e.keyCode ) {
		// Delete row
		case K.DELETE if( inCDB ):
			doDeleteSelectedRow();

		// Move cursor up
		case K.UP:
			moveCursor(0, -1, e.shiftKey, ctrlDown);
			e.preventDefault();

		// Move cursor down
		case K.DOWN:
			moveCursor(0, 1, e.shiftKey, ctrlDown);
			e.preventDefault();

		// Move cursor left
		case K.LEFT:
			moveCursor(-1, 0, e.shiftKey, ctrlDown);
		
		// Move cursor right
		case K.RIGHT:
			moveCursor(1, 0, e.shiftKey, ctrlDown);
		
		// Open list
		case K.ENTER if( inCDB ):
			// open list
			if( cursor.s != null && J(".cursor.t_list,.cursor.t_properties").click().length > 0 )
				e.preventDefault();
		
		// Prevent default behavior (page down)
		case K.SPACE:
			e.preventDefault(); // scrolling

		// Tab: next column
		case K.TAB:
			moveCursor(e.shiftKey? -1:1, 0, false, false);
		
		case K.ESC:
			if( cursor.s != null && cursor.s.parent != null ) {
				var p = cursor.s.parent;
				setCursor(p.sheet, p.column, p.line);
				J(".cursor").click();
			} else if( cursor.select != null ) {
				cursor.select = null;
				updateCursor();
			}

		default:
		}

		if( level != null ) level.onKey(e);
		if( pages.curPage >= 0 ) pages.onKey(e);
	}

	function onKeyUp( e : js.html.KeyboardEvent ) {
		if( level != null && !isInput() ) level.onKeyUp(e);
	}

	public function getLine( sheet : Sheet, index : Int ) {
		return J("table[sheet='"+sheet.getPath()+"'] > tbody > tr").not(".head,.separator,.list").eq(index);
	}

	function showReferences( sheet : Sheet, index : Int ) {
		var results = sheet.getReferences(index);
		if( results == null )
			return;
		if( results.length == 0 ) {
			window.window.alert("Nothing refers to this row.");
			return;
		}

		var line = getLine(sheet, index);

		// hide previous
		line.next("tr.list").change();

		var res = J("<tr>").addClass("list");
		J("<td>").appendTo(res);
		var cell = J("<td>").attr("colspan", "" + (sheet.columns.length + (sheet.isLevel() ? 1 : 0))).appendTo(res);
		var div = J("<div>").appendTo(cell);
		var content = J("<table>").appendTo(div);

		var cols = J("<tr>").addClass("head");
		J("<td>").addClass("start").appendTo(cols).click(function(_) {
			res.change();
		});
		for( name in ["path", "id"] )
			J("<td>").text(name).appendTo(cols);
		content.append(cols);
		var index = 0;
		for( rs in results ) {
			var l = J("<tr>").appendTo(content).addClass("clickable");
			J("<td>").text("" + (index++)).appendTo(l);
			var slast = rs.s[rs.s.length - 1];
			J("<td>").text(slast.s.name.split("@").join(".")+"."+slast.c).appendTo(l);
			var path = [];
			for( i in 0...rs.s.length ) {
				var s = rs.s[i];
				var oid = Reflect.field(rs.o.path[i], s.id);
				if( oid == null || oid == "" )
					path.push(s.s.name.split("@").pop() + "[" + rs.o.indexes[i]+"]");
				else
					path.push(oid);
			}
			J("<td>").text(path.join(".")).appendTo(l);
			l.click(function(e) {
				var key = null;
				for( i in 0...rs.s.length - 1 ) {
					var p = rs.s[i];
					key = p.s.getPath() + "@" + p.c + ":" + rs.o.indexes[i];
					openedList.set(key, true);
				}
				var starget = rs.s[0].s;
				sheetCursors.set(starget.name, {
					s : new cdb.Sheet(base,{ name : slast.s.name, separators : [], lines : [], columns : [], props : {} },key),
					x : -1,
					y : rs.o.indexes[rs.o.indexes.length - 1],
				});
				selectSheet(starget);
				e.stopPropagation();
			});
		}

		res.change(function(e) {
			res.remove();
			e.stopPropagation();
		});

		res.insertAfter(line);
	}

	#if false
	function changed( sheet : Sheet, c : Column, index : Int, old : Dynamic ) {
		switch( c.type ) {
		case TImage:
			var op = prepSnapshot();
			saveImages();
			commitSnapshot(op);
		case TTilePos:
			var op = prepSnapshot();
			// if we change a file that has moved, change it for all instances having the same file
			var obj = sheet.lines[index];
			var oldV : cdb.Types.TilePos = old;
			var newV : cdb.Types.TilePos = Reflect.field(obj, c.name);
			if( newV != null && oldV != null && oldV.file != newV.file && !sys.FileSystem.exists(getAbsPath(oldV.file)) && sys.FileSystem.exists(getAbsPath(newV.file)) ) {
				var change = false;
				for( i in 0...sheet.lines.length ) {
					var t : Dynamic = Reflect.field(sheet.lines[i], c.name);
					if( t != null && t.file == oldV.file ) {
						t.file = newV.file;
						change = true;
					}
				}
				if( change ) refresh();
			}
			sheet.updateValue(c, index, old);
			commitSnapshot(op);
		default:
			sheet.updateValue(c, index, old);
		}
		/*
		save();
		trace("Chg Row " + sheet.name + " ; " + index);

		if (c.type != TId) {
			trace("Conservative save");
//			saveConservative(sheet.name, index, c);
save();
		} else {
			trace("Full save");
			save();
		}
		*/
	}
	#end




	function changed(sheet: Sheet, c: Column, index: Int, old: Dynamic) {
		switch( c.type ) {
		// ========FROM MAIN=========
		case TImage:
			var op = prepSnapshot();
			saveImages();
			commitSnapshot(op);
		
		// =======FROM MAIN=======
		/*
		case TTilePos:
			
			
			// if we change a file that has moved, change it for all instances having the same file
			var obj = sheet.lines[index];
			var oldV : cdb.Types.TilePos = old;
			var newV : cdb.Types.TilePos = Reflect.field(obj, c.name);
			if( newV != null && 
				oldV != null && 
				oldV.file != newV.file && 
				!sys.FileSystem.exists(getAbsPath(oldV.file)) &&
				 sys.FileSystem.exists(getAbsPath(newV.file)) )
			{
				var op = prepSnapshot();
				var change = false;
				for( i in 0...sheet.lines.length ) {
					var t : Dynamic = Reflect.field(sheet.lines[i], c.name);
					if( t != null && t.file == oldV.file ) {
						t.file = newV.file;
						change = true;
					}
				}
				if( change ) refresh();
				commitSnapshot(op);
			}
//			sheet.updateValue(c, index, old);
		*/

		// ========= FROM SHEET ==========
		case TId:
			sheet.sync();

		case TInt if( sheet.isLevel() && (c.name == "width" || c.name == "height") ):
			var op = prepSnapshot();

			var obj = sheet.sheet.lines[index];
			var newW : Int = Reflect.field(obj, "width");
			var newH : Int = Reflect.field(obj, "height");
			var oldW = newW;
			var oldH = newH;
			if( c.name == "width" )
				oldW = old;
			else
				oldH = old;

			function remapTileLayer( v : cdb.Types.TileLayer ) {

				if( v == null ) return null;

				var odat = v.data.decode();
				var ndat = [];

				// object layer
				if( odat[0] == 0xFFFF )
					ndat = odat;
				else {
					var pos = 0;
					for( y in 0...newH ) {
						if( y >= oldH ) {
							for( x in 0...newW )
								ndat.push(0);
						} else if( newW <= oldW ) {
							for( x in 0...newW )
								ndat.push(odat[pos++]);
							pos += oldW - newW;
						} else {
							for( x in 0...oldW )
								ndat.push(odat[pos++]);
							for( x in oldW...newW )
								ndat.push(0);
						}
					}
				}
				return { file : v.file, size : v.size, stride : v.stride, data : cdb.Types.TileLayerData.encode(ndat, base.compress) };
			}

			for( c in sheet.columns ) {
				var v : Dynamic = Reflect.field(obj, c.name);
				if( v == null ) continue;
				switch( c.type ) {
				case TLayer(_):
					var v : cdb.Types.Layer<Int> = v;
					var odat = v.decode([for( i in 0...256 ) i]);
					var ndat = [];
					for( y in 0...newH )
						for( x in 0...newW ) {
							var k = y < oldH && x < oldW ? odat[x + y * oldW] : 0;
							ndat.push(k);
						}
					v = cdb.Types.Layer.encode(ndat, base.compress);
					Reflect.setField(obj, c.name, v);

				case TList:
					var s = sheet.getSub(c);
					if( s.hasColumn("x", [TInt,TFloat]) && s.hasColumn("y", [TInt,TFloat]) ) {
						var elts : Array<{ x : Float, y : Float }> = Reflect.field(obj, c.name);
						for( e in elts.copy() )
							if( e.x >= newW || e.y >= newH )
								elts.remove(e);
					} else if( s.hasColumn("data", [TTileLayer]) ) {
						var a : Array<{ data : cdb.Types.TileLayer }> = v;
						for( o in a )
							o.data = remapTileLayer(o.data);
					}

				case TTileLayer:
					Reflect.setField(obj, c.name, remapTileLayer(v));

				default:
				}
			}

		default:
			if( sheet.props.displayColumn == c.name ) {
				var obj = sheet.lines[index];
				for( cid in sheet.columns )
					if( cid.type == TId ) {
						var id = Reflect.field(obj, cid.name);
						if( id != null ) {
							var disp = Reflect.field(obj, c.name);
							if( disp == null ) disp = "#" + id;
							sheet.index.get(id).disp = disp;
						}
					}
			}

			if( sheet.props.displayIcon == c.name ) {
				var obj = sheet.lines[index];
				for( cid in sheet.columns )
					if( cid.type == TId ) {
						var id = Reflect.field(obj, cid.name);
						if( id != null && id != "" )
							sheet.index.get(id).ico = Reflect.field(obj, c.name);
					}
			}
		}
	}

	function tileHtml( v : cdb.Types.TilePos, ?isInline ) {
		var path = getAbsPath(v.file);
		if( !quickExists(path) ) {
			if( isInline ) return "";
			return '<span class="error">' + v.file + '</span>';
		}
		var id = UID++;
		var width = v.size * (v.width == null?1:v.width);
		var height = v.size * (v.height == null?1:v.height);
		var max = width > height ? width : height;
		var zoom = 1;//max <= 32 ? 2 : 64 / max;
		var inl = isInline ? 'display:inline-block;' : '';
		var url = "file://" + path;
		var html = '<div class="tile" id="_c${id}" style="width : ${Std.int(width * zoom)}px; height : ${Std.int(height * zoom)}px; background : url(\'$url\') -${Std.int(v.size*v.x*zoom)}px -${Std.int(v.size*v.y*zoom)}px; opacity:0; $inl"></div>';
		html += '<img src="$url" style="display:none" onload="$(\'#_c$id\').css({opacity:1, backgroundSize : ((this.width*$zoom)|0)+\'px \' + ((this.height*$zoom)|0)+\'px\' '+(zoom > 1 ? ", imageRendering : 'pixelated'" : "") +'}); if( this.parentNode != null ) this.parentNode.removeChild(this)"/>';
		return html;
	}

	public function valueHtml( c : Column, v : Dynamic, sheet : Sheet, obj : Dynamic ) : String {
		if( v == null ) {
			if( c.opt )
				return "&nbsp;";
			return '<span class="error">#NULL</span>';
		}
		return switch( c.type ) {
		case TInt, TFloat:
			switch( c.display ) {
			case Percent:
				(Math.round(v * 10000)/100) + "%";
			default:
				v + "";
			}
		case TId:
			v == "" ? '<span class="error">#MISSING</span>' : (base.getSheet(sheet.name).index.get(v).obj == obj ? v : '<span class="error">#DUP($v)</span>');
		case TString, TLayer(_):
			v == "–" ? "&nbsp;" : StringTools.replace(StringTools.htmlEscape(v), "\n","<br/>");
		case TRef(sname):
			if( v == "" )
				'<span class="error">#MISSING</span>';
			else {
				var s = base.getSheet(sname);
				var i = s.index.get(v);
				if (i == null) {
					return '<span class="error">#REF($v)</span>';
				} else {
					var output = "";
					if (!prefs.hideInlineIcons && i.ico != null)
						output += tileHtml(i.ico, true);
					output += StringTools.htmlEscape(i.disp);
					return output;
				}
			}
		case TBool:
			v?"Y":"N";
		case TEnum(values):
			values[v];
		case TImage:
			if( v == "" )
				'<span class="error">#MISSING</span>'
			else {
				var data = Reflect.field(imageBank, v);
				if( data == null )
					'<span class="error">#NOTFOUND($v)</span>'
				else
					'<img src="$data"/>';
			}
		case TList:
			var a : Array<Dynamic> = v;
			if (prefs.hideListPreviews) {
				return '<span class="array-shortened">List (</span>${a.length}<span class="array-shortened">)</span>';
			}
			var ps = sheet.getSub(c);
			var out : Array<String> = [];
			var size = 0;
			for( v in a ) {
				var vals = [];
				for( c in ps.columns )
					switch( c.type ) {
					case TList, TProperties:
						continue;
					default:
						vals.push(valueHtml(c, Reflect.field(v, c.name), ps, v));
					}
				var v = vals.length == 1 ? vals[0] : ""+vals;
				if( size > 500 ) {
					out.push("...");
					break;
				}
				var vstr = v;
				if( v.indexOf("<") >= 0 ) {
					vstr = ~/<img src="[^"]+" style="display:none"[^>]+>/g.replace(vstr, "");
					vstr = ~/<img src="[^"]+"\/>/g.replace(vstr, "[I]");
					vstr = ~/<div id="[^>]+><\/div>/g.replace(vstr, "[D]");
				}
				size += vstr.length;
				out.push(v);
			}
			if( out.length == 0 )
				return "";
			return out.join(", ");
		case TProperties:
			var ps = sheet.getSub(c);
			var out = [];
			for( c in ps.columns ) {
				var pval = Reflect.field(v, c.name);
				if( pval == null && c.opt ) continue;
				out.push("<span class='propName'>"+c.name+"</span> <span class='propVal'>"+valueHtml(c, pval, ps, v)+"</span>");
			}
			return out.join("<br/>");
		case TCustom(name):
			var t = base.getCustomType(name);
			var a : Array<Dynamic> = v;
			var cas = t.cases[a[0]];
			var str = cas.name;
			if( cas.args.length > 0 ) {
				str += "(";
				var out = [];
				var pos = 1;
				for( i in 1...a.length )
					out.push(valueHtml(cas.args[i-1], a[i], sheet, this));
				str += out.join(",");
				str += ")";
			}
			str;
		case TFlags(values):
			var v : Int = v;
			var flags = [];
			for( i in 0...values.length )
				if( v & (1 << i) != 0 )
					flags.push(StringTools.htmlEscape(values[i]));
			flags.length == 0 ? String.fromCharCode(0x2205) : flags.join("|<wbr>");
		case TColor:
			var id = UID++;
			'<div class="color" style="background-color:#${StringTools.hex(v,6)}"></div>';
		case TFile:
			var path = getAbsPath(v);
			var url = "file://" + path;
			var ext = v.split(".").pop().toLowerCase();
			var val = StringTools.htmlEscape(v);
			var html = v == "" ? '<span class="error">#MISSING</span>' : '<span title="$val">$val</span>';
			if( v != "" && !quickExists(path) )
				html = '<span class="error">' + html + '</span>';
			else if( ext == "png" || ext == "jpg" || ext == "jpeg" || ext == "gif" )
				html = '<span class="preview">$html<div class="previewContent"><div class="label"></div><img src="$url" onload="$(this).parent().find(\'.label\').text(this.width+\'x\'+this.height)"/></div></span>';
			if( v != "" )
				html += ' <input type="submit" value="open" onclick="_.openFile(\'$path\')"/>';
			html;
		case TTilePos:
			return tileHtml(v);
		case TTileLayer:
			var v : cdb.Types.TileLayer = v;
			var path = getAbsPath(v.file);
			if( !quickExists(path) )
				'<span class="error">' + v.file + '</span>';
			else
				'#DATA';
		case TDynamic:
			var str = Std.string(v).split("\n").join(" ").split("\t").join("");
			if( str.length > 33 ) str = str.substr(0, 33) + "...";
			str;
		}
	}

	function popupLine( sheet : Sheet, index : Int ) {
		var n = new Menu();
		var ___ = new MenuItem({type: separator});
		var nup = new MenuItem( { label : "Move Up" } );
		var ndown = new MenuItem( { label : "Move Down" } );
		var nsetidx = new MenuItem( { label: "Move To Index..."} );
		var nins = new MenuItem( { label : "Insert Row Below" } );
		var ndel = new MenuItem( { label : "Delete Row" } );
		var nsep = new MenuItem( { label : "New Separator Above", type : MenuItemType.checkbox } );
		var nref = new MenuItem( { label : "Show References" } );
		for( m in [nup, ndown, nsetidx, ___, nins, ndel, nsep, ___, nref] )
			n.append(m);
		var sepIndex = Lambda.indexOf(sheet.separators, index);
		nsep.checked = sepIndex >= 0;
		nins.click = function() {
			newLine(sheet, index);
		};
		nup.click = function() {
			var newIndex = sheet.moveLine(opStack, index, -1);
			setCursor(sheet, -1, newIndex);
		};
		ndown.click = function() {
			var newIndex = sheet.moveLine(opStack, index, 1);
			setCursor(sheet, -1, newIndex);
		};
		ndel.click = function() {
			var op = prepSnapshot();
			sheet.deleteLine(index);
			commitSnapshot(op);
		};
		nsetidx.click = function() {
			var captionSuffix = "";
			var newIndex : Int = index;
			while (true) {
				var caption = "Enter new index for row #" + index + " (min=0, max=" + (sheet.lines.length-1) + ")" + captionSuffix;
				var newIndexStr = window.window.prompt(caption, "" + index);
				if (newIndexStr == null) {
					return;
				}
				var parsedIndex = Std.parseInt(newIndexStr);
				if (parsedIndex == null || parsedIndex < 0 || parsedIndex >= sheet.lines.length) {
					captionSuffix = "\n⚠ You entered an illegal value";
					continue;
				}
				newIndex = parsedIndex;
				break;
			}
			opStack.push(new ops.RowMove(sheet.getNestedPos(index), newIndex));
			setCursor(sheet, -1, newIndex);
		};
		nsep.click = function() {
			var op = prepSnapshot();
			if( sepIndex >= 0 ) {
				sheet.separators.splice(sepIndex, 1);
				if( sheet.props.separatorTitles != null ) sheet.props.separatorTitles.splice(sepIndex, 1);
			} else {
				sepIndex = sheet.separators.length;
				for( i in 0...sheet.separators.length )
					if( sheet.separators[i] > index ) {
						sepIndex = i;
						break;
					}
				sheet.separators.insert(sepIndex, index);
				if( sheet.props.separatorTitles != null && sheet.props.separatorTitles.length > sepIndex )
					sheet.props.separatorTitles.insert(sepIndex, null);
			}
			sheet.props.separatorTitles[sepIndex] = "UNTITLED";
			commitSnapshot(op);
		};
		nref.click = function() {
			showReferences(sheet, index);
		};
		if( sheet.props.hide )
			nsep.enabled = false;
		n.popup(mousePos.x, mousePos.y);
	}

	function popupColumn( sheet : Sheet, c : Column, ?isProperties ) {
		var n = new Menu();
		var nedit = new MenuItem( { label : "Edit" } );
		var nins = new MenuItem( { label : "New Column..." } );
		var nleft = new MenuItem( { label : "Move Left" } );
		var nright = new MenuItem( { label : "Move Right" } );
		var ndel = new MenuItem( { label : "Delete Column" } );
		var ndisp = new MenuItem( { label : "Display Column", type : MenuItemType.checkbox } );
		var nicon = new MenuItem( { label : "Display Icon", type : MenuItemType.checkbox } );
		for( m in [nedit, nins, nleft, nright, ndel, ndisp, nicon] )
			n.append(m);

		switch( c.type ) {
		case TId, TString, TEnum(_), TFlags(_):
		case TInt, TFloat:
		default:
		}

		ndisp.checked = sheet.props.displayColumn == c.name;
		nicon.checked = sheet.props.displayIcon == c.name;

		ndisp.enabled = false;
		nicon.enabled = false;
		switch( c.type ) {
		case TString, TRef(_):
			ndisp.enabled = true;
		case TTilePos:
			nicon.enabled = true;
		default:
		}

		nedit.click = function() {
			newColumn(sheet.name, c);
		};
		nleft.click = function() {
			var index = Lambda.indexOf(sheet.columns, c);
			if( index > 0 ) {
				var op = prepSnapshot();
				sheet.columns.remove(c);
				sheet.columns.insert(index - 1, c);
				commitSnapshot(op);
			}
		};
		nright.click = function() {
			var index = Lambda.indexOf(sheet.columns, c);
			if( index < sheet.columns.length - 1 ) {
				var op = prepSnapshot();
				sheet.columns.remove(c);
				sheet.columns.insert(index + 1, c);
				commitSnapshot(op);
			}
		}
		ndel.click = function() {
			if( !isProperties || js.Browser.window.confirm("Do you really want to delete this property for all objects?") )
				deleteColumn(sheet, c.name);
		};
		ndisp.click = function() {
			var op = prepSnapshot();
			if( sheet.props.displayColumn == c.name ) {
				sheet.props.displayColumn = null;
			} else {
				sheet.props.displayColumn = c.name;
			}
			sheet.sync();
			commitSnapshot(op);
		};
		nicon.click = function() {
			var op = prepSnapshot();
			if( sheet.props.displayIcon == c.name ) {
				sheet.props.displayIcon = null;
			} else {
				sheet.props.displayIcon = c.name;
			}
			sheet.sync();
			commitSnapshot(op);
		};
		nins.click = function() {
			newColumn(sheet.name, Lambda.indexOf(sheet.columns,c) + 1);
		};
		n.popup(mousePos.x, mousePos.y);
	}


	function popupSheet( s : Sheet, li : JQuery ) {
		var n = new Menu();
		var nins = new MenuItem( { label : "Add Sheet" } );
		var nleft = new MenuItem( { label : "Move Left" } );
		var nright = new MenuItem( { label : "Move Right" } );
		var nren = new MenuItem( { label : "Rename" } );
		var ndel = new MenuItem( { label : "Delete" } );
		var nindex = new MenuItem( { label : "Add Index", type : MenuItemType.checkbox } );
		var ngroup = new MenuItem( { label : "Add Group", type : MenuItemType.checkbox } );
		for( m in [nins, nleft, nright, nren, ndel, nindex, ngroup] )
			n.append(m);
		nleft.click = function() {
			var op = prepSnapshot("move sheet left");
			var prev = -1;
			for( i in 0...base.sheets.length ) {
				var s2 = base.sheets[i];
				if( s == s2 ) break;
				if( !s2.props.hide ) prev = i;
			}
			if( prev < 0 ) return;
			base.sheets.remove(s);
			base.sheets.insert(prev, s);
			base.updateSheets();
			prefs.curSheet = prev;
			initContent();
			commitSnapshot(op);
		};
		nright.click = function() {
			var op = prepSnapshot("move sheet right");

			var sheets = [for( s in base.sheets ) if( !s.props.hide ) s];
			var index = sheets.indexOf(s);
			var next = sheets[index+1];
			if( index < 0 || next == null ) return;
			base.sheets.remove(s);
			index = base.sheets.indexOf(next) + 1;
			base.sheets.insert(index, s);

			// move sub sheets as well !
			var moved = [s];
			var delta = 0;
			for( ssub in base.sheets.copy() ) {
				var parent = ssub.getParent();
				if( parent != null && moved.indexOf(parent.s) >= 0 ) {
					base.sheets.remove(ssub);
					var idx = base.sheets.indexOf(s) + (++delta);
					base.sheets.insert(idx, ssub);
					moved.push(ssub);
				}
			}

			base.updateSheets();
			prefs.curSheet = base.sheets.indexOf(s);
			initContent();
			commitSnapshot(op);
		}
		ndel.click = function() {
			var op = prepSnapshot("delete sheet");
			base.deleteSheet(s);
			initContent();
			commitSnapshot(op);
		};
		nins.click = function() {
			newSheet();
		};
		nindex.checked = s.props.hasIndex;
		nindex.click = function() {
			var op = prepSnapshot();
			if( s.props.hasIndex ) {
				for( o in s.getLines() )
					Reflect.deleteField(o, "index");
				s.props.hasIndex = false;
			} else {
				for( c in s.columns )
					if( c.name == "index" ) {
						error("Column 'index' already exists");
						return;
					}
				s.props.hasIndex = true;
			}
			commitSnapshot(op);
		};
		ngroup.checked = s.props.hasGroup;
		ngroup.click = function() {
			var op = prepSnapshot();
			if( s.props.hasGroup ) {
				for( o in s.getLines() )
					Reflect.deleteField(o, "group");
				s.props.hasGroup = false;
			} else {
				for( c in s.columns )
					if( c.name == "group" ) {
						error("Column 'group' already exists");
						return;
					}
				s.props.hasGroup = true;
			}
			commitSnapshot(op);
		};
		nren.click = function() {
			li.dblclick();
		};
		if( s.isLevel() || (s.hasColumn("width", [TInt]) && s.hasColumn("height", [TInt]) && s.hasColumn("props",[TDynamic])) ) {
			var nlevel = new MenuItem( { label : "Level", type : MenuItemType.checkbox } );
			nlevel.checked = s.isLevel();
			n.append(nlevel);
			nlevel.click = function() {
				var op = prepSnapshot();
				if( s.isLevel() )
					Reflect.deleteField(s.props, "level");
				else
					s.props.level = {
						tileSets : {},
					}
				commitSnapshot(op);
			};
		}

		n.popup(mousePos.x, mousePos.y);
	}

	public function editCell( column : Column, v : JQuery, sheet : Sheet, rowIndex : Int ) {
		var rowModifyOp = new ops.RowModify(this, sheet.getNestedPos(rowIndex));
		opStack.pushNoApply(rowModifyOp);

		if( macEditMenu != null ) window.menu.append(macEditMenu);

		for (mi in editMenu.items)
			mi.enabled = false;

		var obj = sheet.lines[rowIndex];
		var val : Dynamic = Reflect.field(obj, column.name);
		var old = val;
		inline function getValue() {
			return valueHtml(column, val, sheet, obj);
		}
		inline function commitOpAndSave() {
			rowModifyOp.commitNewState(this);
		}
		inline function changed() {
			updateClasses(v, column, val);
			commitOpAndSave();
			this.changed(sheet, column, rowIndex, old);
		}

		var html = getValue();

		if( v.hasClass("edit") ) return;

		function editDone() {
			if( macEditMenu != null ) window.menu.remove(macEditMenu);
			for (mi in editMenu.items)
				mi.enabled = true;

			v.html(html);
			v.removeClass("edit");
			if (rowModifyOp.isUseless()) {
				trace("last operation was useless");
				opStack.removeLastOp(rowModifyOp);
			}
		}

		switch( column.type ) {

		// ---- Begin "Edit Text Box Cell" Monstrosity ----
		case TInt, TFloat, TString, TId, TCustom(_), TDynamic:
			v.empty();

			var inputBox = J(column.type==TString?"<textarea>":"<input>");

			v.addClass("edit");
			inputBox.appendTo(v);

			if( val != null ) {
				switch( column.type ) {
				case TCustom(t):
					inputBox.val(base.typeValToString(base.getCustomType(t), val));
				case TDynamic:
					inputBox.val(haxe.Json.stringify(val));
				default:
					inputBox.val(""+val);
				}
			}

			inputBox.change(function(e) e.stopPropagation());

			inputBox.keydown(function(e:js.jquery.Event) {
				switch( e.keyCode ) {
				case K.ESC:
					editDone();
				case K.ENTER:
					if( !inputBox.is("textarea") || !e.shiftKey && !e.altKey && !e.ctrlKey ) {
						inputBox.blur();
						e.preventDefault();
					}
				case K.UP, K.DOWN:
					if( !inputBox.is("textarea") )
						inputBox.blur();
					return;
				case K.TAB:
					inputBox.blur();
					moveCursor(e.shiftKey? -1:1, 0, false, false);
					haxe.Timer.delay(function() J(".cursor").dblclick(), 1);
					e.preventDefault();
				default:
				}
				e.stopPropagation();
			});

			inputBox.blur(function(_) {
				var newValue = inputBox.val();
				var oldValue = val;
				var prevObj = column.type == TId && oldValue != null ? base.getSheet(sheet.name).index.get(val) : null;
				var prevTarget = null;

				if( newValue == "" && column.opt ) {
					if( val != null ) {
						val = html = null;
						Reflect.deleteField(obj, column.name);
						changed();
					}
				} else {
					var val2 : Dynamic = switch( column.type ) {
					case TInt:
						Std.parseInt(newValue);
					case TFloat:
						var f = Std.parseFloat(newValue);
						if( Math.isNaN(f) ) null else f;
					case TId:
						base.r_ident.match(newValue) ? newValue : null;
					case TCustom(t):
						try base.parseTypeVal(base.getCustomType(t), newValue) catch( e : Dynamic ) null;
					case TDynamic:
						try base.parseDynamic(newValue) catch( e : Dynamic ) null;
					default:
						newValue;
					}
					if( val2 != val && val2 != null ) {

						prevTarget = base.getSheet(sheet.name).index.get(val2);
						if( column.type == TId && val != null && (prevObj == null || prevObj.obj == obj) ) {
							var m = new Map();
							m.set(val, val2);
							base.updateRefs(sheet, m);
						}

						val = val2;
						Reflect.setField(obj, column.name, val);
						changed();
						html = getValue();
					}
				}
				editDone();
				// handle #DUP in case we change the first element (creates a dup or removes one)
				if( column.type == TId &&
					prevObj != null &&
					oldValue != val &&
					((prevObj.obj == obj && base.getSheet(sheet.name).index.get(oldValue) != null) ||
					(prevTarget != null && base.getSheet(sheet.name).index.get(val).obj != prevTarget.obj)) )
				{
					refresh();
					return;
				}
			});

			switch( column.type ) {
			case TCustom(t):
				var t = base.getCustomType(t);
				inputBox.keyup(function(_) {
					var str = inputBox.val();
					try {
						if( str != "" )
							base.parseTypeVal(t, str);
						inputBox.removeClass("error");
					} catch( msg : String ) {
						window.window.alert(msg);
						inputBox.addClass("error");
					}
				});
			default:
			}
			inputBox.focus();
			inputBox.select();
		// ---- End "Edit Text Box Cell" Monstrosity ----

		case TEnum(values):
			v.empty();
			v.addClass("edit");

			var select = J("<select>");
			v.append(select);

			for( i in 0...values.length )
				J("<option>").attr("value", "" + i).attr(val == i ? "selected" : "_sel", "selected").text(values[i]).appendTo(select);

			if( column.opt )
				J("<option>").attr("value","-1").text("--- None ---").prependTo(select);

			select.change(function(e) {
				val = Std.parseInt(select.val());
				if( val < 0 ) {
					val = null;
					Reflect.deleteField(obj, column.name);
				} else
					Reflect.setField(obj, column.name, val);
				html = getValue();
				changed();
				editDone();
				e.stopPropagation();
			});

			select.keydown(function(e) {
				switch( e.keyCode ) {
				case K.LEFT, K.RIGHT:
					select.blur();
					return;
				case K.TAB:
					select.blur();
					moveCursor(e.shiftKey? -1:1, 0, false, false);
					haxe.Timer.delay(function() J(".cursor").dblclick(), 1);
					e.preventDefault();
				default:
				}
				e.stopPropagation();
			});

			select.blur(function(_) {
				editDone();
			});

			select.focus();
			
			var event : Dynamic = cast js.Browser.document.createEvent('MouseEvents');
			event.initMouseEvent('mousedown', true, true, js.Browser.window);
			select[0].dispatchEvent(event);

		case TRef(sname):
			var sdat = base.getSheet(sname);
			if( sdat == null ) return;
			v.empty();
			v.addClass("edit");

			var select = J("<select>");
			var elts = [for( d in sdat.all ){ id : d.id, ico : d.ico, text : d.disp }];
			if( column.opt || val == null || val == "" )
				elts.unshift( { id : "~", ico : null, text : "--- None ---" } );
			v.append(select);
			select.change(function(e) e.stopPropagation());

			var props : Dynamic = { data : elts };
			if( sdat.props.displayIcon != null ) {
				function buildElement(i) {
					var text = StringTools.htmlEscape(i.text);
					return J("<div>"+(i.ico == null ? "<div style='display:inline-block;width:16px'/>" : tileHtml(i.ico,true)) + " " + text+"</div>");
				}
				props.templateResult = props.templateSelection = buildElement;
			}
			(untyped select.select2)(props);
			(untyped select.select2)("val", val == null ? "" : val);
			(untyped select.select2)("open");

			select.change(function(e) {
				val = select.val();
				if( val == "~" ) {
					val = null;
					Reflect.deleteField(obj, column.name);
				} else
					Reflect.setField(obj, column.name, val);
				html = getValue();
				changed();
				editDone();
			});
			select.on("select2:close", function(_) editDone());

		case TBool:
			if( column.opt && val == false ) {
				val = null;
				Reflect.deleteField(obj, column.name);
			} else {
				val = !val;
				Reflect.setField(obj, column.name, val);
			}
			v.html(getValue());
			changed();

		case TImage:
			inline function loadImage(file : String) {
				var ext = file.split(".").pop().toLowerCase();
				if( ext == "jpeg" ) ext = "jpg";
				if( ext != "png" && ext != "gif" && ext != "jpg" ) {
					error("Unsupported image extension " + ext);
					return;
				}
				var bytes = sys.io.File.getBytes(file);
				var md5 = haxe.crypto.Md5.make(bytes).toHex();
				if( imageBank == null ) imageBank = { };
				if( !Reflect.hasField(imageBank, md5) ) {
					var data = "data:image/" + ext + ";base64," + new haxe.crypto.BaseCode(haxe.io.Bytes.ofString("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")).encodeBytes(bytes).toString();
					Reflect.setField(imageBank, md5, data);
				}
				val = md5;
				Reflect.setField(obj, column.name, val);
				v.html(getValue());
				changed();
			}

			if ( untyped v.dropFile != null ) {
				loadImage(untyped v.dropFile);
			} else {
				var input = J("<input>").attr("type", "file").css("display","none").change(function(e) {
					var j = JTHIS;
					loadImage(j.val());
					j.remove();
				});
				input.appendTo(J("body"));
				input.click();
			}

		case TFlags(values):
			var div = J("<div>").addClass("flagValues");
			div.click(function(e) e.stopPropagation());
			div.dblclick(function(e) e.stopPropagation());

			for( i in 0...values.length ) {
				var input = J("<input>");
				input.attr("type", "checkbox");
				input.prop("checked", val & (1 << i) != 0);
				input.change(function(e) {
					val &= ~(1 << i);
					if( JTHIS.prop("checked") ) val |= 1 << i;
					e.stopPropagation();
				});
				J("<label>").text(values[i]).appendTo(div).append(input);
			}

			v.empty();
			v.append(div);

			cursor.onchange = function() {
				if( column.opt && val == 0 ) {
					val = null;
					Reflect.deleteField(obj, column.name);
				} else
					Reflect.setField(obj, column.name, val);
				html = getValue();
				commitOpAndSave();
				editDone();
				
			};

		case TTileLayer:
			// nothing

		case TColor:
			var id = Std.random(0x1);
			v.html('<div class="modal" onclick="$(\'#_c${id}\').spectrum(\'toggle\')"></div><input type="text" id="_c${id}"/>');
			var spect : Dynamic = J('#_c$id');
			spect.spectrum({
				color : "#" + StringTools.hex(val, 6),
				showInput: true,
				showButtons: true,
				showInitial: true,
				preferredFormat: "hex3",
				change : function() spect.spectrum('hide'),
				hide : function(vcol:Dynamic) {
					var color = Std.parseInt("0x" + vcol.toHex());
					val = color;
					Reflect.setField(obj, column.name, color);
					v.html(getValue());
					commitOpAndSave();
				}
			});
			spect.spectrum("show");

		case TFile:
			v.empty();
			v.off();
			v.html(getValue());
			v.find("input").addClass("deletable").change(function(e) {
				if( Reflect.field(obj,column.name) != null ) {
					Reflect.deleteField(obj, column.name);
					v.html(getValue());
					commitOpAndSave();
				}
			});
			v.dblclick(function(_) {
				chooseFile(function(path) {
					val = path;
					Reflect.setField(obj, column.name, path);
					v.html(getValue());
					commitOpAndSave();
				});
			});

		case TList, TLayer(_), TTilePos, TProperties:
			throw "assert2";
		}
	}

	function updateCursor() {
		J(".selected").removeClass("selected");
		J(".cursor").removeClass("cursor");
		J(".cursorLine").removeClass("cursorLine");
		if( cursor.s == null )
			return;
		if( cursor.y < 0 ) {
			cursor.y = 0;
			cursor.select = null;
		}
		if( cursor.y >= cursor.s.lines.length ) {
			cursor.y = cursor.s.lines.length - 1;
			cursor.select = null;
		}
		var max = cursor.s.props.isProps ? 1 : cursor.s.columns.length;
		if( cursor.x >= max ) {
			cursor.x = max - 1;
			cursor.select = null;
		}
		var l = getLine(cursor.s, cursor.y);
		if( cursor.x < 0 ) {
			l.addClass("selected");
			if( cursor.select != null ) {
				var y = cursor.y;
				while( cursor.select.y != y ) {
					if( cursor.select.y > y ) y++ else y--;
					getLine(cursor.s, y).addClass("selected");
				}
			}
		} else {
			l.find("td.c").eq(cursor.x).addClass("cursor").closest("tr").addClass("cursorLine");
			if( cursor.select != null ) {
				var s = getSelection();
				for( y in s.y1...s.y2 + 1 )
					getLine(cursor.s, y).find("td.c").slice(s.x1, s.x2+1).addClass("selected");
			}
		}
		var e = l[0];
		if( e != null ) untyped e.scrollIntoViewIfNeeded();
	}

	public function refresh(text: String = "Working...") {
		trace("Refresh");
		var nowLoading = js.Browser.document.querySelector("#now-loading-text");
		nowLoading.innerText = text;
		nowLoading.className  = "";
		js.Browser.window.setTimeout(function() {
			var content = J("#content");
			content.empty();
			var t = J("<table>");
			checkCursor = true;
			fillTable(t, viewSheet);
			if( cursor.s != viewSheet && checkCursor ) setCursor(viewSheet,false);

			t.appendTo(content);
			J("<div>").appendTo(content).addClass("tableBottom");
			updateCursor();
			nowLoading.className = "no-display";
		});

	}

	inline function makeRelativePath( path : String ) : String {
		if ( prefs.curFile == null ) return path;

		var parts = path.split("\\").join("/").split("/");
		var base = prefs.curFile.split("\\").join("/").split("/");
		base.pop();
		while( parts.length > 1 && base.length > 0 && parts[0] == base[0] ) {
			parts.shift();
			base.shift();
		}
		if( parts.length == 0 || (parts[0] != "" && parts[0].charAt(1) != ":") )
			while( base.length > 0 ) {
				parts.unshift("..");
				base.pop();
			}
		return parts.join("/");
	}

	public function chooseFile( callb : String -> Void, ?cancel : Void -> Void ) {

		if( prefs.curFile == null ) {
			error("Please save CDB file first");
			if( cancel != null ) cancel();
			return;
		}


		var fs = J("#fileSelect");
		if( fs.attr("nwworkingdir") == null )
			fs.attr("nwworkingdir", new haxe.io.Path(prefs.curFile).dir);
		fs.off("change");
		fs.val("");
		fs.change(function(_) {
			fs.off("change");
			var path : String = fs.val();
			fs.val("");
			if( path == "" ) {
				if( cancel != null ) cancel();
				return;
			}
			fs.attr("nwworkingdir", ""); // keep path

			// make the path relative
			var relPath = makeRelativePath(path);

			callb(relPath);
		}).click();
	}

	function fillProps( content : JQuery, sheet : Sheet, props : Dynamic ) {

		content.addClass("sheet");
		content.attr("sheet", sheet.getPath());

		var available = [];
		var index = 0;
		for( c in sheet.columns ) {
			if( c.opt && !Reflect.hasField(props,c.name) ) {
				available.push(c);
				continue;
			}
			var v = Reflect.field(props, c.name);
			var l = J("<tr>").attr("colName",c.name).appendTo(content);
			var th = J("<th>").text(c.name).appendTo(l);
			var td = J("<td>").addClass("c").addClass("t_" + c.type.getName().substr(1).toLowerCase()).html(valueHtml(c, v, sheet, props)).appendTo(l);
			var index = index++;
			l.click(function(e) {
				setCursor(sheet, 0, index);
				e.stopPropagation();
			});
			th.mousedown(function(e) {
				if( e.which == 3 ) {
					haxe.Timer.delay(popupColumn.bind(sheet,c,true),1);
					e.preventDefault();
					l.click();
					return;
				}
			});
			td.dblclick(function(e) {
				editCell(c, td, sheet, 0);
				e.preventDefault();
				e.stopPropagation();
			});
		}

		// Sort alphabetically
		available.sort(function(a,b) { return a.name < b.name ? -1 : 1; });

		var end = J("<tr>").appendTo(content);
		end = J("<td>").attr("colspan", "2").appendTo(end);
		var sel = J("<select>").appendTo(end);
		J("<option>").attr("value", "").text("--- Choose ---").appendTo(sel);
		for( c in available )
			J("<option>").attr("value",c.name).text(c.name).appendTo(sel);
		J("<option>").attr("value","new").text("New property...").appendTo(sel);
		sel.change(function(e) {
			e.stopPropagation();
			var v = sel.val();
			if( v == "" )
				return;
			sel.val("");
			if( v == "new" ) {
				newColumn(sheet.name);
				return;
			}
			for( c in available )
				if( c.name == v ) {
					var op = prepSnapshot();
					Reflect.setField(props, c.name, base.getDefault(c, true));
					commitSnapshot(op);
					return;
				}
		});
	}

	function updateClasses(v:JQuery, c:Column, val:Dynamic) {
		switch( c.type ) {
			case TBool :
				v.removeClass("true, false").addClass( val==true ? "true" : "false" );

			case TInt, TFloat :
				v.removeClass("zero");
				if( val==0 )
					v.addClass("zero");

			default :
		}
	}

	function fillTable( content : JQuery, sheet : Sheet ) {
		if( sheet.columns.length == 0 ) {
			content.html('<a href="javascript:_.newColumn(\'${sheet.name}\')">Insert Column</a>');
			return;
		}

		var todo = [];
		var inTodo = false;
		var cols = J("<tr>").addClass("head");
		var colCount = sheet.columns.length;
		var lines = [];

		var types = [for( t in Type.getEnumConstructs(ColumnType) ) t.substr(1).toLowerCase()];

		if (sheet.isLevel()) {
			J("<th>").text("Edit").addClass("level-editor-extra-column").appendTo(cols);
			colCount++;
		}

		J("<th>").text("#").addClass("start").appendTo(cols).click(function(_) {
			if( sheet.props.hide )
				content.change();
			else
				J("tr.list table").change();
		});

		content.addClass("sheet");
		content.attr("sheet", sheet.getPath());
		content.click(function(e) e.stopPropagation());

		// Header Row
		for( cindex in 0...sheet.columns.length ) {
			var c = sheet.columns[cindex];
			var col = J("<th>");
			J("<span>").text(c.name).attr("title", c.name).appendTo(col);
			col.addClass( "t_"+c.type.getName().substr(1).toLowerCase() );
			if( sheet.props.displayColumn == c.name )
				col.addClass("display");
			col.mousedown(function(e) {
				if( e.which == 3 ) {
					haxe.Timer.delay(popupColumn.bind(sheet,c),1);
					e.preventDefault();
					return;
				}
			});
			col.dblclick(function(_) newColumn(sheet.name, c));
			cols.append(col);
		}

		for( index in 0...sheet.lines.length ) {
			var l = J("<tr>");
			lines.push(l);
			l.data("index", index);

			if (sheet.isLevel()) {
				var c = J("<a href='#'>Edit</a>");
				J("<td>").addClass("level-editor-extra-column").append(c).appendTo(l);
				c.click(function(_) {
					l.click();
					var found = null;
					for( l in levels )
						if( l.sheet == sheet && l.index == index )
							found = l;
					if( found == null ) {
						found = new Level(this, sheet, index);
						levels.push(found);
						selectLevel(found, true);
					} else
						selectLevel(found);
				});
			}

			var head = J("<td>").addClass("start").text("" + index);
			l.mousedown(function(e) {
				if( e.which == 3 ) {
					head.click();
					haxe.Timer.delay(popupLine.bind(sheet,index),1);
					e.preventDefault();
					return;
				}
			}).click(function(e) {
				if( e.shiftKey && cursor.s == sheet && cursor.x < 0 ) {
					cursor.select = { x : -1, y : index };
					updateCursor();
				} else
					setCursor(sheet, -1, index);
			});
			head.appendTo(l);

			for( cindex in 0...sheet.columns.length ) {
				var c = sheet.columns[cindex];
				var ctype = "t_" + types[Type.enumIndex(c.type)];

				var obj = sheet.lines[index];
				var val : Dynamic = Reflect.field(obj,c.name);
				var v = J("<td>").addClass(ctype).addClass("c");
				v.appendTo(l);

				updateClasses(v, c, val);

				var html = valueHtml(c, val, sheet, obj);
				if( html == "&nbsp;" ) v.text(" ") else if( html.indexOf('<') < 0 && html.indexOf('&') < 0 ) v.text(html) else v.html(html);
				v.data("index", cindex);
				v.click(function(e) {
					if( inTodo ) {
						// nothing
					} else if( e.shiftKey && cursor.s == sheet ) {
						cursor.select = { x : cindex, y : index };
						updateCursor();
						e.stopImmediatePropagation();
					} else
						setCursor(sheet, cindex, index);
					e.stopPropagation();
				});

				function set(val2:Dynamic) {
					var old = val;
					val = val2;
					if( val == null )
						Reflect.deleteField(obj, c.name);
					else
						Reflect.setField(obj, c.name, val);
					html = valueHtml(c, val, sheet, obj);
					v.html(html);
					this.changed(sheet, c, index, old);
				}

				switch( c.type ) {
				case TImage:
					v.find("img").addClass("deletable").change(function(e) {
						if( Reflect.field(obj,c.name) != null ) {
							var op = prepSnapshot();
							Reflect.deleteField(obj, c.name);
							commitSnapshot(op);
						}
					}).click(function(e) {
						JTHIS.addClass("selected");
						e.stopPropagation();
					});
					v.dblclick(function(_) editCell(c, v, sheet, index));
					v[0].addEventListener("drop", function(e : js.html.DragEvent ) {
						e.preventDefault();
						e.stopPropagation();
						if (e.dataTransfer.files.length > 0) {
							untyped v.dropFile = e.dataTransfer.files[0].path;
							editCell(c, v, sheet, index);
							untyped v.dropFile = null;
						}
					});
				case TList:
					var key = sheet.getPath() + "@" + c.name + ":" + index;
					v.click(function(e) {
						var next = l.next("tr.list");
						if( next.length > 0 ) {
							if( next.data("name") == c.name ) {
								next.change();
								return;
							}
							next.change();
						}
						next = J("<tr>").addClass("list").data("name", c.name);
						J("<td>").appendTo(next);
						var cell = J("<td>").attr("colspan", "" + colCount).appendTo(next);
						var div = J("<div>").appendTo(cell);
						var content = J("<table>").appendTo(div);
						var psheet = sheet.getSub(c);
						if( val == null ) {
							val = [];
							Reflect.setField(obj, c.name, val);
						}
						psheet = new cdb.Sheet(base,{
							columns : psheet.columns, // SHARE
							props : psheet.props, // SHARE
							name : psheet.name, // same
							lines : val, // ref
							separators : [], // none
						},key, { sheet : sheet, column : cindex, line : index });
						fillTable(content, psheet);
						next.insertAfter(l);
						v.text("...");
						v.addClass("opened");
						openedList.set(key,true);
						next.change(function(e) {
							if( c.opt && val.length == 0 ) {
								var op = prepSnapshot();
								val = null;
								Reflect.deleteField(obj, c.name);
								commitSnapshot(op);
							}
							html = valueHtml(c, val, sheet, obj);
							v.html(html);
							v.removeClass("opened");
							next.remove();
							openedList.remove(key);
							e.stopPropagation();
						});
						if( inTodo ) {
							// make sure we use the same instance
							if( cursor.s != null && cursor.s.getPath() == psheet.getPath() ) {
								cursor.s = psheet;
								checkCursor = false;
							}
						} else {
							setCursor(psheet);
						}
						e.stopPropagation();
					});
					if( openedList.get(key) )
						todo.push(function() v.click());
				case TProperties:


					var key = sheet.getPath() + "@" + c.name + ":" + index;
					v.click(function(e) {
						var next = l.next("tr.list");
						if( next.length > 0 ) {
							if( next.data("name") == c.name ) {
								next.change();
								return;
							}
							next.change();
						}
						next = J("<tr>").addClass("list").data("name", c.name);
						J("<td>").appendTo(next);
						var cell = J("<td>").attr("colspan", "" + colCount).appendTo(next);
						var div = J("<div>").appendTo(cell);
						var content = J("<table>").addClass("props").appendTo(div);
						var psheet = sheet.getSub(c);
						if( val == null ) {
							val = {};
							Reflect.setField(obj, c.name, val);
						}

						psheet = new cdb.Sheet(base,{
							columns : psheet.columns, // SHARE
							props : psheet.props, // SHARE
							name : psheet.name, // same
							lines : [for( f in Reflect.fields(val) ) null], // create as many fake lines as properties (for cursor navigation)
							separators : [], // none
						}, key, { sheet : sheet, column : cindex, line : index });
						@:privateAccess psheet.sheet.lines[0] = val; // ref
						fillProps(content, psheet, val);
						next.insertAfter(l);
						v.text("...");
						v.addClass("opened");
						openedList.set(key,true);
						next.change(function(e) {
							if( c.opt && Reflect.fields(val).length == 0 ) {
								var op = prepSnapshot();
								val = null;
								Reflect.deleteField(obj, c.name);
								commitSnapshot(op);
							}
							html = valueHtml(c, val, sheet, obj);
							v.html(html);
							v.removeClass("opened");
							next.remove();
							openedList.remove(key);
							e.stopPropagation();
						});
						if( inTodo ) {
							// make sure we use the same instance
							if( cursor.s != null && cursor.s.getPath() == psheet.getPath() ) {
								cursor.s = psheet;
								checkCursor = false;
							}
						} else {
							setCursor(psheet);
						}
						e.stopPropagation();
					});
					if( openedList.get(key) )
						todo.push(function() v.click());

				case TLayer(_):
					// nothing
				case TFile:
					v.find("input").addClass("deletable").change(function(e) {
						if( Reflect.field(obj,c.name) != null ) {
							var op = prepSnapshot("remove file");
							Reflect.deleteField(obj, c.name);
							commitSnapshot(op);
						}
					});
					v.dblclick(function(_) {
						chooseFile(function(path) {
							var op = prepSnapshot("set file");
							set(path);
							commitSnapshot(op);
						});
					});
					v[0].addEventListener("drop", function( e : js.html.DragEvent ) {
						if ( e.dataTransfer.files.length > 0 ) {
							e.preventDefault();
							e.stopPropagation();
							var op = prepSnapshot("set file");
							var path = untyped e.dataTransfer.files[0].path;
							var relPath = makeRelativePath(path);
							set(relPath);
							commitSnapshot(op);
						}
					});
				case TTilePos:

					v.find("div").addClass("deletable").change(function(e) {
						if( Reflect.field(obj,c.name) != null ) {
							var op = prepSnapshot("remove tile");
							Reflect.deleteField(obj, c.name);
							commitSnapshot(op);
						}
					});

					v.dblclick(function(_) {
						var rv : cdb.Types.TilePos = val;
						var file = rv == null ? null : rv.file;
						var size = rv == null ? 16 : rv.size;
						var posX = rv == null ? 0 : rv.x;
						var posY = rv == null ? 0 : rv.y;
						var width = rv == null ? null : rv.width;
						var height = rv == null ? null : rv.height;
						if( width == null ) width = 1;
						if( height == null ) height = 1;
						if( file == null ) {
							var i = index - 1;
							while( i >= 0 ) {
								var o = sheet.lines[i--];
								var v2 = Reflect.field(o, c.name);
								if( v2 != null ) {
									file = v2.file;
									size = v2.size;
									break;
								}
							}
						}

						function setVal() {
							var v : Dynamic = { file : file, size : size, x : posX, y : posY };
							if( width != 1 ) v.width = width;
							if( height != 1 ) v.height = height;
							set(v);
						}

						if( file == null ) {
							chooseFile(function(path) {
								file = path;
								setVal();
								v.dblclick();
							});
							return;
						}
						var dialog = J(J(".tileSelect").parent().html()).prependTo(J("body"));

						var maxWidth = 1000000, maxHeight = 1000000;

						dialog.find(".tileView").css( { backgroundImage : 'url("file://${getAbsPath(file)}")' } ).mousemove(function(e) {
							var off = JTHIS.offset();
							posX = size == 1 ? Std.int((e.pageX - off.left)/width)*width : Std.int((e.pageX - off.left)/size);
							posY = size == 1 ? Std.int((e.pageY - off.top)/height)*height : Std.int((e.pageY - off.top) / size);
							if( (posX + width) * size > maxWidth )
								posX = Std.int(maxWidth / size) - width;
							if( (posY + height) * size > maxHeight )
								posY = Std.int(maxHeight / size) - height;
							if( posX < 0 ) posX = 0;
							if( posY < 0 ) posY = 0;
							J(".tileCursor").not(".current").css({
								marginLeft : (size * posX - 1) + "px",
								marginTop : (size * posY - 1) + "px",
							});
						}).click(function(_) {
							var op = prepSnapshot();
							setVal();
							dialog.remove();
							commitSnapshot(op);
						});
						dialog.find("[name=size]").val("" + size).change(function(_) {
							size = Std.parseInt(JTHIS.val());
							J(".tileCursor").css( { width:(size*width)+"px", height:(size*height)+"px" } );
							J(".tileCursor.current").css( { marginLeft : (size * posX - 2) + "px", marginTop : (size * posY - 2) + "px" } );
						}).change();
						dialog.find("[name=width]").val("" + width).change(function(_) {
							width = Std.parseInt(JTHIS.val());
							J(".tileCursor").css( { width:(size*width)+"px", height:(size*height)+"px" } );
						}).change();
						dialog.find("[name=height]").val("" + height).change(function(_) {
							height = Std.parseInt(JTHIS.val());
							J(".tileCursor").css( { width:(size*width)+"px", height:(size*height)+"px" } );
						}).change();
						dialog.find("[name=cancel]").click(function(_) dialog.remove());
						dialog.find("[name=file]").click(function(_) {
							chooseFile(function(f) {
								var op = prepSnapshot();
								file = f;
								dialog.remove();
								setVal();
								commitSnapshot(op);
								v.dblclick();
							});
						});
						dialog.keydown(function(e) e.stopPropagation()).keypress(function(e) e.stopPropagation());
						dialog.show();

						var i = js.Browser.document.createImageElement();
						i.onload = function(_) {
							maxWidth = i.width;
							maxHeight = i.height;
							dialog.find(".tileView").height(i.height).width(i.width);
							dialog.find(".tilePath").text(file+" (" + i.width + "x" + i.height + ")");
						};
						i.src = "file://" + getAbsPath(file);

					});


				default:
					v.dblclick(function(e) editCell(c, v, sheet, index));
				}
			}
		}

		if( sheet.lines.length == 0 ) {
			var l = J('<tr><td colspan="${sheet.columns.length + 1}"><a href="javascript:_.insertLine()">Insert Row</a></td></tr>');
			l.find("a").click(function(_) setCursor(sheet));
			lines.push(l);
		}

		content.empty();
		content.append(cols);

		// Separators
		var snext = 0;
		for( i in 0...lines.length ) {
			while( sheet.separators[snext] == i ) {
				var sep = J("<tr>").addClass("separator").append('<td colspan="${colCount+1}">').appendTo(content);
				var content = sep.find("td");
				var title = if( sheet.props.separatorTitles != null ) sheet.props.separatorTitles[snext] else null;
				if( title != null ) content.text(title);
				var pos = snext;
				sep.dblclick(function(e) {
					content.empty();
					J("<input>").appendTo(content).focus().val(title == null ? "" : title).blur(function(_) {
						var op = prepSnapshot();
						title = JTHIS.val();
						JTHIS.remove();
						content.text(title);
						var titles = sheet.props.separatorTitles;
						if( titles == null ) titles = [];
						while( titles.length < pos )
							titles.push(null);
						titles[pos] = title == "" ? null : title;
						while( titles[titles.length - 1] == null && titles.length > 0 )
							titles.pop();
						if( titles.length == 0 ) titles = null;
						sheet.props.separatorTitles = titles;
						commitSnapshot(op);
					}).keypress(function(e) {
						e.stopPropagation();
					}).keydown(function(e) {
						if( e.keyCode == 13 ) { JTHIS.blur(); e.preventDefault(); } else if( e.keyCode == 27 ) content.text(title);
						e.stopPropagation();
					});
				});
				snext++;
			}
			content.append(lines[i]);
		}

		inTodo = true;
		for( t in todo ) t();
		inTodo = false;
	}

	@:keep function openFile( file : String ) {
		js.node.webkit.Shell.openItem(file);
	}

	public function setCursor( ?s, ?x=0, ?y=0, ?sel, update = true ) {
		
		cursor.s = s;
		cursor.x = x;
		cursor.y = y;
		cursor.select = sel;
		var ch = cursor.onchange;
		if( ch != null ) {
			cursor.onchange = null;
			ch();
		}
		trace("setCursor " + s.name + " " + x + " " + y + " " + sel);
		if( update ) updateCursor();
	}

	function selectSheet( s : Sheet, manual = true ) {
		viewSheet = s;
		pages.curPage = -1;
		cursor = sheetCursors.get(s.name);
		if( cursor == null ) {
			cursor = {
				x : 0,
				y : 0,
				s : s,
			};
			sheetCursors.set(s.name, cursor);
		}
		if( manual ) {
			if( level != null ) level.dispose();
			level = null;
		}
		prefs.curSheet = Lambda.indexOf(base.sheets, s);
		J("#sheets li").removeClass("active").filter("#sheet_" + prefs.curSheet).addClass("active");
		if( manual ) refresh("Loading " + s.name + "...");
	}

	function selectLevel( l : Level, initContentAfterwards : Bool = false ) {
		var nowLoading = js.Browser.document.querySelector("#now-loading-text");
		nowLoading.innerText = "Working...";
		nowLoading.className  = "";
		js.Browser.window.setTimeout(function() {
			nowLoading.className = "no-display";
			if( level != null ) level.dispose();
			pages.curPage = -1;
			level = l;
			level.init();
			J("#sheets li").removeClass("active").filter("#level_" + l.sheetPath.split(".").join("_") + "_" + l.index).addClass("active");

			if (initContentAfterwards) {
				initContent();
			}
		});
	}


	public function closeLevel( l : Level ) {
		l.dispose();
		var i = Lambda.indexOf(levels, l);
		levels.remove(l);
		if( level == l )
			level = null;
		initContent();
	}


	function newSheet() {
		var s = J("#newsheet").show();
		s.find("#sheet_name").val("");
		s.find("#sheet_level").removeAttr("checked");
	}

	function deleteColumn( sheet : Sheet, ?cname) {
		var op = prepSnapshot();
		if( cname == null ) {
			sheet = getSheet(colProps.sheet);
			cname = colProps.ref.name;
		}
		if( !sheet.deleteColumn(cname) )
			return;
		J("#newcol").hide();
		commitSnapshot(op);
	}

	function editTypes() {
		var op = prepSnapshot();

		if( typesStr == null ) {
			var tl = [];
			for( t in base.getCustomTypes() )
				tl.push("enum " + t.name + " {\n" + base.typeCasesToString(t, "\t") + "\n}");
			typesStr = tl.join("\n\n");
		}
		var content = J("#content");
		content.html(J("#editTypes").html());
		var text = content.find("textarea");
		var apply = content.find("input.button").first();
		var cancel = content.find("input.button").eq(1);
		var types : Array<CustomType>;
		text.change(function(_) {
			var nstr = text.val();
			if( nstr == typesStr ) return;
			typesStr = nstr;
			var errors = [];
			var t = StringTools.trim(typesStr);
			var r = ~/^enum[ \r\n\t]+([A-Za-z0-9_]+)[ \r\n\t]*\{([^}]*)\}/;
			var oldTMap = @:privateAccess base.tmap;
			var descs = [];
			var tmap = new Map();
			@:privateAccess base.tmap = tmap;
			types = [];
			while( r.match(t) ) {
				var name = r.matched(1);
				var desc = r.matched(2);
				if( tmap.get(name) != null )
					errors.push("Duplicate type " + name);
				var td = { name : name, cases : [] } ;
				tmap.set(name, td);
				descs.push(desc);
				types.push(td);
				t = StringTools.trim(r.matchedRight());
			}
			for( t in types ) {
				try
					t.cases = base.parseTypeCases(descs.shift())
				catch( msg : Dynamic )
					errors.push(msg);
			}
			@:privateAccess base.tmap = oldTMap;
			if( t != "" )
				errors.push("Invalid " + StringTools.htmlEscape(t));
			window.window.alert(errors.length == 0 ? null : errors.join("\n\n"));
			if( errors.length == 0 ) apply.removeAttr("disabled") else apply.attr("disabled","");
		});
		text.keydown(function(e) {
			if( e.keyCode == 9 ) { // TAB
				e.preventDefault();
				new js.Selection(cast text[0]).insert("\t", "", "");
			}
			e.stopPropagation();
		});
		text.keyup(function(e) {
			text.change();
			e.stopPropagation();
		});
		text.val(typesStr);
		cancel.click(function(_) {
			typesStr = null;
			// prevent partial changes being made
			rollbackSnapshot(op);

			initContent();
		});
		apply.click(function(_) {
			var tpairs = base.makePairs(base.getCustomTypes(), types);
			// check if we can remove some types used in sheets
			for( p in tpairs )
				if( p.b == null ) {
					var t = p.a;
					for( s in base.sheets )
						for( c in s.columns )
							switch( c.type ) {
							case TCustom(name) if( name == t.name ):
								error("Type "+name+" used by " + s.name + "@" + c.name+" cannot be removed");
								return;
							default:
							}
				}
			// add new types
			for( t in types )
				if( !Lambda.exists(tpairs,function(p) return p.b == t) )
					base.getCustomTypes().push(t);
			// update existing types
			for( p in tpairs ) {
				if( p.b == null )
					base.getCustomTypes().remove(p.a);
				else
					try base.updateType(p.a, p.b) catch( msg : String ) {
						error("Error while updating " + p.b.name + " : " + msg);
						return;
					}
			}

			// full rebuild
			initContent();

			commitSnapshot(op);

			typesStr = null;
		});
		typesStr = null;
		text.change();
	}

	function newColumn( ?sheetName : String, ?ref : Column, ?index : Int ) {
		var form = J("#newcol form");

		colProps = { sheet : sheetName, ref : ref, index : index };

		var sheets = J("[name=sheet]");
		sheets.empty();
		for( i in 0...base.sheets.length ) {
			var s = base.sheets[i];
			if( s.props.hide ) continue;
			J("<option>").attr("value", "" + i).text(s.name).appendTo(sheets);
		}

		var types = J("[name=ctype]");
		types.empty();
		types.off("change");
		types.change(function(_) {
			J("#col_options").toggleClass("t_edit",types.val() != "");
		});
		J("<option>").attr("value", "").text("--- Select ---").appendTo(types);
		for( t in base.getCustomTypes() )
			J("<option>").attr("value", "" + t.name).text(t.name).appendTo(types);

		form.removeClass("edit").removeClass("create");

		if( ref != null ) {
			form.addClass("edit");
			form.find("[name=name]").val(ref.name);
			form.find("[name=type]").val(ref.type.getName().substr(1).toLowerCase()).change();
			form.find("[name=req]").prop("checked", !ref.opt);
			form.find("[name=display]").val(ref.display == null ? "0" : Std.string(ref.display));
			form.find("[name=localizable]").prop("checked", ref.kind==Localizable);
			switch( ref.type ) {
			case TEnum(values), TFlags(values):
				form.find("[name=values]").val(values.join(","));
			case TRef(sname), TLayer(sname):
				form.find("[name=sheet]").val( "" + base.sheets.indexOf(getSheet(sname)));
			case TCustom(name):
				form.find("[name=ctype]").val(name);
			default:
			}
		} else {
			form.addClass("create");
			form.find("input").not("[type=submit]").val("");
			form.find("[name=req]").prop("checked", true);
			form.find("[name=localizable]").prop("checked", false);
		}
		types.change();

		J("#newcol").show();
	}

	function newLine( sheet : Sheet, ?index : Int ) {
		var op = prepSnapshot();
		sheet.newLine(index);
		commitSnapshot(op);
	}

	function insertLine() {
		if( cursor.s != null ) newLine(cursor.s);
	}

	function createSheet( name : String, level : Bool ) {
		var op = prepSnapshot();
		name = StringTools.trim(name);
		if( !base.r_ident.match(name) ) {
			error("Invalid sheet name");
			return;
		}
		var s = base.createSheet(name);
		if( s == null ) {
			error("Sheet name already in use");
			return;
		}
		J("#newsheet").hide();
		prefs.curSheet = base.sheets.length - 1;
		s.sync();
		if( level ) initLevel(s);
		initContent();
		commitSnapshot(op);
	}

	function initLevel( s : Sheet ) {
		var cols = [ { n : "id", t : TId }, { n : "width", t : TInt }, { n : "height", t : TInt }, { n : "props", t : TDynamic }, { n : "tileProps", t : TList }, { n : "layers", t : TList } ];
		for( c in cols ) {
			if( s.hasColumn(c.n) ) {
				if( !s.hasColumn(c.n, [c.t]) ) {
					error("Column " + c.n + " already exists but does not have type " + c.t);
					return;
				}
			} else {
				inline function mkCol(n, t) : Column return { name : n, type : t, typeStr : null };
				var col = mkCol(c.n, c.t);
				s.addColumn(col);
				if( c.n == "layers" ) {
					var s = s.getSub(col);
					s.addColumn(mkCol("name",TString));
					s.addColumn(mkCol("data",TTileLayer));
				}
			}
		}
		if( s.props.level == null )
			s.props.level = { tileSets : { } };
		if( s.lines.length == 0 && s.parent == null ) {
			var o : Dynamic = s.newLine();
			o.width = 128;
			o.height = 128;
		}
	}

	function createColumn() {
		var op = prepSnapshot();

		var v : Dynamic<String> = { };
		var cols = J("#col_form input, #col_form select").not("[type=submit]");
		for( i in cols.elements() )
			Reflect.setField(v, i.attr("name"), i.attr("type") == "checkbox" ? (i.is(":checked")?"on":null) : i.val());

		var sheet = colProps.sheet == null ? viewSheet : getSheet(colProps.sheet);
		var refColumn = colProps.ref;

		var t : ColumnType = switch( v.type ) {
		case "id": TId;
		case "int": TInt;
		case "float": TFloat;
		case "string": TString;
		case "bool": TBool;
		case "enum":
			var vals = StringTools.trim(v.values).split(",");
			if( vals.length == 0 ) {
				error("Missing value list");
				return;
			}
			TEnum([for( f in vals ) StringTools.trim(f)]);
		case "flags":
			var vals = StringTools.trim(v.values).split(",");
			if( vals.length == 0 ) {
				error("Missing value list");
				return;
			}
			TFlags([for( f in vals ) StringTools.trim(f)]);
		case "ref":
			var s = base.sheets[Std.parseInt(v.sheet)];
			if( s == null ) {
				error("Sheet not found");
				return;
			}
			TRef(s.name);
		case "image":
			TImage;
		case "list":
			TList;
		case "custom":
			var t = base.getCustomType(v.ctype);
			if( t == null ) {
				error("Type not found");
				return;
			}
			TCustom(t.name);
		case "color":
			TColor;
		case "layer":
			var s = base.sheets[Std.parseInt(v.sheet)];
			if( s == null ) {
				error("Sheet not found");
				return;
			}
			TLayer(s.name);
		case "file":
			TFile;
		case "tilepos":
			TTilePos;
		case "tilelayer":
			TTileLayer;
		case "dynamic":
			TDynamic;
		case "properties":
			TProperties;
		default:
			return;
		}
		var c : Column = {
			type : t,
			typeStr : null,
			name : v.name,
		};
		if( v.req != "on" ) c.opt = true;
		if( v.display != "0" ) c.display = cast Std.parseInt(v.display);
		if( v.localizable == "on" ) c.kind = Localizable;

		if( refColumn != null ) {
			var err = base.updateColumn(sheet, refColumn, c);
			if( err != null ) {
				// might have partial change
				commitSnapshot(op);
				error(err);
				return;
			}
		} else {
			var err = sheet.addColumn(c, colProps.index);
			if( err != null ) {
				error(err);
				return;
			}
			// automatically add to current selection
			if( sheet.props.isProps && cursor.s.columns == sheet.columns ) {
				var obj = cursor.s.lines[0];
				if( obj != null )
					Reflect.setField(obj, c.name, base.getDefault(c, true));
			}
		}

		J("#newcol").hide();
		for( c in cols.elements() )
			c.val("");
		commitSnapshot(op);
	}

	public function initContent() {
		(untyped J("body").spectrum).clearAll();
		var sheets = J("ul#sheets");
		sheets.children().remove();
		for( i in 0...base.sheets.length ) {
			var s = base.sheets[i];
			if( s.props.hide ) continue;
			var li = J("<li>");
			li.attr("title", s.name);
			li.text(s.name).attr("id", "sheet_" + i).appendTo(sheets).click(function(_) selectSheet(s)).dblclick(function(_) {
				li.empty();
				J("<input>").val(s.name).appendTo(li).focus().blur(function(_) {
					li.text(s.name);
					var name = JTHIS.val();
					if( !base.r_ident.match(name) ) {
						error("Invalid sheet name");
						return;
					}
					var f = base.getSheet(name);
					if( f != null ) {
						if( f != s ) error("Sheet name already in use");
						return;
					}

					var op = prepSnapshot("rename sheet");

					var old = s.name;
					s.rename(name);

					base.mapType(function(t) {
						return switch( t ) {
						case TRef(o) if( o == old ):
							TRef(name);
						case TLayer(o) if( o == old ):
							TLayer(name);
						default:
							t;
						}
					});

					for( s in base.sheets )
						if( StringTools.startsWith(s.name, old + "@") )
							s.rename(name + "@" + s.name.substr(old.length + 1));

					initContent();
					commitSnapshot(op);
				}).keydown(function(e) {
					if( e.keyCode == 13 ) JTHIS.blur() else if( e.keyCode == 27 ) initContent();
					e.stopPropagation();
				}).keypress(function(e) {
					e.stopPropagation();
				});
			}).mousedown(function(e) {
				if( e.which == 3 ) {
					haxe.Timer.delay(popupSheet.bind(s,li),1);
					e.stopPropagation();
				}
			});
		}
		pages.updateTabs();
		var s = base.sheets[prefs.curSheet];
		if( s == null ) s = base.sheets[0];
		if( s != null ) selectSheet(s, false);

		var old = levels;
		var lcur = null;
		levels = [];
		for( level in old ) {
			if( base.getSheet(level.sheetPath) == null ) continue;
			var s = getSheet(level.sheetPath);
			if( s.lines.length < level.index )
				continue;
			var l = new Level(this, s, level.index);
			if( level == this.level ) lcur = l;
			levels.push(l);
			var li = J("<li>");
			var name = level.getName();
			if( name == "" ) name = "???";
			li.text(name).attr("id", "level_" + l.sheetPath.split(".").join("_") + "_" + l.index).appendTo(sheets).click(function(_) selectLevel(l));
		}

		if( pages.curPage >= 0 )
			pages.select();
		else if( lcur != null )
			selectLevel(lcur);
		else if( base.sheets.length == 0 )
			J("#content").html("<a href='javascript:_.newSheet()'>Create a sheet</a>");
		else
			refresh();
	}

	function doUndo() {
		opStack.undo();
		initContent();
	}

	function doRedo() {
		opStack.redo();
		initContent();
	}

	function initMenu() {
//		window.showDevTools();
		var modifier = "ctrl";
		var menu = Menu.createWindowMenu();
		if(Sys.systemName().indexOf("Mac") != -1) {
			modifier = "cmd";
		}
		var mfile = new MenuItem({ label : "File" });
		var mfiles = new Menu();
		var mnew = new MenuItem( { label : "New", key : "N", modifiers : modifier } );
		var mopen = new MenuItem( { label : "Open...", key : "O", modifiers : modifier } );
		var mrecent = new MenuItem( { label : "Recent Files" } );
		var msave = new MenuItem( { label : "Save", key : "S", modifiers : modifier } );
		var msaveas = new MenuItem( { label : "Save As...", key : "S", modifiers : "shift+" + modifier } );
		var msaveasmonofile = new MenuItem( { label : "Export Legacy Monofile..." } );
		var mreload = new MenuItem( { label : "Reload From Disk", key : "F5"} );
		var mclean = new MenuItem( { label : "Clean Images" } );
		var mexport = new MenuItem( { label : "Export Localized texts" } );
		mcompress = new MenuItem( { label : "Enable Compression", type : MenuItemType.checkbox } );
		mcompress.click = function() {
			base.compress = mcompress.checked;
		};
		var mexit = new MenuItem( { label : "Exit", key : "Q", modifiers : modifier } );

		mnew.click = function() {
			prefs.curFile = null;
			load(true);
		};

		mopen.click = function() {
			var i = J("<input>").attr("type", "file").css("display","none").change(function(e) {
				var j = JTHIS;
				prefs.curFile = j.val();
				load();
				j.remove();
			});
			i.appendTo(J("body"));
			i.click();
		};

		msave.click = function() {
			if (prefs.curFile == "" || prefs.curFile == null) {
				msaveas.click();
			} else {
				save();
			}
		};

		msaveas.click = function() {
			var i = J("<input>").attr("type", "file").attr("nwsaveas","new.cdb").css("display","none").change(function(e) {
				var j = JTHIS;
				prefs.curFile = j.val();
				save();
				j.remove();
			});
			i.appendTo(J("body"));
			i.click();
		};

		msaveasmonofile.click = function() {
			var i = J("<input>").attr("type", "file").attr("nwsaveas","monofile.cdb").css("display","none").change(function(e) {
				var j = JTHIS;
				sys.io.File.saveContent(j.val(), base.saveMonofileLegacyFormat());
				j.remove();
			});
			i.appendTo(J("body"));
			i.click();
		};

		mreload.click = function() {
			var doReload = true;
			if (opStack.hasUnsavedChanges()) {
				doReload = window.window.confirm("There are unsaved changes.\nReload anyway?");
			}
			if (doReload) {
				load();
			}
		};

		mclean.click = function() {
			var op = prepSnapshot();
			var lcount = @:privateAccess base.cleanLayers();
			var icount = 0;
			if( imageBank != null ) {
				var count = Reflect.fields(imageBank).length;
				cleanImages();
				var count2 = Reflect.fields(imageBank).length;
				icount = count - count2;
				if( count2 == 0 ) imageBank = null;
			}
			error([
				lcount + " tileset data removed",
				icount + " unused images removed"
			].join("\n"));
			refresh();
			if( lcount > 0 ) commitSnapshot(op);
			if( icount > 0 ) saveImages();
		};

		mexit.click = function() {
			Sys.exit(0);
		};

		var mrecents = new Menu();
		for( file in prefs.recent ) {
			if( file == null ) continue;
			var m = new MenuItem( { label : file } );
			m.click = function() {
				prefs.curFile = file;
				load();
			};
			mrecents.append(m);
		}
		mrecent.submenu = mrecents;

		var msep = new MenuItem({type:separator});
		for( m in [mnew, msep, mopen, mrecent, msep, msave, msaveas, msaveasmonofile, msep, mreload, msep, mclean, mcompress, mexport, msep, mexit] )
			mfiles.append(m);
		mfile.submenu = mfiles;

		mexport.click = function() {

			var lang = new cdb.Lang(@:privateAccess base.data);
			var xml = lang.buildXML();
			var i = J("<input>").attr("type", "file").attr("nwsaveas","export.xml").css("display","none").change(function(e) {
				var j = JTHIS;
				var file = j.val();
				sys.io.File.saveContent(file, String.fromCharCode(0xFEFF)+xml); // prefix with BOM
				j.remove();
			});
			i.appendTo(J("body"));
			i.click();

		};

		// -----------------------------------
		var mi_edit = new MenuItem({ label : "Edit" });
		var m_edit = new Menu();
		mi_edit.submenu = m_edit;

		var mi_undo = new MenuItem({ label : "Undo", key : "Z", modifiers: modifier });
		mi_undo.click = function() { if (pages.curPage < 0) doUndo(); };

		var mi_redo = new MenuItem({ label : "Redo", key : "Y", modifiers: modifier });
		mi_redo.click = function() { if (pages.curPage < 0) doRedo(); };

		var mi_cut = new MenuItem({ label : "Cut", key : "X", modifiers : modifier });
		mi_cut.click = function() { if (isInCDB()) { doCopy(); doDeleteSelectedRow(); } };

		var mi_copy = new MenuItem({ label : "Copy", key : "C", modifiers : modifier });
		mi_copy.click = function() { if (isInCDB()) { doCopy(); } };

		var mi_paste = new MenuItem({ label : "Paste", key : "V", modifiers : modifier });
		mi_paste.click = function() { if (isInCDB()) { doPaste(); } };

		var mi_find = new MenuItem({ label : "Find", key : "F", modifiers : modifier });
		mi_find.click = function() {
			if (!isInCDB()) return;
			var s = J("#search");
			s.show();
			s.find("input").focus().select();
		}

		for (mi in [mi_undo, mi_redo, msep, mi_cut, mi_copy, mi_paste, msep, mi_find]) {
			m_edit.append(mi);
		}

		editMenu = m_edit;

		// -----------------------------------

		var mi_sheet = new MenuItem({ label : "Sheet" });
		var m_sheet = new Menu();
		mi_sheet.submenu = m_sheet;

		var mi_newSheet = new MenuItem({ label : "New Sheet..." });
		mi_newSheet.click = newSheet;

		var mi_newColumn = new MenuItem({ label: "New Column..." });
		mi_newColumn.click = function() { newColumn(); };

		var mi_newRow = new MenuItem({ label: "New Row", key: "Insert" });
		mi_newRow.click = function() {
			if (!isInCDB()) return;
			if (cursor.s == null) return;
			newLine(cursor.s, cursor.y);
			moveCursor(0, 1, false, false);
		};

		var mi_ref1 = new MenuItem({ label : "Show References", key : "F3" });
		mi_ref1.click = function() { 
			if (isInCDB() && cursor.s != null)
				showReferences(cursor.s, cursor.y);
		};

		var mi_ref2 = new MenuItem({ label : "Go To Reference", key : "F4" });
		mi_ref2.click = function() {
			if (isInCDB())
				openTableReferencedBySelectedCell();
		};

		function goToNextSheet(delta: Int) {
			var sheets = base.sheets.filter(function(s) return !s.props.hide);
			var pos = (level == null ? Lambda.indexOf(sheets, viewSheet) : sheets.length + Lambda.indexOf(levels, level)) + delta;
			if (pos == -1) pos = sheets.length + levels.length;
			var s = sheets[pos % (sheets.length + levels.length)];
			if( s != null ) selectSheet(s) else {
				var level = levels[pos - sheets.length];
				if( level != null ) selectLevel(level);
			}
		}

		var mi_nextSheet = new MenuItem({ label : "Next Sheet", key : "Tab", modifiers : modifier });
		mi_nextSheet.click = function() { goToNextSheet(1); };

		var mi_prevSheet = new MenuItem({ label : "Previous Sheet", key : "Tab", modifiers : modifier + "+shift" });
		mi_prevSheet.click = function() { goToNextSheet(-1); };

		for (mi in [mi_newSheet, mi_newColumn, mi_newRow, msep, mi_ref1, mi_ref2, msep, mi_nextSheet, mi_prevSheet]) {
			m_sheet.append(mi);
		}

		// -----------------------------------


		window.zoomLevel = prefs.zoomLevel;
		var mi_view = new MenuItem({label: "View"});
		var m_view = new Menu();
		mi_view.submenu = m_view;

		var mi_hideListPreviews = new MenuItem({label: "Hide List Previews", type: checkbox});
		mi_hideListPreviews.checked = prefs.hideListPreviews;
		mi_hideListPreviews.click = function() {
			prefs.hideListPreviews = !prefs.hideListPreviews;
			mi_hideListPreviews.checked = prefs.hideListPreviews;
			refresh();
		};
		m_view.append(mi_hideListPreviews);

		var mi_hideInlineIcons = new MenuItem({label: "Hide Inline Icons", type: checkbox});
		mi_hideInlineIcons.checked = prefs.hideInlineIcons;
		mi_hideInlineIcons.click = function() {
			prefs.hideInlineIcons = !prefs.hideInlineIcons;
			mi_hideInlineIcons.checked = prefs.hideInlineIcons;
			refresh();
		};
		m_view.append(mi_hideInlineIcons);

		m_view.append(new MenuItem({type: separator}));

		var mi_zoomLevels = new Map<Int, MenuItem>();
		for (i in -4...7) {
			var mi_zoom_n = new MenuItem({label: "Zoom " + Math.round(Math.pow(1.2, i) * 100) + "%", type: checkbox});
			mi_zoom_n.click = function() {
				if (mi_zoomLevels.exists(window.zoomLevel))
					mi_zoomLevels[window.zoomLevel].checked = false;
				window.zoomLevel = i;
				mi_zoom_n.checked = true;
				prefs.zoomLevel = window.zoomLevel;
				savePrefs();
			};
			m_view.append(mi_zoom_n);
			mi_zoomLevels[i] = mi_zoom_n;
		}
		if (mi_zoomLevels.exists(window.zoomLevel))
			mi_zoomLevels[window.zoomLevel].checked = true;

		// -----------------------------------

		if(Sys.systemName().indexOf("Mac") != -1) {
			menu.createMacBuiltin("CastleDB", {hideEdit: false, hideWindow: true}); // needed so copy&paste inside INPUTs work
			menu.removeAt(0); // remove default menu
			macEditMenu = menu.items[0]; // save default edit menu
			menu.removeAt(0); // remove default edit menu
			menu.insert(mfile, 0); // put it before the default Edit menu
		}
		else {
			menu.append(mfile);
			menu.append(mi_edit);
			menu.append(mi_view);
			menu.append(mi_sheet);
		}

		window.menu = menu;
		if( prefs.windowPos.x > 0 && prefs.windowPos.y > 0 ) window.moveTo(prefs.windowPos.x, prefs.windowPos.y);
		if( prefs.windowPos.w > 50 && prefs.windowPos.h > 50 ) window.resizeTo(prefs.windowPos.w, prefs.windowPos.h);
		window.show();
		if( prefs.windowPos.max ) window.maximize();
		window.on('close', function() {
			if( opStack.hasUnsavedChanges() ) {
				if( !js.Browser.window.confirm("Quit without saving changes?") )
					return;
			}
			if( !prefs.windowPos.max )
				prefs.windowPos = {
					x : window.x,
					y : window.y,
					w : window.width,
					h : window.height,
					max : false,
				};
			savePrefs();
			window.close(true);
		});
		window.on('maximize', function() {
			prefs.windowPos.max = true;
		});
		window.on('unmaximize', function() {
			prefs.windowPos.max = false;
		});
	}

	override function load(noError = false) {
		if( sys.FileSystem.exists(prefs.curFile+".mine") && !Resolver.resolveConflict(prefs.curFile) ) {
			error("CDB file has unresolved conflict, merge by hand before reloading.");
			return;
		}

		super.load(noError);

		initContent();
		prefs.recent.remove(prefs.curFile);
		if( prefs.curFile != null )
			prefs.recent.unshift(prefs.curFile);
		if( prefs.recent.length > 8 ) prefs.recent.pop();
		mcompress.checked = base.compress;
	}

	public static var inst : Main;
	static function main() {
		untyped if( js.node.Fs.accessSync == null ) js.node.Fs.accessSync = function(path) if( !(js.node.Fs : Dynamic).existsSync(path) ) throw path + " does not exists";
		inst = new Main();
		Reflect.setField(js.Browser.window, "_", inst);
	}

}
