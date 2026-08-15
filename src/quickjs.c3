<*
 quickjs-ng, bound through the flat C surface in `native/qjs_shim.c`.

 **Nothing here declares a QuickJS symbol directly.** Its public API passes
 `JSValue` — sixteen bytes, a union and a tag — by value and returns it the same
 way, and every one of those calls would be a bet that this side lowers a
 two-eightbyte struct exactly the way the C compiler did. The bet is usually won
 and the loss is silent: a corrupted tag read as an object pointer, crashing
 somewhere with no connection to the call that did it. The shim moves every value
 through a pointer instead, so the ABI question never comes up.

 The other half of the reason is that much of QuickJS's API is macros and
 `static inline` functions in the header — `JS_FreeValue`, `JS_VALUE_GET_TAG`,
 `JS_NewInt32` — which exist in no object file and cannot be linked against at
 all. The shim re-exports them as real symbols.

 **Ownership.** A `Value` returned by anything here is owned by the caller and
 must be released with `Context.release`, once. `defer` is the only sane way to
 write that, and every function below is documented in those terms. The exception
 is `Value.tag` and the `is_*` predicates, which borrow.
*>
module qjs;




// The tags a value can carry. Only the ones a caller has any business branching
// on are named; the rest are internal to the engine and arrive as `OTHER`.
const int TAG_BIG_INT = -9;
const int TAG_SYMBOL = -8;
const int TAG_STRING = -7;
const int TAG_OBJECT = -1;
const int TAG_INT = 0;
const int TAG_BOOL = 1;
const int TAG_NULL = 2;
const int TAG_UNDEFINED = 3;
// What `JS_GetException` answers with when nothing is pending — not undefined,
// which is a value a script can genuinely throw. The engine uses it internally
// for a slot that has never been written, and asking for an exception there is
// exactly that. See `Context.exception`.
const int TAG_UNINITIALIZED = 4;
const int TAG_EXCEPTION = 6;
const int TAG_FLOAT64 = 8;

const int EVAL_GLOBAL = 0;
const int EVAL_MODULE = 1;

// The element types `Context.typed_array` can lay over a buffer. Only the ones
// a host has data in are named; the enum they come from has twelve entries and
// the other seven exist for JavaScript's benefit rather than a binding's.
const int ARRAY_UINT8 = 2;
const int ARRAY_INT32 = 5;
const int ARRAY_UINT32 = 6;
const int ARRAY_FLOAT32 = 10;
const int ARRAY_FLOAT64 = 11;

<*
 One JavaScript value, sixteen opaque bytes.

 Passed to the shim by address and never inspected here. It is a plain value type
 rather than a pointer because it is the engine's own inline representation — a
 small integer or a boolean lives entirely inside it, with nothing allocated.
*>
struct Value
{
	ulong a;
	ulong b;
}

alias Runtime = void*;
alias ContextRef = void*;

<*
 Called between bytecode instructions; return true to abort the running script.

 It runs on whichever thread is executing the script, and must not call back into
 the context that is running — it is asked *whether* to stop, not to do anything.
*>
alias InterruptFn = fn int(Runtime rt, void* opaque);

<*
 A function written here and called from JavaScript.

 Everything crosses by pointer for the same reason the shim exists: `this_val`
 and each argument are sixteen bytes the C compiler returns in a register pair,
 and reproducing that lowering is a bet with a silent loss.

 `this_val` and `args` are **borrowed** — release neither. Whatever is written
 to `out` is handed to the engine, which owns it afterwards and will release it;
 a callback that writes nothing returns `undefined`. `wrap` turns `ctx` back
 into a handle the rest of this module takes.
*>
alias HostFn = fn void(ContextRef ctx, Value* this_val, int argc, Value* args, void* opaque, Value* out);

// ---------------------------------------------------------------------------
// The shim.

