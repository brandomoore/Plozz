#include "bdj_runtime.h"
#include "file/dl.h"
#include "util/logging.h"
#if defined(PLOZZ_EMBEDDED_BDJ)
#include <dlfcn.h>
#include <limits.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static char runtime_root[PATH_MAX], cache_root[PATH_MAX], jar_root[PATH_MAX];
static pthread_mutex_t runtime_lock = PTHREAD_MUTEX_INITIALIZER;
static int runtime_quarantined;

void plozz_bdj_quarantine(void) {
    pthread_mutex_lock(&runtime_lock);
    runtime_quarantined = 1;
    pthread_mutex_unlock(&runtime_lock);
}

int plozz_bdj_is_quarantined(void) {
    pthread_mutex_lock(&runtime_lock);
    int result = runtime_quarantined;
    pthread_mutex_unlock(&runtime_lock);
    return result;
}

int plozz_bdj_configure(const char *runtime, const char *cache) {
    char canonical_runtime[PATH_MAX], canonical_cache[PATH_MAX];
    if (!runtime || !cache || !realpath(runtime, canonical_runtime) || !realpath(cache, canonical_cache))
        return 0;
    pthread_mutex_lock(&runtime_lock);
    int ok = 0;
    if (runtime_root[0]) {
        ok = !strcmp(runtime_root, canonical_runtime) && !strcmp(cache_root, canonical_cache);
    } else if (strlen(canonical_runtime) + sizeof("/jars/") < sizeof(jar_root)) {
        strlcpy(runtime_root, canonical_runtime, sizeof(runtime_root));
        strlcpy(cache_root, canonical_cache, sizeof(cache_root));
        snprintf(jar_root, sizeof(jar_root), "%s/jars/", runtime_root);
        ok = 1;
    }
    pthread_mutex_unlock(&runtime_lock);
    return ok;
}

const char *plozz_bdj_cache_root(void) { return cache_root; }

void *dl_dlopen(const char *path, const char *version) {
    (void)version;
    char allowed[PATH_MAX], candidate[PATH_MAX];
    if (plozz_bdj_is_quarantined() || !runtime_root[0] || !path ||
        snprintf(allowed, sizeof(allowed), "%s/lib/zero/libjvm.dylib", runtime_root) >= sizeof(allowed) ||
        snprintf(candidate, sizeof(candidate), "%s.dylib", path) >= sizeof(candidate) ||
        strcmp(candidate, allowed)) {
        BD_DEBUG(DBG_CRIT, "Optional library is outside the bundled Java runtime\n");
        return NULL;
    }
    char framework[PATH_MAX];
    if (snprintf(framework, sizeof(framework),
                 "%s/../Frameworks/PlozzBDJjvm.framework/PlozzBDJjvm", runtime_root) >= sizeof(framework)) {
        return NULL;
    }
    return dlopen(framework, RTLD_NOW | RTLD_GLOBAL | RTLD_NODELETE);
}

void *dl_dlsym(void *handle, const char *symbol) {
    return handle && symbol ? dlsym(handle, symbol) : NULL;
}

int dl_dlclose(void *handle) {
    return handle ? dlclose(handle) : -1;
}

const char *dl_get_path(void) { return jar_root[0] ? jar_root : NULL; }
#else
#include <stddef.h>

void plozz_bdj_quarantine(void) {}
int plozz_bdj_is_quarantined(void) { return 0; }
int plozz_bdj_configure(const char *runtime, const char *cache) {
    (void)runtime; (void)cache;
    BD_DEBUG(DBG_CRIT, "Java disc menus are not included in this build\n");
    return 0;
}
const char *plozz_bdj_cache_root(void) { return NULL; }
void *dl_dlopen(const char *path, const char *version) {
    (void)path; (void)version;
    BD_DEBUG(DBG_CRIT, "Optional disc runtimes are not included in this build\n");
    return NULL;
}
void *dl_dlsym(void *handle, const char *symbol) { (void)handle; (void)symbol; return NULL; }
int dl_dlclose(void *handle) { (void)handle; return -1; }
const char *dl_get_path(void) { return NULL; }
#endif
