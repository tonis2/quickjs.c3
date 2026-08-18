<*
 That the embedded JavaScript engine starts, runs, fails usefully, and stops.

 These are about the *binding*, not about JavaScript — quickjs-ng has its own
 test262 run and nothing here is going to improve on it. What is worth checking
 is the boundary: that sixteen bytes of `JSValue` survive the trip through the
 shim intact, that a throw arrives as something a caller can read rather than as
 a crash, and that the two limits which make a hosted engine safe to run inside a
 window — memory and interrupt — actually fire.

 **The value round-trips are the ABI checks.** A `Value` is passed to the shim by
 address precisely so that no assumption about struct lowering is made here; if
 one were wrong anyway, a number written in JS and read back in C3 is where it
 would show, and it would show as a wrong number rather than as a compile error.
 That is also what makes this suite worth running on a platform before trusting
 the binding on it.
*>
module quickjs_tests;

import qjs;


import std::core::test;
import std::math;

// 8 MB. Generous for anything a script here does and small enough that the
// allocation bomb below reaches it in well under a second.
const usz SMALL_HEAP = 8 * 1024 * 1024;

// A quarter of a megabyte of native stack. Deep recursion in JS is what this
// catches, and the number only has to be smaller than the real thread stack.
const usz SMALL_STACK = 256 * 1024;

fn void the_engine_starts_and_stops() @test
{
	qjs::Context? opened = qjs::open();
	if (catch opened)
	{
		test::@check(false, "a runtime and context can be created");
		return;
	}
	qjs::Context js = opened;

	test::@check(js.open_now(), "the context reports itself open");
	js.close();
	test::@check(!js.open_now(), "and closed afterwards");

	// Twice, because it is deferred beside calls that may not have succeeded and
	// a second close has to be a no-op rather than a double free.
	js.close();
	test::@check(!js.open_now(), "closing a closed context is not an error");
}

<*
 A number written in JavaScript is the same number read in C3.

 The `JSValue` for `6 * 7` is an inline integer — no allocation, the whole value
 living in the sixteen bytes that cross the boundary. If the two sides disagreed
 about that struct at all this is where it would come out wrong.
*>
fn void a_number_survives_the_boundary() @test
{
	qjs::Context? opened = qjs::open();
	if (catch opened) { test::@check(false, "the engine starts"); return; }
	qjs::Context js = opened;
	defer js.close();

	qjs::Value? answer = js.eval("6 * 7");
	if (catch answer) { test::@check(false, "an arithmetic expression evaluates"); return; }
	defer js.release(answer);

	test::@check(answer.tag() == qjs::TAG_INT, "a whole number comes back as an int, not a double");
	test::@check(math::abs(js.number(answer) - 42.0) < 1e-12,
		"and reads back as what it was: %.6f", js.number(answer));

	// A float, which uses the other arm of the union — the one an int would
	// alias if the layout were wrong.
	qjs::Value? half = js.eval("1 / 8");
	if (catch half) { test::@check(false, "a fractional expression evaluates"); return; }
	defer js.release(half);

	test::@check(half.tag() == qjs::TAG_FLOAT64, "a fraction comes back as a double");
	test::@check(math::abs(js.number(half) - 0.125) < 1e-12,
		"and keeps its value through the union: %.6f", js.number(half));
}

fn void a_string_survives_the_boundary() @test
{
	qjs::Context? opened = qjs::open();
	if (catch opened) { test::@check(false, "the engine starts"); return; }
	qjs::Context js = opened;
	defer js.close();

	qjs::Value? greeting = js.eval(`["mixamorig", "LeftHand"].join(":")`);
	if (catch greeting) { test::@check(false, "a string expression evaluates"); return; }
	defer js.release(greeting);

	test::@check(greeting.tag() == qjs::TAG_STRING, "a string comes back tagged as one");

	String text = js.text(greeting);
	defer alloc::free(mem, text.ptr);
	test::@check(text == "mixamorig:LeftHand", "and reads back byte for byte: \"%s\"", text);

	// The other direction, which is how a joint name will reach a script.
	qjs::Value handed = js.string("mixamorig:RightFoot");
	qjs::Value global = js.global();
	defer js.release(global);
	// set_property takes ownership of `handed`; it must not be released here.
	test::@check(js.set_property(global, "joint", handed), "a string can be installed as a global");

	qjs::Value? echoed = js.eval("joint.length");
	if (catch echoed) { test::@check(false, "a script can read a global the host set"); return; }
	defer js.release(echoed);
	test::@check((int)js.number(echoed) == 19, "the script sees the whole string, not a truncated one");
}

<*
 A throw is a fault with a sentence, not a crash.

 This is the shape the whole script surface depends on: `run_script` has to
 answer a caller with something it can act on, and "the engine died" is not that.
 The stack matters as much as the message — a script an agent wrote is going to
 fail, and the line number is most of what it needs.
*>
fn void a_throw_arrives_as_a_readable_fault() @test
{
	qjs::Context? opened = qjs::open();
	if (catch opened) { test::@check(false, "the engine starts"); return; }
	qjs::Context js = opened;
	defer js.close();

	qjs::Value? thrown = js.eval(`throw new Error("no dot named LeftKnee")`, "walk.js");
	test::@check(@catch(thrown) == qjs::THREW, "a script that throws faults rather than returning");

	String message = js.exception();
	defer alloc::free(mem, message.ptr);

	test::@check(message.contains("no dot named LeftKnee"),
		"the message survives to the caller: \"%s\"", message);
	test::@check(message.contains("walk.js"),
		"and carries the stack, so a failing line can be found: \"%s\"", message);
}

fn void a_syntax_error_is_the_same_kind_of_answer() @test
{
	qjs::Context? opened = qjs::open();
	if (catch opened) { test::@check(false, "the engine starts"); return; }
	qjs::Context js = opened;
	defer js.close();

	qjs::Value? broken = js.eval("const = ;");
	test::@check(@catch(broken) == qjs::THREW, "source that will not parse faults like source that throws");

	String message = js.exception();
	defer alloc::free(mem, message.ptr);
	test::@check(message.contains("SyntaxError"), "and says so: \"%s\"", message);
}

