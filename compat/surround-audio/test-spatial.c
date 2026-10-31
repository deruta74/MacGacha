/* SPDX-License-Identifier: LGPL-2.1-or-later */
/* MacGacha — https://github.com/deruta74/MacGacha */
/* Native fake-AU harness: never links AudioUnit or opens an audio device. */
#include <CoreAudio/CoreAudio.h>
#include <AudioUnit/AudioUnit.h>
#include <assert.h>
#include <stdio.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef unsigned int UINT32;
typedef int BOOL;
typedef int HRESULT;
typedef int EDataFlow;
#pragma pack(push, 2)
typedef struct {
    unsigned short wFormatTag, nChannels;
    UInt32 nSamplesPerSec, nAvgBytesPerSec;
    unsigned short nBlockAlign, wBitsPerSample, cbSize;
} WAVEFORMATEX;
typedef struct { WAVEFORMATEX Format; struct { unsigned short wValidBitsPerSample; } Samples;
    UInt32 dwChannelMask; __int128 SubFormat; } WAVEFORMATEXTENSIBLE;
#pragma pack(pop)
enum { eRender, eCapture, WAVE_FORMAT_EXTENSIBLE = 0xfffe,
    KSAUDIO_SPEAKER_7POINT1_SURROUND = 0x63f, KSDATAFORMAT_SUBTYPE_IEEE_FLOAT = 3 };
