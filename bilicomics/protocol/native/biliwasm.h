#ifndef BILIWASM_H
#define BILIWASM_H

#if defined(__GNUC__) || defined(__clang__)
#define BILIWASM_API __attribute__((visibility("default")))
#else
#define BILIWASM_API
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* Returns 0 for a completed WASM callback, even when its result.error is set.
 * Returns 1 for a host failure. output_json may be NULL on an allocation or
 * argument failure; otherwise release it with biliwasm_free.
 * Each invocation creates and frees an isolated runtime. The library does
 * not use a browser, Node.js, network, cookies, shell, or temporary files.
 * Calls must be serialized: the cJSON dependency has process-global state.
 */
BILIWASM_API int biliwasm_run(const char *wasm_path, const char *request_json, char **output_json);
BILIWASM_API void biliwasm_free(char *output_json);

#ifdef __cplusplus
}
#endif
#endif
