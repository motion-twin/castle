interface Operation {
    public function apply(context : Main) : Void;
    public function rollback(context : Main) : Void;
}