#include "macgacha-surround.h"
#define FALSE 0
#define TRUE 1
#define FAILED(x) ((x) < 0)
struct coreaudio_stream {
    AudioUnit unit, spatial_mixer;
    float *spatial_buffer;
    UInt32 spatial_frames;
    AudioStreamBasicDescription dev_desc;
    WAVEFORMATEX *fmt;
    AudioDeviceID dev_id;
    int flow;
};
static int calls, fail_at, live, running, head_supported = 1, head_value;
static UInt32 transport = kAudioDeviceTransportTypeBluetooth, source_kind;
static UInt32 observed_bitmap, observed_algorithm, observed_mode, observed_output;
static int pulls;
static int allocations;
static OSStatus head_info_error, head_set_error, head_get_error;
static UInt32 head_size = sizeof(UInt32);
static UInt32 head_get_size = sizeof(UInt32);
static Boolean head_writable = 1;
static unsigned format_bits = 32;
static int optional_calls[256];
static int record_optional = 1;
static AudioDeviceID default_device = 42;
static OSStatus step(void) { return ++calls == fail_at ? -777 : noErr; }
static int ca_get_audiodesc(AudioStreamBasicDescription *d, const WAVEFORMATEX *f) {
    memset(d, 0, sizeof(*d));
    d->mSampleRate = f->nSamplesPerSec; d->mFormatID = kAudioFormatLinearPCM;
    d->mFormatFlags = kAudioFormatFlagIsFloat;
    d->mChannelsPerFrame = f->nChannels; d->mBitsPerChannel = format_bits;
    d->mFramesPerPacket = 1; d->mBytesPerFrame = d->mBytesPerPacket = f->nBlockAlign;
    return 0;
}
static OSStatus ca_render_cb(void *s, AudioUnitRenderActionFlags *fl,
        const AudioTimeStamp *ts, UInt32 bus, UInt32 n, AudioBufferList *data) {
    float *p = data->mBuffers[0].mData;
    (void)s; (void)fl; (void)ts; (void)bus;
    ++pulls;
    for (UInt32 i = 0; i < n; ++i)
        for (UInt32 c = 0; c < 8; ++c) p[i * 8 + c] = 100 * c + i;
    return noErr;
}
static OSStatus fake_new(AudioComponent c, AudioComponentInstance *u) {
    OSStatus s = step(); (void)c;
    if (!s) { *u = (AudioUnit)(uintptr_t)(++live); }
    return s;
}
static AudioComponent fake_find(AudioComponent c, const AudioComponentDescription *d) {
    (void)c; assert(d->componentSubType == kAudioUnitSubType_SpatialMixer || d->componentSubType == kAudioUnitSubType_HALOutput);
    return step() ? NULL : (AudioComponent)1;
}
static OSStatus fake_dispose(AudioComponentInstance u) { assert(u); --live; return 0; }
static OSStatus fake_set(AudioUnit u, AudioUnitPropertyID p, AudioUnitScope sc,
        AudioUnitElement el, const void *d, UInt32 n) {
    (void)u; (void)sc; (void)el; (void)n;
    if (p == kAudioUnitProperty_SpatialMixerEnableHeadTracking && record_optional) optional_calls[calls + 1] = 1;
    OSStatus s = step(); if (s) return s;
    if (p == kAudioUnitProperty_StreamFormat) {
        const AudioStreamBasicDescription *f = d;
        assert(n == sizeof(*f) && el == 0);
        assert(f->mFormatFlags & kAudioFormatFlagIsNonInterleaved);
        assert(f->mBitsPerChannel == 32 && f->mBytesPerFrame == 4 && f->mBytesPerPacket == 4);
        assert(f->mFramesPerPacket == 1 && f->mSampleRate == 48000);
        assert(sc == kAudioUnitScope_Input || sc == kAudioUnitScope_Output);
        assert(f->mChannelsPerFrame == (u == (AudioUnit)2 && sc == kAudioUnitScope_Input ? 8 : 2));
    }
    if (p == kAudioUnitProperty_SpatialMixerEnableHeadTracking) {
        assert(sc == kAudioUnitScope_Global && el == 0 && n == sizeof(UInt32));
        if (head_set_error) return head_set_error;
    }
    if (p == kAudioUnitProperty_AudioChannelLayout && sc == kAudioUnitScope_Input &&
        ((const AudioChannelLayout *)d)->mChannelLayoutTag == kAudioChannelLayoutTag_UseChannelBitmap)
        observed_bitmap = ((const AudioChannelLayout *)d)->mChannelBitmap;
    if (p == kAudioUnitProperty_SpatializationAlgorithm) observed_algorithm = *(const UInt32 *)d;
    if (p == kAudioUnitProperty_SpatialMixerSourceMode) observed_mode = *(const UInt32 *)d;
    if (p == kAudioUnitProperty_SpatialMixerOutputType) observed_output = *(const UInt32 *)d;
    if (p == kAudioUnitProperty_SpatialMixerEnableHeadTracking) head_value = *(const UInt32 *)d;
    return 0;
}
static OSStatus fake_get(AudioUnit u, AudioUnitPropertyID p, AudioUnitScope sc,
        AudioUnitElement el, void *d, UInt32 *n) {
    (void)u; (void)sc; (void)el; (void)n;
    if (p == kAudioUnitProperty_SpatialMixerEnableHeadTracking && record_optional) optional_calls[calls + 1] = 1;
    OSStatus s = step(); if (s) return s;
    if (p == kAudioUnitProperty_SpatialMixerEnableHeadTracking && head_get_error) return head_get_error;
    if (p == kAudioUnitProperty_SpatialMixerEnableHeadTracking) *n = head_get_size;
    *(UInt32 *)d = p == kAudioUnitProperty_MaximumFramesPerSlice ? 64 : head_value;
    return 0;
}
static OSStatus fake_info(AudioUnit u, AudioUnitPropertyID p, AudioUnitScope sc,
        AudioUnitElement el, UInt32 *size, Boolean *writable) {
    (void)u; (void)p; (void)sc; (void)el;
    if (record_optional) optional_calls[calls + 1] = 1;
    OSStatus s = step(); if (s) return s;
    assert(p == kAudioUnitProperty_SpatialMixerEnableHeadTracking && sc == kAudioUnitScope_Global && el == 0);
    if (head_info_error) return head_info_error;
    if (!head_supported) return kAudioUnitErr_InvalidProperty;
    *size = head_size; *writable = head_writable; return 0;
}
static OSStatus fake_init(AudioUnit u) { (void)u; return step(); }
static OSStatus fake_start(AudioUnit u) {
    (void)u; OSStatus s = step(); if (!s) ++running; return s;
}
static OSStatus fake_stop(AudioUnit u) { (void)u; running = 0; return 0; }
static OSStatus fake_uninit(AudioUnit u) { (void)u; return 0; }
static Boolean fake_has(AudioObjectID o, const AudioObjectPropertyAddress *a) {
    (void)o; return a->mSelector != kAudioDevicePropertyDataSource || source_kind != 0;
}
static OSStatus fake_object(AudioObjectID o, const AudioObjectPropertyAddress *a,
        UInt32 qs, const void *q, UInt32 *n, void *d) {
    (void)o; (void)qs; (void)q; (void)n;
    OSStatus s = step(); if (s) return s;
    if (a->mSelector == kAudioDevicePropertyDataSourceKindForID)
        *(UInt32 *)((AudioValueTranslation *)d)->mOutputData = source_kind;
    else *(UInt32 *)d = a->mSelector == kAudioHardwarePropertyDefaultOutputDevice ? default_device :
        a->mSelector == kAudioDevicePropertyTransportType ? transport : source_kind;
    return 0;
}
static void *fake_malloc(size_t size) {
    if (step()) return NULL;
    void *p = malloc(size); if (p) ++allocations; return p;
}
static void fake_free(void *p) { if (p) --allocations; free(p); }
#define AudioComponentFindNext fake_find
#define AudioComponentInstanceNew fake_new
#define AudioComponentInstanceDispose fake_dispose
#define AudioUnitSetProperty fake_set
#define AudioUnitGetProperty fake_get
#define AudioUnitGetPropertyInfo fake_info
#define AudioUnitInitialize fake_init
#define AudioUnitUninitialize fake_uninit
#define AudioOutputUnitStart fake_start
#define AudioOutputUnitStop fake_stop
#define AudioObjectHasProperty fake_has
#define AudioObjectGetPropertyData fake_object
#define malloc fake_malloc
#define free fake_free
static unsigned log_lines;
static int test_fprintf(FILE *file, const char *format, ...)
{
    char text[512], output[64], spatial[128];
    unsigned channels, rate; int end = 0, result;
    va_list args;
    va_start(args, format); result = vsnprintf(text, sizeof(text), format, args); va_end(args);
    assert(file == stderr && result > 0 && result < (int)sizeof(text));
    assert(sscanf(text, "macgacha-surround: stream output=%63s channels=%u rate=%u spatial=%127s%n",
        output, &channels, &rate, spatial, &end) == 4);
    assert(!strcmp(text + end, "\n") && !strchr(output, '/') && !strchr(spatial, '/'));
    assert(!strcmp(spatial, "on") || !strncmp(spatial, "fallback:", 9));
    ++log_lines;
    return result;
}
#define fprintf test_fprintf
#include "macgacha-spatial.h"
#undef fprintf
static BOOL checked_start(struct coreaudio_stream *stream)
{
    unsigned before = log_lines;
    BOOL result = macgacha_spatial_start(stream);
    assert(log_lines == before + !!macgacha_surround_enabled());
    return result;
}
#define macgacha_spatial_start checked_start
#undef malloc
#undef free

