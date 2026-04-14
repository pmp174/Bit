// SPDX-FileCopyrightText: 2002-2026 PCSX2 Dev Team
// SPDX-License-Identifier: GPL-3.0+

// ARM64 IOP Recompiler — Instruction tables (Phase 0: all interpreter fallback)

#include "Common.h"
#include "arm64/iR3000A.h"
#include "IopMem.h"
#include "IopGte.h"

namespace a64 = vixl::aarch64;

extern int g_psxWriteOk;
extern u32 g_psxMaxRecMem;

// Forward declarations for IOP interpreter functions
extern void psxADDI();  extern void psxADDIU(); extern void psxSLTI();  extern void psxSLTIU();
extern void psxANDI();  extern void psxORI();   extern void psxXORI();  extern void psxLUI();
extern void psxSLL();   extern void psxSRL();   extern void psxSRA();
extern void psxSLLV();  extern void psxSRLV();  extern void psxSRAV();
extern void psxADD();   extern void psxADDU();  extern void psxSUB();   extern void psxSUBU();
extern void psxAND();   extern void psxOR();    extern void psxXOR();   extern void psxNOR();
extern void psxSLT();   extern void psxSLTU();
extern void psxMULT();  extern void psxMULTU(); extern void psxDIV();   extern void psxDIVU();
extern void psxMFHI();  extern void psxMTHI();  extern void psxMFLO();  extern void psxMTLO();
extern void psxLB();    extern void psxLH();    extern void psxLW();
extern void psxLBU();   extern void psxLHU();   extern void psxLWL();   extern void psxLWR();
extern void psxSB();    extern void psxSH();    extern void psxSW();    extern void psxSWL();  extern void psxSWR();
extern void psxJ();     extern void psxJAL();   extern void psxJR();    extern void psxJALR();
extern void psxBEQ();   extern void psxBNE();   extern void psxBLEZ();  extern void psxBGTZ();
extern void psxBLTZ();  extern void psxBGEZ();  extern void psxBLTZAL(); extern void psxBGEZAL();
extern void psxMFC0();  extern void psxMTC0();  extern void psxCFC0();  extern void psxCTC0();
extern void psxRFE();
extern void psxSYSCALL(); extern void psxBREAK();

