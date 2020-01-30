package ops;

class FullSnapshot implements Operation {
	public var previousState : String;
	public var currentState : String;

	public function new() {
		previousState = null;
		currentState = null;
	}

	public function setPreviousState(context : Main) {
		previousState = cdb.Parser.saveMonofile(context.base.data, true);
		return this;
	}

	public function setCurrentState(context : Main) {
		currentState = cdb.Parser.saveMonofile(context.base.data, true);
	}

	public function apply(context: Main) : Void {
		context.base.loadJson(currentState);
	}

	public function rollback(context: Main) : Void {
		context.base.loadJson(previousState);
	}
}