<*
 Reading the exception clears it, so the next script starts clean.

 Left pending, the engine refuses everything afterwards and the second failure
 reports the first one's message — which reads as a script failing for a reason
 that has nothing to do with it.
*>
fn void the_engine_survives_a_failed_script() @test
{
	qjs::Context? opened = qjs::open();
	if (catch opened) { test::@check(false, "the engine starts"); return; }
	qjs::Context js = opened;
	defer js.close();

	qjs::Value? failed = js.eval(`throw new Error("first")`);
	test::@check(@catch(failed) == qjs::THREW, "the first script throws");
	String first = js.exception();
	defer alloc::free(mem, first.ptr);

	qjs::Value? after = js.eval("1 + 1");
	if (catch after)
	{
		test::@check(false, "a script runs after one that threw");
		return;
	}
	defer js.release(after);
	test::@check((int)js.number(after) == 2, "and answers with its own result");

	String nothing = js.exception();
	defer alloc::free(mem, nothing.ptr);
	test::@check(nothing.len == 0, "with no exception left pending: \"%s\"", nothing);
}

<*
 The memory limit fires, and fires as an exception rather than as a dead process.

 The whole reason a limit is set at all: a script an agent wrote is not trusted
 to be finite, and the alternative to catching this is the window disappearing.
*>
fn void an_allocation_bomb_hits_the_memory_limit() @test
{
	qjs::Context? opened = qjs::open(memory_limit: SMALL_HEAP);
	if (catch opened) { test::@check(false, "the engine starts with a memory limit"); return; }
	qjs::Context js = opened;
	defer js.close();

	qjs::Value? bomb = js.eval("const held = []; while (true) held.push(new Array(4096).fill(0));");
	test::@check(@catch(bomb) == qjs::THREW, "a script that allocates without end is stopped");

	String message = js.exception();
	defer alloc::free(mem, message.ptr);
	test::@check(message.contains("memory") || message.contains("Memory"),
		"and is told why: \"%s\"", message);

	// The engine is still usable, which is what makes this a refusal rather than
	// a failure — one bad script must not cost the session.
	qjs::Value? after = js.eval("2 + 2");
	if (catch after) { test::@check(false, "the engine survives its own memory limit"); return; }
	defer js.release(after);
	test::@check((int)js.number(after) == 4, "and answers correctly afterwards");
}

fn void runaway_recursion_hits_the_stack_limit() @test
{
	qjs::Context? opened = qjs::open(memory_limit: SMALL_HEAP, stack_limit: SMALL_STACK);
	if (catch opened) { test::@check(false, "the engine starts with a stack limit"); return; }
	qjs::Context js = opened;
	defer js.close();

	qjs::Value? deep = js.eval("function down(n) { return down(n + 1); } down(0);");
	test::@check(@catch(deep) == qjs::THREW, "unbounded recursion is stopped rather than smashing the stack");

	String message = js.exception();
	defer alloc::free(mem, message.ptr);
	test::@check(message.contains("stack"), "and says which limit it hit: \"%s\"", message);
}

// How many times the interrupt handler below has been asked. A module-level
// counter because the handler is a plain C callback with nowhere else to keep
// one, and these checks do not run concurrently.
int interrupt_asks @local = 0;

// Stops the script the second time it is asked, which is soon: the handler runs
// between bytecode instructions. Returning non-zero is the abort.
fn int stop_at_once(void* rt, void* opaque) @local
{
	interrupt_asks++;
	return interrupt_asks > 1 ? 1 : 0;
}

<*
 An endless loop can be stopped from outside.

 Neither of the two limits above catches this one: a `while (true)` that
 allocates nothing and recurses nowhere runs forever inside a memory limit and a
 stack limit both. The interrupt handler is the only thing that ends it, and it
 is what a wall-clock budget will be built on.
*>
fn void an_endless_loop_can_be_interrupted() @test
{
	qjs::Context? opened = qjs::open(memory_limit: SMALL_HEAP);
	if (catch opened) { test::@check(false, "the engine starts"); return; }
	qjs::Context js = opened;
	defer js.close();

	interrupt_asks = 0;
	js.on_interrupt(&stop_at_once);

	qjs::Value? spinning = js.eval("let n = 0; while (true) { n++; }");
	test::@check(@catch(spinning) == qjs::THREW, "a loop with no exit is aborted from outside");
	test::@check(interrupt_asks > 1, "the handler was asked more than once (%d)", interrupt_asks);

	String message = js.exception();
	defer alloc::free(mem, message.ptr);
	test::@check(message.contains("interrupt"), "and the reason names the interrupt: \"%s\"", message);

	// Cleared, or every later script in this context dies at its second
	// instruction — which is the failure mode of leaving one installed.
	js.on_interrupt(null);
	qjs::Value? after = js.eval("3 * 3");
	if (catch after) { test::@check(false, "clearing the handler lets scripts run again"); return; }
	defer js.release(after);
	test::@check((int)js.number(after) == 9, "and they answer correctly");
}

<*
 An awaited script parks on the job queue instead of running to the end.

 The mechanism §2.5 rests on: the frame loop drains one job per frame, so a long
 script cooperates rather than owning the window. `eval` returns as soon as the
 script suspends, which is why the result is not the answer yet.
*>
fn void an_async_script_parks_on_the_job_queue() @test
{
	qjs::Context? opened = qjs::open(memory_limit: SMALL_HEAP);
	if (catch opened) { test::@check(false, "the engine starts"); return; }
	qjs::Context js = opened;
	defer js.close();

	qjs::Value? started = js.eval(
		"globalThis.done = 0;"
		"(async () => { for (let i = 0; i < 3; i++) { await null; globalThis.done++; } })();");
	if (catch started) { test::@check(false, "an async script starts"); return; }
	defer js.release(started);

	test::@check(js.jobs_waiting(), "the script suspended with work still queued");

	usz drained = 0;
	while (js.jobs_waiting() && drained < 32)
	{
		js.step_job();
		drained++;
	}

	qjs::Value global = js.global();
	defer js.release(global);
	qjs::Value counted = js.property(global, "done");
	defer js.release(counted);

	test::@check((int)js.number(counted) == 3,
		"and ran to completion once the host drained the queue (%d after %d steps)",
		(int)js.number(counted), drained);
	test::@check(drained > 1, "in more than one step, which is what lets a frame be drawn between them");
}