extern fn Runtime qjs_new_runtime();
extern fn void qjs_free_runtime(Runtime rt);
extern fn ContextRef qjs_new_context(Runtime rt);
extern fn void qjs_free_context(ContextRef ctx);
extern fn Runtime qjs_runtime_of(ContextRef ctx);

extern fn void qjs_set_memory_limit(Runtime rt, usz bytes);
extern fn void qjs_set_max_stack_size(Runtime rt, usz bytes);
extern fn void qjs_run_gc(Runtime rt);
extern fn void qjs_set_interrupt_handler(Runtime rt, InterruptFn cb, void* opaque);

extern fn int qjs_job_pending(Runtime rt);
extern fn int qjs_execute_pending_job(Runtime rt);

extern fn void qjs_free_value(ContextRef ctx, Value* v);
extern fn void qjs_dup_value(ContextRef ctx, Value* v, Value* out);
extern fn int qjs_tag(Value* v);
extern fn int qjs_is_exception(Value* v);
extern fn int qjs_is_undefined(Value* v);
extern fn int qjs_is_null(Value* v);
extern fn int qjs_is_error(ContextRef ctx, Value* v);

extern fn void qjs_undefined(Value* out);
extern fn void qjs_null(Value* out);
extern fn void qjs_new_bool(int b, Value* out);
extern fn void qjs_new_int32(int n, Value* out);
extern fn void qjs_new_float64(double d, Value* out);
extern fn void qjs_new_string(ContextRef ctx, char* s, usz len, Value* out);

extern fn int qjs_to_float64(ContextRef ctx, Value* v, double* out);
extern fn int qjs_to_int32(ContextRef ctx, Value* v, int* out);
extern fn int qjs_to_bool(ContextRef ctx, Value* v);
extern fn char* qjs_to_cstring(ContextRef ctx, Value* v, usz* len);
extern fn void qjs_free_cstring(ContextRef ctx, char* s);

extern fn void qjs_global(ContextRef ctx, Value* out);
extern fn void qjs_new_object(ContextRef ctx, Value* out);
extern fn void qjs_get_prop(ContextRef ctx, Value* obj, ZString name, Value* out);
extern fn int qjs_set_prop(ContextRef ctx, Value* obj, ZString name, Value* value);
extern fn void qjs_new_object_proto(ContextRef ctx, Value* proto, Value* out);
extern fn int qjs_define_getset(ContextRef ctx, Value* obj, ZString name, Value* getter, Value* setter);

extern fn void qjs_new_array(ContextRef ctx, Value* out);
extern fn int qjs_set_index(ContextRef ctx, Value* obj, uint index, Value* value);
extern fn void qjs_get_index(ContextRef ctx, Value* obj, uint index, Value* out);
extern fn int qjs_length(ContextRef ctx, Value* obj, long* out);

extern fn void qjs_new_buffer(ContextRef ctx, char* data, usz len, Value* out);
extern fn void qjs_detach_buffer(ContextRef ctx, Value* buffer);
extern fn int qjs_freeze_buffer(Value* buffer);
extern fn void qjs_new_typed_array(ContextRef ctx, int kind, Value* buffer, usz offset, usz count, Value* out);

extern fn void qjs_new_function(ContextRef ctx, HostFn cb, ZString name, int argc, void* opaque, Value* out);
extern fn int qjs_is_function(ContextRef ctx, Value* v);
extern fn void qjs_call(ContextRef ctx, Value* callee, Value* this_val, int argc, Value* args, Value* out);
extern fn void qjs_new_error(ContextRef ctx, ZString message, Value* out);
extern fn void qjs_throw(ContextRef ctx, Value* v, Value* out);

extern fn void qjs_json_stringify(ContextRef ctx, Value* v, Value* out);
extern fn void qjs_json_parse(ContextRef ctx, char* buf, usz len, ZString filename, Value* out);

extern fn void qjs_eval(ContextRef ctx, char* src, usz len, ZString filename, int type, Value* out);
extern fn void qjs_take_exception(ContextRef ctx, Value* out);

// ---------------------------------------------------------------------------

