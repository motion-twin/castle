package ops;

class SeparatorMove implements Operation {
	private var tableName : String;
	private var sepIdx : Int;
	private var oldPos : Int;
	private var newPos : Int;

	public function new(sheet: cdb.Sheet, separatorIndex: Int, newSeparatorPos: Int) {
		this.tableName = sheet.name;
		this.sepIdx = separatorIndex;
		this.oldPos = sheet.separators[separatorIndex];
		this.newPos = newSeparatorPos;
	}

	private function _apply(context: Main, pos1: Int, pos2: Int) {
		var table = context.base.getSheet(tableName);

		cdb.MultifileLoadSave.deleteRowFile(context.schemaPath, table.sheet, oldPos);
		cdb.MultifileLoadSave.deleteRowFile(context.schemaPath, table.sheet, newPos);

		table.separators[sepIdx] = pos2;

		cdb.MultifileLoadSave.saveRow(context.schemaPath, table.sheet, oldPos);
		cdb.MultifileLoadSave.saveRow(context.schemaPath, table.sheet, newPos);
		cdb.MultifileLoadSave.saveTableIndex(context.schemaPath, table.sheet);
	}

	public function apply(context : Main) : Void {
		_apply(context, oldPos, newPos);
	}

	public function rollback(context : Main) : Void {
		_apply(context, newPos, oldPos);
	}
}
