// SPDX-FileCopyrightText: 2002-2026 PCSX2 Dev Team
// SPDX-License-Identifier: GPL-3.0+

// ARM64 EE Recompiler — MMI 128-bit SIMD instructions (Phase 3: NEON)

#include "Common.h"
#include "R5900OpcodeTables.h"
#include "arm64/iR5900.h"
#include "arm64/iCore.h"

namespace a64 = vixl::aarch64;

namespace Interp = R5900::Interpreter::OpcodeImpl::MMI;

// GPR 128-bit offset from RCPUSTATE
static s64 gprQ(int reg) { return (s64)offsetof(cpuRegisters, GPR) + reg * 16; }
// HI/LO 128-bit offsets
static s64 hiQ() { return (s64)offsetof(cpuRegisters, HI); }
static s64 loQ() { return (s64)offsetof(cpuRegisters, LO); }

// Scratch NEON registers (caller-saved, not in allocator pool)
#define QS0 a64::q0
#define QS1 a64::q1
#define QS2 a64::q2
#define QS3 a64::q3

// .4S (32-bit x4) views
#define VS0 a64::VRegister(0, 128, 4)
#define VS1 a64::VRegister(1, 128, 4)
#define VS2 a64::VRegister(2, 128, 4)
#define VS3 a64::VRegister(3, 128, 4)

// .8H (16-bit x8) views
#define VH0 a64::VRegister(0, 128, 8)
#define VH1 a64::VRegister(1, 128, 8)
#define VH2 a64::VRegister(2, 128, 8)
#define VH3 a64::VRegister(3, 128, 8)

// .16B (8-bit x16) views
#define VB0 a64::VRegister(0, 128, 16)
#define VB1 a64::VRegister(1, 128, 16)
#define VB2 a64::VRegister(2, 128, 16)
#define VB3 a64::VRegister(3, 128, 16)

// .2D (64-bit x2) views
#define VD0 a64::VRegister(0, 128, 2)
#define VD1 a64::VRegister(1, 128, 2)
#define VD2 a64::VRegister(2, 128, 2)
#define VD3 a64::VRegister(3, 128, 2)

namespace R5900 {
namespace Dynarec {
namespace OpcodeImpl {
namespace MMI {

////////////////////////////////////////////////////////////////////
// Bitwise Logic: PAND, POR, PXOR, PNOR
////////////////////////////////////////////////////////////////////

void recPAND()
{
	EE::Profiler.EmitOp(eeOpcode::PAND);
	if (!_Rd_) return;
	iFlushCall(FLUSH_EVERYTHING);
	if (_Rs_ == 0 || _Rt_ == 0)
	{
		// AND with zero = zero
		armAsm->Movi(VD0, 0);
		armAsm->Str(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rd_)));
	}
	else
	{
		armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rs_)));
		armAsm->Ldr(QS1, a64::MemOperand(RCPUSTATE, gprQ(_Rt_)));
		armAsm->And(VB0, VB0, VB1);
		armAsm->Str(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rd_)));
	}
	GPR_DEL_CONST(_Rd_);
}

void recPOR()
{
	EE::Profiler.EmitOp(eeOpcode::POR);
	if (!_Rd_) return;
	iFlushCall(FLUSH_EVERYTHING);
	if (_Rs_ == 0 && _Rt_ == 0)
	{
		armAsm->Movi(VD0, 0);
		armAsm->Str(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rd_)));
	}
	else if (_Rs_ == 0)
	{
		armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rt_)));
		armAsm->Str(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rd_)));
	}
	else if (_Rt_ == 0)
	{
		armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rs_)));
		armAsm->Str(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rd_)));
	}
	else
	{
		armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rs_)));
		armAsm->Ldr(QS1, a64::MemOperand(RCPUSTATE, gprQ(_Rt_)));
		armAsm->Orr(VB0, VB0, VB1);
		armAsm->Str(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rd_)));
	}
	GPR_DEL_CONST(_Rd_);
}

void recPXOR()
{
	EE::Profiler.EmitOp(eeOpcode::PXOR);
	if (!_Rd_) return;
	iFlushCall(FLUSH_EVERYTHING);
	if (_Rs_ == _Rt_)
	{
		// XOR with self = zero
		armAsm->Movi(VD0, 0);
		armAsm->Str(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rd_)));
	}
	else if (_Rs_ == 0)
	{
		armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rt_)));
		armAsm->Str(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rd_)));
	}
	else if (_Rt_ == 0)
	{
		armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rs_)));
		armAsm->Str(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rd_)));
	}
	else
	{
		armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rs_)));
		armAsm->Ldr(QS1, a64::MemOperand(RCPUSTATE, gprQ(_Rt_)));
		armAsm->Eor(VB0, VB0, VB1);
		armAsm->Str(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rd_)));
	}
	GPR_DEL_CONST(_Rd_);
}

void recPNOR()
{
	EE::Profiler.EmitOp(eeOpcode::PNOR);
	if (!_Rd_) return;
	iFlushCall(FLUSH_EVERYTHING);
	if (_Rs_ == 0 && _Rt_ == 0)
	{
		// NOR(0,0) = all ones
		armAsm->Movi(VD0, 0xFFFFFFFFFFFFFFFFULL);
		armAsm->Str(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rd_)));
	}
	else
	{
		armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rs_ ? _Rs_ : _Rt_)));
		if (_Rs_ != 0 && _Rt_ != 0)
		{
			armAsm->Ldr(QS1, a64::MemOperand(RCPUSTATE, gprQ(_Rt_)));
			armAsm->Orr(VB0, VB0, VB1);
		}
		armAsm->Not(VB0, VB0);
		armAsm->Str(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rd_)));
	}
	GPR_DEL_CONST(_Rd_);
}

