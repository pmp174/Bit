// SPDX-FileCopyrightText: 2002-2026 PCSX2 Dev Team
// SPDX-License-Identifier: GPL-3.0+

// ARM64 EE Recompiler — Jump instructions (Phase 0: interpreter fallback)

#include "Common.h"
#include "R5900OpcodeTables.h"
#include "arm64/iR5900.h"
#include "arm64/iCore.h"

namespace Interp = R5900::Interpreter::OpcodeImpl;

namespace R5900 {
namespace Dynarec {
namespace OpcodeImpl {

	REC_SYS(J);
	REC_SYS(JAL);
	REC_SYS(JR);
	REC_SYS(JALR);

} // namespace OpcodeImpl
} // namespace Dynarec
} // namespace R5900
