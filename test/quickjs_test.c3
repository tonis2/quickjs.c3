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
import std::core::mem;
import std::core::mem::allocator;
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