////////////////////////////////////////////////////////////////////
// Parallel Add/Sub Word (.4S)
////////////////////////////////////////////////////////////////////

void recPADDW()
{
	EE::Profiler.EmitOp(eeOpcode::PADDW);
	if (!_Rd_) return;
	iFlushCall(FLUSH_EVERYTHING);
	if (_Rs_ == 0 && _Rt_ == 0)
	{
		armAsm->Movi(VD0, 0);
	}
	else if (_Rs_ == 0)
	{
		armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rt_)));
	}
	else if (_Rt_ == 0)
	{
		armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rs_)));
	}
	else
	{
		armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rs_)));
		armAsm->Ldr(QS1, a64::MemOperand(RCPUSTATE, gprQ(_Rt_)));
		armAsm->Add(VS0, VS0, VS1);
	}
	armAsm->Str(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rd_)));
	GPR_DEL_CONST(_Rd_);
}

void recPSUBW()
{
	EE::Profiler.EmitOp(eeOpcode::PSUBW);
	if (!_Rd_) return;
	iFlushCall(FLUSH_EVERYTHING);
	if (_Rs_ == 0 && _Rt_ == 0)
	{
		armAsm->Movi(VD0, 0);
	}
	else if (_Rt_ == 0)
	{
		armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rs_)));
	}
	else if (_Rs_ == 0)
	{
		armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rt_)));
		armAsm->Neg(VS0, VS0);
	}
	else
	{
		armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rs_)));
		armAsm->Ldr(QS1, a64::MemOperand(RCPUSTATE, gprQ(_Rt_)));
		armAsm->Sub(VS0, VS0, VS1);
	}
	armAsm->Str(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rd_)));
	GPR_DEL_CONST(_Rd_);
}

////////////////////////////////////////////////////////////////////
// Parallel Add/Sub Halfword (.8H)
////////////////////////////////////////////////////////////////////

void recPADDH()
{
	EE::Profiler.EmitOp(eeOpcode::PADDH);
	if (!_Rd_) return;
	iFlushCall(FLUSH_EVERYTHING);
	if (_Rs_ == 0 && _Rt_ == 0)
	{
		armAsm->Movi(VD0, 0);
	}
	else if (_Rs_ == 0)
	{
		armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rt_)));
	}
	else if (_Rt_ == 0)
	{
		armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rs_)));
	}
	else
	{
		armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rs_)));
		armAsm->Ldr(QS1, a64::MemOperand(RCPUSTATE, gprQ(_Rt_)));
		armAsm->Add(VH0, VH0, VH1);
	}
	armAsm->Str(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rd_)));
	GPR_DEL_CONST(_Rd_);
}

void recPSUBH()
{
	EE::Profiler.EmitOp(eeOpcode::PSUBH);
	if (!_Rd_) return;
	iFlushCall(FLUSH_EVERYTHING);
	if (_Rs_ == 0 && _Rt_ == 0)
	{
		armAsm->Movi(VD0, 0);
	}
	else if (_Rt_ == 0)
	{
		armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rs_)));
	}
	else if (_Rs_ == 0)
	{
		armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rt_)));
		armAsm->Neg(VH0, VH0);
	}
	else
	{
		armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rs_)));
		armAsm->Ldr(QS1, a64::MemOperand(RCPUSTATE, gprQ(_Rt_)));
		armAsm->Sub(VH0, VH0, VH1);
	}
	armAsm->Str(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rd_)));
	GPR_DEL_CONST(_Rd_);
}

////////////////////////////////////////////////////////////////////
// Parallel Add/Sub Byte (.16B)
////////////////////////////////////////////////////////////////////

void recPADDB()
{
	EE::Profiler.EmitOp(eeOpcode::PADDB);
	if (!_Rd_) return;
	iFlushCall(FLUSH_EVERYTHING);
	if (_Rs_ == 0 && _Rt_ == 0)
	{
		armAsm->Movi(VD0, 0);
	}
	else if (_Rs_ == 0)
	{
		armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rt_)));
	}
	else if (_Rt_ == 0)
	{
		armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rs_)));
	}
	else
	{
		armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rs_)));
		armAsm->Ldr(QS1, a64::MemOperand(RCPUSTATE, gprQ(_Rt_)));
		armAsm->Add(VB0, VB0, VB1);
	}
	armAsm->Str(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rd_)));
	GPR_DEL_CONST(_Rd_);
}

void recPSUBB()
{
	EE::Profiler.EmitOp(eeOpcode::PSUBB);
	if (!_Rd_) return;
	iFlushCall(FLUSH_EVERYTHING);
	if (_Rs_ == 0 && _Rt_ == 0)
	{
		armAsm->Movi(VD0, 0);
	}
	else if (_Rt_ == 0)
	{
		armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rs_)));
	}
	else if (_Rs_ == 0)
	{
		armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rt_)));
		armAsm->Neg(VB0, VB0);
	}
	else
	{
		armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rs_)));
		armAsm->Ldr(QS1, a64::MemOperand(RCPUSTATE, gprQ(_Rt_)));
		armAsm->Sub(VB0, VB0, VB1);
	}
	armAsm->Str(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rd_)));
	GPR_DEL_CONST(_Rd_);
}

////////////////////////////////////////////////////////////////////
// Saturating Add/Sub (signed) - NEON has native saturation
////////////////////////////////////////////////////////////////////

void recPADDSW()
{
	EE::Profiler.EmitOp(eeOpcode::PADDSW);
	if (!_Rd_) return;
	iFlushCall(FLUSH_EVERYTHING);
	armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rs_)));
	armAsm->Ldr(QS1, a64::MemOperand(RCPUSTATE, gprQ(_Rt_)));
	armAsm->Sqadd(VS0, VS0, VS1);
	armAsm->Str(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rd_)));
	GPR_DEL_CONST(_Rd_);
}

