// SPDX-FileCopyrightText: 2002-2026 PCSX2 Dev Team
// SPDX-License-Identifier: GPL-3.0+

// ARM64 EE Recompiler — Branch instructions (Phase 0: interpreter fallback)

#include "Common.h"
#include "R5900OpcodeTables.h"
#include "arm64/iR5900.h"
#include "arm64/iCore.h"

namespace Interp = R5900::Interpreter::OpcodeImpl;

namespace R5900 {
namespace Dynarec {
namespace OpcodeImpl {

	REC_SYS(BEQ);
	REC_SYS(BNE);
	REC_SYS(BLEZ);
	REC_SYS(BGTZ);
	REC_SYS(BLTZ);
	REC_SYS(BGEZ);
	REC_SYS(BEQL);
	REC_SYS(BNEL);
	REC_SYS(BLEZL);
	REC_SYS(BGTZL);
	REC_SYS(BLTZL);
	REC_SYS(BGEZL);
	REC_SYS(BLTZAL);
	REC_SYS(BGEZAL);
	REC_SYS(BLTZALL);
	REC_SYS(BGEZALL);

} // namespace OpcodeImpl
} // namespace Dynarec
} // namespace R5900
