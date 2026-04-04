// SPDX-FileCopyrightText: 2002-2026 PCSX2 Dev Team
// SPDX-License-Identifier: GPL-3.0+

// ARM64 EE Recompiler — Miscellaneous instructions and handlers

#include "Common.h"
#include "arm64/iR5900.h"
#include "arm64/iCore.h"
#include "R5900OpcodeTables.h"

namespace R5900 {
namespace Dynarec {

namespace OpcodeImpl {

////////////////////////////////////////////////////
// NOP-like instructions
void recPREF()
{
}

void recSYNC()
{
}

void recCACHE()
{
	// Cache operations are no-ops in JIT mode
}

////////////////////////////////////////////////////
// Error handlers

void recNULL()
{
	Console.Error("EE: Unimplemented op %x", cpuRegs.code);
}

void recUnknown()
{
	Console.Error("EE: Unrecognized op %x", cpuRegs.code);
}

void recMMI_Unknown()
{
	Console.Error("EE: Unrecognized MMI op %x", cpuRegs.code);
}

void recCOP0_Unknown()
{
	Console.Error("EE: Unrecognized COP0 op %x", cpuRegs.code);
}

void recCOP1_Unknown()
{
	Console.Error("EE: Unrecognized FPU/COP1 op %x", cpuRegs.code);
}

////////////////////////////////////////////////////
// Trap instructions — all use recBranchCall

void recTGE()
{
	recBranchCall(R5900::Interpreter::OpcodeImpl::TGE);
}

void recTGEU()
{
	recBranchCall(R5900::Interpreter::OpcodeImpl::TGEU);
}

void recTLT()
{
	recBranchCall(R5900::Interpreter::OpcodeImpl::TLT);
}

void recTLTU()
{
	recBranchCall(R5900::Interpreter::OpcodeImpl::TLTU);
}

void recTEQ()
{
	recBranchCall(R5900::Interpreter::OpcodeImpl::TEQ);
}

void recTNE()
{
	recBranchCall(R5900::Interpreter::OpcodeImpl::TNE);
}

void recTGEI()
{
	recBranchCall(R5900::Interpreter::OpcodeImpl::TGEI);
}

void recTGEIU()
{
	recBranchCall(R5900::Interpreter::OpcodeImpl::TGEIU);
}

void recTLTI()
{
	recBranchCall(R5900::Interpreter::OpcodeImpl::TLTI);
}

void recTLTIU()
{
	recBranchCall(R5900::Interpreter::OpcodeImpl::TLTIU);
}

void recTEQI()
{
	recBranchCall(R5900::Interpreter::OpcodeImpl::TEQI);
}

void recTNEI()
{
	recBranchCall(R5900::Interpreter::OpcodeImpl::TNEI);
}

} // namespace OpcodeImpl
} // namespace Dynarec
} // namespace R5900