faultdef
	// The engine would not start. Out of memory, and nothing else.
	NO_RUNTIME,
	// The script threw, or failed to parse. The message is the caller's to fetch
	// with `Context.exception`, which is where the stack trace is too.
	THREW;

<*
 A runtime and one context on it, which is the only shape crig needs.

 QuickJS separates the two so several contexts can share an object heap; nothing
 here wants that, and keeping them together means one thing to open and one to
 close. **A `JSRuntime` belongs to the thread that made it** — the stack-overflow
 check reads the stack top recorded at creation — so this must not be handed
 across threads.

 Zero-initialised is closed and safe to `close` again.
*>
struct Context
{
	Runtime runtime;
	ContextRef ctx;
}

<*
 Start an engine.

 @param memory_limit : `Bytes the whole runtime may allocate, or 0 for no limit. A script that asks for more gets an out-of-memory exception it can be told about, rather than the process being killed.`
 @param stack_limit : `Bytes of native stack a script may use, or 0 for no check. This is what turns runaway recursion into an exception instead of a segfault.`
 @return? NO_RUNTIME : `The engine could not be created.`
*>
fn Context? open(usz memory_limit = 0, usz stack_limit = 0)
{
	Runtime runtime = qjs_new_runtime();
	if (runtime == null) return NO_RUNTIME~;

	// Before the context, so a limit cannot be overrun while building one.
	if (memory_limit > 0) qjs_set_memory_limit(runtime, memory_limit);
	qjs_set_max_stack_size(runtime, stack_limit);

	ContextRef ctx = qjs_new_context(runtime);
	if (ctx == null)
	{
		qjs_free_runtime(runtime);
		return NO_RUNTIME~;
	}
	return { .runtime = runtime, .ctx = ctx };
}

<*
 Shut it down. Every `Value` taken from this context is dead afterwards.

 Safe on a zeroed struct and safe twice, so it can be `defer`red beside a call
 that may not have succeeded.
*>
fn void Context.close(&self)
{
	if (self.ctx != null) qjs_free_context(self.ctx);
	if (self.runtime != null) qjs_free_runtime(self.runtime);
	*self = {};
}

fn bool Context.open_now(&self) => self.ctx != null;

<*
 The handle for a context somebody else owns — what a `HostFn` is given.

 **Never `close` one of these.** It names the same engine `open` returned, and
 closing it from inside a call would free the runtime the call is running on.
*>
fn Context wrap(ContextRef ctx)
{
	return { .runtime = qjs_runtime_of(ctx), .ctx = ctx };
}

<*
 Release a value. Exactly once, and not after `close`.
*>
fn void Context.release(&self, Value value)
{
	qjs_free_value(self.ctx, &value);
}

<*
 Another reference to the same value, which the caller must also release.
*>
fn Value Context.retain(&self, Value value)
{
	Value out;
	qjs_dup_value(self.ctx, &value, &out);
	return out;
}

<*
 Run `source` as a script.

 	`Value result = js.eval("1 + 1")!;`
 	`defer js.release(result);`

 @param name : `What the engine calls this source in a stack trace. A path, or something a reader will recognise — it is never opened.`
 @param type : `EVAL_GLOBAL, or EVAL_MODULE for source using import/export.`
 @return `The value the script ended on, owned by the caller.`
 @return? THREW : `The script threw or would not parse; Context.exception has the message.`
*>
fn Value? Context.eval(&self, String source, String name = "<eval>", int type = EVAL_GLOBAL)
{
	ZString named = name.zstr_copy(mem);
	defer alloc::free(mem, (void*)named);

	// **Copied, always.** `JS_Eval` requires `input[input_len]` to be `\0` — it
	// is a documented precondition, not a nicety — and a `String` in C3 carries
	// no such promise: a literal happens to have one, a slice of a file read off
	// disk does not, and there is no way to check without reading the byte the
	// question is about. The failure is a parse of one byte of whatever follows
	// the buffer, which surfaces as `SyntaxError: invalid UTF-8 sequence`
	// somewhere no one will connect to it.
	ZString text = source.zstr_copy(mem);
	defer alloc::free(mem, (void*)text);

	Value result;
	qjs_eval(self.ctx, (char*)text, source.len, named, type, &result);
	if (qjs_is_exception(&result) != 0) return THREW~;
	return result;
}