void recPSUBSW()
{
	EE::Profiler.EmitOp(eeOpcode::PSUBSW);
	if (!_Rd_) return;
	iFlushCall(FLUSH_EVERYTHING);
	armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rs_)));
	armAsm->Ldr(QS1, a64::MemOperand(RCPUSTATE, gprQ(_Rt_)));
	armAsm->Sqsub(VS0, VS0, VS1);
	armAsm->Str(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rd_)));
	GPR_DEL_CONST(_Rd_);
}

void recPADDSH()
{
	EE::Profiler.EmitOp(eeOpcode::PADDSH);
	if (!_Rd_) return;
	iFlushCall(FLUSH_EVERYTHING);
	armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rs_)));
	armAsm->Ldr(QS1, a64::MemOperand(RCPUSTATE, gprQ(_Rt_)));
	armAsm->Sqadd(VH0, VH0, VH1);
	armAsm->Str(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rd_)));
	GPR_DEL_CONST(_Rd_);
}

void recPSUBSH()
{
	EE::Profiler.EmitOp(eeOpcode::PSUBSH);
	if (!_Rd_) return;
	iFlushCall(FLUSH_EVERYTHING);
	armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rs_)));
	armAsm->Ldr(QS1, a64::MemOperand(RCPUSTATE, gprQ(_Rt_)));
	armAsm->Sqsub(VH0, VH0, VH1);
	armAsm->Str(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rd_)));
	GPR_DEL_CONST(_Rd_);
}

void recPADDSB()
{
	EE::Profiler.EmitOp(eeOpcode::PADDSB);
	if (!_Rd_) return;
	iFlushCall(FLUSH_EVERYTHING);
	armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rs_)));
	armAsm->Ldr(QS1, a64::MemOperand(RCPUSTATE, gprQ(_Rt_)));
	armAsm->Sqadd(VB0, VB0, VB1);
	armAsm->Str(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rd_)));
	GPR_DEL_CONST(_Rd_);
}

void recPSUBSB()
{
	EE::Profiler.EmitOp(eeOpcode::PSUBSB);
	if (!_Rd_) return;
	iFlushCall(FLUSH_EVERYTHING);
	armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rs_)));
	armAsm->Ldr(QS1, a64::MemOperand(RCPUSTATE, gprQ(_Rt_)));
	armAsm->Sqsub(VB0, VB0, VB1);
	armAsm->Str(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rd_)));
	GPR_DEL_CONST(_Rd_);
}

////////////////////////////////////////////////////////////////////
// Unsigned Saturating Add/Sub
////////////////////////////////////////////////////////////////////

void recPADDUW()
{
	EE::Profiler.EmitOp(eeOpcode::PADDUW);
	if (!_Rd_) return;
	iFlushCall(FLUSH_EVERYTHING);
	armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rs_)));
	armAsm->Ldr(QS1, a64::MemOperand(RCPUSTATE, gprQ(_Rt_)));
	armAsm->Uqadd(VS0, VS0, VS1);
	armAsm->Str(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rd_)));
	GPR_DEL_CONST(_Rd_);
}

void recPSUBUW()
{
	EE::Profiler.EmitOp(eeOpcode::PSUBUW);
	if (!_Rd_) return;
	iFlushCall(FLUSH_EVERYTHING);
	armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rs_)));
	armAsm->Ldr(QS1, a64::MemOperand(RCPUSTATE, gprQ(_Rt_)));
	armAsm->Uqsub(VS0, VS0, VS1);
	armAsm->Str(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rd_)));
	GPR_DEL_CONST(_Rd_);
}

void recPADDUH()
{
	EE::Profiler.EmitOp(eeOpcode::PADDUH);
	if (!_Rd_) return;
	iFlushCall(FLUSH_EVERYTHING);
	armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rs_)));
	armAsm->Ldr(QS1, a64::MemOperand(RCPUSTATE, gprQ(_Rt_)));
	armAsm->Uqadd(VH0, VH0, VH1);
	armAsm->Str(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rd_)));
	GPR_DEL_CONST(_Rd_);
}

void recPSUBUH()
{
	EE::Profiler.EmitOp(eeOpcode::PSUBUH);
	if (!_Rd_) return;
	iFlushCall(FLUSH_EVERYTHING);
	armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rs_)));
	armAsm->Ldr(QS1, a64::MemOperand(RCPUSTATE, gprQ(_Rt_)));
	armAsm->Uqsub(VH0, VH0, VH1);
	armAsm->Str(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rd_)));
	GPR_DEL_CONST(_Rd_);
}

void recPADDUB()
{
	EE::Profiler.EmitOp(eeOpcode::PADDUB);
	if (!_Rd_) return;
	iFlushCall(FLUSH_EVERYTHING);
	armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rs_)));
	armAsm->Ldr(QS1, a64::MemOperand(RCPUSTATE, gprQ(_Rt_)));
	armAsm->Uqadd(VB0, VB0, VB1);
	armAsm->Str(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rd_)));
	GPR_DEL_CONST(_Rd_);
}

void recPSUBUB()
{
	EE::Profiler.EmitOp(eeOpcode::PSUBUB);
	if (!_Rd_) return;
	iFlushCall(FLUSH_EVERYTHING);
	armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rs_)));
	armAsm->Ldr(QS1, a64::MemOperand(RCPUSTATE, gprQ(_Rt_)));
	armAsm->Uqsub(VB0, VB0, VB1);
	armAsm->Str(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rd_)));
	GPR_DEL_CONST(_Rd_);
}