int main(void) {
    WAVEFORMATEXTENSIBLE fmt = {.Format = {.nSamplesPerSec = 48000}};
    macgacha_surround_mix_format(&fmt);
    assert(fmt.Format.nChannels == 8 && fmt.Format.nSamplesPerSec == 48000 &&
        fmt.Format.wBitsPerSample == 32 && fmt.Format.nBlockAlign == 32 &&
        fmt.Format.nAvgBytesPerSec == 1536000 && fmt.Samples.wValidBitsPerSample == 32 &&
        fmt.dwChannelMask == 0x63f && fmt.SubFormat == KSDATAFORMAT_SUBTYPE_IEEE_FLOAT);
    struct coreaudio_stream s = {.fmt = &fmt.Format, .dev_id = 42, .flow = eRender};
    const char *values[] = {NULL, "", "0", "true", "01"};
    for (unsigned i = 0; i < sizeof(values)/sizeof(*values); ++i) {
        if (values[i]) setenv("MACGACHA_SURROUND", values[i], 1); else unsetenv("MACGACHA_SURROUND");
        calls = 0; assert(!macgacha_spatial_start(&s)); assert(!calls && !live);
        assert(!macgacha_surround_endpoint_prefix(eRender));
        assert(!strcmp(macgacha_surround_device(MACGACHA_SURROUND_ENDPOINT "device"), MACGACHA_SURROUND_ENDPOINT "device"));
    }
    setenv("MACGACHA_SURROUND", "1", 1);
    assert(macgacha_surround_endpoint_prefix(eRender) == sizeof(MACGACHA_SURROUND_ENDPOINT) - 1);
    assert(!macgacha_surround_endpoint_prefix(eCapture));
    assert(!strcmp(macgacha_surround_device(MACGACHA_SURROUND_ENDPOINT "device"), "device"));
    assert(!strcmp(macgacha_surround_device("device"), "device"));
    head_info_error = -10851;
    assert(macgacha_spatial_start(&s)); assert(!head_value);
    macgacha_spatial_dispose(&s); head_info_error = 0; calls = 0;
    s.flow = eCapture; assert(!macgacha_spatial_start(&s)); assert(!calls);
    s.flow = eRender;
    assert(macgacha_spatial_start(&s));
    assert(observed_bitmap == 0x63f && observed_algorithm == kSpatializationAlgorithm_UseOutputType);
    assert(observed_mode == kSpatialMixerSourceMode_AmbienceBed && observed_output == kSpatialMixerOutputType_Headphones);
    assert(head_value == 1 && live == 2 && running == 1);
    int total_calls = calls;
    record_optional = 0;
    struct { UInt32 n; AudioBuffer b[8]; } planar = {.n = 8};
    float channels[8][4];
    for (unsigned c = 0; c < 8; ++c) planar.b[c] = (AudioBuffer){1, sizeof(channels[c]), channels[c]};
    assert(!macgacha_spatial_pull(&s, NULL, NULL, 0, 4, (AudioBufferList *)&planar));
    for (unsigned c = 0; c < 8; ++c) for (unsigned f = 0; f < 4; ++f) assert(channels[c][f] == 100 * c + f);
    assert(pulls == 1);
    assert(macgacha_spatial_pull(&s, NULL, NULL, 0, 65, (AudioBufferList *)&planar));
    assert(pulls == 1);
    planar.n = 1; assert(macgacha_spatial_pull(&s, NULL, NULL, 0, 4, (AudioBufferList *)&planar));
    assert(pulls == 1);
    planar.n = 8; planar.b[3].mDataByteSize = 1;
    assert(macgacha_spatial_pull(&s, NULL, NULL, 0, 4, (AudioBufferList *)&planar)); assert(pulls == 1);
    macgacha_spatial_dispose(&s); assert(!live && !running && !s.unit && !s.spatial_buffer && !allocations);
    for (int i = 1; i <= total_calls; ++i) {
        calls = 0; fail_at = i;
        BOOL started = macgacha_spatial_start(&s);
        assert(started == optional_calls[i]);
        if (started) {
            /* Optional tracking errors preserve the spatial chain. */
            assert(live == 2 && running == 1);
            macgacha_spatial_dispose(&s);
        }
        assert(!live && !running && !s.unit && !s.spatial_mixer && !s.spatial_buffer && !allocations);
    }
    fail_at = 0; calls = 0; head_supported = 0;
    assert(macgacha_spatial_start(&s)); macgacha_spatial_dispose(&s);
    head_supported = 1;
    const OSStatus optional_errors[] = {-10851, -10879, -10868, -777};
    for (unsigned i = 0; i < sizeof(optional_errors) / sizeof(*optional_errors); ++i) {
        head_info_error = optional_errors[i]; head_value = 0;
        assert(macgacha_spatial_start(&s)); assert(!head_value);
        macgacha_spatial_dispose(&s); head_info_error = 0;
        head_set_error = optional_errors[i]; head_value = 0;
        assert(macgacha_spatial_start(&s)); assert(!head_value);
        macgacha_spatial_dispose(&s); head_set_error = 0;
        head_get_error = optional_errors[i];
        assert(macgacha_spatial_start(&s)); assert(!head_value);
        macgacha_spatial_dispose(&s); head_get_error = 0;
    }
    head_size = 1; head_value = 0;
    assert(macgacha_spatial_start(&s)); assert(!head_value); macgacha_spatial_dispose(&s);
    head_size = sizeof(UInt32); head_writable = 0;
    assert(macgacha_spatial_start(&s)); assert(!head_value); macgacha_spatial_dispose(&s);
    head_writable = 1;
    head_get_size = 1;
    assert(macgacha_spatial_start(&s)); assert(!head_value); macgacha_spatial_dispose(&s);
    head_get_size = sizeof(UInt32);
    head_supported = 1; transport = kAudioDeviceTransportTypeBuiltIn;
    assert(macgacha_spatial_start(&s)); assert(observed_output == kSpatialMixerOutputType_BuiltInSpeakers && !head_value);
    macgacha_spatial_dispose(&s);
    source_kind = 'hdpn';
    assert(macgacha_spatial_start(&s)); assert(observed_output == kSpatialMixerOutputType_Headphones);
    macgacha_spatial_dispose(&s);
    transport = kAudioDeviceTransportTypeUSB; source_kind = 0;
    assert(macgacha_spatial_start(&s)); assert(observed_output == kSpatialMixerOutputType_ExternalSpeakers);
    macgacha_spatial_dispose(&s);
    transport = kAudioDeviceTransportTypeBluetooth; source_kind = kAudioStreamTerminalTypeSpeaker;
    assert(macgacha_spatial_start(&s)); assert(observed_output == kSpatialMixerOutputType_ExternalSpeakers);
    macgacha_spatial_dispose(&s);
    default_device = 99; assert(!macgacha_spatial_start(&s)); assert(!live && !allocations);
    default_device = 42;
    fmt.dwChannelMask = 0xff;
    calls = 0; assert(!macgacha_spatial_start(&s)); assert(!calls && !live);
    fmt.dwChannelMask = 0x63f;
    fmt.Format.nChannels = 2;
    calls = 0; assert(!macgacha_spatial_start(&s)); assert(!calls && !live);
    fmt.Format.nChannels = 8; format_bits = 16;
    calls = 0; assert(!macgacha_spatial_start(&s)); assert(!calls && !live);
    format_bits = 32; fmt.Format.cbSize = 0;
    calls = 0; assert(!macgacha_spatial_start(&s)); assert(!calls && !live);
    fmt.Format.cbSize = 22; fmt.Format.nBlockAlign = 16;
    calls = 0; assert(!macgacha_spatial_start(&s)); assert(!calls && !live);
    printf("PASS: opt-in, layouts, planar pull bounds, output routing, optional tracking; %d setup fault points covered\n", total_calls);
    return 0;
}
