#include "qjs_shim.h"
#include "quickjs.h"

/* QjsValue and JSValue are the same sixteen bytes; only this file knows that.
   The casts are through a union rather than a pointer cast so the compiler is
   not asked to believe two unrelated types alias. */
typedef union { QjsValue shim; JSValue real; } Both;

static JSValue in(const QjsValue *v)
{
    Both b;
    b.shim = *v;
    return b.real;
}

static void out(JSValue v, QjsValue *slot)
{
    Both b;
    b.real = v;
    *slot = b.shim;
}

/* --- runtime and context ------------------------------------------------ */

JSRuntime *qjs_new_runtime(void) { return JS_NewRuntime(); }
void qjs_free_runtime(JSRuntime *rt) { JS_FreeRuntime(rt); }
JSContext *qjs_new_context(JSRuntime *rt) { return JS_NewContext(rt); }
void qjs_free_context(JSContext *ctx) { JS_FreeContext(ctx); }
JSRuntime *qjs_runtime_of(JSContext *ctx) { return JS_GetRuntime(ctx); }

void qjs_set_memory_limit(JSRuntime *rt, size_t bytes) { JS_SetMemoryLimit(rt, bytes); }
void qjs_set_max_stack_size(JSRuntime *rt, size_t bytes) { JS_SetMaxStackSize(rt, bytes); }
void qjs_run_gc(JSRuntime *rt) { JS_RunGC(rt); }

void qjs_set_interrupt_handler(JSRuntime *rt, qjs_interrupt_fn *cb, void *opaque)
{
    JS_SetInterruptHandler(rt, cb, opaque);
}

int qjs_job_pending(JSRuntime *rt) { return JS_IsJobPending(rt) ? 1 : 0; }

int qjs_execute_pending_job(JSRuntime *rt)
{
    JSContext *unused;
    return JS_ExecutePendingJob(rt, &unused);
}

/* --- values ------------------------------------------------------------- */

void qjs_free_value(JSContext *ctx, const QjsValue *v) { JS_FreeValue(ctx, in(v)); }

void qjs_dup_value(JSContext *ctx, const QjsValue *v, QjsValue *slot)
{
    out(JS_DupValue(ctx, in(v)), slot);
}

int qjs_tag(const QjsValue *v) { return JS_VALUE_GET_NORM_TAG(in(v)); }
int qjs_is_exception(const QjsValue *v) { return JS_IsException(in(v)) ? 1 : 0; }
int qjs_is_undefined(const QjsValue *v) { return JS_IsUndefined(in(v)) ? 1 : 0; }
int qjs_is_null(const QjsValue *v) { return JS_IsNull(in(v)) ? 1 : 0; }
int qjs_is_error(JSContext *ctx, const QjsValue *v) { (void)ctx; return JS_IsError(in(v)) ? 1 : 0; }

void qjs_undefined(QjsValue *slot) { out(JS_UNDEFINED, slot); }
void qjs_null(QjsValue *slot) { out(JS_NULL, slot); }
void qjs_new_bool(int b, QjsValue *slot) { out(JS_NewBool(NULL, b != 0), slot); }
void qjs_new_int32(int32_t n, QjsValue *slot) { out(JS_NewInt32(NULL, n), slot); }
void qjs_new_float64(double d, QjsValue *slot) { out(JS_NewFloat64(NULL, d), slot); }

void qjs_new_string(JSContext *ctx, const char *s, size_t len, QjsValue *slot)
{
    out(JS_NewStringLen(ctx, s, len), slot);
}

int qjs_to_float64(JSContext *ctx, const QjsValue *v, double *res)
{
    return JS_ToFloat64(ctx, res, in(v));
}

int qjs_to_int32(JSContext *ctx, const QjsValue *v, int32_t *res)
{
    return JS_ToInt32(ctx, res, in(v));
}

int qjs_to_bool(JSContext *ctx, const QjsValue *v) { return JS_ToBool(ctx, in(v)); }

const char *qjs_to_cstring(JSContext *ctx, const QjsValue *v, size_t *len)
{
    return JS_ToCStringLen(ctx, len, in(v));
}

void qjs_free_cstring(JSContext *ctx, const char *s) { JS_FreeCString(ctx, s); }

/* --- objects ------------------------------------------------------------ */

void qjs_global(JSContext *ctx, QjsValue *slot) { out(JS_GetGlobalObject(ctx), slot); }
void qjs_new_object(JSContext *ctx, QjsValue *slot) { out(JS_NewObject(ctx), slot); }

void qjs_get_prop(JSContext *ctx, const QjsValue *obj, const char *name, QjsValue *slot)
{
    out(JS_GetPropertyStr(ctx, in(obj), name), slot);
}

int qjs_set_prop(JSContext *ctx, const QjsValue *obj, const char *name, const QjsValue *value)
{
    return JS_SetPropertyStr(ctx, in(obj), name, in(value));
}

/* --- evaluating --------------------------------------------------------- */

void qjs_eval(JSContext *ctx, const char *src, size_t len, const char *filename,
              int type, QjsValue *slot)
{
    int flags = type == QJS_EVAL_MODULE ? JS_EVAL_TYPE_MODULE : JS_EVAL_TYPE_GLOBAL;
    out(JS_Eval(ctx, src, len, filename, flags), slot);
}

void qjs_take_exception(JSContext *ctx, QjsValue *slot)
{
    out(JS_GetException(ctx), slot);
}