////////////////////////////////////////////////////////////////////
// Comparisons
////////////////////////////////////////////////////////////////////

void recPCGTW()
{
	EE::Profiler.EmitOp(eeOpcode::PCGTW);
	if (!_Rd_) return;
	iFlushCall(FLUSH_EVERYTHING);
	armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rs_)));
	armAsm->Ldr(QS1, a64::MemOperand(RCPUSTATE, gprQ(_Rt_)));
	armAsm->Cmgt(VS0, VS0, VS1);
	armAsm->Str(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rd_)));
	GPR_DEL_CONST(_Rd_);
}

void recPCEQW()
{
	EE::Profiler.EmitOp(eeOpcode::PCEQW);
	if (!_Rd_) return;
	iFlushCall(FLUSH_EVERYTHING);
	armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rs_)));
	armAsm->Ldr(QS1, a64::MemOperand(RCPUSTATE, gprQ(_Rt_)));
	armAsm->Cmeq(VS0, VS0, VS1);
	armAsm->Str(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rd_)));
	GPR_DEL_CONST(_Rd_);
}

void recPCGTH()
{
	EE::Profiler.EmitOp(eeOpcode::PCGTH);
	if (!_Rd_) return;
	iFlushCall(FLUSH_EVERYTHING);
	armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rs_)));
	armAsm->Ldr(QS1, a64::MemOperand(RCPUSTATE, gprQ(_Rt_)));
	armAsm->Cmgt(VH0, VH0, VH1);
	armAsm->Str(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rd_)));
	GPR_DEL_CONST(_Rd_);
}

void recPCEQH()
{
	EE::Profiler.EmitOp(eeOpcode::PCEQH);
	if (!_Rd_) return;
	iFlushCall(FLUSH_EVERYTHING);
	armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rs_)));
	armAsm->Ldr(QS1, a64::MemOperand(RCPUSTATE, gprQ(_Rt_)));
	armAsm->Cmeq(VH0, VH0, VH1);
	armAsm->Str(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rd_)));
	GPR_DEL_CONST(_Rd_);
}

void recPCGTB()
{
	EE::Profiler.EmitOp(eeOpcode::PCGTB);
	if (!_Rd_) return;
	iFlushCall(FLUSH_EVERYTHING);
	armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rs_)));
	armAsm->Ldr(QS1, a64::MemOperand(RCPUSTATE, gprQ(_Rt_)));
	armAsm->Cmgt(VB0, VB0, VB1);
	armAsm->Str(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rd_)));
	GPR_DEL_CONST(_Rd_);
}

void recPCEQB()
{
	EE::Profiler.EmitOp(eeOpcode::PCEQB);
	if (!_Rd_) return;
	iFlushCall(FLUSH_EVERYTHING);
	armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rs_)));
	armAsm->Ldr(QS1, a64::MemOperand(RCPUSTATE, gprQ(_Rt_)));
	armAsm->Cmeq(VB0, VB0, VB1);
	armAsm->Str(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rd_)));
	GPR_DEL_CONST(_Rd_);
}

////////////////////////////////////////////////////////////////////
// Min/Max
////////////////////////////////////////////////////////////////////

void recPMAXW()
{
	EE::Profiler.EmitOp(eeOpcode::PMAXW);
	if (!_Rd_) return;
	iFlushCall(FLUSH_EVERYTHING);
	armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rs_)));
	armAsm->Ldr(QS1, a64::MemOperand(RCPUSTATE, gprQ(_Rt_)));
	armAsm->Smax(VS0, VS0, VS1);
	armAsm->Str(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rd_)));
	GPR_DEL_CONST(_Rd_);
}

void recPMINW()
{
	EE::Profiler.EmitOp(eeOpcode::PMINW);
	if (!_Rd_) return;
	iFlushCall(FLUSH_EVERYTHING);
	armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rs_)));
	armAsm->Ldr(QS1, a64::MemOperand(RCPUSTATE, gprQ(_Rt_)));
	armAsm->Smin(VS0, VS0, VS1);
	armAsm->Str(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rd_)));
	GPR_DEL_CONST(_Rd_);
}

void recPMAXH()
{
	EE::Profiler.EmitOp(eeOpcode::PMAXH);
	if (!_Rd_) return;
	iFlushCall(FLUSH_EVERYTHING);
	armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rs_)));
	armAsm->Ldr(QS1, a64::MemOperand(RCPUSTATE, gprQ(_Rt_)));
	armAsm->Smax(VH0, VH0, VH1);
	armAsm->Str(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rd_)));
	GPR_DEL_CONST(_Rd_);
}

void recPMINH()
{
	EE::Profiler.EmitOp(eeOpcode::PMINH);
	if (!_Rd_) return;
	iFlushCall(FLUSH_EVERYTHING);
	armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rs_)));
	armAsm->Ldr(QS1, a64::MemOperand(RCPUSTATE, gprQ(_Rt_)));
	armAsm->Smin(VH0, VH0, VH1);
	armAsm->Str(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rd_)));
	GPR_DEL_CONST(_Rd_);
}

////////////////////////////////////////////////////////////////////
// Absolute Value
////////////////////////////////////////////////////////////////////

void recPABSW()
{
	EE::Profiler.EmitOp(eeOpcode::PABSW);
	if (!_Rd_) return;
	iFlushCall(FLUSH_EVERYTHING);
	armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rt_)));
	// PS2 PABSW: abs(0x80000000) = 0x7FFFFFFF (clamped, not overflow)
	armAsm->Abs(VS0, VS0);
	// Detect 0x80000000 overflow: SQABS saturates, but Abs doesn't. Use Sqabs instead.
	// Actually, NEON SQABS does signed saturating abs, which gives 0x7FFFFFFF for 0x80000000
	armAsm->Sqabs(VS0, VS0);
	armAsm->Str(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rd_)));
	GPR_DEL_CONST(_Rd_);
}