// ---------------------------------------------------------------------------
// Host functions: the direction the value crossings run the other way.

// What `counts_up` counts, so the test can prove the opaque pointer arrived and
// is the caller's own memory rather than a copy.
struct Tally
{
	int calls;
	double last;
}

<*
 Adds its arguments, and records that it was called.

 Deliberately reads `argc` rather than trusting an arity: JS will call a function
 declared with two parameters using none, and the callback is what has to survive
 that rather than the engine.
*>
fn void adds_up(qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out) @local
{
	qjs::Context js = qjs::wrap(ctx);
	Tally* tally = (Tally*)opaque;

	double total = 0;
	for (int i = 0; i < argc; i++) total += js.number(args[i]);

	if (tally)
	{
		tally.calls++;
		tally.last = total;
	}
	*out = qjs::number_value(total);
}

<*
 Refuses, the way a host function reports a bad argument.
*>
fn void always_refuses(qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out) @local
{
	qjs::Context js = qjs::wrap(ctx);
	*out = js.raise("no rig is loaded — call apply_plan first");
}

<*
 A function written here is callable from a script, and its answer comes back.

 This is the ABI check run backwards: the arguments arrive as sixteen-byte values
 the engine wrote and this side reads, where every earlier test had this side
 writing and the engine reading.
*>
fn void a_script_can_call_a_host_function() @test
{
	qjs::Context? opened = qjs::open(memory_limit: SMALL_HEAP);
	if (catch opened) { test::@check(false, "the engine starts"); return; }
	qjs::Context js = opened;
	defer js.close();

	Tally tally;
	qjs::Value global = js.global();
	defer js.release(global);
	js.set_property(global, "addsUp", js.function(&adds_up, "addsUp", 2, &tally));

	qjs::Value? answer = js.eval("addsUp(1, 2) + addsUp(0.5, 0.25, 0.25)");
	if (catch answer) { test::@check(false, "the script runs"); return; }
	defer js.release(answer);

	test::@check(math::abs(js.number(answer) - 4.0) < 1e-12,
		"the host function's answers came back (%.4f, wanted 4)", js.number(answer));
	test::@check(tally.calls == 2, "it ran twice (%d)", tally.calls);
	test::@check(math::abs(tally.last - 1.0) < 1e-12,
		"and wrote through the opaque pointer into the caller's own memory (%.4f)", tally.last);
}

<*
 Calling it with nothing is not a crash.

 A declared arity is what `fn.length` reports and nothing more; the engine will
 happily pass fewer arguments than that, and a callback that indexed `args[0]`
 on the strength of the declaration would read off the end of the stack frame.
*>
fn void a_host_function_survives_being_called_wrong() @test
{
	qjs::Context? opened = qjs::open(memory_limit: SMALL_HEAP);
	if (catch opened) { test::@check(false, "the engine starts"); return; }
	qjs::Context js = opened;
	defer js.close();

	qjs::Value global = js.global();
	defer js.release(global);
	js.set_property(global, "addsUp", js.function(&adds_up, "addsUp", 2));

	qjs::Value? answer = js.eval("[addsUp(), addsUp(7), addsUp(1,2,3,4,5)].join(',')");
	if (catch answer) { test::@check(false, "the script runs"); return; }
	defer js.release(answer);

	String text = js.text(answer);
	defer alloc::free(mem, text.ptr);
	test::@check(text == "0,7,15", "no arguments, one, and more than declared all work (%s)", text);
}

<*
 A host function's refusal is a JS exception the script can catch.

 This is what makes a tool's refusal sentence reach a script's own error
 handling instead of arriving as a magic return value it has to test for.
*>
fn void a_host_refusal_is_a_catchable_error() @test
{
	qjs::Context? opened = qjs::open(memory_limit: SMALL_HEAP);
	if (catch opened) { test::@check(false, "the engine starts"); return; }
	qjs::Context js = opened;
	defer js.close();

	qjs::Value global = js.global();
	defer js.release(global);
	js.set_property(global, "refuses", js.function(&always_refuses, "refuses", 0));

	qjs::Value? caught = js.eval("try { refuses(); 'not reached' } catch (e) { e.message }");
	if (catch caught) { test::@check(false, "the script runs"); return; }
	defer js.release(caught);

	String text = js.text(caught);
	defer alloc::free(mem, text.ptr);
	test::@check(text == "no rig is loaded — call apply_plan first",
		"the refusal's own sentence reached the script (%s)", text);
}

<*
 And an uncaught one comes back out to the host as a fault.
*>
fn void an_uncaught_host_refusal_stops_the_script() @test
{
	qjs::Context? opened = qjs::open(memory_limit: SMALL_HEAP);
	if (catch opened) { test::@check(false, "the engine starts"); return; }
	qjs::Context js = opened;
	defer js.close();

	qjs::Value global = js.global();
	defer js.release(global);
	js.set_property(global, "refuses", js.function(&always_refuses, "refuses", 0));

	qjs::Value? answer = js.eval("globalThis.reached = false; refuses(); globalThis.reached = true;");
	test::@check(@catch(answer) == qjs::THREW, "the script faulted");
	if (try answer) js.release(answer);

	String why = js.exception();
	defer alloc::free(mem, why.ptr);
	test::@check(why.contains("no rig is loaded"), "carrying the reason (%s)", why);

	qjs::Value again = js.global();
	defer js.release(again);
	qjs::Value reached = js.property(again, "reached");
	defer js.release(reached);
	test::@check(!js.truth(reached), "and stopped at the throw rather than running on");
}