<*
 The pending exception as a sentence, always allocated from `allocator` — see
 `Context.text` for why the empty answer is allocated too.

 Reading it clears it, which is what makes a second script runnable after a first
 one threw. An engine with nothing pending answers with the empty string, so a
 caller can tell "no exception" from a script that genuinely threw `undefined`.

 Telling those apart is the whole reason the check below is on the tag rather than
 on `is_undefined`: with nothing pending the engine hands back `UNINITIALIZED`, its
 own marker for a slot never written, and stringifying that gives the literal
 "[uninitialized]" — which reads like a real message and is not one.

 The `stack` property is appended when the throw carried one — every `Error` does,
 and a bare `throw 3` does not.
*>
fn String Context.exception(&self, Allocator allocator = mem)
{
	Value thrown;
	qjs_take_exception(self.ctx, &thrown);
	defer self.release(thrown);

	int tag = qjs_tag(&thrown);
	if (tag == TAG_UNDEFINED || tag == TAG_NULL || tag == TAG_UNINITIALIZED) return "".copy(allocator);

	String message = self.text(thrown, allocator);
	if (qjs_is_error(self.ctx, &thrown) == 0) return message;

	Value stack;
	qjs_get_prop(self.ctx, &thrown, "stack", &stack);
	defer self.release(stack);
	if (qjs_is_undefined(&stack) != 0) return message;

	String trace = self.text(stack, allocator);
	defer alloc::free(allocator, trace.ptr);
	if (trace.len == 0) return message;

	String joined = string::format(allocator, "%s\n%s", message, trace);
	alloc::free(allocator, message.ptr);
	return joined;
}

<*
 `value` as text, the way `String(value)` would give it. Empty when the value has
 no string form.

 **Always allocated from `allocator`, including when it is empty**, so the caller
 frees it unconditionally. Handing back a static `""` on the empty path would be
 one byte cheaper and would mean every caller had to guard its own `free` — which
 is a crash the day one of them forgets, and the answer is empty on exactly the
 paths nobody tests.
*>
fn String Context.text(&self, Value value, Allocator allocator = mem)
{
	usz len = 0;
	char* raw = qjs_to_cstring(self.ctx, &value, &len);
	if (raw == null) return "".copy(allocator);
	defer qjs_free_cstring(self.ctx, raw);
	return ((String)raw[:len]).copy(allocator);
}

<*
 `value` as a number. Zero when it has no numeric form, which is also what a
 caller gets for `NaN` — check the tag first if the difference matters.
*>
fn double Context.number(&self, Value value)
{
	double out = 0;
	if (qjs_to_float64(self.ctx, &value, &out) != 0) return 0;
	return out;
}

fn bool Context.truth(&self, Value value) => qjs_to_bool(self.ctx, &value) != 0;

fn int Value.tag(self)
{
	Value copy = self;
	return qjs_tag(&copy);
}

fn bool Value.is_undefined(self)
{
	Value copy = self;
	return qjs_is_undefined(&copy) != 0;
}

fn bool Value.is_null(self)
{
	Value copy = self;
	return qjs_is_null(&copy) != 0;
}

<*
 The global object, owned by the caller. Where a host function is installed.
*>
fn Value Context.global(&self)
{
	Value out;
	qjs_global(self.ctx, &out);
	return out;
}

<*
 A property of `object`, owned by the caller. Undefined when there is none.
*>
fn Value Context.property(&self, Value object, ZString name)
{
	Value out;
	qjs_get_prop(self.ctx, &object, name, &out);
	return out;
}

