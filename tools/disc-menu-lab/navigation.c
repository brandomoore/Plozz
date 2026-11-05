#include "libbluray/bluray.h"
#include "libbluray/keys.h"
#include "libbluray/decoders/overlay.h"
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

typedef struct {
    pthread_mutex_t lock;
    uint32_t *pixels, *presented;
    unsigned width, height, frames;
    int failed;
} Overlay;

#ifdef PLOZZ_EMBEDDED_NAVIGATION
extern void disc_menu_present(const uint32_t *pixels, unsigned width, unsigned height);
#endif

static void overlay(void *opaque, const BD_ARGB_OVERLAY *event) {
    Overlay *state = opaque;
    if (!event || event->plane != 1) return;
    pthread_mutex_lock(&state->lock);
    if (event->cmd == BD_ARGB_OVERLAY_INIT) {
        free(state->pixels);
        free(state->presented);
        state->pixels = NULL;
        state->presented = NULL;
        state->width = event->w;
        state->height = event->h;
        if (!event->w || !event->h || event->w > 1920 || event->h > 1080) {
            state->failed = 1;
        } else {
            state->pixels = calloc((size_t)event->w * event->h, sizeof(uint32_t));
            state->presented = calloc((size_t)event->w * event->h, sizeof(uint32_t));
            if (!state->pixels || !state->presented) state->failed = 1;
        }
    } else if (event->cmd == BD_ARGB_OVERLAY_DRAW) {
        if (!state->pixels || !event->argb || event->stride < event->w ||
            (unsigned)event->x + event->w > state->width ||
            (unsigned)event->y + event->h > state->height) {
            state->failed = 1;
        } else {
            for (unsigned row = 0; row < event->h; row++) {
                memcpy(state->pixels + (event->y + row) * state->width + event->x,
                       event->argb + row * event->stride, event->w * sizeof(uint32_t));
            }
        }
    } else if (event->cmd == BD_ARGB_OVERLAY_FLUSH) {
        if (state->pixels && state->presented && !state->failed) {
            memcpy(state->presented, state->pixels,
                   (size_t)state->width * state->height * sizeof(uint32_t));
            state->frames++;
#ifdef PLOZZ_EMBEDDED_NAVIGATION
            disc_menu_present(state->presented, state->width, state->height);
#endif
        } else {
            state->failed = 1;
        }
    }
    pthread_mutex_unlock(&state->lock);
}

static double now(void) {
    struct timespec value;
    clock_gettime(CLOCK_MONOTONIC, &value);
    return value.tv_sec + value.tv_nsec / 1000000000.0;
}

static unsigned frame_count(Overlay *state) {
    pthread_mutex_lock(&state->lock);
    unsigned result = state->frames;
    pthread_mutex_unlock(&state->lock);
    return result;
}

static int menu_ready(Overlay *state, unsigned selected) {
    if (!selected) return 1;
    pthread_mutex_lock(&state->lock);
    int ok = !state->failed && state->presented && state->width == 1280 && state->height == 720;
    for (unsigned episode = 1; ok && episode <= 2; episode++) {
        unsigned left = 80 + (episode - 1) * 580;
        uint32_t expected = episode == selected ? 0x00ffff00 : 0x00808080;
        ok = (state->presented[270 * 1280 + left + 20] & 0x00ffffff) == expected;
        unsigned black = 0;
        for (unsigned y = 315; y < 345; y++) {
            for (unsigned x = left + 40; x < left + 220; x++) {
                if ((state->presented[y * 1280 + x] & 0x00ffffff) == 0) black++;
            }
        }
        ok = ok && black >= 100;
    }
    pthread_mutex_unlock(&state->lock);
    return ok;
}

static int snapshot(Overlay *state, const char *path) {
    pthread_mutex_lock(&state->lock);
    FILE *file = fopen(path, "wb");
    int ok = file && state->presented && !state->failed;
    if (ok) {
        ok = fprintf(file, "P6\n%u %u\n255\n", state->width, state->height) > 0;
        for (size_t i = 0; ok && i < (size_t)state->width * state->height; i++) {
            uint32_t pixel = state->presented[i];
            unsigned char rgb[] = {pixel >> 16, pixel >> 8, pixel};
            ok = fwrite(rgb, 1, 3, file) == 3;
        }
    }
    if (file && fclose(file)) ok = 0;
    pthread_mutex_unlock(&state->lock);
    return ok;
}

