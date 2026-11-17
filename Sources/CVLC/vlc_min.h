// Minimal declarations for the libvlc 3.x C API used by StudyO Player.
// The library itself comes from VLC.app (copied into the app bundle by build.sh).
#ifndef VLC_MIN_H
#define VLC_MIN_H

#include <stdint.h>
#include <stdbool.h>

typedef struct libvlc_instance_t libvlc_instance_t;
typedef struct libvlc_media_t libvlc_media_t;
typedef struct libvlc_media_player_t libvlc_media_player_t;
typedef int64_t libvlc_time_t;

typedef struct libvlc_track_description_t {
    int i_id;
    char *psz_name;
    struct libvlc_track_description_t *p_next;
} libvlc_track_description_t;

libvlc_instance_t *libvlc_new(int argc, const char *const *argv);
void libvlc_release(libvlc_instance_t *inst);
const char *libvlc_errmsg(void);
const char *libvlc_get_version(void);

libvlc_media_t *libvlc_media_new_path(libvlc_instance_t *inst, const char *path);
libvlc_media_t *libvlc_media_new_location(libvlc_instance_t *inst, const char *mrl);
void libvlc_media_release(libvlc_media_t *media);

libvlc_media_player_t *libvlc_media_player_new(libvlc_instance_t *inst);
void libvlc_media_player_release(libvlc_media_player_t *mp);
void libvlc_media_player_set_media(libvlc_media_player_t *mp, libvlc_media_t *media);
void libvlc_media_player_set_nsobject(libvlc_media_player_t *mp, void *drawable);
int libvlc_media_player_play(libvlc_media_player_t *mp);
void libvlc_media_player_set_pause(libvlc_media_player_t *mp, int do_pause);
void libvlc_media_player_stop(libvlc_media_player_t *mp);
int libvlc_media_player_is_playing(libvlc_media_player_t *mp);
int libvlc_media_player_get_state(libvlc_media_player_t *mp);
libvlc_time_t libvlc_media_player_get_time(libvlc_media_player_t *mp);
void libvlc_media_player_set_time(libvlc_media_player_t *mp, libvlc_time_t time);
libvlc_time_t libvlc_media_player_get_length(libvlc_media_player_t *mp);
int libvlc_media_player_set_rate(libvlc_media_player_t *mp, float rate);
void libvlc_media_player_next_frame(libvlc_media_player_t *mp);
int libvlc_media_player_add_slave(libvlc_media_player_t *mp, int type, const char *uri, bool select);

int libvlc_audio_set_volume(libvlc_media_player_t *mp, int volume);
int libvlc_audio_get_volume(libvlc_media_player_t *mp);
void libvlc_audio_set_mute(libvlc_media_player_t *mp, int status);
int libvlc_audio_get_track(libvlc_media_player_t *mp);
int libvlc_audio_set_track(libvlc_media_player_t *mp, int track);
libvlc_track_description_t *libvlc_audio_get_track_description(libvlc_media_player_t *mp);

int libvlc_video_get_spu(libvlc_media_player_t *mp);
int libvlc_video_set_spu(libvlc_media_player_t *mp, int spu);
libvlc_track_description_t *libvlc_video_get_spu_description(libvlc_media_player_t *mp);
void libvlc_track_description_list_release(libvlc_track_description_t *list);

int libvlc_video_take_snapshot(libvlc_media_player_t *mp, unsigned num, const char *path,
                               unsigned width, unsigned height);

// Used by the Touch Bar thumbnail generator (renders frames into memory).
typedef void *(*libvlc_video_lock_cb)(void *opaque, void **planes);
typedef void (*libvlc_video_unlock_cb)(void *opaque, void *picture, void *const *planes);
typedef void (*libvlc_video_display_cb)(void *opaque, void *picture);
void libvlc_video_set_callbacks(libvlc_media_player_t *mp, libvlc_video_lock_cb lock,
                                libvlc_video_unlock_cb unlock, libvlc_video_display_cb display,
                                void *opaque);
void libvlc_video_set_format(libvlc_media_player_t *mp, const char *chroma,
                             unsigned width, unsigned height, unsigned pitch);
int libvlc_video_get_size(libvlc_media_player_t *mp, unsigned num, unsigned *px, unsigned *py);
void libvlc_media_add_option(libvlc_media_t *media, const char *option);

// Core variable access, used only to read the live audio level published by the
// engine's "audiobargraph_a" filter (for the waveform display).
typedef union {
    int64_t i_int;
    bool b_bool;
    float f_float;
    char *psz_string;
    void *p_address;
    struct { int32_t x; int32_t y; } coords;
} vlc_value_t;
int var_GetChecked(void *object, const char *name, int type, vlc_value_t *value);
int var_SetChecked(void *object, const char *name, int type, vlc_value_t value);
typedef struct { int i_type; int i_count; vlc_value_t *p_values; } vlc_list_t;
vlc_list_t *vlc_list_children(void *object);
void vlc_list_release(vlc_list_t *list);

#endif