void recPABSH()
{
	EE::Profiler.EmitOp(eeOpcode::PABSH);
	if (!_Rd_) return;
	iFlushCall(FLUSH_EVERYTHING);
	armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rt_)));
	armAsm->Sqabs(VH0, VH0);
	armAsm->Str(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rd_)));
	GPR_DEL_CONST(_Rd_);
}

////////////////////////////////////////////////////////////////////
// Immediate Shifts
////////////////////////////////////////////////////////////////////

void recPSLLW()
{
	EE::Profiler.EmitOp(eeOpcode::PSLLW);
	if (!_Rd_) return;
	iFlushCall(FLUSH_EVERYTHING);
	if (_Sa_ == 0)
	{
		armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rt_)));
	}
	else
	{
		armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rt_)));
		armAsm->Shl(VS0, VS0, _Sa_);
	}
	armAsm->Str(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rd_)));
	GPR_DEL_CONST(_Rd_);
}

void recPSRLW()
{
	EE::Profiler.EmitOp(eeOpcode::PSRLW);
	if (!_Rd_) return;
	iFlushCall(FLUSH_EVERYTHING);
	if (_Sa_ == 0)
	{
		armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rt_)));
	}
	else
	{
		armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rt_)));
		armAsm->Ushr(VS0, VS0, _Sa_);
	}
	armAsm->Str(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rd_)));
	GPR_DEL_CONST(_Rd_);
}

void recPSRAW()
{
	EE::Profiler.EmitOp(eeOpcode::PSRAW);
	if (!_Rd_) return;
	iFlushCall(FLUSH_EVERYTHING);
	if (_Sa_ == 0)
	{
		armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rt_)));
	}
	else
	{
		armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rt_)));
		armAsm->Sshr(VS0, VS0, _Sa_);
	}
	armAsm->Str(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rd_)));
	GPR_DEL_CONST(_Rd_);
}

void recPSLLH()
{
	EE::Profiler.EmitOp(eeOpcode::PSLLH);
	if (!_Rd_) return;
	iFlushCall(FLUSH_EVERYTHING);
	if (_Sa_ == 0)
	{
		armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rt_)));
	}
	else
	{
		armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rt_)));
		armAsm->Shl(VH0, VH0, _Sa_);
	}
	armAsm->Str(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rd_)));
	GPR_DEL_CONST(_Rd_);
}

void recPSRLH()
{
	EE::Profiler.EmitOp(eeOpcode::PSRLH);
	if (!_Rd_) return;
	iFlushCall(FLUSH_EVERYTHING);
	if (_Sa_ == 0)
	{
		armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rt_)));
	}
	else
	{
		armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rt_)));
		armAsm->Ushr(VH0, VH0, _Sa_);
	}
	armAsm->Str(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rd_)));
	GPR_DEL_CONST(_Rd_);
}

void recPSRAH()
{
	EE::Profiler.EmitOp(eeOpcode::PSRAH);
	if (!_Rd_) return;
	iFlushCall(FLUSH_EVERYTHING);
	if (_Sa_ == 0)
	{
		armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rt_)));
	}
	else
	{
		armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rt_)));
		armAsm->Sshr(VH0, VH0, _Sa_);
	}
	armAsm->Str(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rd_)));
	GPR_DEL_CONST(_Rd_);
}

////////////////////////////////////////////////////////////////////
// Copy / Move operations
////////////////////////////////////////////////////////////////////

// PCPYLD: Rd = Rs[63:0] | Rt[63:0]  (lower dwords of each)
void recPCPYLD()
{
	EE::Profiler.EmitOp(eeOpcode::PCPYLD);
	if (!_Rd_) return;
	iFlushCall(FLUSH_EVERYTHING);
	// Rd[127:64] = Rs[63:0], Rd[63:0] = Rt[63:0]
	if (_Rs_ == 0 && _Rt_ == 0)
	{
		armAsm->Movi(VD0, 0);
	}
	else if (_Rs_ == 0)
	{
		armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rt_)));
		// Zero upper 64 bits: Ins v0.d[1], xzr won't work directly; use Movi+Ins
		armAsm->Mov(a64::x0, 0);
		armAsm->Ins(VD0, 1, a64::x0);
	}
	else if (_Rt_ == 0)
	{
		armAsm->Ldr(QS1, a64::MemOperand(RCPUSTATE, gprQ(_Rs_)));
		armAsm->Movi(VD0, 0);
		// Rd[127:64] = Rs[63:0]
		armAsm->Ins(VD0, 1, VD1, 0);
	}
	else
	{
		armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rt_)));
		armAsm->Ldr(QS1, a64::MemOperand(RCPUSTATE, gprQ(_Rs_)));
		// Rd[127:64] = Rs[63:0], keep Rd[63:0] = Rt[63:0]
		armAsm->Ins(VD0, 1, VD1, 0);
	}
	armAsm->Str(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rd_)));
	GPR_DEL_CONST(_Rd_);
}