static int pump(BLURAY *disc, Overlay *state, unsigned minimum_frames,
                unsigned expected_playlist, const char *output, int wait_menu,
                unsigned expected_selection) {
    FILE *file = output ? fopen(output, "wb") : NULL;
    if (output && !file) return 0;
    double deadline = now() + 15;
    unsigned playlist = 0;
    size_t bytes = 0;
    int ok = 0;
    int menu_seen = 0;
    while (now() < deadline) {
        uint8_t buffer[6144];
        BD_EVENT event = {0};
        int count = bd_read_ext(disc, buffer, sizeof(buffer), &event);
        if (count < 0 || event.event == BD_EVENT_ERROR || event.event == BD_EVENT_READ_ERROR) {
            fprintf(stderr, "Navigation error: read=%d event=%u param=%u\n",
                    count, event.event, event.param);
            break;
        }
        if (event.event == BD_EVENT_PLAYLIST) {
            playlist = event.param;
            printf("PLAYLIST %u\n", playlist);
        }
        if (event.event == BD_EVENT_TITLE) {
            printf("TITLE %u\n", event.param);
            if (event.param == 0) menu_seen = 1;
        }
        if (count > 0 && file && playlist == expected_playlist) {
            if (fwrite(buffer, 1, (size_t)count, file) != (size_t)count) break;
            bytes += (size_t)count;
        }
        if (frame_count(state) >= minimum_frames && menu_ready(state, expected_selection) &&
            (!wait_menu || menu_seen) &&
            (!expected_playlist || (playlist == expected_playlist && bytes >= 65536))) {
            ok = 1;
            break;
        }
        usleep(5000);
    }
    if (file && fclose(file)) ok = 0;
    printf("PUMP playlist=%u bytes=%zu frames=%u result=%s\n",
           playlist, bytes, frame_count(state), ok ? "pass" : "fail");
    return ok;
}

static int key(BLURAY *disc, unsigned code) {
    return bd_user_input(disc, -1, code | BD_VK_KEY_PRESSED) >= 0 &&
           bd_user_input(disc, -1, code | BD_VK_KEY_RELEASED) >= 0;
}

int disc_menu_navigation(int argc, char **argv) {
    if (argc != 4) {
        fprintf(stderr, "usage: navigation AUTHORED_DISC JAVA_HOME EVIDENCE_DIRECTORY\n");
        return 2;
    }

    setbuf(stdout, NULL);
    Overlay state = {.lock = PTHREAD_MUTEX_INITIALIZER};
    BLURAY *disc = bd_init();
    int ok = 0;
    char path[4096];
    if (!disc) return 1;
    if (!bd_set_player_setting_str(disc, BLURAY_PLAYER_JAVA_HOME, argv[2])) goto finish;
    snprintf(path, sizeof(path), "%s/cache", argv[3]);
    if (!bd_set_player_setting_str(disc, BLURAY_PLAYER_CACHE_ROOT, path)) goto finish;
    snprintf(path, sizeof(path), "%s/persistent", argv[3]);
    if (!bd_set_player_setting_str(disc, BLURAY_PLAYER_PERSISTENT_ROOT, path)) goto finish;
    if (!bd_set_player_setting(disc, BLURAY_PLAYER_SETTING_PERSISTENT_STORAGE, 0)) goto finish;
    bd_register_argb_overlay_proc(disc, &state, overlay, NULL);
    if (!bd_open_disc(disc, argv[1], NULL)) goto finish;
    const BLURAY_DISC_INFO *info = bd_get_disc_info(disc);
    printf("DISC detected=%u bdj=%u handled=%u titles=%u\n",
           info->bluray_detected, info->bdj_detected, info->bdj_handled, info->num_titles);
    if (!info->bluray_detected || !info->bdj_detected || !info->bdj_handled) goto finish;
    if (!bd_play(disc) || !pump(disc, &state, 1, 0, NULL, 0, 1)) goto finish;
    snprintf(path, sizeof(path), "%s/menu-first.ppm", argv[3]);
    if (!snapshot(&state, path) || !key(disc, BD_VK_ENTER)) goto finish;
    snprintf(path, sizeof(path), "%s/episode-1.m2ts", argv[3]);
    if (!pump(disc, &state, 1, 1, path, 0, 0)) goto finish;

    unsigned frames = frame_count(&state);
    if (bd_menu_call(disc, -1) <= 0 || !pump(disc, &state, frames, 0, NULL, 1, 1)) goto finish;
    frames = frame_count(&state);
    if (!key(disc, BD_VK_RIGHT) || !pump(disc, &state, frames + 1, 0, NULL, 0, 2)) goto finish;
    snprintf(path, sizeof(path), "%s/menu-second.ppm", argv[3]);
    if (!snapshot(&state, path) || !key(disc, BD_VK_ENTER)) goto finish;
    snprintf(path, sizeof(path), "%s/episode-2.m2ts", argv[3]);
    if (!pump(disc, &state, 1, 2, path, 0, 0)) goto finish;
    ok = 1;

finish:
    bd_close(disc);
    if (state.failed) ok = 0;
    free(state.pixels);
    free(state.presented);
    pthread_mutex_destroy(&state.lock);
    printf("NAVIGATION %s\n", ok ? "PASS" : "FAIL");
    return ok ? 0 : 1;
}

#ifndef PLOZZ_EMBEDDED_NAVIGATION
int main(int argc, char **argv) {
    return disc_menu_navigation(argc, argv);
}
#endif
