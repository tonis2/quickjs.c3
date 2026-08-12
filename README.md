# quickjs.c3

[quickjs-ng](https://github.com/quickjs-ng/quickjs) as a C3 library. The engine is
a git submodule at `vendor/quickjs-ng`, not a copy in this tree — no CMake step
and nothing to install.

```sh
git clone --recursive <this repo>          # or, after a plain clone:
git submodule update --init --recursive
```

The gitlink is the version record: it names the exact upstream commit, and `git
diff` shows an engine bump as one line instead of eighty thousand. Note that a
submodule *pins* — `--recursive` fetches the commit this library was built and
tested against, which is the point. Move it deliberately:

```sh
git -C vendor/quickjs-ng fetch && git -C vendor/quickjs-ng checkout <commit>
native/build-quickjs.sh <targets…>          # rebuild the archives
c3c test                                    # then commit both
```

Consumers link a prebuilt `lib/<target>/libquickjs.a` rather than compiling the
engine, because `c3c` has no object cache and `quickjs.c` is 2 MB of C: as a
`c-sources` entry it cost ~4.2 s on *every* build of the consuming app, changes or
not. The archive is committed for the targets under `lib/`; on any other platform,
run `native/build-quickjs.sh` once and commit what it writes. `native/qjs_shim.c`
is **not** in the archive — it is the file this binding edits, it compiles in
0.03 s, and archiving it would mean re-running the script after every change. It
does `#include "quickjs.h"`, so the submodule has to be checked out even though
the engine is linked rather than compiled.

Developing the binding builds the engine from source instead: `project.json`
points its `c-sources` at `vendor/quickjs-ng`, so `c3c test` here compiles against
the exact upstream the gitlink names, and an engine bump that breaks the shim
fails in this repo rather than in somebody's app.

## Building an archive for another target

**Give the compiler a target; don't expect `--target` to.** c3c never passes
`-target` to the C compiler — it hands each `c-sources` file to whatever `--cc`
names, defaulting to the host's, and archives the result without complaining. On
0.8.2, `c3c build quickjs --target linux-x64` from an arm Mac reports success and
writes an archive holding one ELF x86-64 object beside five Mach-O arm64 ones. The
fix is a compiler already aimed at the target, which `--cc` selects.

```sh
native/build-quickjs.sh macos-aarch64 macos-x64   # Xcode clang, both slices
native/build-quickjs.sh windows-x64               # needs mingw-w64
native/build-quickjs.sh linux-x64                 # on Linux, or a linux cross-gcc
```

The script refuses any target whose compiler is missing rather than falling back
to the host's and producing the wrong object format.

**Windows** is cross-built from macOS and works end to end, but the arrangement is
worth understanding. c3c links `windows-x64` with `lld-link` against the MSVC CRT
it downloads to `~/.cache/c3/msvc_sdk` — 694 MB of import libraries with **zero
headers**, since C3 needs no C headers. So clang cannot compile C for that ABI at
all (`'stdlib.h' file not found`). mingw-w64 supplies the headers, and its objects
link against the MSVC CRT once three flags stop them reaching for mingw's own
runtime — `-D__USE_MINGW_ANSI_STDIO=0` (else printf redirects to
`__mingw_vsnprintf` in libmingwex), `-fno-stack-protector` (libssp),
`-mno-stack-arg-probe` (`___chkstk_ms` in libgcc). `manifest.json` carries them
under `windows-x64` so `qjs_shim.c` gets them too, and a consumer builds with:

```sh
c3c build <target> --target windows-x64 --cc x86_64-w64-mingw32-gcc
```

Verified to a 1.6 MB PE32+ console binary with the engine linked in; not executed,
since that needs a Windows box.

c3c's other Windows target, `mingw-x64`, is not shipped: on 0.8.2 it cannot link
even a hello world from macOS, because its own `std.io` objects call
`___chkstk_ms` and the link provides no libgcc. That is upstream, not here.

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