// PCPYUD: Rd = Rs[127:64] | Rt[127:64]  (upper dwords of each)
void recPCPYUD()
{
	EE::Profiler.EmitOp(eeOpcode::PCPYUD);
	if (!_Rd_) return;
	iFlushCall(FLUSH_EVERYTHING);
	// Rd[63:0] = Rs[127:64], Rd[127:64] = Rt[127:64]
	if (_Rs_ == 0 && _Rt_ == 0)
	{
		armAsm->Movi(VD0, 0);
	}
	else if (_Rs_ == 0)
	{
		armAsm->Ldr(QS1, a64::MemOperand(RCPUSTATE, gprQ(_Rt_)));
		armAsm->Movi(VD0, 0);
		armAsm->Ins(VD0, 1, VD1, 1);
	}
	else if (_Rt_ == 0)
	{
		armAsm->Ldr(QS1, a64::MemOperand(RCPUSTATE, gprQ(_Rs_)));
		armAsm->Movi(VD0, 0);
		armAsm->Ins(VD0, 0, VD1, 1);
	}
	else
	{
		armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rs_)));
		armAsm->Ldr(QS1, a64::MemOperand(RCPUSTATE, gprQ(_Rt_)));
		// Rd[63:0] = Rs[127:64]
		armAsm->Ins(VD0, 0, VD0, 1);
		// Rd[127:64] = Rt[127:64]
		armAsm->Ins(VD0, 1, VD1, 1);
	}
	armAsm->Str(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rd_)));
	GPR_DEL_CONST(_Rd_);
}

// PCPYH: Rd = replicate Rt halfword[0] to all 8 halfword slots
void recPCPYH()
{
	EE::Profiler.EmitOp(eeOpcode::PCPYH);
	if (!_Rd_) return;
	iFlushCall(FLUSH_EVERYTHING);
	if (_Rt_ == 0)
	{
		armAsm->Movi(VD0, 0);
	}
	else
	{
		armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rt_)));
		armAsm->Dup(VH0, VH0, 0);
	}
	armAsm->Str(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rd_)));
	GPR_DEL_CONST(_Rd_);
}

////////////////////////////////////////////////////////////////////
// HI/LO Move (128-bit)
////////////////////////////////////////////////////////////////////

void recPMFHI()
{
	EE::Profiler.EmitOp(eeOpcode::PMFHI);
	if (!_Rd_) return;
	iFlushCall(FLUSH_EVERYTHING);
	armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, hiQ()));
	armAsm->Str(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rd_)));
	GPR_DEL_CONST(_Rd_);
}

void recPMFLO()
{
	EE::Profiler.EmitOp(eeOpcode::PMFLO);
	if (!_Rd_) return;
	iFlushCall(FLUSH_EVERYTHING);
	armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, loQ()));
	armAsm->Str(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rd_)));
	GPR_DEL_CONST(_Rd_);
}

void recPMTHI()
{
	EE::Profiler.EmitOp(eeOpcode::PMTHI);
	iFlushCall(FLUSH_EVERYTHING);
	armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rs_)));
	armAsm->Str(QS0, a64::MemOperand(RCPUSTATE, hiQ()));
}

void recPMTLO()
{
	EE::Profiler.EmitOp(eeOpcode::PMTLO);
	iFlushCall(FLUSH_EVERYTHING);
	armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rs_)));
	armAsm->Str(QS0, a64::MemOperand(RCPUSTATE, loQ()));
}

////////////////////////////////////////////////////////////////////
// Variable Shifts (Rs provides shift amount per-element)
////////////////////////////////////////////////////////////////////

void recPSLLVW()
{
	EE::Profiler.EmitOp(eeOpcode::PSLLVW);
	if (!_Rd_) return;
	iFlushCall(FLUSH_EVERYTHING);
	armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rt_)));
	armAsm->Ldr(QS1, a64::MemOperand(RCPUSTATE, gprQ(_Rs_)));
	// Mask shift to 5 bits per element
	armAsm->Movi(VS2, 0x1F, a64::LSL, 0);
	armAsm->And(VB1, VB1, VB2);
	// NEON USHL does variable shift (positive = left)
	armAsm->Ushl(VS0, VS0, VS1);
	armAsm->Str(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rd_)));
	GPR_DEL_CONST(_Rd_);
}

void recPSRLVW()
{
	EE::Profiler.EmitOp(eeOpcode::PSRLVW);
	if (!_Rd_) return;
	iFlushCall(FLUSH_EVERYTHING);
	armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rt_)));
	armAsm->Ldr(QS1, a64::MemOperand(RCPUSTATE, gprQ(_Rs_)));
	// Mask shift to 5 bits, then negate for right shift
	armAsm->Movi(VS2, 0x1F, a64::LSL, 0);
	armAsm->And(VB1, VB1, VB2);
	armAsm->Neg(VS1, VS1);
	armAsm->Ushl(VS0, VS0, VS1);
	armAsm->Str(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rd_)));
	GPR_DEL_CONST(_Rd_);
}

void recPSRAVW()
{
	EE::Profiler.EmitOp(eeOpcode::PSRAVW);
	if (!_Rd_) return;
	iFlushCall(FLUSH_EVERYTHING);
	armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rt_)));
	armAsm->Ldr(QS1, a64::MemOperand(RCPUSTATE, gprQ(_Rs_)));
	// Mask shift to 5 bits, then negate for right shift
	armAsm->Movi(VS2, 0x1F, a64::LSL, 0);
	armAsm->And(VB1, VB1, VB2);
	armAsm->Neg(VS1, VS1);
	// SSHL does signed variable shift (negative = arithmetic right)
	armAsm->Sshl(VS0, VS0, VS1);
	armAsm->Str(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rd_)));
	GPR_DEL_CONST(_Rd_);
}

////////////////////////////////////////////////////////////////////
// Extract Lower/Upper (interleave with zero or with Rs)
////////////////////////////////////////////////////////////////////

// PEXTLW: Interleave lower 32-bit words: Rd = {Rs[1],Rt[1],Rs[0],Rt[0]}
void recPEXTLW()
{
	EE::Profiler.EmitOp(eeOpcode::PEXTLW);
	if (!_Rd_) return;
	iFlushCall(FLUSH_EVERYTHING);
	armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rt_)));
	armAsm->Ldr(QS1, a64::MemOperand(RCPUSTATE, gprQ(_Rs_)));
	// ZIP1 interleaves lower halves: {a0,b0,a1,b1}
	armAsm->Zip1(VS0, VS0, VS1);
	armAsm->Str(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rd_)));
	GPR_DEL_CONST(_Rd_);
}

