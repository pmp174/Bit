// SPDX-FileCopyrightText: 2002-2026 PCSX2 Dev Team
// SPDX-License-Identifier: GPL-3.0+

// ARM64 EE Recompiler — COP0 instructions (Phase 0: interpreter fallback)

#include "Common.h"
#include "R5900OpcodeTables.h"
#include "arm64/iR5900.h"
#include "arm64/iCore.h"

namespace Interp = R5900::Interpreter::OpcodeImpl::COP0;

namespace R5900 {
namespace Dynarec {
namespace OpcodeImpl {
namespace COP0 {

	REC_FUNC(MFC0);
	REC_FUNC(MTC0);
	REC_SYS(BC0F);
	REC_SYS(BC0T);
	REC_SYS(BC0FL);
	REC_SYS(BC0TL);
	REC_FUNC(TLBR);
	REC_FUNC(TLBWI);
	REC_FUNC(TLBWR);
	REC_FUNC(TLBP);
	REC_SYS(ERET);
	REC_SYS(DI);
	REC_SYS(EI);

} // namespace COP0
} // namespace OpcodeImpl
} // namespace Dynarec
} // namespace R5900