<*
 Set a property. **Takes ownership of `value`** — the engine's own rule, and the
 caller must not release it afterwards.

 @return `False when the property could not be set.`
*>
fn bool Context.set_property(&self, Value object, ZString name, Value value)
{
	return qjs_set_prop(self.ctx, &object, name, &value) >= 0;
}

<*
 `value` as JSON, allocated from `allocator` — the natural way to get a whole
 structure out in one piece rather than walking it property by property.

 Empty when the value has no JSON form: `undefined`, a function, or a symbol.
 That is JSON's own answer rather than a failure, and it is why the empty string
 is not the same as `"null"`. A circular object throws, which arrives here as
 empty too — call `Context.exception` if the difference matters.
*>
fn String Context.json(&self, Value value, Allocator allocator = mem)
{
	Value text;
	qjs_json_stringify(self.ctx, &value, &text);
	defer self.release(text);
	if (qjs_is_exception(&text) != 0 || qjs_is_undefined(&text) != 0) return "".copy(allocator);
	return self.text(text, allocator);
}

<*
 `text` parsed as JSON, owned by the caller — the same crossing the other way.

 @param name : `What a parse error calls the source. Never opened.`
 @return? THREW : `Malformed JSON; Context.exception says where.`
*>
fn Value? Context.from_json(&self, String text, String name = "<json>")
{
	ZString named = name.zstr_copy(mem);
	defer alloc::free(mem, (void*)named);

	// Zero-terminated for the same documented reason `eval` copies — see there.
	ZString body = text.zstr_copy(mem);
	defer alloc::free(mem, (void*)body);

	Value out;
	qjs_json_parse(self.ctx, (char*)body, text.len, named, &out);
	if (qjs_is_exception(&out) != 0) return THREW~;
	return out;
}

fn Value Context.string(&self, String text)
{
	Value out;
	qjs_new_string(self.ctx, text.ptr, text.len, &out);
	return out;
}

<*
 An empty object, owned by the caller.
*>
fn Value Context.object(&self)
{
	Value out;
	qjs_new_object(self.ctx, &out);
	return out;
}

<*
 An object with `proto` behind it, owned by the caller.

 The prototype is **borrowed**, so one object can stand behind any number of
 these — which is what makes a host-side class: the accessors are defined once
 on the prototype and every instance carries only its own identity.
*>
fn Value Context.object_of(&self, Value proto)
{
	Value out;
	qjs_new_object_proto(self.ctx, &proto, &out);
	return out;
}

<*
 Define `name` as an accessor: reading it calls `getter`, assigning to it calls
 `setter`.

 	`js.accessor(proto, "position", js.function(&read_position, "position", 0, run),`
 	`            js.function(&write_position, "position", 1, run));`

 **Takes ownership of both**, the same way `set_property` does. Pass
 `undefined_value()` for the setter to make the property read-only — an
 assignment then throws in strict mode and is quietly dropped outside it, which
 is JavaScript's own rule for a getter with no setter.

 @return `False when the property could not be defined.`
*>
fn bool Context.accessor(&self, Value object, ZString name, Value getter, Value setter = undefined_value())
{
	return qjs_define_getset(self.ctx, &object, name, &getter, &setter) >= 0;
}

<*
 An empty array, owned by the caller.
*>
fn Value Context.array(&self)
{
	Value out;
	qjs_new_array(self.ctx, &out);
	return out;
}

<*
 Set `array[index]`. **Takes ownership of `value`.**
*>
fn bool Context.set_index(&self, Value array, uint index, Value value)
{
	return qjs_set_index(self.ctx, &array, index, &value) >= 0;
}

<*
 `array[index]`, owned by the caller. Undefined when there is no such element.
*>
fn Value Context.index(&self, Value array, uint index)
{
	Value out;
	qjs_get_index(self.ctx, &array, index, &out);
	return out;
}

<*
 `value.length` as JavaScript reads it, which answers for anything array-like
 and not only for a real array.

 @return `-1 when the value has no length, which includes the case where asking for one threw.`