void recPEXTUW()
{
	EE::Profiler.EmitOp(eeOpcode::PEXTUW);
	if (!_Rd_) return;
	iFlushCall(FLUSH_EVERYTHING);
	armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rt_)));
	armAsm->Ldr(QS1, a64::MemOperand(RCPUSTATE, gprQ(_Rs_)));
	// ZIP2 interleaves upper halves
	armAsm->Zip2(VS0, VS0, VS1);
	armAsm->Str(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rd_)));
	GPR_DEL_CONST(_Rd_);
}

void recPEXTLH()
{
	EE::Profiler.EmitOp(eeOpcode::PEXTLH);
	if (!_Rd_) return;
	iFlushCall(FLUSH_EVERYTHING);
	armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rt_)));
	armAsm->Ldr(QS1, a64::MemOperand(RCPUSTATE, gprQ(_Rs_)));
	armAsm->Zip1(VH0, VH0, VH1);
	armAsm->Str(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rd_)));
	GPR_DEL_CONST(_Rd_);
}

void recPEXTUH()
{
	EE::Profiler.EmitOp(eeOpcode::PEXTUH);
	if (!_Rd_) return;
	iFlushCall(FLUSH_EVERYTHING);
	armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rt_)));
	armAsm->Ldr(QS1, a64::MemOperand(RCPUSTATE, gprQ(_Rs_)));
	armAsm->Zip2(VH0, VH0, VH1);
	armAsm->Str(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rd_)));
	GPR_DEL_CONST(_Rd_);
}

void recPEXTLB()
{
	EE::Profiler.EmitOp(eeOpcode::PEXTLB);
	if (!_Rd_) return;
	iFlushCall(FLUSH_EVERYTHING);
	armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rt_)));
	armAsm->Ldr(QS1, a64::MemOperand(RCPUSTATE, gprQ(_Rs_)));
	armAsm->Zip1(VB0, VB0, VB1);
	armAsm->Str(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rd_)));
	GPR_DEL_CONST(_Rd_);
}

void recPEXTUB()
{
	EE::Profiler.EmitOp(eeOpcode::PEXTUB);
	if (!_Rd_) return;
	iFlushCall(FLUSH_EVERYTHING);
	armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rt_)));
	armAsm->Ldr(QS1, a64::MemOperand(RCPUSTATE, gprQ(_Rs_)));
	armAsm->Zip2(VB0, VB0, VB1);
	armAsm->Str(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rd_)));
	GPR_DEL_CONST(_Rd_);
}

////////////////////////////////////////////////////////////////////
// Pack operations
////////////////////////////////////////////////////////////////////

// PPACW: Pack word - takes even-indexed 32-bit words from Rs and Rt
// Rd = {Rs[2],Rs[0],Rt[2],Rt[0]}
void recPPACW()
{
	EE::Profiler.EmitOp(eeOpcode::PPACW);
	if (!_Rd_) return;
	iFlushCall(FLUSH_EVERYTHING);
	armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rt_)));
	armAsm->Ldr(QS1, a64::MemOperand(RCPUSTATE, gprQ(_Rs_)));
	// UZP1.4S extracts even indices: {a0,a2,b0,b2}
	armAsm->Uzp1(VS0, VS0, VS1);
	armAsm->Str(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rd_)));
	GPR_DEL_CONST(_Rd_);
}

// PPACH: Pack halfword
void recPPACH()
{
	EE::Profiler.EmitOp(eeOpcode::PPACH);
	if (!_Rd_) return;
	iFlushCall(FLUSH_EVERYTHING);
	armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rt_)));
	armAsm->Ldr(QS1, a64::MemOperand(RCPUSTATE, gprQ(_Rs_)));
	armAsm->Uzp1(VH0, VH0, VH1);
	armAsm->Str(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rd_)));
	GPR_DEL_CONST(_Rd_);
}

// PPACB: Pack byte
void recPPACB()
{
	EE::Profiler.EmitOp(eeOpcode::PPACB);
	if (!_Rd_) return;
	iFlushCall(FLUSH_EVERYTHING);
	armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rt_)));
	armAsm->Ldr(QS1, a64::MemOperand(RCPUSTATE, gprQ(_Rs_)));
	armAsm->Uzp1(VB0, VB0, VB1);
	armAsm->Str(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rd_)));
	GPR_DEL_CONST(_Rd_);
}

////////////////////////////////////////////////////////////////////
// Shuffle/Exchange operations
////////////////////////////////////////////////////////////////////

// PEXEW: Exchange even words: {w3,w0,w1,w2} → swap w0↔w2
void recPEXEW()
{
	EE::Profiler.EmitOp(eeOpcode::PEXEW);
	if (!_Rd_) return;
	iFlushCall(FLUSH_EVERYTHING);
	armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rt_)));
	// Swap elements 0 and 2: {w2,w1,w0,w3} = Rev64 on .4S swaps within each 64-bit lane
	armAsm->Rev64(VS0, VS0);
	armAsm->Str(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rd_)));
	GPR_DEL_CONST(_Rd_);
}

// PEXEH: Exchange even halfwords within each 32-bit lane
void recPEXEH()
{
	EE::Profiler.EmitOp(eeOpcode::PEXEH);
	if (!_Rd_) return;
	iFlushCall(FLUSH_EVERYTHING);
	armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rt_)));
	armAsm->Rev32(VH0, VH0);
	armAsm->Str(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rd_)));
	GPR_DEL_CONST(_Rd_);
}

