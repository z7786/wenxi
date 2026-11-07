#include "quickjs.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <stdint.h>
#ifdef _WIN32
#include <windows.h>
#define EXPORT __declspec(dllexport)
static double now_ms(void) { LARGE_INTEGER t, f; QueryPerformanceCounter(&t); QueryPerformanceFrequency(&f); return 1000.0 * t.QuadPart / f.QuadPart; }
#else
#include <time.h>
#define EXPORT __attribute__((visibility("default"))) __attribute__((used))
static double now_ms(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1000.0 + t.tv_nsec / 1000000.0; }
#endif
#define MAX_TEXT 1048576
#define MAX_QUEUE 8
typedef struct {
    int id, sent;
    char *method, *args;
    JSValue resolve, reject;
} HostCall;
typedef struct {
    JSRuntime *rt;
    JSContext *ctx;
    JSValue modules, module, ns, entry_result, result, input, api;
    char operation[65];
    HostCall calls[MAX_QUEUE];
    int next_id, count, called, begun;
    size_t queued_bytes;
    double cpu_ms, started, deadline;
    const char *error;
    char host_error[65];
} Bridge;
static char *copy_text(const char *text, size_t length) {
    if (length > MAX_TEXT) return NULL;
    char *out = malloc(length + 1);
    if (out) { memcpy(out, text, length); out[length] = 0; }
    return out;
}
static int interrupt(JSRuntime *rt, void *opaque) {
    Bridge *b = opaque; (void)rt;
    if (b->error || now_ms() >= b->deadline) { b->error = "SCRIPT_BUDGET"; return 1; }
    return 0;
}
static void enter(Bridge *b) {
    JS_UpdateStackTop(b->rt);
    b->started = now_ms();
    double left = 5000.0 - b->cpu_ms;
    if (left <= 0) b->error = "SCRIPT_BUDGET";
    b->deadline = b->started + (left < 250.0 ? left : 250.0);
}
static void leave(Bridge *b) {
    b->cpu_ms += now_ms() - b->started;
    if (b->cpu_ms >= 5000.0) b->error = "SCRIPT_BUDGET";
}
static void exception(Bridge *b) {
    JSValue error = JS_GetException(b->ctx);
    JS_FreeValue(b->ctx, error);
    if (!b->error) b->error = "SCRIPT_EXECUTION";
}
static void rejected(Bridge *b, JSValueConst promise, const char *fallback) {
    JSValue reason = JS_PromiseResult(b->ctx, promise);
    JSValue code = JS_IsObject(reason) ? JS_GetPropertyStr(b->ctx, reason, "code") : JS_UNDEFINED;
    size_t length = 0;
    const char *text = JS_IsString(code) ? JS_ToCStringLen(b->ctx, &length, code) : NULL;
    int valid = text && length > 7 && length < sizeof(b->host_error) && strncmp(text, "SOURCE_", 7) == 0;
    for (size_t i = 0; valid && i < length; i++)
        if (!((text[i] >= 'A' && text[i] <= 'Z') || (text[i] >= '0' && text[i] <= '9') || text[i] == '_')) valid = 0;
    if (!b->error) {
        if (valid) { memcpy(b->host_error, text, length); b->host_error[length] = 0; b->error = b->host_error; }
        else b->error = fallback;
    }
    if (text) JS_FreeCString(b->ctx, text);
    JS_FreeValue(b->ctx, code); JS_FreeValue(b->ctx, reason);
}
static char *stringify(Bridge *b, JSValueConst value) {
    JSValue json = JS_JSONStringify(b->ctx, value, JS_UNDEFINED, JS_UNDEFINED);
    if (JS_IsException(json) || JS_IsUndefined(json)) {
        JS_FreeValue(b->ctx, json); b->error = "SCRIPT_RESULT"; return NULL;
    }
    size_t length = 0;
    const char *text = JS_ToCStringLen(b->ctx, &length, json);
    char *out = text ? copy_text(text, length) : NULL;
    if (text) JS_FreeCString(b->ctx, text);
    JS_FreeValue(b->ctx, json);
    if (!out) b->error = "SCRIPT_RESULT";
    return out;
}
static JSModuleDef *load_module(JSContext *ctx, const char *name, void *opaque) {
    Bridge *b = opaque;
    JSValue source = JS_GetPropertyStr(ctx, b->modules, name);
    if (!JS_IsString(source)) { JS_FreeValue(ctx, source); JS_ThrowReferenceError(ctx, "Module not in package"); return NULL; }
    size_t length = 0;
    const char *text = JS_ToCStringLen(ctx, &length, source);
    JSValue module = text ? JS_Eval(ctx, text, length, name, JS_EVAL_TYPE_MODULE | JS_EVAL_FLAG_COMPILE_ONLY) : JS_EXCEPTION;
    if (text) JS_FreeCString(ctx, text);
    JS_FreeValue(ctx, source);
    if (JS_IsException(module)) return NULL;
    JSModuleDef *definition = JS_VALUE_GET_PTR(module);
    JS_FreeValue(ctx, module);
    return definition;
}
static JSValue host_call(JSContext *ctx, JSValueConst self, int argc, JSValueConst *argv) {
    Bridge *b = JS_GetContextOpaque(ctx); (void)self;
    if (argc != 2 || !JS_IsString(argv[0]) || b->count >= MAX_QUEUE || b->next_id >= 256)
        return JS_ThrowRangeError(ctx, "Host request limit");
    size_t length = 0;
    const char *method = JS_ToCStringLen(ctx, &length, argv[0]);
    if (!method || !length || length > 64) { if (method) JS_FreeCString(ctx, method); return JS_ThrowTypeError(ctx, "Host method"); }
    char *args = stringify(b, argv[1]);
    if (!args || b->queued_bytes + strlen(args) > 2 * MAX_TEXT) {
        free(args); JS_FreeCString(ctx, method); return JS_ThrowRangeError(ctx, "Host payload limit");
    }
    int slot = 0;
    while (slot < MAX_QUEUE && b->calls[slot].id) slot++;
    HostCall *call = &b->calls[slot];
    call->method = copy_text(method, length); call->args = args;
    JS_FreeCString(ctx, method);
    if (!call->method) { free(call->args); call->args = NULL; return JS_ThrowOutOfMemory(ctx); }
    JSValue callbacks[2];
    JSValue promise = JS_NewPromiseCapability(ctx, callbacks);
    if (JS_IsException(promise)) { free(call->method); free(call->args); memset(call, 0, sizeof(*call)); return promise; }
    call->resolve = callbacks[0]; call->reject = callbacks[1];
    call->id = ++b->next_id; b->count++; b->queued_bytes += strlen(args);
    return promise;
}
EXPORT Bridge *al_js_new(void) {
    Bridge *b = calloc(1, sizeof(*b));
    if (!b) return NULL;
    b->rt = JS_NewRuntime();
    if (!b->rt) { free(b); return NULL; }
    JS_SetMemoryLimit(b->rt, 32 * 1024 * 1024);
    JS_SetMaxStackSize(b->rt, 512 * 1024);
    JS_SetCanBlock(b->rt, false);
    b->ctx = JS_NewContext(b->rt);
    if (!b->ctx) { JS_FreeRuntime(b->rt); free(b); return NULL; }
    b->modules = b->module = b->ns = b->entry_result = b->result = b->input = b->api = JS_UNDEFINED;
    JS_SetContextOpaque(b->ctx, b);
    JS_SetInterruptHandler(b->rt, interrupt, b);
    JS_SetModuleLoaderFunc(b->rt, NULL, load_module, b);
    return b;
}
EXPORT int al_js_begin(Bridge *b, const char *packet) {
    if (!b || !packet || b->begun || strlen(packet) > MAX_TEXT) return 0;
    b->begun = 1; enter(b);
    JSContext *ctx = b->ctx;
    JSValue document = JS_ParseJSON(ctx, packet, strlen(packet), "package.json");
    if (JS_IsException(document)) { exception(b); leave(b); return 0; }
    b->modules = JS_GetPropertyStr(ctx, document, "modules");
    b->input = JS_GetPropertyStr(ctx, document, "input");
    JSValue entry = JS_GetPropertyStr(ctx, document, "entry"), op = JS_GetPropertyStr(ctx, document, "operation");
    const char *entry_text = JS_ToCString(ctx, entry), *op_text = JS_ToCString(ctx, op);
    if (!entry_text || !op_text || strlen(op_text) >= sizeof(b->operation)) b->error = "SCRIPT_PACKAGE";
    else strcpy(b->operation, op_text);
    JSValue global = JS_GetGlobalObject(ctx);
    JS_DefinePropertyValueStr(ctx, global, "__asterHost", JS_NewCFunction(ctx, host_call, "host", 2), 0);
    JS_FreeValue(ctx, global);
    const char *api_source = "Object.freeze({request:o=>__asterHost('request',o),html:(text,selectors)=>__asterHost('html',{text,selectors}),crypto:(op,args)=>__asterHost('crypto',{op,args}),codec:(op,args)=>__asterHost('codec',{op,args}),sleep:ms=>__asterHost('sleep',{ms})})";
    b->api = JS_Eval(ctx, api_source, strlen(api_source), "host-api.js", JS_EVAL_TYPE_GLOBAL);
    if (JS_IsException(b->api)) exception(b);
    if (!b->error) {
        JSValue source = JS_GetPropertyStr(ctx, b->modules, entry_text);
        size_t length = 0; const char *text = JS_IsString(source) ? JS_ToCStringLen(ctx, &length, source) : NULL;
        JSValue module = text ? JS_Eval(ctx, text, length, entry_text, JS_EVAL_TYPE_MODULE | JS_EVAL_FLAG_COMPILE_ONLY) : JS_EXCEPTION;
        if (text) JS_FreeCString(ctx, text);
        JS_FreeValue(ctx, source);
        if (JS_IsException(module)) exception(b);
        else {
            b->module = module;
            b->entry_result = JS_EvalFunction(ctx, JS_DupValue(ctx, module));
            if (JS_IsException(b->entry_result)) exception(b);
        }
    }
    if (entry_text) JS_FreeCString(ctx, entry_text);
    if (op_text) JS_FreeCString(ctx, op_text);
    JS_FreeValue(ctx, entry); JS_FreeValue(ctx, op); JS_FreeValue(ctx, document);
    leave(b); return b->error == NULL;
}
static void drain(Bridge *b) {
    JSContext *ctx;
    while (!b->error && JS_IsJobPending(b->rt)) {
        if (JS_ExecutePendingJob(b->rt, &ctx) < 0) { exception(b); break; }
        if (interrupt(b->rt, b)) break;
    }
}
EXPORT char *al_js_poll(Bridge *b) {
    if (!b) {
        const char *unavailable = "{\"state\":\"error\",\"code\":\"SCRIPT_UNAVAILABLE\"}";
        return copy_text(unavailable, strlen(unavailable));
    }
    if (!b->begun) b->error = "SCRIPT_PROTOCOL";
    enter(b); drain(b);
    if (!b->error && !b->called) {
        int state = JS_PromiseState(b->ctx, b->entry_result);
        if (state == JS_PROMISE_REJECTED) rejected(b, b->entry_result, "SCRIPT_MODULE");
        else if (state != JS_PROMISE_PENDING) {
            /* Export bindings exist only after module instantiation. Keep the
               module alive and wait for top-level await before reading them. */
            b->ns = JS_GetModuleNamespace(b->ctx, JS_VALUE_GET_PTR(b->module));
            if (JS_IsException(b->ns)) exception(b);
            JSValue fn = b->error ? JS_UNDEFINED : JS_GetPropertyStr(b->ctx, b->ns, b->operation);
            if (!JS_IsFunction(b->ctx, fn)) { if (!b->error) b->error = "SCRIPT_OPERATION"; }
            else {
                JSValue args[2] = {b->input, b->api};
                b->result = JS_Call(b->ctx, fn, JS_UNDEFINED, 2, args);
                if (JS_IsException(b->result)) exception(b);
            }
            JS_FreeValue(b->ctx, fn); b->called = 1; drain(b);
        }
    }
    char *out = NULL;
    if (!b->error) {
        int state = b->called ? JS_PromiseState(b->ctx, b->result) : JS_PROMISE_PENDING;
        if (state == JS_PROMISE_REJECTED) rejected(b, b->result, "SCRIPT_EXECUTION");
        else if (state != JS_PROMISE_PENDING) {
            JSValue result = state == JS_PROMISE_FULFILLED ? JS_PromiseResult(b->ctx, b->result) : JS_DupValue(b->ctx, b->result);
            JSValue packet = JS_NewObject(b->ctx);
            JS_SetPropertyStr(b->ctx, packet, "state", JS_NewString(b->ctx, "done"));
            JS_SetPropertyStr(b->ctx, packet, "value", result);
            out = stringify(b, packet); JS_FreeValue(b->ctx, packet);
        } else {
            HostCall *next = NULL;
            for (int i = 0; i < MAX_QUEUE; i++) if (b->calls[i].id && !b->calls[i].sent && (!next || b->calls[i].id < next->id)) next = &b->calls[i];
            if (next) {
                JSValue packet = JS_NewObject(b->ctx);
                JS_SetPropertyStr(b->ctx, packet, "state", JS_NewString(b->ctx, "call"));
                JS_SetPropertyStr(b->ctx, packet, "id", JS_NewInt32(b->ctx, next->id));
                JS_SetPropertyStr(b->ctx, packet, "method", JS_NewString(b->ctx, next->method));
                JS_SetPropertyStr(b->ctx, packet, "args", JS_ParseJSON(b->ctx, next->args, strlen(next->args), "host.json"));
                out = stringify(b, packet); JS_FreeValue(b->ctx, packet); next->sent = 1;
            } else b->error = "SCRIPT_STALLED";
        }
    }
    leave(b);
    if (b->error) { free(out); char text[100]; snprintf(text, sizeof(text), "{\"state\":\"error\",\"code\":\"%s\"}", b->error); out = copy_text(text, strlen(text)); }
    return out;
}
EXPORT int al_js_reply(Bridge *b, int id, const char *json, int failed) {
    if (!b || !json || strlen(json) > MAX_TEXT || b->error) return 0;
    enter(b);
    HostCall *call = NULL;
    for (int i = 0; i < MAX_QUEUE; i++) if (b->calls[i].id == id && b->calls[i].sent) call = &b->calls[i];
    if (!call) { b->error = "SCRIPT_PROTOCOL"; leave(b); return 0; }
    JSValue value = JS_ParseJSON(b->ctx, json, strlen(json), "reply.json");
    if (JS_IsException(value)) exception(b);
    else {
        JSValue result = JS_Call(b->ctx, failed ? call->reject : call->resolve, JS_UNDEFINED, 1, &value);
        if (JS_IsException(result)) exception(b);
        JS_FreeValue(b->ctx, result);
    }
    JS_FreeValue(b->ctx, value); JS_FreeValue(b->ctx, call->resolve); JS_FreeValue(b->ctx, call->reject);
    b->queued_bytes -= strlen(call->args); free(call->method); free(call->args); memset(call, 0, sizeof(*call)); b->count--;
    leave(b); return b->error == NULL;
}
EXPORT void al_js_free_text(char *text) { free(text); }
EXPORT void al_js_close(Bridge *b) {
    if (!b) return;
    JS_SetInterruptHandler(b->rt, NULL, NULL);
    for (int i = 0; i < MAX_QUEUE; i++) if (b->calls[i].id) {
        JS_FreeValue(b->ctx, b->calls[i].resolve); JS_FreeValue(b->ctx, b->calls[i].reject);
        free(b->calls[i].method); free(b->calls[i].args);
    }
    JS_FreeValue(b->ctx, b->modules); JS_FreeValue(b->ctx, b->module); JS_FreeValue(b->ctx, b->ns); JS_FreeValue(b->ctx, b->entry_result);
    JS_FreeValue(b->ctx, b->result); JS_FreeValue(b->ctx, b->input); JS_FreeValue(b->ctx, b->api);
    JS_FreeContext(b->ctx); JS_FreeRuntime(b->rt); free(b);
}
