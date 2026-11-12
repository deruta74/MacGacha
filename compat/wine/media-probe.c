/* SPDX-License-Identifier: GPL-3.0-only */
/* MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)). */
#include <gst/gst.h>
#include <stdio.h>

static void handoff(GstElement *sink, GstBuffer *buffer, GstPad *pad, gpointer user)
{
    (void)sink; (void)buffer; (void)pad;
    g_atomic_int_inc((gint *)user);
}

int main(int argc, char **argv)
{
    if (argc != 2) return 2;
    GError *error = NULL;
    if (!gst_init_check(NULL, NULL, &error)) return 3;
    GstElement *pipeline = gst_parse_launch(
        "filesrc name=input ! qtdemux ! h264parse ! avdec_h264 ! videoconvert ! "
        "video/x-raw,format=RGBA ! fakesink name=output signal-handoffs=true", &error);
    if (!pipeline || error) {
        fprintf(stderr, "pipeline: %s\n", error ? error->message : "missing");
        return 4;
    }
    GstElement *input = gst_bin_get_by_name(GST_BIN(pipeline), "input");
    GstElement *output = gst_bin_get_by_name(GST_BIN(pipeline), "output");
    g_object_set(input, "location", argv[1], NULL);
    gint frames = 0;
    g_signal_connect(output, "handoff", G_CALLBACK(handoff), &frames);
    GstBus *bus = gst_element_get_bus(pipeline);
    gst_element_set_state(pipeline, GST_STATE_PLAYING);
    GstMessage *message = gst_bus_timed_pop_filtered(bus, 30 * GST_SECOND, GST_MESSAGE_EOS | GST_MESSAGE_ERROR);
    int ok = message && GST_MESSAGE_TYPE(message) == GST_MESSAGE_EOS;
    if (message && GST_MESSAGE_TYPE(message) == GST_MESSAGE_ERROR) {
        gchar *debug = NULL;
        gst_message_parse_error(message, &error, &debug);
        fprintf(stderr, "decode: %s\n", error->message);
        g_error_free(error); g_free(debug);
    }
    gst_element_set_state(pipeline, GST_STATE_NULL);
    int count = g_atomic_int_get(&frames);
    if (message) gst_message_unref(message);
    gst_object_unref(bus); gst_object_unref(input); gst_object_unref(output); gst_object_unref(pipeline);
    gst_deinit();
    printf("Decoded video frames: %d\n", count);
    return ok && count == 2 ? 0 : 5;
}
