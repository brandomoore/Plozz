/*
 * This file is part of libbluray
 * Copyright (C) 2009-2010  John Stebbins
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

#if !defined(_BD_UO_MASK_TABLE_H_)
#define _BD_UO_MASK_TABLE_H_

typedef enum {
    UO_MASK_MENU_CALL_INDEX                           = 0,
    UO_MASK_TITLE_SEARCH_INDEX                        = 1,
    UO_MASK_CHAPTER_SEARCH_INDEX                      = 2,
    UO_MASK_TIME_SEARCH_MASK_INDEX                    = 3,
    UO_MASK_SKIP_TO_NEXT_POINT_MASK_INDEX             = 4,
    UO_MASK_SKIP_BACK_TO_PREVIOUS_POINT_MASK_INDEX    = 5,
    UO_MASK_STOP_MASK_INDEX                           = 7,
    UO_MASK_PAUSE_ON_MASK_INDEX                       = 8,
    UO_MASK_STILL_OFF_MASK_INDEX                      = 10,
    UO_MASK_FORWARD_PLAY_MASK_INDEX                   = 11,
    UO_MASK_BACKWARD_PLAY_MASK_INDEX                  = 12,
    UO_MASK_RESUME_MASK_INDEX                         = 13,
    UO_MASK_MOVE_UP_SELECTED_BUTTON_MASK_INDEX        = 14,
    UO_MASK_MOVE_DOWN_SELECTED_BUTTON_MASK_INDEX      = 15,
    UO_MASK_MOVE_LEFT_SELECTED_BUTTON_MASK_INDEX      = 16,
    UO_MASK_MOVE_RIGHT_SELECTED_BUTTON_MASK_INDEX     = 17,
    UO_MASK_SELECT_BUTTON_MASK_INDEX                  = 18,
    UO_MASK_ACTIVATE_BUTTON_MASK_INDEX                = 19,
    UO_MASK_SELECT_AND_ACTIVATE_MASK_INDEX            = 20,
    UO_MASK_PRIMARY_AUDIO_CHANGE_MASK_INDEX           = 21,
    UO_MASK_ANGLE_CHANGE_MASK_INDEX                   = 23,
    UO_MASK_POPUP_ON_MASK_INDEX                       = 24,
    UO_MASK_POPUP_OFF_MASK_INDEX                      = 25,
    UO_MASK_PG_TEXTST_ENABLE_DISABLE_MASK_INDEX       = 26,
    UO_MASK_PG_TEXTST_CHANGE_MASK_INDEX               = 27,
    UO_MASK_SECONDARY_VIDEO_ENABLE_DISABLE_MASK_INDEX = 28,
    UO_MASK_SECONDARY_VIDEO_CHANGE_MASK_INDEX         = 29,
    UO_MASK_SECONDARY_AUDIO_ENABLE_DISABLE_MASK_INDEX = 30,
    UO_MASK_SECONDARY_AUDIO_CHANGE_MASK_INDEX         = 31,
    UO_MASK_PIP_PG_TEXTST_CHANGE_MASK_INDEX           = 33,
} bd_uo_mask_index_e;

typedef struct bd_uo_mask_table
{
    unsigned int menu_call : 1;
    unsigned int title_search : 1;
    unsigned int chapter_search : 1;
    unsigned int time_search : 1;
    unsigned int skip_to_next_point : 1;
    unsigned int skip_to_prev_point : 1;
    unsigned int play_firstplay : 1;
    unsigned int stop : 1;
    unsigned int pause_on : 1;
    unsigned int pause_off : 1;
    unsigned int still_off : 1;
    unsigned int forward : 1;
    unsigned int backward : 1;
    unsigned int resume : 1;
    unsigned int move_up : 1;
    unsigned int move_down : 1;
    unsigned int move_left : 1;
    unsigned int move_right : 1;
    unsigned int select : 1;
    unsigned int activate : 1;
    unsigned int select_and_activate : 1;
    unsigned int primary_audio_change : 1;
    unsigned int reserved0 : 1;
    unsigned int angle_change : 1;
    unsigned int popup_on : 1;
    unsigned int popup_off : 1;
    unsigned int pg_enable_disable : 1;
    unsigned int pg_change : 1;
    unsigned int secondary_video_enable_disable : 1;
    unsigned int secondary_video_change : 1;
    unsigned int secondary_audio_enable_disable : 1;
    unsigned int secondary_audio_change : 1;
    unsigned int reserved1 : 1;
    unsigned int pip_pg_change : 1;
} BD_UO_MASK;

#endif // _BD_UO_MASK_TABLE_H_