<*
 A whole structure crosses in one piece, both ways.

 The alternative — walking an object property by property from the host side —
 is what the JSON pair exists to avoid, and it is how a tool's answer gets to a
 script and a script's answer gets back.
*>
fn void a_structure_crosses_as_json() @test
{
	qjs::Context? opened = qjs::open(memory_limit: SMALL_HEAP);
	if (catch opened) { test::@check(false, "the engine starts"); return; }
	qjs::Context js = opened;
	defer js.close();

	qjs::Value? built = js.eval(`({ joint: "LeftFoot", at: [0, 0.5, -0.25], planted: true })`);
	if (catch built) { test::@check(false, "the script runs"); return; }
	defer js.release(built);

	String written = js.json(built);
	defer alloc::free(mem, written.ptr);
	test::@check(written == `{"joint":"LeftFoot","at":[0,0.5,-0.25],"planted":true}`,
		"the object came out as JSON (%s)", written);

	qjs::Value? read = js.from_json(`{"stride":1.25,"feet":["L","R"]}`);
	if (catch read) { test::@check(false, "JSON parses back into a value"); return; }
	defer js.release(read);

	qjs::Value global = js.global();
	defer js.release(global);
	js.set_property(global, "measured", js.retain(read));

	qjs::Value? back = js.eval("measured.stride + measured.feet.length");
	if (catch back) { test::@check(false, "the script reads it"); return; }
	defer js.release(back);
	test::@check(math::abs(js.number(back) - 3.25) < 1e-12,
		"and the script reads it as a real object (%.4f, wanted 3.25)", js.number(back));
}

<*
 A value with no JSON form answers empty rather than lying.

 `undefined` is what a script that ends on a statement rather than an expression
 leaves behind, so this is the common case and not a corner one — a host that
 read `"undefined"` back would be reporting the four characters as a result.
*>
fn void a_value_with_no_json_form_comes_back_empty() @test
{
	qjs::Context? opened = qjs::open(memory_limit: SMALL_HEAP);
	if (catch opened) { test::@check(false, "the engine starts"); return; }
	qjs::Context js = opened;
	defer js.close();

	qjs::Value? nothing = js.eval("void 0");
	if (catch nothing) { test::@check(false, "the script runs"); return; }
	defer js.release(nothing);

	String written = js.json(nothing);
	defer alloc::free(mem, written.ptr);
	test::@check(written.len == 0, "undefined has no JSON form (%s)", written);

	qjs::Value? nulled = js.eval("null");
	if (catch nulled) { test::@check(false, "the script runs"); return; }
	defer js.release(nulled);

	String spelled = js.json(nulled);
	defer alloc::free(mem, spelled.ptr);
	test::@check(spelled == "null", "and null is distinguishable from it (%s)", spelled);

	qjs::Value? bad = js.from_json("{not json");
	test::@check(@catch(bad) == qjs::THREW, "malformed JSON faults");
	if (try bad) js.release(bad);
	String why = js.exception();
	defer alloc::free(mem, why.ptr);
	test::@check(why.len > 0, "with a reason (%s)", why);
}

// ---------------------------------------------------------------------------
// Accessors, arrays and shared memory — the surface a host-side data layer is
// built from, as against the function-call surface above.

// What the accessor pair below reads and writes, and its own record of having
// been asked. A property that is really a function call is the whole point, so
// the counts are the check that it was one.
struct Reading @local
{
	double value;
	int reads;
	int writes;
}

fn void read_reach(qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out) @local
{
	Reading* held = (Reading*)opaque;
	held.reads++;
	*out = qjs::number_value(held.value);
}

fn void write_reach(qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out) @local
{
	qjs::Context js = qjs::wrap(ctx);
	Reading* held = (Reading*)opaque;
	held.writes++;
	if (argc > 0) held.value = js.number(args[0]);
}

<*
 A property that is a pair of host calls, defined once on a prototype.

 This is what lets a host hand out a handle rather than a copy: `dot.reach` reads
 the document at the moment it is asked, and `dot.reach = x` is an edit. The
 counts matter as much as the value — a plain data property would give the same
 arithmetic and none of the calls.
*>
fn void a_property_can_be_a_pair_of_host_calls() @test
{
	qjs::Context? opened = qjs::open(memory_limit: SMALL_HEAP);
	if (catch opened) { test::@check(false, "the engine starts"); return; }
	qjs::Context js = opened;
	defer js.close();

	Reading held = { .value = 0.25 };

	qjs::Value proto = js.object();
	test::@check(js.accessor(proto, "reach",
		js.function(&read_reach, "reach", 0, &held),
		js.function(&write_reach, "reach", 1, &held)), "the accessor is defined");

	// Two objects over one prototype, which is the arrangement being checked:
	// the pair is defined once and every instance gets it.
	qjs::Value first = js.object_of(proto);
	qjs::Value second = js.object_of(proto);
	js.release(proto);

	qjs::Value global = js.global();
	defer js.release(global);
	js.set_property(global, "first", first);
	js.set_property(global, "second", second);

	qjs::Value? answer = js.eval("first.reach = first.reach * 2; second.reach");
	if (catch answer) { test::@check(false, "the script runs"); return; }
	defer js.release(answer);

	test::@check(math::abs(js.number(answer) - 0.5) < 1e-12,
		"the second object sees what was written through the first (%.4f, wanted 0.5)",
		js.number(answer));
	test::@check(held.writes == 1, "the setter ran once (%d)", held.writes);
	test::@check(held.reads == 2, "and the getter twice (%d)", held.reads);
}

<*
 A host-built array is an ordinary JavaScript array.

 Which is what makes `for (const dot of crig.data.dots)` work with nothing
 written on the JS side to make it work.
