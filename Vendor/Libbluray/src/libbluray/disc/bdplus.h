/*
 * This file is part of libbluray
 * Copyright (C) 2013-2026  VideoLAN
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library. If not, see
 * <http://www.gnu.org/licenses/>.
 */

#ifndef _BD_LIBBDPLUS_H_
#define _BD_LIBBDPLUS_H_

#include "util/attributes.h"

#include <stdint.h>

struct bd_file_s;
typedef struct bd_file_s *(*BDPLUS_FILE_OPEN)(void *handle, const char *filename);

typedef struct bd_bdplus BD_BDPLUS;

BD_PRIVATE int  bdpriv_bdplus_required(void *have_file_handle, int (*have_file)(void *, const char *, const char *));
BD_PRIVATE BD_BDPLUS *bdpriv_bdplus_load(void);
BD_PRIVATE int  bdpriv_bdplus_is_mmbd(BD_BDPLUS *);
BD_PRIVATE int  bdpriv_bdplus_init(BD_BDPLUS *p, const char *root, const char *device,
                               void *file_open_handle, BDPLUS_FILE_OPEN file_open_fp,
                               const uint8_t *vid, const uint8_t *mk);
BD_PRIVATE void bdpriv_bdplus_unload(BD_BDPLUS **p);

BD_PRIVATE int  bdpriv_bdplus_get_gen(BD_BDPLUS *p);
BD_PRIVATE int  bdpriv_bdplus_get_date(BD_BDPLUS *p);

BD_PRIVATE void bdpriv_bdplus_mmap(BD_BDPLUS *p, uint32_t region_id, void *mem);
BD_PRIVATE void bdpriv_bdplus_psr(BD_BDPLUS *p, void *regs, void *read, void *write);
BD_PRIVATE void bdpriv_bdplus_start(BD_BDPLUS *p);
BD_PRIVATE void bdpriv_bdplus_event(BD_BDPLUS *p, uint32_t event, uint32_t param1, uint32_t param2);

#define BD_BDPLUS_TYPE 0x1000
BD_PRIVATE const uint8_t *bdpriv_bdplus_get_data(BD_BDPLUS *p, int type);

/*
 *  stream layer
 */

typedef struct bd_bdplus_st BD_BDPLUS_ST;

BD_PRIVATE BD_BDPLUS_ST *bdpriv_bdplus_m2ts(BD_BDPLUS *p, uint32_t clip_id, uint64_t pos);
BD_PRIVATE int  bdpriv_bdplus_seek(BD_BDPLUS_ST *p, uint64_t pos);
BD_PRIVATE int  bdpriv_bdplus_fixup(BD_BDPLUS_ST *p, uint8_t *buf, int len);
BD_PRIVATE int  bdpriv_bdplus_m2ts_close(BD_BDPLUS_ST **p);


#endif /* _BD_BDPLUS_H_ */
