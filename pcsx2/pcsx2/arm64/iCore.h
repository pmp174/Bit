// SPDX-FileCopyrightText: 2002-2026 PCSX2 Dev Team
// SPDX-License-Identifier: GPL-3.0+

#pragma once

#include "common/Pcsx2Defs.h"
#include "VUmicro.h"
#include "arm64/AsmHelpers.h"

// Namespace Note : iCore contains all of the Register Allocation logic for ARM64,
// ported from the x86 equivalent in x86/iCore.h.

//#define RALOG(...) fprintf(stderr, __VA_ARGS__)
#define RALOG(...)

////////////////////////////////////////////////////////////////////////////////
// Shared Register allocation flags (apply to GPR, NEON, etc).

#define MODE_READ        1
#define MODE_WRITE       2
#define MODE_CALLEESAVED  0x20 // can't flush reg to mem
#define MODE_COP2 0x40 // don't allow using reserved VU registers

#define PROCESS_EE_XMM 0x02 // kept for compatibility with shared code

#define PROCESS_EE_S 0x04 // S is valid, otherwise take from mem
#define PROCESS_EE_T 0x08 // T is valid, otherwise take from mem
#define PROCESS_EE_D 0x10 // D is valid, otherwise take from mem

#define PROCESS_EE_LO         0x40 // lo reg is valid
#define PROCESS_EE_HI         0x80 // hi reg is valid
#define PROCESS_EE_ACC        0x40 // acc reg is valid

#define EEREC_S    (((info) >>  8) & 0xf)
#define EEREC_T    (((info) >> 12) & 0xf)
#define EEREC_D    (((info) >> 16) & 0xf)
#define EEREC_LO   (((info) >> 20) & 0xf)
#define EEREC_HI   (((info) >> 24) & 0xf)
#define EEREC_ACC  (((info) >> 20) & 0xf)

#define PROCESS_EE_SET_S(reg)   (((reg) <<  8) | PROCESS_EE_S)
#define PROCESS_EE_SET_T(reg)   (((reg) << 12) | PROCESS_EE_T)
#define PROCESS_EE_SET_D(reg)   (((reg) << 16) | PROCESS_EE_D)
#define PROCESS_EE_SET_LO(reg)  (((reg) << 20) | PROCESS_EE_LO)
#define PROCESS_EE_SET_HI(reg)  (((reg) << 24) | PROCESS_EE_HI)
#define PROCESS_EE_SET_ACC(reg) (((reg) << 20) | PROCESS_EE_ACC)

// special info not related to above flags
#define PROCESS_CONSTS 1
#define PROCESS_CONSTT 2

// Register info flags (same values as x86's xmminfo for compatibility)
enum reginfo : u16
{
	REGINFO_READLO = 0x001,
	REGINFO_READHI = 0x002,
	REGINFO_WRITELO = 0x004,
	REGINFO_WRITEHI = 0x008,
	REGINFO_WRITED = 0x010,
	REGINFO_READD = 0x020,
	REGINFO_READS = 0x040,
	REGINFO_READT = 0x080,
	REGINFO_READACC = 0x200,
	REGINFO_WRITEACC = 0x400,
	REGINFO_WRITET = 0x800,

	REGINFO_64BITOP = 0x1000,
	REGINFO_FORCEREGS = 0x2000,
	REGINFO_FORCEREGT = 0x4000,
	REGINFO_NORENAME = 0x8000
};

