package ops;

import sys.FileSystem;
import cdb.*;

class RowModify implements Operation {
	var rowPos : cdb.NestedRowPos;
	public var oldState : String;
	public var newState : String;

	var oldFilePath : String;

	public function new(context : Main, rowPos : NestedRowPos) {
		this.rowPos = rowPos;
		oldFilePath = MultifileLoadSave.getNestedRowPath(context.schemaPath, context.base, rowPos);
		oldState = serialize(context.base.getNestedRow(rowPos));
		newState = oldState;
	}

	public function commitNewState(context: Main) : Void {
		FileSystem.deleteFile(oldFilePath);
		newState = serialize(context.base.getNestedRow(rowPos));
		MultifileLoadSave.saveNestedRow(context.schemaPath, context.base, rowPos);
		MultifileLoadSave.saveTableIndex(context.schemaPath, context.base.getSheet(rowPos[0].col).sheet);
	}

	private function _apply(context: Main, state: String) {
		MultifileLoadSave.deleteNestedRowFile(context.schemaPath, context.base, rowPos);
		var arr = context.base.getNestedSheetRowArray(rowPos);
		var idx = rowPos[rowPos.length-1].row;
		arr[idx] = haxe.Json.parse(state);
		context.base.sync();
		MultifileLoadSave.saveNestedRow(context.schemaPath, context.base, rowPos);
		MultifileLoadSave.saveTableIndex(context.schemaPath, context.base.getSheet(rowPos[0].col).sheet);
	}

	public function apply(context: Main) : Void {
		_apply(context, newState);
	}

	public function rollback(context: Main) : Void {
		_apply(context, oldState);
	}

	public function isUseless() : Bool {
		return oldState == newState;
	}

	private static function serialize(obj : Dynamic) {
		return haxe.Json.stringify(obj, null, "");
	}

}
