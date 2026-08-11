# quickjs.c3

[quickjs-ng](https://github.com/quickjs-ng/quickjs) as a C3 library. The engine's C
sources are vendored and built by `c3c` itself — there is no static library to
build first, no CMake step, and nothing to install.

```c3
import qjs;

qjs::Context js = qjs::open(memory_limit: 64 * 1024 * 1024)!;
defer js.close();

qjs::Value? answer = js.eval("[1, 2, 3].reduce((a, b) => a + b)");
if (catch answer)
{
    String why = js.exception();
    defer alloc::free(mem, why.ptr);
    io::printfn("the script failed: %s", why);
    return;
}
defer js.release(answer);

io::printfn("%.0f", js.number(answer));   // 6
```

## Install

As a submodule, which is what keeps the vendored revision pinned:

```sh
git submodule add git@github.com:tonis2/quickjs.c3.git lib/quickjs.c3l
```

Then in your `project.json`:

```json
"dependency-search-paths": ["lib"],
"dependencies": ["quickjs"]
```

## What is vendored

Four of quickjs-ng's translation units — `dtoa.c`, `libregexp.c`, `libunicode.c`,
`quickjs.c` — and the headers they include, under `native/`. `native/REVISION`
records the upstream commit. `quickjs-libc.c` is **not** included: it is the module
that gives scripts files, processes and sockets, and a host embedding a scripting
language usually wants to decide about those itself.

To move to a newer upstream, copy those four `.c` files and the headers they
include over `native/`, update `REVISION`, and run the tests.

## Why there is a shim

`native/qjs_shim.c` is a flat C surface over the engine, and every function in it
takes and returns `JSValue` **through a pointer**. Two reasons, both load-bearing:

**The ABI.** On a 64-bit build `JSValue` is `{ union { int32_t; double; void*; } u;
int64_t tag; }` — sixteen bytes, two eightbytes, returned in a register pair under
both AAPCS64 and SysV. Binding it by value would be a bet that C3 lowers that struct
exactly the way the C compiler did. The bet is usually won, and losing it is silent:
a corrupted tag read as an object pointer, crashing somewhere with no visible
connection to the call that did it. Passing by address costs one indirection nobody
will measure and removes the question entirely.

**The inline half of the API is not in the object file.** `JS_FreeValue`,
`JS_VALUE_GET_TAG`, `JS_NewInt32`, `JS_IsUndefined` and many others are macros and
`static inline` functions in `quickjs.h`. A binding that only links against the
compiled sources finds nothing to call. The shim re-exports them as real symbols.

## Ownership

Every `Value` handed back is the caller's, and is released once with
`Context.release`. `defer` immediately after is the only sane way to write it.

`Context.set_property` **takes** ownership of the value it is given, matching the
engine's own rule — do not release that one.

Strings returned by `Context.text` and `Context.exception` are allocated from the
allocator passed in, **including when they come back empty**, so they are freed
unconditionally.

## Limits

A hosted engine that cannot be stopped is not safe to run inside an application, so
three things bound it, and each catches something the others do not:

| | |
|---|---|
| `open(memory_limit:)` | An allocation bomb becomes an out-of-memory exception. The engine survives it and runs the next script. |
| `open(stack_limit:)` | Unbounded recursion becomes an exception instead of a smashed native stack. |
| `Context.on_interrupt` | The only thing that stops `while (true) { n++; }`, which allocates nothing and recurses nowhere. Build a wall-clock budget on it. |

Clear the interrupt handler with `on_interrupt(null)` when the script is done, or
every later script in that context dies at its second instruction.

## Async

`Context.eval` returns as soon as a script suspends on an `await`; the continuation
sits on the job queue. A host drains it with `step_job`, one job at a time, which is
what lets a long script cooperate with a frame loop instead of owning the thread:

```c3
while (js.jobs_waiting())
{
    js.step_job();
    // draw a frame here
}
```

## Threads

A `JSRuntime` belongs to the thread that created it — the stack-overflow check
compares against the stack top recorded at creation — so a `Context` must not be
used from another thread.

## Testing

```sh
c3c test
```

Ten checks covering the value round-trips (which are the ABI checks), exceptions
and their stack traces, all three limits, and the job queue.

## Licence

The binding is MIT. The vendored engine is quickjs-ng, also MIT — its own notice is
kept at `native/LICENSE`.
