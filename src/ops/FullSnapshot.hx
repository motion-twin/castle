package ops;

class FullSnapshot implements Operation {
	public var previousState : String;
	public var previousFormat : String;
	public var currentState : String;
	public var currentFormat : String;

	public function new() {
	}

	public function setPreviousState(context : Main) {
		previousState = cdb.Parser.saveMonofile(context.base.data, true);
		previousFormat = context.base.data.format;
		return this;
	}

	public function setCurrentState(context : Main) {
		currentState = cdb.Parser.saveMonofile(context.base.data, true);
		currentFormat = context.base.data.format;
	}

	public function apply(context: Main) : Void {
		context.base.loadJson(currentState);
		context.base.data.format = currentFormat;
	}

	public function rollback(context: Main) : Void {
		context.base.loadJson(previousState);
		context.base.data.format = previousFormat;
	}
}

