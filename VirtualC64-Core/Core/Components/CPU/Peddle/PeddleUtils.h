// -----------------------------------------------------------------------------
// This file is part of Peddle - A MOS 65xx CPU emulator
//
// Copyright (C) Dirk W. Hoffmann. www.dirkwhoffmann.de
// Published under the terms of the MIT License
// -----------------------------------------------------------------------------

#pragma once

#include <cassert>

#define LO_BYTE(x) (u8)((x) & 0xFF)
#define HI_BYTE(x) (u8)((x) >> 8)

#define LO_HI(x,y) (u16)((y) << 8 | (x))
#define HI_LO(x,y) (u16)((x) << 8 | (y))

#ifndef unreachable
#ifdef _MSC_VER
#define unreachable    __assume(false)
#else
#define unreachable    __builtin_unreachable()
#endif
#endif

#ifndef likely
#ifdef _MSC_VER
#define likely(x)      (x)
#define unlikely(x)    (x)
#else
#define likely(x)      __builtin_expect(!!(x), 1)
#define unlikely(x)    __builtin_expect(!!(x), 0)
#endif
#endif

#ifndef fatalError
#define fatalError     assert(false); unreachable
#endif