// Compatibility aliases for code shared with x86
using xmminfo = reginfo;
static constexpr u16 XMMINFO_READLO = REGINFO_READLO;
static constexpr u16 XMMINFO_READHI = REGINFO_READHI;
static constexpr u16 XMMINFO_WRITELO = REGINFO_WRITELO;
static constexpr u16 XMMINFO_WRITEHI = REGINFO_WRITEHI;
static constexpr u16 XMMINFO_WRITED = REGINFO_WRITED;
static constexpr u16 XMMINFO_READD = REGINFO_READD;
static constexpr u16 XMMINFO_READS = REGINFO_READS;
static constexpr u16 XMMINFO_READT = REGINFO_READT;
static constexpr u16 XMMINFO_READACC = REGINFO_READACC;
static constexpr u16 XMMINFO_WRITEACC = REGINFO_WRITEACC;
static constexpr u16 XMMINFO_WRITET = REGINFO_WRITET;
static constexpr u16 XMMINFO_64BITOP = REGINFO_64BITOP;
static constexpr u16 XMMINFO_FORCEREGS = REGINFO_FORCEREGS;
static constexpr u16 XMMINFO_FORCEREGT = REGINFO_FORCEREGT;
static constexpr u16 XMMINFO_NORENAME = REGINFO_NORENAME;

////////////////////////////////////////////////////////////////////////////////
//   ARM64 GPR Register Allocation Tools

enum armgprtype : u8
{
	ARMTYPE_TEMP = 0,
	ARMTYPE_GPR = 1,
	ARMTYPE_FPRC = 2,
	ARMTYPE_VIREG = 3,
	ARMTYPE_PCWRITEBACK = 4,
	ARMTYPE_PSX = 5,
	ARMTYPE_PSX_PCWRITEBACK = 6
};

// Compatibility aliases
static constexpr u8 X86TYPE_TEMP = ARMTYPE_TEMP;
static constexpr u8 X86TYPE_GPR = ARMTYPE_GPR;
static constexpr u8 X86TYPE_VIREG = ARMTYPE_VIREG;
static constexpr u8 X86TYPE_FPRC = ARMTYPE_FPRC;
static constexpr u8 X86TYPE_PCWRITEBACK = ARMTYPE_PCWRITEBACK;
static constexpr u8 X86TYPE_PSX = ARMTYPE_PSX;
static constexpr u8 X86TYPE_PSX_PCWRITEBACK = ARMTYPE_PSX_PCWRITEBACK;

struct _armGPRreg
{
	u8 inuse;
	s8 reg;
	u8 mode;
	u8 needed;
	u8 type; // ARMTYPE_
	u16 counter;
	u32 extra;
};

// Callee-saved GPRs available for allocation: x23-x28 (6 registers)
// x19-x22 are dedicated (RCPUSTATE, RFASTMEMBASE, RECLUTPTR, RCYCLES)
static constexpr int ARMGPR_COUNT = 6;

// Map from allocator slot index (0-5) to ARM64 register number (23-28)
static constexpr int ARMGPR_FIRST = 23;
static __fi int armGPRSlotToReg(int slot) { return slot + ARMGPR_FIRST; }
static __fi int armGPRRegToSlot(int reg) { return reg - ARMGPR_FIRST; }

extern _armGPRreg armGPRregs[ARMGPR_COUNT], s_saveArmGPRregs[ARMGPR_COUNT];

void _initArmGPRregs();
int _getFreeArmGPR(int mode);
int _allocArmGPR(int type, int reg, int mode);
int _checkArmGPR(int type, int reg, int mode);
bool _hasArmGPR(int type, int reg, int required_mode = 0);
void _addNeededArmGPR(int type, int reg);
void _clearNeededArmGPRs();
void _freeArmGPR(int armreg);
void _freeArmGPRWithoutWriteback(int armreg);
void _freeArmGPRs();
void _flushArmGPRregs();
void _flushConstRegs(bool delete_const);
void _flushConstReg(int reg);
void _validateRegs();
void _writebackArmGPR(int armreg);

