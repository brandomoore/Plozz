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

#ifndef _BD_LIBAACS_H_
#define _BD_LIBAACS_H_

#include "util/attributes.h"

#include <stdint.h>

struct bd_file_s;
typedef struct bd_file_s * (*AACS_FILE_OPEN2)(void *handle, const char* filename);

typedef struct bd_aacs BD_AACS;

BD_PRIVATE int  bdpriv_aacs_required(void *h, int (*have_file)(void *, const char *, const char *));
BD_PRIVATE BD_AACS *bdpriv_aacs_load(int force_mmbd);
BD_PRIVATE int  bdpriv_aacs_open(BD_AACS *p, const char *device,
                                 void *file_open_handle, AACS_FILE_OPEN2 file_open_fp,
                                 const char *keyfile_path);
BD_PRIVATE void bdpriv_aacs_unload(BD_AACS **p);

BD_PRIVATE void bdpriv_aacs_select_title(BD_AACS *p, uint32_t title);
BD_PRIVATE int  bdpriv_aacs_decrypt_unit(BD_AACS *p, uint8_t *buf);
BD_PRIVATE int  bdpriv_aacs_decrypt_bus(BD_AACS *p, uint8_t *buf);

BD_PRIVATE uint32_t bdpriv_aacs_get_mkbv(BD_AACS *p);
BD_PRIVATE int      bdpriv_aacs_get_bec_enabled(BD_AACS *p);

#define BD_AACS_DISC_ID            1
#define BD_AACS_MEDIA_VID          2
#define BD_AACS_MEDIA_PMSN         3
#define BD_AACS_DEVICE_BINDING_ID  4
#define BD_AACS_DEVICE_NONCE       5
#define BD_AACS_MEDIA_KEY          6
#define BD_AACS_CONTENT_CERT_ID    7
#define BD_AACS_BDJ_ROOT_CERT_HASH 8

BD_PRIVATE const uint8_t *bdpriv_aacs_get_aacs_data(BD_AACS *p, int type);


#endif /* _BD_LIBAACS_H_ */
