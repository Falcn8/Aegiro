// Shim header for SwiftPM systemLibrary target Argon2C.
// Prefer pkg-config include paths, with Homebrew fallbacks for Xcode builds.
#pragma once

#if __has_include(<argon2.h>)
#include <argon2.h>
#elif __has_include("/opt/homebrew/include/argon2.h")
#include "/opt/homebrew/include/argon2.h"
#elif __has_include("/usr/local/include/argon2.h")
#include "/usr/local/include/argon2.h"
#else
#error "argon2.h not found. Install argon2 (brew install argon2)."
#endif