// Compatibility wrappers (x86 API → ARM64 API)
static __fi void _initX86regs() { _initArmGPRregs(); }
static __fi int _allocX86reg(int type, int reg, int mode) { return _allocArmGPR(type, reg, mode); }
static __fi int _checkX86reg(int type, int reg, int mode) { return _checkArmGPR(type, reg, mode); }
static __fi void _addNeededX86reg(int type, int reg) { _addNeededArmGPR(type, reg); }
static __fi void _clearNeededX86regs() { _clearNeededArmGPRs(); }
static __fi void _freeX86reg(int reg) { _freeArmGPR(reg); }
static __fi void _freeX86regs() { _freeArmGPRs(); }
static __fi void _flushX86regs() { _flushArmGPRregs(); }

////////////////////////////////////////////////////////////////////////////////
//   NEON (128-bit) Register Allocation Tools

#define XMMTYPE_TEMP   0 // has to be 0
#define XMMTYPE_GPRREG ARMTYPE_GPR
#define XMMTYPE_FPREG  6
#define XMMTYPE_FPACC  7
#define XMMTYPE_VFREG  8

// lo and hi regs
#define XMMGPR_LO  33
#define XMMGPR_HI  32
#define XMMFPU_ACC 32

enum : int
{
	DELETE_REG_FREE = 0,
	DELETE_REG_FLUSH = 1,
	DELETE_REG_FLUSH_AND_FREE = 2,
	DELETE_REG_FREE_NO_WRITEBACK = 3
};

struct _neonregs
{
	u8 inuse;
	s8 reg;
	u8 type;
	u8 mode;
	u8 needed;
	u16 counter;
};

// Callee-saved NEON regs available for allocation: q8-q15 (8 registers)
static constexpr int ARMNEON_COUNT = 8;
static constexpr int ARMNEON_FIRST = 8;
static __fi int armNEONSlotToReg(int slot) { return slot + ARMNEON_FIRST; }

extern _neonregs neonregs[ARMNEON_COUNT], s_saveNeonregs[ARMNEON_COUNT];

// Compatibility aliases for code that references _xmmregs
using _xmmregs = _neonregs;
static constexpr int iREGCNT_XMM = ARMNEON_COUNT;
extern _xmmregs* xmmregs_alias(); // returns neonregs

void _initNeonregs();
int _getFreeNeonreg(u32 maxreg = ARMNEON_COUNT);
int _allocTempNeonreg();
int _allocFPtoNeonreg(int fpreg, int mode);
int _allocGPRtoNeonreg(int gprreg, int mode);
int _allocFPACCtoNeonreg(int mode);
void _reallocateNeonreg(int neonreg, int newtype, int newreg, int newmode, bool writeback = true);
int _checkNeonreg(int type, int reg, int mode);
bool _hasNeonreg(int type, int reg, int required_mode = 0);
void _addNeededFPtoNeonreg(int fpreg);
void _addNeededFPACCtoNeonreg();
void _addNeededGPRtoArmGPR(int gprreg);
void _addNeededPSXtoArmGPR(int gprreg);
void _addNeededGPRtoNeonreg(int gprreg);
void _clearNeededNeonregs();
void _deleteGPRtoArmGPR(int reg, int flush);
void _deletePSXtoArmGPR(int reg, int flush);
void _deleteGPRtoNeonreg(int reg, int flush);
void _deleteFPtoNeonreg(int reg, int flush);
void _freeNeonreg(int neonreg);
void _freeNeonregWithoutWriteback(int neonreg);
void _writebackNeonreg(int neonreg);
int _allocVFtoNeonreg(int vfreg, int mode);
void _flushNeonreg(int neonreg);
void _flushNeonregs();

