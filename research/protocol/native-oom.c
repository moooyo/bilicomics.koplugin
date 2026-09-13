/* Remote-only allocation-failure check for the native JSON result contract. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "biliwasm.h"
#include "cJSON.h"

static unsigned allocation_number;
static unsigned fail_at;
static unsigned outstanding;
static void *allocated[4096];

static void *test_allocate(size_t size) {
    if (++allocation_number == fail_at) return NULL;
    void *p = malloc(size);
    if (p) {
        for (unsigned i = 0; i < 4096; i++) {
            if (!allocated[i]) { allocated[i] = p; outstanding++; return p; }
        }
        abort();
    }
    return p;
}
static void forget(void *pointer) {
    if (!pointer) return;
    for (unsigned i = 0; i < 4096; i++) {
        if (allocated[i] == pointer) { allocated[i] = NULL; outstanding--; return; }
    }
    abort();
}
static void test_free(void *pointer) { forget(pointer); free(pointer); }

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    cJSON_Hooks hooks = {test_allocate, test_free};
    cJSON_InitHooks(&hooks);
    const char *request = "{\"function\":\"y1_z2w2a3\",\"args\":[\"device=pc&platform=web&nov=27&eot=812\",\"{}\",1789171200000]}";
    unsigned failure_cases = 0, success_cases = 0;
    for (unsigned i = 1; i <= 100; i++) {
        allocation_number = 0;
        fail_at = i;
        char *output = NULL;
        int status = biliwasm_run(argv[1], request, &output);
        if (status) failure_cases++; else success_cases++;
        fail_at = 0;
        if (output) {
            cJSON *parsed = cJSON_Parse(output);
            if (!parsed) abort();
            cJSON *ok = cJSON_GetObjectItemCaseSensitive(parsed, "ok");
            if (status == 0) {
                cJSON *result = cJSON_GetObjectItemCaseSensitive(parsed, "result");
                cJSON *sign = cJSON_GetObjectItemCaseSensitive(result, "sign");
                if (!cJSON_IsTrue(ok) || !cJSON_IsString(sign) || strcmp(sign->valuestring,
                    "Y4wKk9D0kYX0R2LGQ04edYQ0YQX4h9kDsKGXaasha1a4DsKf")) abort();
            } else if (!cJSON_IsFalse(ok)) abort();
            cJSON_Delete(parsed);
            /* The public API uses the same default malloc/free allocation ABI. */
            forget(output);
            biliwasm_free(output);
        } else if (status == 0) abort();
        if (outstanding) { fprintf(stderr, "Leaked JSON allocations at failure %u: %u\n", i, outstanding); return 1; }
    }
    cJSON_InitHooks(NULL);
    printf("{\"allocation_failure_cases\":%u,\"success_cases\":%u,\"outstanding_json_allocations\":%u}\n",
           failure_cases, success_cases, outstanding);
    return 0;
}
