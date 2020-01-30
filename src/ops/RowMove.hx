package ops;

import cdb.NestedRowPos;

class RowMove implements Operation {
	var initialPos : NestedRowPos;
	var newIndex : Int;

	public function new(initialPos: NestedRowPos, newIndex : Int) {
		this.initialPos = initialPos;
		this.newIndex = newIndex;
	}

	public function apply(context : Main) : Void {
		var table = context.base.getNestedSheetRowArray(initialPos);

		var index1 = initialPos[initialPos.length-1].row;
		var index2 = newIndex;

		var row1 = table[index1];
		var row2 = table[index2];

		table[index1] = row2;
		table[index2] = row1;

		/*
		// Index remapping table
		var remap = [for( i in 0...table.length ) i];
		remap[index1] = index2;
		remap[index2] = index1;
		*/
	}

	public function rollback(context: Main) : Void {
		// We're swapping two rows, so it's the exact same operation as Apply
		apply(context);
	}
}