*>
fn void a_host_built_array_is_an_ordinary_array() @test
{
	qjs::Context? opened = qjs::open(memory_limit: SMALL_HEAP);
	if (catch opened) { test::@check(false, "the engine starts"); return; }
	qjs::Context js = opened;
	defer js.close();

	qjs::Value names = js.array();
	js.set_index(names, 0, js.string("Hips"));
	js.set_index(names, 1, js.string("Spine"));
	js.set_index(names, 2, js.string("Head"));
	test::@check(js.length(names) == 3, "the host reads its own length back (%d)", js.length(names));

	qjs::Value second = js.index(names, 1);
	defer js.release(second);
	String read = js.text(second);
	defer alloc::free(mem, read.ptr);
	test::@check(read == "Spine", "and one element of it (%s)", read);

	qjs::Value global = js.global();
	defer js.release(global);
	js.set_property(global, "names", names);

	qjs::Value? joined = js.eval(`[...names].map(n => n.toLowerCase()).join("/")`);
	if (catch joined) { test::@check(false, "the script spreads and maps it"); return; }
	defer js.release(joined);

	String text = js.text(joined);
	defer alloc::free(mem, text.ptr);
	test::@check(text == "hips/spine/head", "the script sees a real array (%s)", text);
}

<*
 A typed array over the host's own memory, and what happens when that memory
 goes away.

 Zero-copy is the reason for it: a mesh's positions are megabytes and a script
 that wants to measure them should not pay for a JSON copy of them. The hazard is
 the same fact from the other side — the engine has no idea when the host frees
 the pages — so the check that matters is the second half: detaching turns every
 view into a `TypeError` at the moment it happens, rather than a read of released
 memory some time later.
*>
fn void a_typed_array_shares_the_hosts_memory_until_it_is_detached() @test
{
	qjs::Context? opened = qjs::open(memory_limit: SMALL_HEAP);
	if (catch opened) { test::@check(false, "the engine starts"); return; }
	qjs::Context js = opened;
	defer js.close();

	float[6] samples = { 0.0f, 0.25f, 0.5f, 0.75f, 1.0f, 1.25f };

	qjs::Value buffer = js.buffer((char*)&samples[0], @sizeof(samples));
	defer js.release(buffer);

	qjs::Value global = js.global();
	defer js.release(global);
	js.set_property(global, "samples", js.typed_array(qjs::ARRAY_FLOAT32, buffer, 0, 6));

	qjs::Value? total = js.eval("samples.reduce((a, b) => a + b, 0)");
	if (catch total) { test::@check(false, "the script reads the array"); return; }
	defer js.release(total);
	test::@check(math::abs(js.number(total) - 3.75) < 1e-6,
		"the script sums the host's own floats (%.4f, wanted 3.75)", js.number(total));

	qjs::Value? wrote = js.eval("samples[0] = 9; samples.length");
	if (catch wrote) { test::@check(false, "the script writes into it"); return; }
	defer js.release(wrote);
	test::@check(samples[0] == 9.0f, "and the write lands in the host's array (%.4f)", (double)samples[0]);
	test::@check(js.number(wrote) == 6.0, "with the length the host gave it (%.0f)", js.number(wrote));

	// The moment the host would free or replace the memory.
	js.detach(buffer);

	qjs::Value? after = js.eval("samples.length");
	if (catch after) { test::@check(false, "reading the length of a detached view is not itself a throw"); return; }
	defer js.release(after);
	test::@check(js.number(after) == 0.0, "a detached view has no elements (%.0f)", js.number(after));

	qjs::Value? refused = js.eval("samples.reduce((a, b) => a + b, 0)");
	test::@check(@catch(refused) == qjs::THREW, "and using one throws rather than reading freed memory");
	if (try refused) js.release(refused);

	String why = js.exception();
	defer alloc::free(mem, why.ptr);
	test::@check(why.contains("TypeError"), "as a TypeError (%s)", why);

	// Twice, because the host detaches every buffer it handed out when the thing
	// behind them is replaced and cannot know which are already gone.
	js.detach(buffer);
}

<*
 A shared buffer the script can read and cannot change.

 Sharing memory means a script sees the host's arrays; it should not also mean it
 can write into them behind whatever bookkeeping the host keeps — a mesh's
 vertices moved from JavaScript would be an edit with no undo and no rebind
 behind it. Read-only says so at the point of the write rather than in a
 paragraph nobody read.
*>
fn void a_frozen_buffer_can_be_read_but_not_written() @test
{
	qjs::Context? opened = qjs::open(memory_limit: SMALL_HEAP);
	if (catch opened) { test::@check(false, "the engine starts"); return; }
	qjs::Context js = opened;
	defer js.close();

	uint[3] counts = { 4, 5, 6 };

	qjs::Value buffer = js.buffer((char*)&counts[0], @sizeof(counts));
	defer js.release(buffer);
	test::@check(js.freeze(buffer), "the buffer is made read-only");

	qjs::Value global = js.global();
	defer js.release(global);
	js.set_property(global, "counts", js.typed_array(qjs::ARRAY_UINT32, buffer, 0, 3));

	qjs::Value? read = js.eval("counts[1]");
	if (catch read) { test::@check(false, "the script still reads it"); return; }
	defer js.release(read);
	test::@check(js.number(read) == 5.0, "reading is unaffected (%.0f)", js.number(read));

	// Sloppy mode first, because that is what a script written without ceremony
	// runs in: JavaScript's own rule for a refused write is to drop it silently.
	qjs::Value? dropped = js.eval("counts[1] = 99; counts[1]");
	if (catch dropped) { test::@check(false, "a refused write is not a throw outside strict mode"); return; }
	defer js.release(dropped);
	test::@check(js.number(dropped) == 5.0, "the write did not land (%.0f)", js.number(dropped));

	// And strict mode is the same answer, not a louder one: the engine refuses
	// the element write in its fast path rather than reporting a failed [[Set]]
	// back to the assignment, so there is nothing for `use strict` to turn into a
	// throw. Worth pinning down, because "read-only" that quietly succeeded would
	// be far worse than one that quietly fails.
	qjs::Value? strict = js.eval(`"use strict"; counts[1] = 99; counts[1]`);
	if (catch strict) { test::@check(false, "strict mode runs"); return; }
	defer js.release(strict);
	test::@check(js.number(strict) == 5.0, "strict mode drops it too (%.0f)", js.number(strict));

	test::@check(counts[1] == 5, "the host's array is untouched either way (%d)", counts[1]);

	// The bulk methods do throw, which is where a script that ignored the above
	// finds out.
	qjs::Value? refused = js.eval("counts.set([1, 2, 3])");
	test::@check(@catch(refused) == qjs::THREW, "and TypedArray.set refuses outright");
	if (try refused) js.release(refused);

	String why = js.exception();
	defer alloc::free(mem, why.ptr);
	test::@check(why.contains("immutable"), "saying which buffer it is (%s)", why);
}

