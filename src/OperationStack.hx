class OperationStack {
	var stack : Array<Operation>;
	// Index of where are in the undo stack.
	// New ops will be inserted at cursor+0.
	// Undo will decrement the cursor.
	// Redo will increment it.
	var cursor : Int;
	var context : Main;
	
	public function new(context : Main) {
		stack = new Array<Operation>();
		this.context = context;
		this.cursor = 0;
	}

	public function push(op : Operation) : Operation {
		pushNoApply(op);

		op.apply(context);

		context.refresh();

		return op;
	}

	public function pushNoApply(op : Operation) : Operation {
		if (cursor <= stack.length - 1) {
			// Trim operation stack if we're not at the top of the stack
			stack.resize(cursor);
			trace("nuking redo");
		}
		
		trace("Push operation: " + Type.getClassName(Type.getClass(op)));
		trace("opened list: " + context.openedList);

		stack.push(op);
		cursor++;

		return op;
	}

	public function undo() {
		// prevent undoing further than initial state (which is at index 0)
		if (cursor <= 0) {
			trace("can't undo");
			return;
		}

		cursor--;

		// rollback current top state
		stack[cursor].rollback(context);
	}

	public function redo() {
		if (cursor >= stack.length) {
			trace("can't redo");
			return;
		}

		stack[cursor].apply(context);

		cursor++;
	}

	public function removeLastOp(op : Operation) {
		if (stack.length > 0 && stack[stack.length - 1] == op)
			stack.pop();
		else
			trace("can't remove last op");
	}
}
