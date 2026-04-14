// SPDX-FileCopyrightText: 2002-2026 PCSX2 Dev Team
// SPDX-License-Identifier: GPL-3.0+

// ARM64 EE Recompiler — VTLB memory access stubs and savestate stubs (Phase 0)

#include "Common.h"
#include "vtlb.h"
#include "MTVU.h"
#include "SaveState.h"
#include "arm64/iR5900.h"
#include "arm64/iCore.h"
#include "arm64/AsmHelpers.h"

// Fastmem backpatch stub - not yet implemented for ARM64
// Matches the declaration in vtlb.h
void vtlb_DynBackpatchLoadStore(uptr code_address, u32 code_size, u32 guest_pc, u32 guest_addr,
	u32 gpr_bitmask, u32 fpr_bitmask, u8 address_register, u8 data_register,
	u8 size_in_bits, bool is_signed, bool is_load, bool is_fpr)
{
	// Not yet implemented for ARM64 — fastmem backpatching is Phase 2
	Console.Warning("ARM64: vtlb_DynBackpatchLoadStore called but not yet implemented");
}

// vuJITFreeze is now provided by arm64/microVU.cpp
