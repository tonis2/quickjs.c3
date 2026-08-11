/*
 * A flat C surface over quickjs-ng, for binding from a language that is not C.
 *
 * Two things here are not conveniences.
 *
 * **JSValue never crosses the boundary by value.** On a 64-bit build it is
 * `{ union { int32_t; double; void*; } u; int64_t tag; }` — sixteen bytes, two
 * eightbytes, returned in a register pair under both AAPCS64 and SysV. A caller
 * that lowers it even slightly differently gets silent corruption rather than a
 * link error, and the failure surfaces as a garbage tag somewhere far away. Every
 * function below takes and returns it through a pointer instead, which is one
 * indirection nobody will ever measure and one entire class of bug that cannot
 * happen.
 *
 * **The inline half of the API is not in the object file.** `JS_VALUE_GET_TAG`,
 * `JS_FreeValue`, `JS_NewInt32`, `JS_IsUndefined` and friends are macros and
 * `static inline` functions in quickjs.h, so a binding that only links against
 * the library finds nothing to call. They are re-exported here as real symbols.
 */
#ifndef QJS_SHIM_H
#define QJS_SHIM_H

#include <stddef.h>
#include <stdint.h>

typedef struct JSRuntime JSRuntime;
typedef struct JSContext JSContext;

/* Sixteen bytes, matching JSValue on a 64-bit build. The caller allocates one
   of these and hands its address over; the layout is never read on this side. */
typedef struct QjsValue { uint64_t a; uint64_t b; } QjsValue;

/* --- runtime and context ------------------------------------------------ */

JSRuntime *qjs_new_runtime(void);
void qjs_free_runtime(JSRuntime *rt);
JSContext *qjs_new_context(JSRuntime *rt);
void qjs_free_context(JSContext *ctx);
JSRuntime *qjs_runtime_of(JSContext *ctx);

void qjs_set_memory_limit(JSRuntime *rt, size_t bytes);
void qjs_set_max_stack_size(JSRuntime *rt, size_t bytes);
void qjs_run_gc(JSRuntime *rt);

/* Returns non-zero from the handler to abort the running script. */
typedef int qjs_interrupt_fn(JSRuntime *rt, void *opaque);
void qjs_set_interrupt_handler(JSRuntime *rt, qjs_interrupt_fn *cb, void *opaque);

/* The promise job queue, which is what an async script parks on. */
int qjs_job_pending(JSRuntime *rt);
int qjs_execute_pending_job(JSRuntime *rt);

/* --- values ------------------------------------------------------------- */

void qjs_free_value(JSContext *ctx, const QjsValue *v);
void qjs_dup_value(JSContext *ctx, const QjsValue *v, QjsValue *out);

int qjs_tag(const QjsValue *v);
int qjs_is_exception(const QjsValue *v);
int qjs_is_undefined(const QjsValue *v);
int qjs_is_null(const QjsValue *v);
int qjs_is_error(JSContext *ctx, const QjsValue *v);

void qjs_undefined(QjsValue *out);
void qjs_null(QjsValue *out);
void qjs_new_bool(int b, QjsValue *out);
void qjs_new_int32(int32_t n, QjsValue *out);
void qjs_new_float64(double d, QjsValue *out);
void qjs_new_string(JSContext *ctx, const char *s, size_t len, QjsValue *out);

/* 0 on success. */
int qjs_to_float64(JSContext *ctx, const QjsValue *v, double *out);
int qjs_to_int32(JSContext *ctx, const QjsValue *v, int32_t *out);
int qjs_to_bool(JSContext *ctx, const QjsValue *v);

/* The string is owned by the context; release it with qjs_free_cstring. NULL on
   failure. `len` may be NULL. */
const char *qjs_to_cstring(JSContext *ctx, const QjsValue *v, size_t *len);
void qjs_free_cstring(JSContext *ctx, const char *s);

/* --- objects ------------------------------------------------------------ */

void qjs_global(JSContext *ctx, QjsValue *out);
void qjs_new_object(JSContext *ctx, QjsValue *out);
void qjs_get_prop(JSContext *ctx, const QjsValue *obj, const char *name, QjsValue *out);
/* Takes ownership of *value, as JS_SetPropertyStr does. */
int qjs_set_prop(JSContext *ctx, const QjsValue *obj, const char *name, const QjsValue *value);

/* --- host functions ----------------------------------------------------- */

/*
 * A function written on the host side and called from JavaScript.
 *
 * `this_val` and `argv` are borrowed — do not release them. `out` is where the
 * return value goes, and it is owned by the engine once written. `opaque` is
 * whatever was handed to qjs_new_function.
 */
typedef void qjs_host_fn(JSContext *ctx, const QjsValue *this_val, int argc,
                         const QjsValue *argv, void *opaque, QjsValue *out);

/*
 * A JS function that calls `cb`. `argc` is the arity JS reports, not a limit —
 * a call may pass fewer or more, and the callback is told how many arrived.
 */
void qjs_new_function(JSContext *ctx, qjs_host_fn *cb, const char *name,
                      int argc, void *opaque, QjsValue *out);

/* --- errors ------------------------------------------------------------- */

/* An Error object with `message` set, owned by the caller. */
void qjs_new_error(JSContext *ctx, const char *message, QjsValue *out);

/* Throw *v, which is consumed. `out` receives the exception sentinel, which is
   what a host function returns after throwing. */
void qjs_throw(JSContext *ctx, const QjsValue *v, QjsValue *out);

/* --- JSON --------------------------------------------------------------- */

/* JSON.stringify(v). Undefined when the value has no JSON form — a function, or
   `undefined` itself. */
void qjs_json_stringify(JSContext *ctx, const QjsValue *v, QjsValue *out);

/* JSON.parse. Exception on malformed input. */
void qjs_json_parse(JSContext *ctx, const char *buf, size_t len,
                    const char *filename, QjsValue *out);

/* --- evaluating --------------------------------------------------------- */

#define QJS_EVAL_GLOBAL 0
#define QJS_EVAL_MODULE 1

void qjs_eval(JSContext *ctx, const char *src, size_t len, const char *filename,
              int type, QjsValue *out);

/* The pending exception, cleared. Undefined when there is none. */
void qjs_take_exception(JSContext *ctx, QjsValue *out);

#endif /* QJS_SHIM_H */
