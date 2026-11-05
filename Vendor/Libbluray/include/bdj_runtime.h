#pragma once

/* Immutable application-owned paths; never derived from a disc. */
int plozz_bdj_configure(const char *runtime, const char *cache);
const char *plozz_bdj_cache_root(void);
void plozz_bdj_quarantine(void);
int plozz_bdj_is_quarantined(void);