// Compatibility wrappers (x86 XMM API → ARM64 NEON API)
static __fi void _initXMMregs() { _initNeonregs(); }
static __fi int _getFreeXMMreg(u32 maxreg = ARMNEON_COUNT) { return _getFreeNeonreg(maxreg); }
static __fi int _allocFPtoXMMreg(int fpreg, int mode) { return _allocFPtoNeonreg(fpreg, mode); }
static __fi int _allocGPRtoXMMreg(int gprreg, int mode) { return _allocGPRtoNeonreg(gprreg, mode); }
static __fi int _allocFPACCtoXMMreg(int mode) { return _allocFPACCtoNeonreg(mode); }
static __fi int _checkXMMreg(int type, int reg, int mode) { return _checkNeonreg(type, reg, mode); }
static __fi bool _hasXMMreg(int type, int reg, int required_mode = 0) { return _hasNeonreg(type, reg, required_mode); }
static __fi void _addNeededFPtoXMMreg(int fpreg) { _addNeededFPtoNeonreg(fpreg); }
static __fi void _addNeededFPACCtoXMMreg() { _addNeededFPACCtoNeonreg(); }
static __fi void _addNeededGPRtoX86reg(int gprreg) { _addNeededGPRtoArmGPR(gprreg); }
static __fi void _addNeededGPRtoXMMreg(int gprreg) { _addNeededGPRtoNeonreg(gprreg); }
static __fi void _clearNeededXMMregs() { _clearNeededNeonregs(); }
static __fi void _deleteGPRtoX86reg(int reg, int flush) { _deleteGPRtoArmGPR(reg, flush); }
static __fi void _deleteGPRtoXMMreg(int reg, int flush) { _deleteGPRtoNeonreg(reg, flush); }
static __fi void _deleteFPtoXMMreg(int reg, int flush) { _deleteFPtoNeonreg(reg, flush); }
static __fi void _freeXMMreg(int reg) { _freeNeonreg(reg); }
static __fi void _freeXMMregWithoutWriteback(int reg) { _freeNeonregWithoutWriteback(reg); }
static __fi void _writebackXMMreg(int reg) { _writebackNeonreg(reg); }
static __fi void _flushXMMregs() { _flushNeonregs(); }
static __fi void _addNeededPSXtoX86reg(int gprreg) { _addNeededPSXtoArmGPR(gprreg); }
static __fi void _deletePSXtoX86reg(int reg, int flush) { _deletePSXtoArmGPR(reg, flush); }

// COP2 stubs (no VU rec on ARM64 yet)
static __fi void mVUFreeCOP2GPR(int hostreg) {}
static __fi bool mVUIsReservedCOP2(int hostreg) { return false; }
static __fi void mVUFreeCOP2XMMreg(int hostreg) {}
static __fi void _flushCOP2regs() {}

//////////////////////
// Instruction Info //
//////////////////////

#define EEINST_LIVE     1
#define EEINST_LASTUSE   8
#define EEINST_XMM    0x20
#define EEINST_USED   0x40

#define EEINST_COP2_DENORMALIZE_STATUS_FLAG 0x100
#define EEINST_COP2_NORMALIZE_STATUS_FLAG 0x200
#define EEINST_COP2_STATUS_FLAG 0x400
#define EEINST_COP2_MAC_FLAG 0x800
#define EEINST_COP2_CLIP_FLAG 0x1000
#define EEINST_COP2_SYNC_VU0 0x2000
#define EEINST_COP2_FINISH_VU0 0x4000
#define EEINST_COP2_FLUSH_VU0_REGISTERS 0x8000

struct EEINST
{
	u16 info;
	u8 regs[34]; // includes HI/LO (HI=32, LO=33)
	u8 fpuregs[33]; // ACC=32
	u8 vfregs[34]; // ACC=32, I=33
	u8 viregs[16];

	u8 writeType[3], writeReg[3];
	u8 readType[4], readReg[4];
};

extern EEINST* g_pCurInstInfo;
extern void _recClearInst(EEINST* pinst);
extern u32 _recIsRegReadOrWritten(EEINST* pinst, int size, u8 xmmtype, u8 reg);
extern void _recFillRegister(EEINST& pinst, int type, int reg, int write);

#define EE_WRITE_DEAD_VALUES 1

static __fi bool EEINST_USEDTEST(u32 reg)
{
	return (g_pCurInstInfo->regs[reg] & (EEINST_USED | EEINST_LASTUSE)) == EEINST_USED;
}