<*
 A function the script defined is callable from here, with arguments.

 The third direction across the boundary, and the last one missing: values
 written here and read by the engine (`eval`), values written by the engine and
 read here (`text`, `number`), values the engine writes and a host function
 reads (`adds_up`) — and now values written here that the engine hands to a
 script as arguments. A host loop that ticks a script once a frame is this call
 and nothing else.
*>
fn void a_host_can_call_a_function_the_script_defined() @test
{
	qjs::Context? opened = qjs::open(memory_limit: SMALL_HEAP);
	if (catch opened) { test::@check(false, "the engine starts"); return; }
	qjs::Context js = opened;
	defer js.close();

	qjs::Value? defined = js.eval("function blend(a, b) { return a * 0.25 + b * 0.75 }");
	if (catch defined) { test::@check(false, "the script defines it"); return; }
	js.release(defined);

	qjs::Value global = js.global();
	defer js.release(global);

	qjs::Value blend = js.property(global, "blend");
	defer js.release(blend);
	test::@check(js.is_function(blend), "and the host finds it on the global");

	// Numbers are inline values with nothing allocated behind them, so these
	// need no release. The borrow rule is the point rather than the leak: `call`
	// does not consume its arguments, and an object among them would still be
	// the caller's afterwards.
	qjs::Value[2] args = { qjs::number_value(4), qjs::number_value(8) };
	qjs::Value? answer = js.call(blend, qjs::undefined_value(), args[..]);
	if (catch answer) { test::@check(false, "the call runs"); return; }
	defer js.release(answer);
	test::@check(math::abs(js.number(answer) - 7.0) < 1e-12,
		"both arguments crossed and the answer came back (%.4f, wanted 7)", js.number(answer));

	// Again, because a call that consumed its function would work exactly once
	// and then read a released object — a frame-two crash for a hook resolved on
	// frame one, which is the shape of bug this binding's pointer discipline is
	// for.
	qjs::Value? again = js.call(blend, qjs::undefined_value(), args[..]);
	if (catch again) { test::@check(false, "the same function is still callable"); return; }
	defer js.release(again);
	test::@check(math::abs(js.number(again) - 7.0) < 1e-12,
		"with the same answer the second time (%.4f)", js.number(again));

	// A function made on this side is callable from this side too, which is what
	// a prelude wrapping a host call in JavaScript ends up handing back.
	qjs::Value hosted = js.function(&adds_up, "addsUp", 2);
	defer js.release(hosted);
	test::@check(js.is_function(hosted), "a host-made function is one as well");
}

<*
 And it can be given a receiver, which is what makes a method callable.
*>
fn void a_call_can_choose_its_receiver() @test
{
	qjs::Context? opened = qjs::open(memory_limit: SMALL_HEAP);
	if (catch opened) { test::@check(false, "the engine starts"); return; }
	qjs::Context js = opened;
	defer js.close();

	qjs::Value? defined = js.eval("function label() { return this.joint }");
	if (catch defined) { test::@check(false, "the script defines it"); return; }
	js.release(defined);

	qjs::Value global = js.global();
	defer js.release(global);

	qjs::Value label = js.property(global, "label");
	defer js.release(label);

	qjs::Value receiver = js.object();
	defer js.release(receiver);
	js.set_property(receiver, "joint", js.string("left_hand"));

	qjs::Value? answer = js.call(label, receiver);
	if (catch answer) { test::@check(false, "the call runs"); return; }
	defer js.release(answer);

	String text = js.text(answer);
	defer alloc::free(mem, text.ptr);
	test::@check(text == "left_hand", "the function saw the receiver it was given (%s)", text);

	// Borrowed, not consumed: the receiver is still a live object here.
	qjs::Value again = js.property(receiver, "joint");
	defer js.release(again);
	String still = js.text(again);
	defer alloc::free(mem, still.ptr);
	test::@check(still == "left_hand", "and the receiver survived the call (%s)", still);
}

<*
 A throw inside the call is a fault here, and the engine keeps running.

 Both halves matter for a script driving a scene: the host has to be able to put
 the message on screen, and it has to be able to draw the next frame — a play
 loop that tore down its engine on the first typo would be unusable.
*>
fn void a_call_that_throws_arrives_as_a_fault() @test
{
	qjs::Context? opened = qjs::open(memory_limit: SMALL_HEAP);
	if (catch opened) { test::@check(false, "the engine starts"); return; }
	qjs::Context js = opened;
	defer js.close();

	qjs::Value? defined = js.eval("function boom() { throw new Error('no clip is bound') }");
	if (catch defined) { test::@check(false, "the script defines it"); return; }
	js.release(defined);

	qjs::Value global = js.global();
	defer js.release(global);

	qjs::Value boom = js.property(global, "boom");
	defer js.release(boom);

	qjs::Value? refused = js.call(boom);
	test::@check(@catch(refused) == qjs::THREW, "the throw arrives as a fault, not a poisoned value");
	if (try refused) js.release(refused);

	String why = js.exception();
	defer alloc::free(mem, why.ptr);
	test::@check(why.contains("no clip is bound"), "carrying the script's own sentence (%s)", why);

	qjs::Value? after = js.eval("1 + 1");
	if (catch after) { test::@check(false, "the engine still runs afterwards"); return; }
	defer js.release(after);
	test::@check(js.number(after) == 2.0, "and answers (%.0f)", js.number(after));
}

