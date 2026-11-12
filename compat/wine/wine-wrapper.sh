#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
set -eu
wrapper_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
wine_root=$(CDPATH= cd -- "$wrapper_dir/.." && pwd -P)
gst_root="$wine_root/lib/GStreamer.framework/Versions/1.0"
export DYLD_FALLBACK_LIBRARY_PATH="$wine_root/lib:$gst_root/lib${DYLD_FALLBACK_LIBRARY_PATH:+:$DYLD_FALLBACK_LIBRARY_PATH}"
export GST_PLUGIN_SYSTEM_PATH_1_0="$gst_root/lib/gstreamer-1.0"
export GST_PLUGIN_SCANNER="$gst_root/libexec/gstreamer-1.0/gst-plugin-scanner"
exec "$wrapper_dir/wine.real" "$@"