static __fi bool EEINST_XMMUSEDTEST(u32 reg)
{
	return (g_pCurInstInfo->regs[reg] & (EEINST_USED | EEINST_XMM | EEINST_LASTUSE)) == (EEINST_USED | EEINST_XMM);
}

static __fi bool EEINST_VFUSEDTEST(u32 reg)
{
	return (g_pCurInstInfo->vfregs[reg] & (EEINST_USED | EEINST_LASTUSE)) == EEINST_USED;
}

static __fi bool EEINST_VIUSEDTEST(u32 reg)
{
	return (g_pCurInstInfo->viregs[reg] & (EEINST_USED | EEINST_LASTUSE)) == EEINST_USED;
}

static __fi bool EEINST_LIVETEST(u32 reg)
{
	return EE_WRITE_DEAD_VALUES || ((g_pCurInstInfo->regs[reg] & EEINST_LIVE) != 0);
}

static __fi bool EEINST_RENAMETEST(u32 reg)
{
	return (reg == 0 || !EEINST_USEDTEST(reg) || !EEINST_LIVETEST(reg));
}

static __fi bool FPUINST_ISLIVE(u32 reg)   { return !!(g_pCurInstInfo->fpuregs[reg] & EEINST_LIVE); }
static __fi bool FPUINST_LASTUSE(u32 reg)  { return !!(g_pCurInstInfo->fpuregs[reg] & EEINST_LASTUSE); }

static __fi bool FPUINST_USEDTEST(u32 reg)
{
	return (g_pCurInstInfo->fpuregs[reg] & (EEINST_USED | EEINST_LASTUSE)) == EEINST_USED;
}

static __fi bool FPUINST_LIVETEST(u32 reg)
{
	return EE_WRITE_DEAD_VALUES || FPUINST_ISLIVE(reg);
}

static __fi bool FPUINST_RENAMETEST(u32 reg)
{
	return (!EEINST_USEDTEST(reg) || !EEINST_LIVETEST(reg));
}

extern u16 g_armGPRAllocCounter;
extern u16 g_neonAllocCounter;

// Compatibility aliases
static __fi u16& g_x86AllocCounter_ref() { return g_armGPRAllocCounter; }
static __fi u16& g_xmmAllocCounter_ref() { return g_neonAllocCounter; }

// allocates only if later insts use this register
int _allocIfUsedGPRtoArmGPR(int gprreg, int mode);
int _allocIfUsedGPRtoNeon(int gprreg, int mode);
int _allocIfUsedFPUtoNeon(int fpureg, int mode);

// Compatibility
static __fi int _allocIfUsedGPRtoX86(int gprreg, int mode) { return _allocIfUsedGPRtoArmGPR(gprreg, mode); }
static __fi int _allocIfUsedGPRtoXMM(int gprreg, int mode) { return _allocIfUsedGPRtoNeon(gprreg, mode); }
static __fi int _allocIfUsedFPUtoXMM(int fpureg, int mode) { return _allocIfUsedFPUtoNeon(fpureg, mode); }

//////////////////////////////////////////////////////////////////////////
// iFlushCall Parameters

#define FLUSH_NONE             0x000
#define FLUSH_CONSTANT_REGS    0x001
#define FLUSH_FLUSH_XMM        0x002
#define FLUSH_FREE_XMM         0x004
#define FLUSH_ALL_X86          0x020
#define FLUSH_FREE_TEMP_X86    0x040
#define FLUSH_FREE_NONTEMP_X86 0x080
#define FLUSH_FREE_VU0         0x100
#define FLUSH_PC               0x200
#define FLUSH_CODE             0x800

#define FLUSH_EVERYTHING   0x1ff
#define FLUSH_INTERPRETER  0xfff
#define FLUSH_FULLVTLB 0x000
#define FLUSH_NODESTROY (FLUSH_CONSTANT_REGS | FLUSH_FLUSH_XMM | FLUSH_ALL_X86)