<*
 Calling something that is not a function is refused rather than jumped to.

 The case a host reaches by looking for a hook the script never wrote, which is
 the normal state of a script being edited — hence `is_function`, so absence can
 be silence instead of an exception once a frame.
*>
fn void calling_something_that_is_not_a_function_is_refused() @test
{
	qjs::Context? opened = qjs::open(memory_limit: SMALL_HEAP);
	if (catch opened) { test::@check(false, "the engine starts"); return; }
	qjs::Context js = opened;
	defer js.close();

	qjs::Value global = js.global();
	defer js.release(global);
	js.set_property(global, "update", qjs::number_value(3));

	qjs::Value hook = js.property(global, "update");
	defer js.release(hook);
	test::@check(!js.is_function(hook), "a number is not callable");

	qjs::Value missing = js.property(global, "neverDefined");
	defer js.release(missing);
	test::@check(!js.is_function(missing), "and neither is a name nothing ever wrote");

	qjs::Value? refused = js.call(hook);
	test::@check(@catch(refused) == qjs::THREW, "calling one is a fault rather than a jump into a number");
	if (try refused) js.release(refused);

	String why = js.exception();
	defer alloc::free(mem, why.ptr);
	test::@check(why.contains("not a function"), "saying what was wrong with it (%s)", why);
}

<*
 Source that is not zero-terminated still parses.

 `JS_Eval` and `JS_ParseJSON` both document `buf[len] == '\0'` as a requirement,
 and a `String` in C3 makes no such promise: a literal has one because the
 compiler puts it there, and a slice of a file read off disk does not. The
 binding copies rather than trusting, which is what this pins down.

 Built as a slice of a longer buffer with deliberate garbage after it, because
 that is the shape of the bug: the engine reads one byte past the end and parses
 it, and what comes back is a `SyntaxError` about a byte the caller never wrote.
 A heap allocation that happened to be followed by a zero would pass either way,
 which is why this cannot be left to a plain string.
*>
fn void source_that_is_not_zero_terminated_still_parses() @test
{
	qjs::Context? opened = qjs::open(memory_limit: SMALL_HEAP);
	if (catch opened) { test::@check(false, "the engine starts"); return; }
	qjs::Context js = opened;
	defer js.close();

	// `7 + 1` followed by something that would change the answer if it were read.
	char[16] buffer = { '7', ' ', '+', ' ', '1', '2', '3', '4', '5', 0xC3, 0x28, 'x', 'x', 'x', 'x', 'x' };
	String source = (String)buffer[:5];

	qjs::Value? answer = js.eval(source);
	if (catch answer)
	{
		String why = js.exception();
		defer alloc::free(mem, why.ptr);
		test::@check(false, "an unterminated source parsed (%s)", why);
		return;
	}
	defer js.release(answer);
	test::@check(js.number(answer) == 8.0,
		"and stopped exactly at the length it was given (%.0f, wanted 8)", js.number(answer));

	// The same for JSON, which carries the same requirement.
	char[16] json = { '{', '"', 'a', '"', ':', '1', '}', ',', 'j', 'u', 'n', 'k', 0xFF, 0xFE, 0, 0 };
	qjs::Value? parsed = js.from_json((String)json[:7]);
	if (catch parsed) { test::@check(false, "an unterminated JSON body parsed"); return; }
	defer js.release(parsed);

	qjs::Value a = js.property(parsed, "a");
	defer js.release(a);
	test::@check(js.number(a) == 1.0, "with the object it described (%.0f)", js.number(a));
}

// ---------------------------------------------------------------------------
// Modules.
//
// A fake filesystem, because the thing under test is the loader protocol and
// not anybody's directory layout. `names` and `sources` are parallel; both hold
// literals, whose bytes are static, which is what makes returning a pointer
// into one of them from `fake_load` correct without any lifetime bookkeeping.

struct FakeModules
{
	String[] names;
	String[] sources;
	// What the last normalize call was told the importer was. Kept so a test can
	// assert the base is real rather than empty — a loader handed "" for every
	// import cannot resolve a relative specifier, and would look fine until the
	// first subdirectory.
	char[256] last_base;
	usz normalize_calls;
	bool refuse;
	// Every load is answered out of this one buffer, overwritten each time.
	// The shim documents the source as borrowed and compiled during the call;
	// if it ever retained the pointer instead, a two-deep import would compile
	// the *inner* module's bytes twice and `a_module_can_import_another` would
	// stop resolving. A fake that returned its literals directly could not tell
	// the difference, because a literal's bytes are static and never move.
	char[512] scratch;
}

fn int fake_normalize(ZString base, ZString name, char* out, usz out_size, void* opaque) @local
{
	FakeModules* store = (FakeModules*)opaque;
	store.normalize_calls++;

	String seen = base.str_view();
	usz kept = seen.len < 255 ? seen.len : 255;
	for (usz i = 0; i < kept; i++) store.last_base[i] = seen[i];
	store.last_base[kept] = 0;

	if (store.refuse) return -1;

	// The name is the key: this fake has no directories to resolve against.
	String want = name.str_view();
	if (want.len + 1 > out_size) return -1;
	for (usz i = 0; i < want.len; i++) out[i] = want[i];
	out[want.len] = 0;
	return 0;
}

fn char* fake_load(ZString name, usz* len_out, void* opaque) @local
{
	FakeModules* store = (FakeModules*)opaque;
	String want = name.str_view();
	foreach (i, known : store.names)
	{
		if (known == want)
		{
			String source = store.sources[i];
			if (source.len > 512) return null;
			for (usz b = 0; b < source.len; b++) store.scratch[b] = source[b];
			*len_out = source.len;
			return &store.scratch[0];
		}
	}
	return null;
}

<*
 Drive a module to completion.

 Module evaluation hands back a promise even when nothing in it awaits, so a
 test that stopped at `eval` would assert against a scene that had not run yet.
*>
macro @settle(js)
{
	while (js.jobs_waiting()) js.step_job();
}