// PREVH: Reverse halfwords in each 64-bit lane
void recPREVH()
{
	EE::Profiler.EmitOp(eeOpcode::PREVH);
	if (!_Rd_) return;
	iFlushCall(FLUSH_EVERYTHING);
	armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rt_)));
	armAsm->Rev64(VH0, VH0);
	armAsm->Str(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rd_)));
	GPR_DEL_CONST(_Rd_);
}

// PROT3W: Rotate 3 words: {w3,w0,w2,w1}
void recPROT3W()
{
	EE::Profiler.EmitOp(eeOpcode::PROT3W);
	if (!_Rd_) return;
	iFlushCall(FLUSH_EVERYTHING);
	armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rt_)));
	// PROT3W: Rd = {Rt[3], Rt[0], Rt[2], Rt[1]} = rotate lower 3 words
	// Use EXT to rotate: EXT by 4 bytes gives {w1,w2,w3,w0}, then fix w3 position
	// Simpler: use scalar moves
	armAsm->Mov(QS1, QS0);
	armAsm->Ins(VS0, 0, VS1, 1);  // Rd[0] = Rt[1]
	armAsm->Ins(VS0, 1, VS1, 2);  // Rd[1] = Rt[2]
	armAsm->Ins(VS0, 2, VS1, 0);  // Rd[2] = Rt[0]
	// Rd[3] = Rt[3] unchanged
	armAsm->Str(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rd_)));
	GPR_DEL_CONST(_Rd_);
}

// PEXCW: Exchange center words: {w3,w1,w2,w0} → swap w1↔w2
void recPEXCW()
{
	EE::Profiler.EmitOp(eeOpcode::PEXCW);
	if (!_Rd_) return;
	iFlushCall(FLUSH_EVERYTHING);
	armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rt_)));
	// Swap elements 1 and 2
	armAsm->Mov(QS1, QS0);
	armAsm->Ins(VS0, 1, VS1, 2);
	armAsm->Ins(VS0, 2, VS1, 1);
	armAsm->Str(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rd_)));
	GPR_DEL_CONST(_Rd_);
}

// PEXCH: Exchange center halfwords within each 32-bit lane
void recPEXCH()
{
	EE::Profiler.EmitOp(eeOpcode::PEXCH);
	if (!_Rd_) return;
	iFlushCall(FLUSH_EVERYTHING);
	armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rt_)));
	// Swap halfwords 1↔2, 5↔6 within each 64-bit group
	// Use TRN (transpose): TRN1/TRN2 on .4S does pairwise transpose
	// Simpler: use scalar insert
	armAsm->Mov(QS1, QS0);
	armAsm->Ins(VH0, 1, VH1, 2);
	armAsm->Ins(VH0, 2, VH1, 1);
	armAsm->Ins(VH0, 5, VH1, 6);
	armAsm->Ins(VH0, 6, VH1, 5);
	armAsm->Str(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rd_)));
	GPR_DEL_CONST(_Rd_);
}

// PINTH: Interleave halfwords from upper halves
void recPINTH()
{
	EE::Profiler.EmitOp(eeOpcode::PINTH);
	if (!_Rd_) return;
	iFlushCall(FLUSH_EVERYTHING);
	armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rt_)));
	armAsm->Ldr(QS1, a64::MemOperand(RCPUSTATE, gprQ(_Rs_)));
	armAsm->Zip2(VH0, VH0, VH1);
	armAsm->Str(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rd_)));
	GPR_DEL_CONST(_Rd_);
}

// PINTEH: Interleave even halfwords
void recPINTEH()
{
	EE::Profiler.EmitOp(eeOpcode::PINTEH);
	if (!_Rd_) return;
	iFlushCall(FLUSH_EVERYTHING);
	armAsm->Ldr(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rt_)));
	armAsm->Ldr(QS1, a64::MemOperand(RCPUSTATE, gprQ(_Rs_)));
	// Take even halfwords from each: UZP1.8H then interleave
	// PINTEH: Rd = {Rs[6],Rt[6],Rs[4],Rt[4],Rs[2],Rt[2],Rs[0],Rt[0]} (even halfwords interleaved)
	armAsm->Uzp1(VH0, VH0, VH0);  // pack even halfwords of Rt
	armAsm->Uzp1(VH1, VH1, VH1);  // pack even halfwords of Rs
	armAsm->Zip1(VH0, VH0, VH1);  // interleave them
	armAsm->Str(QS0, a64::MemOperand(RCPUSTATE, gprQ(_Rd_)));
	GPR_DEL_CONST(_Rd_);
}

////////////////////////////////////////////////////////////////////
// Interpreter fallback for complex/rare operations
////////////////////////////////////////////////////////////////////

REC_FUNC(PLZCW);
REC_FUNC(PMFHL);
REC_FUNC(PMTHL);
REC_FUNC(PADSBH);
REC_FUNC(PEXT5);
REC_FUNC(PPAC5);
REC_FUNC(QFSRV);

////////////////////////////////////////////////////////////////////
// Multiply operations (write HI/LO) - interpreter fallback
////////////////////////////////////////////////////////////////////

REC_FUNC(PMULTW);
REC_FUNC(PMULTH);
REC_FUNC(PMULTUW);
REC_FUNC(PMADDW);
REC_FUNC(PMADDH);
REC_FUNC(PMADDUW);
REC_FUNC(PMSUBW);
REC_FUNC(PMSUBH);
REC_FUNC(PHMADH);
REC_FUNC(PHMSBH);
REC_FUNC(PDIVW);
REC_FUNC(PDIVBW);
REC_FUNC(PDIVUW);

} // namespace MMI
} // namespace OpcodeImpl
} // namespace Dynarec
} // namespace R5900
