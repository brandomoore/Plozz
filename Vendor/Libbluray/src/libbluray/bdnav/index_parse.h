/*
 * This file is part of libbluray
 * Copyright (C) 2010-2026  Petri Hintukainen <phintuka@users.sourceforge.net>
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

#if !defined(_INDX_PARSE_H_)
#define _INDX_PARSE_H_

#include "index_data.h"

#include "util/attributes.h"

struct bd_disc;

BD_PRIVATE INDX_ROOT* indx_get(struct bd_disc *disc);  /* parse index.bdmv */
BD_PRIVATE void       indx_free(INDX_ROOT **index);

#endif // _INDX_PARSE_H_

