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

import std::core::mem;
import std::core::mem::allocator;
import std::core::string;

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

extern fn void qjs_new_function(ContextRef ctx, HostFn cb, ZString name, int argc, void* opaque, Value* out);
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

	Value result;
	qjs_eval(self.ctx, source.ptr, source.len, named, type, &result);
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

	Value out;
	qjs_json_parse(self.ctx, text.ptr, text.len, named, &out);
	if (qjs_is_exception(&out) != 0) return THREW~;
	return out;
}

fn Value Context.string(&self, String text)
{
	Value out;
	qjs_new_string(self.ctx, text.ptr, text.len, &out);
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