*>
fn long Context.length(&self, Value value)
{
	long out = 0;
	if (qjs_length(self.ctx, &value, &out) != 0) return -1;
	return out;
}

<*
 An `ArrayBuffer` over memory the host owns, owned by the caller.

 Nothing is copied: this is the whole point of it, and the whole hazard. The
 engine is told the memory is not its to manage, so it will neither free nor
 resize nor move it — and it has no idea when the host does. **Detach the buffer
 before the memory goes away**, which turns every view of it into a `TypeError`
 at that moment rather than a read of released pages some time later.

 	`Value buffer = js.buffer((char*)mesh.positions.ptr, @sizeof(mesh.positions[0]) * mesh.positions.len);`
 	`Value view = js.typed_array(qjs::ARRAY_FLOAT32, buffer, 0, mesh.positions.len * 3);`
*>
fn Value Context.buffer(&self, char* data, usz bytes)
{
	Value out;
	qjs_new_buffer(self.ctx, data, bytes, &out);
	return out;
}

<*
 Detach a buffer: every typed array over it becomes unusable, and reading one
 throws `TypeError: detached ArrayBuffer`.

 Idempotent, and harmless on a value that is not a buffer at all.
*>
fn void Context.detach(&self, Value buffer)
{
	qjs_detach_buffer(self.ctx, &buffer);
}

<*
 Make a buffer read-only: no write through any view of it reaches the memory.

 The other half of what makes sharing the host's memory safe. Zero-copy means a
 script can *see* the host's arrays; without this it could also change them,
 behind whatever bookkeeping the host keeps about them. Detaching still works —
 read-only is about the script, not about the host.

 **How the refusal reads in JavaScript differs by route**, and it is worth
 knowing which. `view[0] = 1` is dropped silently, in strict mode as well as
 outside it — the engine refuses it in the element fast path, so there is no
 failed `[[Set]]` for `use strict` to turn into a throw. The bulk methods
 (`set`, `fill`, `copyWithin`, `sort`) throw
 `TypeError: ArrayBuffer is immutable`. Both leave the memory alone, which is
 the guarantee; only one of them says so out loud.

 @return `False when the value is not an ArrayBuffer.`
*>
fn bool Context.freeze(&self, Value buffer)
{
	return qjs_freeze_buffer(&buffer) == 0;
}

<*
 A typed array over `buffer`, owned by the caller — what a script actually
 reads. The buffer is **borrowed** and stays the caller's to release.

 @param kind : `One of the ARRAY_* constants: the element type to read the bytes as.`
 @param offset : `Where the view starts, in elements of that kind.`
 @param count : `How many elements it covers.`
*>
fn Value Context.typed_array(&self, int kind, Value buffer, usz offset, usz count)
{
	Value out;
	qjs_new_typed_array(self.ctx, kind, &buffer, offset, count, &out);
	return out;
}

fn Value number_value(double d)
{
	Value out;
	qjs_new_float64(d, &out);
	return out;
}

fn Value int_value(int n)
{
	Value out;
	qjs_new_int32(n, &out);
	return out;
}

fn Value bool_value(bool b)
{
	Value out;
	qjs_new_bool(b ? 1 : 0, &out);
	return out;
}

fn Value undefined_value()
{
	Value out;
	qjs_undefined(&out);
	return out;
}

<*
 `null` — which a host means when there is nothing rather than when it was not
 asked, and which JSON carries where `undefined` disappears.
*>
fn Value null_value()
{
	Value out;
	qjs_null(&out);
	return out;
}

<*
 A JS function that calls `body`, owned by the caller — install it with
 `set_property`, which takes that ownership over.

 	`js.set_property(global, "hypot", js.function(&hypot, "hypot", 2));`

 @param name : `What the function calls itself. Shows up in stack traces and in String(fn), and nothing looks it up by it.`
 @param arity : `The argument count JS reports as fn.length. Not a limit — a call may pass any number, and the callback is told how many arrived.`
 @param opaque : `Handed back to the callback untouched. Must outlive the function, which lives until the context closes or the value is collected.`
