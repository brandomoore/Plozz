#include "libbluray/bdj/bdj.h"
#include "util/logging.h"
#include <stdlib.h>

BDJAVA *bdj_open(const char *path, struct bluray *disc, const char *id, BDJ_CONFIG *config) {
    (void)path; (void)disc; (void)id; (void)config;
    BD_DEBUG(DBG_BDJ | DBG_CRIT, "Java disc menus are not included in this build\n");
    return NULL;
}

void bdj_close(BDJAVA *java) { (void)java; }

int bdj_process_event(BDJAVA *java, unsigned event, unsigned parameter) {
    (void)java; (void)event; (void)parameter;
    return -1;
}

int bdj_jvm_available(BDJ_CONFIG *config) {
    (void)config;
    return BDJ_CHECK_NO_JVM;
}

void bdj_config_cleanup(BDJ_CONFIG *config) {
    free(config->cache_root); config->cache_root = NULL;
    free(config->persistent_root); config->persistent_root = NULL;
    free(config->java_home); config->java_home = NULL;
    for (unsigned index = 0; index < 2; index++) {
        free(config->classpath[index]); config->classpath[index] = NULL;
    }
}