fn void a_module_can_import_another() @test
{
	qjs::Context? opened = qjs::open(memory_limit: SMALL_HEAP);
	if (catch opened) { test::@check(false, "the engine starts"); return; }
	qjs::Context js = opened;
	defer js.close();

	String[2] names = { "lib.js", "deeper.js" };
	String[2] sources = {
		"import { two } from 'deeper.js'; export const answer = 40 + two;",
		"export const two = 2;",
	};
	FakeModules store = { .names = names[..], .sources = sources[..] };
	qjs::ModuleHooks hooks = { .normalize = &fake_normalize, .load = &fake_load, .opaque = &store };
	js.on_modules(&hooks);

	qjs::Value? started = js.eval(
		"import { answer } from 'lib.js'; globalThis.result = answer;",
		"main.js", qjs::EVAL_MODULE);
	if (catch started)
	{
		String why = js.exception();
		defer alloc::free(mem, why.ptr);
		test::@check(false, "the entry module evaluated (%s)", why);
		return;
	}
	js.release(started);
	@settle(js);

	qjs::Value global = js.global();
	defer js.release(global);
	qjs::Value result = js.property(global, "result");
	defer js.release(result);

	test::@check(js.number(result) == 42.0,
		"and the import chain resolved two deep (%.0f, wanted 42)", js.number(result));
	test::@check(store.normalize_calls == 2,
		"one normalize per import, not per module (%d)", store.normalize_calls);
	test::@check(((ZString)&store.last_base[0]).str_view() == "lib.js",
		"and the second import was resolved against the module that wrote it (%s)",
		((ZString)&store.last_base[0]).str_view());
}

<*
 An import the host refuses is refused, rather than falling through to a
 filesystem the host never agreed to.

 This is the check that a sandbox is a sandbox: `refuse` stands for any policy —
 a path outside the assets root, a specifier with no extension, a bare name that
 is not a real file — and what matters is that saying no is possible and lands
 as an error the script can see.
*>
fn void an_import_the_host_refuses_never_reaches_the_loader() @test
{
	qjs::Context? opened = qjs::open(memory_limit: SMALL_HEAP);
	if (catch opened) { test::@check(false, "the engine starts"); return; }
	qjs::Context js = opened;
	defer js.close();

	String[1] names = { "secrets.js" };
	String[1] sources = { "export const key = 'must not be reachable';" };
	FakeModules store = { .names = names[..], .sources = sources[..], .refuse = true };
	qjs::ModuleHooks hooks = { .normalize = &fake_normalize, .load = &fake_load, .opaque = &store };
	js.on_modules(&hooks);

	qjs::Value? started = js.eval(
		"import { key } from 'secrets.js'; globalThis.leaked = key;",
		"main.js", qjs::EVAL_MODULE);
	if (try started)
	{
		js.release(started);
		@settle(js);
		test::@check(false, "a refused import was allowed through");
		return;
	}

	String why = js.exception();
	defer alloc::free(mem, why.ptr);
	test::@check(why.contains("secrets.js"),
		"and the error names what was asked for (%s)", why);
}

<*
 A module the loader cannot find is a `ReferenceError` naming it, not a crash
 and not a silent empty module.
*>
fn void a_module_that_is_not_there_says_which() @test
{
	qjs::Context? opened = qjs::open(memory_limit: SMALL_HEAP);
	if (catch opened) { test::@check(false, "the engine starts"); return; }
	qjs::Context js = opened;
	defer js.close();

	String[1] names = { "present.js" };
	String[1] sources = { "export const x = 1;" };
	FakeModules store = { .names = names[..], .sources = sources[..] };
	qjs::ModuleHooks hooks = { .normalize = &fake_normalize, .load = &fake_load, .opaque = &store };
	js.on_modules(&hooks);

	qjs::Value? started = js.eval("import { x } from 'absent.js';", "main.js", qjs::EVAL_MODULE);
	if (try started)
	{
		js.release(started);
		test::@check(false, "an import of a module that does not exist succeeded");
		return;
	}

	String why = js.exception();
	defer alloc::free(mem, why.ptr);
	test::@check(why.contains("absent.js"), "and the error names it (%s)", why);
}

<*
 With no loader installed, an import fails — and this pins the behaviour that
 made the feature worth building, because the failure does not mention modules.

 The parse succeeds; the death arrives at link time from somewhere that names
 neither `import` nor the missing loader. Anyone meeting it for the first time
 reads it as a broken script rather than as a host that never installed a hook.
*>
fn void without_a_loader_an_import_fails() @test
{
	qjs::Context? opened = qjs::open(memory_limit: SMALL_HEAP);
	if (catch opened) { test::@check(false, "the engine starts"); return; }
	qjs::Context js = opened;
	defer js.close();

	qjs::Value? started = js.eval("import { x } from 'anything.js';", "main.js", qjs::EVAL_MODULE);
	if (try started)
	{
		js.release(started);
		test::@check(false, "an import resolved with no loader installed");
		return;
	}
	// Deliberately not asserting the message: it is quickjs's, it is unhelpful,
	// and that unhelpfulness is the point rather than a contract.
	String why = js.exception();
	alloc::free(mem, why.ptr);
}

<*
 A module may be evaluated with no imports at all, which is the case a host hits
 first and the one most likely to be broken by an over-eager loader.
*>
fn void a_module_with_no_imports_needs_no_loader() @test
{
	qjs::Context? opened = qjs::open(memory_limit: SMALL_HEAP);
	if (catch opened) { test::@check(false, "the engine starts"); return; }
	qjs::Context js = opened;
	defer js.close();

	qjs::Value? started = js.eval("globalThis.ran = 7;", "main.js", qjs::EVAL_MODULE);
	if (catch started) { test::@check(false, "a module with no imports evaluated"); return; }
	js.release(started);
	@settle(js);

	qjs::Value global = js.global();
	defer js.release(global);
	qjs::Value ran = js.property(global, "ran");
	defer js.release(ran);
	test::@check(js.number(ran) == 7.0, "and its top level ran (%.0f)", js.number(ran));
}
