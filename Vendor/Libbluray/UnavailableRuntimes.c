#include "libbluray/bdj/bdj.h"
#include "file/dl.h"
#include "util/logging.h"
#include <assert.h>
#include <stdlib.h>

/* This target deliberately contains no JVM or optional decryption libraries. */
int bdj_jvm_available(BDJ_CONFIG *storage) {
    (void)storage;
    return BDJ_CHECK_NO_JVM;
}

BDJAVA *bdj_open(const char *path, struct bluray *disc, const char *id, BDJ_CONFIG *storage) {
    (void)path; (void)disc; (void)id; (void)storage;
    BD_DEBUG(DBG_CRIT, "BD-J is unavailable in this HDMV-only build\n");
    return NULL;
}

void bdj_close(BDJAVA *context) { assert(context == NULL); }

int bdj_process_event(BDJAVA *context, unsigned event, unsigned parameter) {
    (void)context; (void)event; (void)parameter;
    return 0;
}

void bdj_config_cleanup(BDJ_CONFIG *storage) {
    free(storage->persistent_root); storage->persistent_root = NULL;
    free(storage->cache_root); storage->cache_root = NULL;
    free(storage->java_home); storage->java_home = NULL;
    free(storage->classpath[0]); storage->classpath[0] = NULL;
    free(storage->classpath[1]); storage->classpath[1] = NULL;
}

void *dl_dlopen(const char *path, const char *version) {
    (void)path; (void)version;
    BD_DEBUG(DBG_CRIT, "Optional runtime libraries are unavailable\n");
    return NULL;
}

void *dl_dlsym(void *handle, const char *symbol) {
    (void)handle; (void)symbol;
    return NULL;
}

int dl_dlclose(void *handle) {
    (void)handle;
    return -1;
}

const char *dl_get_path(void) { return NULL; }
