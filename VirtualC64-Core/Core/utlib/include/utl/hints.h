/// -----------------------------------------------------------------------------
// This file is part of utlib - A lightweight utility library
//
// Copyright (C) Dirk W. Hoffmann. www.dirkwhoffmann.de
// Licensed under the Mozilla Public License v2
//
// See https://mozilla.org/MPL/2.0 for license information
// -----------------------------------------------------------------------------

#pragma once

#include <cassert>

//
// Optimizing code
//

#ifndef unreachable
#if defined(__clang__) || defined(__GNUC__) || defined(__GNUG__)
#define unreachable    __builtin_unreachable()
#elif defined(_MSC_VER)
#define unreachable    __assume(false)
#else
#define unreachable
#endif
#endif

#ifndef likely
#if defined(__clang__) || defined(__GNUC__) || defined(__GNUG__)
#define likely(x)      __builtin_expect(!!(x), 1)
#define unlikely(x)    __builtin_expect(!!(x), 0)
#elif defined(_MSC_VER)
#define likely(x)      (x)
#define unlikely(x)    (x)
#else
#define likely(x)      (x)
#define unlikely(x)    (x)
#endif
#endif

#ifndef alwaysinline
#if defined(__clang__) || defined(__GNUC__) || defined(__GNUG__)
#define alwaysinline   __attribute__((always_inline))
#elif defined(_MSC_VER)
#define alwaysinline   __forceinline
#else
#define alwaysinline   inline
#endif
#endif

#ifndef fatalError
#define fatalError     assert(false); unreachable
#endif


//
// Debugging
//

/* The following macro can be used to disable clang sanitizer checks. It has
 * been added to make the code compatible with gcc which doesn't recognize
 * the 'no_sanitize' keyword.
 */
#if defined(__clang__)
#define NO_SANITIZE(x) __attribute__((no_sanitize(x)))
#else
#define NO_SANITIZE(x)
#endif
