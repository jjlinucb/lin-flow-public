// Umbrella header for Homebrew's whisper.cpp install. Absolute paths on
// purpose: SwiftPM system-library targets don't get extra -I flags, and
// /opt/homebrew/include is where `brew link` puts every header.
#include "/opt/homebrew/include/whisper.h"
#include "/opt/homebrew/include/parakeet.h"
#include "/opt/homebrew/include/ggml-backend.h"