*>
fn Value Context.function(&self, HostFn body, ZString name, int arity = 0, void* opaque = null)
{
	Value out;
	qjs_new_function(self.ctx, body, name, arity, opaque, &out);
	return out;
}

<*
 Whether `value` can be called — true for a function declared in a script, for
 one made by `Context.function`, and for a class, which JavaScript counts as a
 function too.

 Worth asking before `Context.call` when the script is the user's rather than
 the host's: a script that never defined the hook the host looks for should be
 quiet, not throwing once a frame.
*>
fn bool Context.is_function(&self, Value value)
{
	return qjs_is_function(self.ctx, &value) != 0;
}

<*
 Call a JavaScript function from here — the mirror of `Context.function`, and
 what a host loop calling into a script once a frame needs.

 	`Value update = js.property(global, "update");`
 	`defer js.release(update);`
 	`if (js.is_function(update))`
 	`{`
 	`    Value[2] args = { qjs::number_value(dt), input };`
 	`    Value? answer = js.call(update, qjs::undefined_value(), args[..]);`
 	`}`

 **Everything passed in is borrowed**, which is the opposite of the rule
 `set_property` and `accessor` follow: the function, the receiver and every
 argument are still the caller's to release afterwards. Only the answer is
 owned by the caller.

 @param this_val : `What the function sees as its receiver. Undefined is right for a plain function, and only a method reached through the host rather than through a property access needs anything else.`
 @param args : `The arguments, in order. Passing more or fewer than the function declares is allowed, as it is from JavaScript.`
 @return `Whatever the function returned, owned by the caller.`
 @return? THREW : `It threw, or was not callable at all; Context.exception has the message.`
*>
fn Value? Context.call(&self, Value function, Value this_val = undefined_value(), Value[] args = {})
{
	Value out;
	qjs_call(self.ctx, &function, &this_val, (int)args.len, args.ptr, &out);
	if (qjs_is_exception(&out) != 0) return THREW~;
	return out;
}

<*
 An `Error` carrying `message`, owned by the caller. Usually wanted as `raise`,
 which throws it in the same breath.
*>
fn Value Context.error(&self, String message)
{
	ZString text = message.zstr_copy(mem);
	defer alloc::free(mem, (void*)text);

	Value out;
	qjs_new_error(self.ctx, text, &out);
	return out;
}

<*
 Throw an `Error` carrying `message`, and hand back what a `HostFn` returns
 having done so:

 	`*out = js.raise("no rig is loaded");`
 	`return;`

 The value is the engine's exception marker, not the error object — the error is
 pending on the context, where a `catch` in the script or `Context.exception`
 outside it will find it.
*>
fn Value Context.raise(&self, String message)
{
	Value thrown = self.error(message);
	Value out;
	qjs_throw(self.ctx, &thrown, &out);
	return out;
}

<*
 Ask to be interrupted.

 The handler is called often, between bytecode instructions, and returning
 non-zero aborts the script with an uncatchable exception. It is the only way to
 stop a `while (true)`.

 Null clears it.
*>
fn void Context.on_interrupt(&self, InterruptFn handler, void* opaque = null)
{
	qjs_set_interrupt_handler(self.runtime, handler, opaque);
}

<*
 Run one queued promise job.

 A script that awaits parks its continuation here rather than blocking, so a host
 that wants a script to yield — to draw a frame, say — drains this a job at a time
 instead of running it to completion.

 @return `False when the queue was empty or the job threw.`
*>
fn bool Context.step_job(&self)
{
	return qjs_execute_pending_job(self.runtime) > 0;
}

fn bool Context.jobs_waiting(&self) => qjs_job_pending(self.runtime) != 0;

<*
 Collect garbage now. Only worth calling after dropping something large.
*>
fn void Context.collect(&self)
{
	qjs_run_gc(self.runtime);
}
