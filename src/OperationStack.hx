import js.html.Document;
import js.html.BodyElement;

class OperationStack {
	var stack : Array<Operation>;
	// Index of where are in the undo stack.
	// New ops will be inserted at cursor+0.
	// Undo will decrement the cursor.
	// Redo will increment it.
	var cursor : Int;
	var context : Main;

	var savePoint : Int;
	
	public function new(context : Main) {
		stack = new Array<Operation>();
		this.context = context;
		this.cursor = 0;
		this.savePoint = 0;
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
		checkSavePoint();

		return op;
	}

	public function undo() {
		// prevent undoing further than initial state (which is at index 0)
		if (cursor <= 0) {
			trace("can't undo");
			return;
		}

		cursor--;
		checkSavePoint();

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
		checkSavePoint();
	}

	public function removeLastOp(op : Operation) {
		if (stack.length > 0 && stack[stack.length - 1] == op) {
			stack.pop();
			cursor--;
			checkSavePoint();
		} else
			trace("can't remove last op");
	}

	private var unsavedCSSLinkTag : js.html.LinkElement;

	// forceQueryTag: necessary after Reload From Disk, which renews the op stack,
	// and therefore we lose the reference to the existing tag
	private function checkSavePoint(forceQueryTag : Bool = false) {
		if (savePoint != cursor) {
			context.window.title = "[*] CastleDB: " + context.prefs.curFile;
			if (unsavedCSSLinkTag == null) {
				unsavedCSSLinkTag = js.Browser.document.createLinkElement();
				unsavedCSSLinkTag.id = "unsavedstylesheet";
				unsavedCSSLinkTag.rel = "stylesheet";
				unsavedCSSLinkTag.type = "text/css";
				unsavedCSSLinkTag.href = "unsaved.css";
				js.Browser.document.body.appendChild(unsavedCSSLinkTag);
			}
		}
		else {
			context.window.title = "CastleDB: " + context.prefs.curFile;
			var tagToNuke : js.html.Element = unsavedCSSLinkTag;
			if (tagToNuke == null && forceQueryTag) {
				tagToNuke = js.Browser.document.getElementById("unsavedstylesheet");
			}
			if (tagToNuke != null) {
				js.Browser.document.body.removeChild(tagToNuke);
			}
			unsavedCSSLinkTag = null;
		}
	}

	public function setSavePointHere() {
		savePoint = cursor;
		checkSavePoint(true);
	}

	public function hasUnsavedChanges() : Bool {
		return savePoint != cursor;
	}
}