// Phase 0: every instruction stores code/pc, flushes, and calls interpreter
#define REC_FUNC(f) \
	static void rpsx##f() \
	{ \
		_psxFlushCall(FLUSH_EVERYTHING); \
		armAsm->Mov(RWARG1, psxRegs.code); \
		armAsm->Str(RWARG1, a64::MemOperand(a64::x19, (s64)offsetof(psxRegisters, code))); \
		armEmitCall(reinterpret_cast<const void*>(&psx##f)); \
		PSX_DEL_CONST(_Rt_); \
	}

#define REC_GTE_FUNC(f) \
	static void rgte##f() \
	{ \
		_psxFlushCall(FLUSH_EVERYTHING); \
		armAsm->Mov(RWARG1, psxRegs.code); \
		armAsm->Str(RWARG1, a64::MemOperand(a64::x19, (s64)offsetof(psxRegisters, code))); \
		armEmitCall(reinterpret_cast<const void*>(&gte##f)); \
		PSX_DEL_CONST(_Rt_); \
	}

extern void psxLWL();
extern void psxLWR();
extern void psxSWL();
extern void psxSWR();

// ========================================================================
// Basic ALU - interpreter fallback
// ========================================================================

REC_FUNC(ADDI);
REC_FUNC(ADDIU);
REC_FUNC(SLTI);
REC_FUNC(SLTIU);
REC_FUNC(ANDI);
REC_FUNC(ORI);
REC_FUNC(XORI);
REC_FUNC(LUI);

// SPECIAL ALU
REC_FUNC(SLL);
REC_FUNC(SRL);
REC_FUNC(SRA);
REC_FUNC(SLLV);
REC_FUNC(SRLV);
REC_FUNC(SRAV);
REC_FUNC(ADD);
REC_FUNC(ADDU);
REC_FUNC(SUB);
REC_FUNC(SUBU);
REC_FUNC(AND);
REC_FUNC(OR);
REC_FUNC(XOR);
REC_FUNC(NOR);
REC_FUNC(SLT);
REC_FUNC(SLTU);

// Multiply / Divide
REC_FUNC(MULT);
REC_FUNC(MULTU);
REC_FUNC(DIV);
REC_FUNC(DIVU);

// HI/LO moves
REC_FUNC(MFHI);
REC_FUNC(MTHI);
REC_FUNC(MFLO);
REC_FUNC(MTLO);

// ========================================================================
// Load/Store - interpreter fallback
// ========================================================================

REC_FUNC(LB);
REC_FUNC(LH);
REC_FUNC(LW);
REC_FUNC(LBU);
REC_FUNC(LHU);
REC_FUNC(LWL);
REC_FUNC(LWR);
REC_FUNC(SB);
REC_FUNC(SH);
REC_FUNC(SW);
REC_FUNC(SWL);
REC_FUNC(SWR);

// ========================================================================
// Branch/Jump diagnostic logging
// ========================================================================

static void iopBranchLog(const char* fmt, ...) __attribute__((format(printf, 1, 2)));
static void iopBranchLog(const char* fmt, ...) {
	static FILE* logFile = nullptr;
	if (!logFile) logFile = fopen("/tmp/pcsx2_openemu.log", "a");
	if (!logFile) return;
	va_list args;
	va_start(args, fmt);
	// Timestamp
	time_t now = time(nullptr);
	struct tm* t = localtime(&now);
	fprintf(logFile, "[%02d:%02d:%02d %s] [IOP-BRANCH] ",
		t->tm_hour > 12 ? t->tm_hour - 12 : t->tm_hour,
		t->tm_min, t->tm_sec, t->tm_hour >= 12 ? "PM" : "AM");
	vfprintf(logFile, fmt, args);
	fprintf(logFile, "\n");
	fflush(logFile);
	va_end(args);
}

// Runtime JR/JALR target logging — called from JIT code
// w0 = branch target (before saving to psxRegs.pc)
static void iopLogJRTarget(u32 target)
{
	static u32 s_jrCount = 0;
	s_jrCount++;
	if (s_jrCount <= 50 || (s_jrCount % 10000) == 0)
		iopBranchLog("JR/JALR #%u: target=0x%08X fromPC=0x%08X",
			s_jrCount, target, psxRegs.pc);
}

// ========================================================================
// Branch/Jump
// ========================================================================

// J: Direct jump
static void rpsxJ()
{
	u32 newpc = (_InstrucTarget_ << 2) + ((psxpc - 4) & 0xf0000000);
	static u32 s_jCount = 0;
	s_jCount++;
	if (s_jCount <= 50)
		iopBranchLog("J #%u: fromPC=0x%08X target=0x%08X", s_jCount, psxpc - 4, newpc);
	psxRecompileNextInstruction(true, false);
	psxSetBranchImm(newpc);
}

// JAL: Jump and link
static void rpsxJAL()
{
	u32 newpc = (_InstrucTarget_ << 2) + ((psxpc - 4) & 0xf0000000);
	// Link: r31 = address after delay slot (psxpc + 4)
	_psxDeleteReg(31, 0);
	PSX_SET_CONST(31);
	g_psxConstRegs[31] = psxpc + 4;
	static u32 s_jalCount = 0;
	s_jalCount++;
	if (s_jalCount <= 50)
		iopBranchLog("JAL #%u: fromPC=0x%08X target=0x%08X link=0x%08X", s_jalCount, psxpc - 4, newpc, psxpc + 4);

	psxRecompileNextInstruction(true, false);
	psxSetBranchImm(newpc);
}

// JR: Jump to register
static void rpsxJR()
{
	_psxMoveGPRtoR(a64::w0, _Rs_);
	// Log the branch target at runtime (w0 = first arg for the call)
	armEmitCall(reinterpret_cast<const void*>(&iopLogJRTarget));
	// Reload branch target after logging call (w0 was clobbered)
	_psxMoveGPRtoR(a64::w0, _Rs_);
	// Save branch target to psxRegs.pc before delay slot, since the delay slot's
	// interpreter call will clobber w0. FLUSH_EVERYTHING (0x1FF) does NOT include
	// FLUSH_PC (0x200), so psxRegs.pc is preserved across the delay slot.
	armAsm->Str(a64::w0, a64::MemOperand(a64::x19, (s64)offsetof(psxRegisters, pc)));
	psxRecompileNextInstruction(true, false);
	// Restore branch target from psxRegs.pc
	armAsm->Ldr(a64::w0, a64::MemOperand(a64::x19, (s64)offsetof(psxRegisters, pc)));
	psxSetBranchReg();
}

// JALR: Jump and link to register
static void rpsxJALR()
{
	int rd = _Rd_ ? _Rd_ : 31;
	_psxDeleteReg(rd, 0);
	PSX_SET_CONST(rd);
	g_psxConstRegs[rd] = psxpc + 4;

	_psxMoveGPRtoR(a64::w0, _Rs_);
	// Save branch target to psxRegs.pc before delay slot (see rpsxJR comment)
	armAsm->Str(a64::w0, a64::MemOperand(a64::x19, (s64)offsetof(psxRegisters, pc)));
	psxRecompileNextInstruction(true, false);
	// Restore branch target from psxRegs.pc
	armAsm->Ldr(a64::w0, a64::MemOperand(a64::x19, (s64)offsetof(psxRegisters, pc)));
	psxSetBranchReg();
}

// ========================================================================
// Conditional Branches (all interpreter fallback approach)
// ========================================================================

static void rpsxBEQ()
{
	u32 branchTo = ((s32)(s16)_Imm_) * 4 + psxpc;
	// Save register indices BEFORE delay slot overwrites psxRegs.code
	const int rs = _Rs_;
	const int rt = _Rt_;
	_psxFlushCall(FLUSH_EVERYTHING);

	// Store code for interpreter
	armAsm->Mov(RWARG1, psxRegs.code);
	armAsm->Str(RWARG1, a64::MemOperand(a64::x19, (s64)offsetof(psxRegisters, code)));

	psxRecompileNextInstruction(true, false);

	// Compare Rs and Rt
	if (rs == rt)
	{
		// Always taken
		psxSetBranchImm(branchTo);
	}
	else
	{
		_psxFlushCall(FLUSH_EVERYTHING);

		// Load Rs and Rt (use saved indices, not _Rs_/_Rt_ which now decode delay slot)
		armAsm->Ldr(RWARG1, a64::MemOperand(a64::x19, (s64)offsetof(psxRegisters, GPR.r[0]) + rs * 4));
		armAsm->Ldr(RWARG2, a64::MemOperand(a64::x19, (s64)offsetof(psxRegisters, GPR.r[0]) + rt * 4));
		armAsm->Cmp(RWARG1, RWARG2);

		a64::Label notTaken;
		armAsm->B(a64::ne, &notTaken);

		psxSetBranchImm(branchTo);

		armAsm->Bind(&notTaken);
		psxSetBranchImm(psxpc);
	}
}

static void rpsxBNE()
{
	u32 branchTo = ((s32)(s16)_Imm_) * 4 + psxpc;
	const int rs = _Rs_;
	const int rt = _Rt_;
	_psxFlushCall(FLUSH_EVERYTHING);

	armAsm->Mov(RWARG1, psxRegs.code);
	armAsm->Str(RWARG1, a64::MemOperand(a64::x19, (s64)offsetof(psxRegisters, code)));

	psxRecompileNextInstruction(true, false);

	if (rs == rt)
	{
		// Never taken
		psxSetBranchImm(psxpc);
	}
	else
	{
		_psxFlushCall(FLUSH_EVERYTHING);

		armAsm->Ldr(RWARG1, a64::MemOperand(a64::x19, (s64)offsetof(psxRegisters, GPR.r[0]) + rs * 4));
		armAsm->Ldr(RWARG2, a64::MemOperand(a64::x19, (s64)offsetof(psxRegisters, GPR.r[0]) + rt * 4));
		armAsm->Cmp(RWARG1, RWARG2);

		a64::Label notTaken;
		armAsm->B(a64::eq, &notTaken);

		psxSetBranchImm(branchTo);

		armAsm->Bind(&notTaken);
		psxSetBranchImm(psxpc);
	}
}

static void rpsxBLEZ()
{
	u32 branchTo = ((s32)(s16)_Imm_) * 4 + psxpc;
	const int rs = _Rs_;
	_psxFlushCall(FLUSH_EVERYTHING);

	armAsm->Mov(RWARG1, psxRegs.code);
	armAsm->Str(RWARG1, a64::MemOperand(a64::x19, (s64)offsetof(psxRegisters, code)));

	psxRecompileNextInstruction(true, false);

	_psxFlushCall(FLUSH_EVERYTHING);

	armAsm->Ldr(RWARG1, a64::MemOperand(a64::x19, (s64)offsetof(psxRegisters, GPR.r[0]) + rs * 4));
	armAsm->Cmp(RWARG1, 0);

	a64::Label notTaken;
	armAsm->B(a64::gt, &notTaken);
	psxSetBranchImm(branchTo);
	armAsm->Bind(&notTaken);
	psxSetBranchImm(psxpc);
}

static void rpsxBGTZ()
{
	u32 branchTo = ((s32)(s16)_Imm_) * 4 + psxpc;
	const int rs = _Rs_;
	_psxFlushCall(FLUSH_EVERYTHING);

	armAsm->Mov(RWARG1, psxRegs.code);
	armAsm->Str(RWARG1, a64::MemOperand(a64::x19, (s64)offsetof(psxRegisters, code)));

	psxRecompileNextInstruction(true, false);

	_psxFlushCall(FLUSH_EVERYTHING);

	armAsm->Ldr(RWARG1, a64::MemOperand(a64::x19, (s64)offsetof(psxRegisters, GPR.r[0]) + rs * 4));
	armAsm->Cmp(RWARG1, 0);

	a64::Label notTaken;
	armAsm->B(a64::le, &notTaken);
	psxSetBranchImm(branchTo);
	armAsm->Bind(&notTaken);
	psxSetBranchImm(psxpc);
}

// REGIMM branches
static void rpsxBLTZ()
{
	u32 branchTo = ((s32)(s16)_Imm_) * 4 + psxpc;
	const int rs = _Rs_;
	_psxFlushCall(FLUSH_EVERYTHING);

	armAsm->Mov(RWARG1, psxRegs.code);
	armAsm->Str(RWARG1, a64::MemOperand(a64::x19, (s64)offsetof(psxRegisters, code)));

	psxRecompileNextInstruction(true, false);

	_psxFlushCall(FLUSH_EVERYTHING);

	armAsm->Ldr(RWARG1, a64::MemOperand(a64::x19, (s64)offsetof(psxRegisters, GPR.r[0]) + rs * 4));
	armAsm->Cmp(RWARG1, 0);

	a64::Label notTaken;
	armAsm->B(a64::ge, &notTaken);
	psxSetBranchImm(branchTo);
	armAsm->Bind(&notTaken);
	psxSetBranchImm(psxpc);
}

static void rpsxBGEZ()
{
	u32 branchTo = ((s32)(s16)_Imm_) * 4 + psxpc;
	const int rs = _Rs_;
	_psxFlushCall(FLUSH_EVERYTHING);

	armAsm->Mov(RWARG1, psxRegs.code);
	armAsm->Str(RWARG1, a64::MemOperand(a64::x19, (s64)offsetof(psxRegisters, code)));

	psxRecompileNextInstruction(true, false);

	_psxFlushCall(FLUSH_EVERYTHING);

	armAsm->Ldr(RWARG1, a64::MemOperand(a64::x19, (s64)offsetof(psxRegisters, GPR.r[0]) + rs * 4));
	armAsm->Cmp(RWARG1, 0);

	a64::Label notTaken;
	armAsm->B(a64::lt, &notTaken);
	psxSetBranchImm(branchTo);
	armAsm->Bind(&notTaken);
	psxSetBranchImm(psxpc);
}

static void rpsxBLTZAL()
{
	u32 branchTo = ((s32)(s16)_Imm_) * 4 + psxpc;
	const int rs = _Rs_;
	_psxDeleteReg(31, 0);
	PSX_SET_CONST(31);
	g_psxConstRegs[31] = psxpc + 4;

	_psxFlushCall(FLUSH_EVERYTHING);

	armAsm->Mov(RWARG1, psxRegs.code);
	armAsm->Str(RWARG1, a64::MemOperand(a64::x19, (s64)offsetof(psxRegisters, code)));

	psxRecompileNextInstruction(true, false);

	_psxFlushCall(FLUSH_EVERYTHING);

	armAsm->Ldr(RWARG1, a64::MemOperand(a64::x19, (s64)offsetof(psxRegisters, GPR.r[0]) + rs * 4));
	armAsm->Cmp(RWARG1, 0);

	a64::Label notTaken;
	armAsm->B(a64::ge, &notTaken);
	psxSetBranchImm(branchTo);
	armAsm->Bind(&notTaken);
	psxSetBranchImm(psxpc);
}

static void rpsxBGEZAL()
{
	u32 branchTo = ((s32)(s16)_Imm_) * 4 + psxpc;
	const int rs = _Rs_;
	_psxDeleteReg(31, 0);
	PSX_SET_CONST(31);
	g_psxConstRegs[31] = psxpc + 4;

	_psxFlushCall(FLUSH_EVERYTHING);

	armAsm->Mov(RWARG1, psxRegs.code);
	armAsm->Str(RWARG1, a64::MemOperand(a64::x19, (s64)offsetof(psxRegisters, code)));

	psxRecompileNextInstruction(true, false);

	_psxFlushCall(FLUSH_EVERYTHING);

	armAsm->Ldr(RWARG1, a64::MemOperand(a64::x19, (s64)offsetof(psxRegisters, GPR.r[0]) + rs * 4));
	armAsm->Cmp(RWARG1, 0);

	a64::Label notTaken;
	armAsm->B(a64::lt, &notTaken);
	psxSetBranchImm(branchTo);
	armAsm->Bind(&notTaken);
	psxSetBranchImm(psxpc);
}

// ========================================================================
// COP0
// ========================================================================

REC_FUNC(MFC0);
REC_FUNC(MTC0);
REC_FUNC(CFC0);
REC_FUNC(CTC0);
REC_FUNC(RFE);

// ========================================================================
// COP2 (GTE)
// ========================================================================

REC_GTE_FUNC(MFC2);
REC_GTE_FUNC(MTC2);
REC_GTE_FUNC(CFC2);
REC_GTE_FUNC(CTC2);

REC_GTE_FUNC(LWC2);
REC_GTE_FUNC(SWC2);

REC_GTE_FUNC(RTPS);
REC_GTE_FUNC(NCLIP);
REC_GTE_FUNC(OP);
REC_GTE_FUNC(DPCS);
REC_GTE_FUNC(INTPL);
REC_GTE_FUNC(MVMVA);
REC_GTE_FUNC(NCDS);
REC_GTE_FUNC(CDP);
REC_GTE_FUNC(NCDT);
REC_GTE_FUNC(NCCS);
REC_GTE_FUNC(CC);
REC_GTE_FUNC(NCS);
REC_GTE_FUNC(NCT);
REC_GTE_FUNC(SQR);
REC_GTE_FUNC(DCPL);
REC_GTE_FUNC(DPCT);
REC_GTE_FUNC(AVSZ3);
REC_GTE_FUNC(AVSZ4);
REC_GTE_FUNC(RTPT);
REC_GTE_FUNC(GPF);
REC_GTE_FUNC(GPL);
REC_GTE_FUNC(NCCT);

// ========================================================================
// Dispatch Tables
// ========================================================================

extern void rpsxSYSCALL();
extern void rpsxBREAK();

extern void (*rpsxBSC[64])();
extern void (*rpsxSPC[64])();
extern void (*rpsxREG[32])();
extern void (*rpsxCP0[32])();
extern void (*rpsxCP2[64])();
extern void (*rpsxCP2BSC[32])();

static void rpsxSPECIAL() { rpsxSPC[_Funct_](); }
static void rpsxREGIMM() { rpsxREG[_Rt_](); }
static void rpsxCOP0() { rpsxCP0[_Rs_](); }
static void rpsxCOP2() { rpsxCP2[_Funct_](); }
static void rpsxBASIC() { rpsxCP2BSC[_Rs_](); }

static void rpsxNULL()
{
	Console.WriteLn("IOP psxUNK: %8.8x", psxRegs.code);
}

// clang-format off
void (*rpsxBSC[64])() = {
	rpsxSPECIAL, rpsxREGIMM, rpsxJ   , rpsxJAL  , rpsxBEQ , rpsxBNE , rpsxBLEZ, rpsxBGTZ,
	rpsxADDI   , rpsxADDIU , rpsxSLTI, rpsxSLTIU, rpsxANDI, rpsxORI , rpsxXORI, rpsxLUI ,
	rpsxCOP0   , rpsxNULL  , rpsxCOP2, rpsxNULL , rpsxNULL, rpsxNULL, rpsxNULL, rpsxNULL,
	rpsxNULL   , rpsxNULL  , rpsxNULL, rpsxNULL , rpsxNULL, rpsxNULL, rpsxNULL, rpsxNULL,
	rpsxLB     , rpsxLH    , rpsxLWL , rpsxLW   , rpsxLBU , rpsxLHU , rpsxLWR , rpsxNULL,
	rpsxSB     , rpsxSH    , rpsxSWL , rpsxSW   , rpsxNULL, rpsxNULL, rpsxSWR , rpsxNULL,
	rpsxNULL   , rpsxNULL  , rgteLWC2, rpsxNULL , rpsxNULL, rpsxNULL, rpsxNULL, rpsxNULL,
	rpsxNULL   , rpsxNULL  , rgteSWC2, rpsxNULL , rpsxNULL, rpsxNULL, rpsxNULL, rpsxNULL,
};

void (*rpsxSPC[64])() = {
	rpsxSLL , rpsxNULL, rpsxSRL , rpsxSRA , rpsxSLLV   , rpsxNULL , rpsxSRLV, rpsxSRAV,
	rpsxJR  , rpsxJALR, rpsxNULL, rpsxNULL, rpsxSYSCALL, rpsxBREAK, rpsxNULL, rpsxNULL,
	rpsxMFHI, rpsxMTHI, rpsxMFLO, rpsxMTLO, rpsxNULL   , rpsxNULL , rpsxNULL, rpsxNULL,
	rpsxMULT, rpsxMULTU, rpsxDIV, rpsxDIVU, rpsxNULL   , rpsxNULL , rpsxNULL, rpsxNULL,
	rpsxADD , rpsxADDU, rpsxSUB , rpsxSUBU, rpsxAND    , rpsxOR   , rpsxXOR , rpsxNOR ,
	rpsxNULL, rpsxNULL, rpsxSLT , rpsxSLTU, rpsxNULL   , rpsxNULL , rpsxNULL, rpsxNULL,
	rpsxNULL, rpsxNULL, rpsxNULL, rpsxNULL, rpsxNULL   , rpsxNULL , rpsxNULL, rpsxNULL,
	rpsxNULL, rpsxNULL, rpsxNULL, rpsxNULL, rpsxNULL   , rpsxNULL , rpsxNULL, rpsxNULL,
};

void (*rpsxREG[32])() = {
	rpsxBLTZ  , rpsxBGEZ  , rpsxNULL, rpsxNULL, rpsxNULL, rpsxNULL, rpsxNULL, rpsxNULL,
	rpsxNULL  , rpsxNULL  , rpsxNULL, rpsxNULL, rpsxNULL, rpsxNULL, rpsxNULL, rpsxNULL,
	rpsxBLTZAL, rpsxBGEZAL, rpsxNULL, rpsxNULL, rpsxNULL, rpsxNULL, rpsxNULL, rpsxNULL,
	rpsxNULL  , rpsxNULL  , rpsxNULL, rpsxNULL, rpsxNULL, rpsxNULL, rpsxNULL, rpsxNULL,
};

void (*rpsxCP0[32])() = {
	rpsxMFC0, rpsxNULL, rpsxCFC0, rpsxNULL, rpsxMTC0, rpsxNULL, rpsxCTC0, rpsxNULL,
	rpsxNULL, rpsxNULL, rpsxNULL, rpsxNULL, rpsxNULL, rpsxNULL, rpsxNULL, rpsxNULL,
	rpsxRFE , rpsxNULL, rpsxNULL, rpsxNULL, rpsxNULL, rpsxNULL, rpsxNULL, rpsxNULL,
	rpsxNULL, rpsxNULL, rpsxNULL, rpsxNULL, rpsxNULL, rpsxNULL, rpsxNULL, rpsxNULL,
};

void (*rpsxCP2[64])() = {
	rpsxBASIC, rgteRTPS , rpsxNULL , rpsxNULL, rpsxNULL, rpsxNULL , rgteNCLIP, rpsxNULL,
	rpsxNULL , rpsxNULL , rpsxNULL , rpsxNULL, rgteOP  , rpsxNULL , rpsxNULL , rpsxNULL,
	rgteDPCS , rgteINTPL, rgteMVMVA, rgteNCDS, rgteCDP , rpsxNULL , rgteNCDT , rpsxNULL,
	rpsxNULL , rpsxNULL , rpsxNULL , rgteNCCS, rgteCC  , rpsxNULL , rgteNCS  , rpsxNULL,
	rgteNCT  , rpsxNULL , rpsxNULL , rpsxNULL, rpsxNULL, rpsxNULL , rpsxNULL , rpsxNULL,
	rgteSQR  , rgteDCPL , rgteDPCT , rpsxNULL, rpsxNULL, rgteAVSZ3, rgteAVSZ4, rpsxNULL,
	rgteRTPT , rpsxNULL , rpsxNULL , rpsxNULL, rpsxNULL, rpsxNULL , rpsxNULL , rpsxNULL,
	rpsxNULL , rpsxNULL , rpsxNULL , rpsxNULL, rpsxNULL, rgteGPF  , rgteGPL  , rgteNCCT,
};

void (*rpsxCP2BSC[32])() = {
	rgteMFC2, rpsxNULL, rgteCFC2, rpsxNULL, rgteMTC2, rpsxNULL, rgteCTC2, rpsxNULL,
	rpsxNULL, rpsxNULL, rpsxNULL, rpsxNULL, rpsxNULL, rpsxNULL, rpsxNULL, rpsxNULL,
	rpsxNULL, rpsxNULL, rpsxNULL, rpsxNULL, rpsxNULL, rpsxNULL, rpsxNULL, rpsxNULL,
	rpsxNULL, rpsxNULL, rpsxNULL, rpsxNULL, rpsxNULL, rpsxNULL, rpsxNULL, rpsxNULL,
};
// clang-format on

// ========================================================================
// Back-Prop Function Tables (register liveness analysis)
// ========================================================================

#define rpsxpropSetRead(reg) \
	{ \
		if (!(pinst->regs[reg] & EEINST_USED)) \
			pinst->regs[reg] |= EEINST_LASTUSE; \
		prev->regs[reg] |= EEINST_LIVE | EEINST_USED; \
		pinst->regs[reg] |= EEINST_USED; \
		_recFillRegister(*pinst, XMMTYPE_GPRREG, reg, 0); \
	}

#define rpsxpropSetWrite(reg) \
	{ \
		prev->regs[reg] &= ~(EEINST_LIVE | EEINST_USED); \
		if (!(pinst->regs[reg] & EEINST_USED)) \
			pinst->regs[reg] |= EEINST_LASTUSE; \
		pinst->regs[reg] |= EEINST_USED; \
		_recFillRegister(*pinst, XMMTYPE_GPRREG, reg, 1); \
	}

void rpsxpropSPECIAL(EEINST* prev, EEINST* pinst);
void rpsxpropREGIMM(EEINST* prev, EEINST* pinst);
void rpsxpropCP0(EEINST* prev, EEINST* pinst);
void rpsxpropCP2(EEINST* prev, EEINST* pinst);

void rpsxpropBSC(EEINST* prev, EEINST* pinst)
{
	switch (psxRegs.code >> 26)
	{
		case 0: rpsxpropSPECIAL(prev, pinst); break;
		case 1: rpsxpropREGIMM(prev, pinst); break;
		case 2: break; // J
		case 3: rpsxpropSetWrite(31); break; // JAL
		case 4: case 5:
			rpsxpropSetRead(_Rs_);
			rpsxpropSetRead(_Rt_);
			break;
		case 6: case 7:
			rpsxpropSetRead(_Rs_);
			break;
		case 15: rpsxpropSetWrite(_Rt_); break; // LUI
		case 16: rpsxpropCP0(prev, pinst); break;
		case 18: rpsxpropCP2(prev, pinst); break;
		case 40: case 41: case 42: case 43: case 46: // stores
			rpsxpropSetRead(_Rt_);
			rpsxpropSetRead(_Rs_);
			break;
		case 50: case 58: break; // LWC2/SWC2
		default:
			rpsxpropSetWrite(_Rt_);
			rpsxpropSetRead(_Rs_);
			break;
	}
}

void rpsxpropSPECIAL(EEINST* prev, EEINST* pinst)
{
	switch (_Funct_)
	{
		case 0: case 2: case 3: // SLL, SRL, SRA
			rpsxpropSetWrite(_Rd_);
			rpsxpropSetRead(_Rt_);
			break;
		case 8: // JR
			rpsxpropSetRead(_Rs_);
			break;
		case 9: // JALR
			rpsxpropSetWrite(_Rd_);
			rpsxpropSetRead(_Rs_);
			break;
		case 12: case 13: // SYSCALL, BREAK
			_recClearInst(prev);
			prev->info = 0;
			break;
		case 15: break; // SYNC
		case 16: // MFHI
			rpsxpropSetWrite(_Rd_);
			rpsxpropSetRead(PSX_HI);
			break;
		case 17: // MTHI
			rpsxpropSetWrite(PSX_HI);
			rpsxpropSetRead(_Rs_);
			break;
		case 18: // MFLO
			rpsxpropSetWrite(_Rd_);
			rpsxpropSetRead(PSX_LO);
			break;
		case 19: // MTLO
			rpsxpropSetWrite(PSX_LO);
			rpsxpropSetRead(_Rs_);
			break;
		case 24: case 25: case 26: case 27: // MULT, MULTU, DIV, DIVU
			rpsxpropSetWrite(PSX_LO);
			rpsxpropSetWrite(PSX_HI);
			rpsxpropSetRead(_Rs_);
			rpsxpropSetRead(_Rt_);
			break;
		case 32: case 33: case 34: case 35: // ADD, ADDU, SUB, SUBU
			rpsxpropSetWrite(_Rd_);
			if (_Rs_) rpsxpropSetRead(_Rs_);
			if (_Rt_) rpsxpropSetRead(_Rt_);
			break;
		default:
			rpsxpropSetWrite(_Rd_);
			rpsxpropSetRead(_Rs_);
			rpsxpropSetRead(_Rt_);
			break;
	}
}

void rpsxpropREGIMM(EEINST* prev, EEINST* pinst)
{
	switch (_Rt_)
	{
		case 0: case 1: // BLTZ, BGEZ
			rpsxpropSetRead(_Rs_);
			break;
		case 16: case 17: // BLTZAL, BGEZAL
			rpsxpropSetRead(_Rs_);
			break;
		default:
			break;
	}
}

void rpsxpropCP0(EEINST* prev, EEINST* pinst)
{
	switch (_Rs_)
	{
		case 0: case 2: // MFC0, CFC0
			rpsxpropSetWrite(_Rt_);
			break;
		case 4: case 6: // MTC0, CTC0
			rpsxpropSetRead(_Rt_);
			break;
		case 16: break; // RFE
		default: break;
	}
}

void rpsxpropCP2(EEINST* prev, EEINST* pinst)
{
	switch (_Funct_)
	{
		case 0: // BASIC
			switch (_Rs_)
			{
				case 0: case 2: rpsxpropSetWrite(_Rt_); break;
				case 4: case 6: rpsxpropSetRead(_Rt_); break;
				default: break;
			}
			break;
		default: break;
	}
}
