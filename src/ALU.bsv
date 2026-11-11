// ============================================================
// ALU.bsv - 单个 RISC ALU 模块
//
// 实现 RMT 流水线的 ALU 指令执行，支持 29 种操作码
// 遵循 Read-Before-Write 语义（VLIW 两相提交）
// ============================================================

package ALU;

import Vector :: *;
import GetPut :: *;
import RegFile :: *;
import FIFOF :: *;
import SpecialFIFOs :: *;
import DefaultValue :: *;
import RMTInterfaces :: *;
`include "RMTConfig.bh"

// ============================================================
//                      ALU 模块接口
// ============================================================

interface ALUIfc;
    // 加载指令和参数
    method Action load(ALUInsn insn, Bit#(64) param);

    // 提供操作数（来自 PHV 读取）
    method Action operands(FieldValue s1, FieldValue s2);

    // 获取写回结果
    method WriteBackEntry result;

    // 状态查询
    method Bool ready;
    method Bool valid;
endinterface

// ============================================================
//                  纯组合 ALU 计算函数
//  ★ 供 ActionEngine 直接调用（避免实例化 16 个 mkALU 带来的
//    同规则多方法调用 G0004 与 load/operands 守卫死锁问题）
// ============================================================

// 写回位宽：优先取目的字段宽度（dstw），未设置时回退源字段位宽；
// MOVI 无源字段时取 128（立即数全宽）。
function Bit#(8) wb_width(ALUInsn insn, FieldValue s1, Bit#(8) dstw);
    Bit#(8) w = (dstw != 0) ? dstw : s1.bitlen;
    if (w == 0 && insn.op == ALU_MOVI) w = 8'd128;
    return w;
endfunction

function WriteBackEntry alu_execute(ALUInsn insn, Bit#(64) param,
                                    FieldValue s1, FieldValue s2,
                                    Bit#(8) dst_bitlen);
    // 提取操作数值
    Bit#(128) v1 = s1.value;
    Bit#(128) v2 = s2.value;
    // ★ 写回位宽 = 目的字段宽度（原实现取源字段 bitlen → MOVI 被清零、MOV 不按目标截断）
    Bit#(8)   w = wb_width(insn, s1, dst_bitlen);

    // 立即数：优先使用动作参数，否则用指令中的立即数
    Bit#(64) imm_val = insn.use_param ? param : insn.imm;
    Bit#(128) imm128 = {64'h0, imm_val};

    // 默认写回条目
    WriteBackEntry wb = defaultWB();
    wb.fd = insn.fd;

    // 根据操作码执行计算
    case (insn.op)
        ALU_NOP: wb.kind = WB_NONE;

        ALU_MOVI: begin
            wb.kind = WB_FIELD;
            wb.val = FieldValue { value: imm128, bitlen: w };
        end

        ALU_MOV: begin
            wb.kind = WB_FIELD;
            wb.val = FieldValue { value: s1.value, bitlen: w };
        end

        ALU_ADD: begin
            wb.kind = WB_FIELD;
            wb.val = FieldValue { value: v1 + v2, bitlen: w };
        end

        ALU_SUB: begin
            wb.kind = WB_FIELD;
            wb.val = FieldValue { value: v1 - v2, bitlen: w };
        end

        ALU_AND: begin
            wb.kind = WB_FIELD;
            wb.val = FieldValue { value: v1 & v2, bitlen: w };
        end

        ALU_OR: begin
            wb.kind = WB_FIELD;
            wb.val = FieldValue { value: v1 | v2, bitlen: w };
        end

        ALU_XOR: begin
            wb.kind = WB_FIELD;
            wb.val = FieldValue { value: v1 ^ v2, bitlen: w };
        end

        ALU_SHL: begin
            Bit#(7) shift_amt = v2[6:0];
            wb.kind = WB_FIELD;
            wb.val = FieldValue { value: v1 << shift_amt, bitlen: w };
        end

        ALU_SHR: begin
            Bit#(7) shift_amt = v2[6:0];
            wb.kind = WB_FIELD;
            wb.val = FieldValue { value: v1 >> shift_amt, bitlen: w };
        end

        ALU_ADDI: begin
            wb.kind = WB_FIELD;
            wb.val = FieldValue { value: v1 + imm128, bitlen: w };
        end

        ALU_SUBI: begin
            wb.kind = WB_FIELD;
            wb.val = FieldValue { value: v1 - imm128, bitlen: w };
        end

        ALU_ANDI: begin
            wb.kind = WB_FIELD;
            wb.val = FieldValue { value: v1 & imm128, bitlen: w };
        end

        ALU_ORI: begin
            wb.kind = WB_FIELD;
            wb.val = FieldValue { value: v1 | imm128, bitlen: w };
        end

        ALU_XORI: begin
            wb.kind = WB_FIELD;
            wb.val = FieldValue { value: v1 ^ imm128, bitlen: w };
        end

        ALU_SHLI: begin
            Bit#(7) shift_amt = imm_val[6:0];
            wb.kind = WB_FIELD;
            wb.val = FieldValue { value: v1 << shift_amt, bitlen: w };
        end

        ALU_SHRI: begin
            Bit#(7) shift_amt = imm_val[6:0];
            wb.kind = WB_FIELD;
            wb.val = FieldValue { value: v1 >> shift_amt, bitlen: w };
        end

        ALU_MOVX: begin
            // 索引访问（ActionEngine 已把 s1 换成 seg[idx] 的值）
            wb.kind = WB_FIELD;
            wb.val = FieldValue { value: s1.value, bitlen: w };
        end

        ALU_VALID: begin
            wb.kind = WB_VALIDITY;
            wb.fd = insn.fd;      // 头部 ID
            wb.valid = True;
        end

        ALU_INVALID: begin
            wb.kind = WB_VALIDITY;
            wb.fd = insn.fd;      // 头部 ID
            wb.valid = False;
        end

        ALU_DROP: begin
            // 条件丢弃：fs1 字段值非零 → 丢包（DNN 分类等条件动作使用）
            wb.kind = (s1.value != 0) ? WB_DROP : WB_NONE;
        end

        default: wb.kind = WB_NONE;   // 有状态 extern 操作：暂不处理
    endcase

    // 按字段位宽截断结果（与软件 fv_mask 一致）
    if (wb.kind == WB_FIELD && wb.val.bitlen < 128) begin
        Bit#(128) mask = (1 << wb.val.bitlen) - 1;
        wb.val.value = wb.val.value & mask;
    end

    return wb;
endfunction

// ============================================================
//                      ALU 模块实现
// ============================================================

module mkALU(ALUIfc);
    // --------------------------------------------------------
    // 状态寄存器
    // --------------------------------------------------------
    Reg#(ALUInsn)        insn_r     <- mkRegU;           // 当前指令
    Reg#(Bit#(64))       param_r    <- mkRegU;           // 动作参数
    Reg#(FieldValue)     s1_r       <- mkRegU;           // 源操作数 1
    Reg#(FieldValue)     s2_r       <- mkRegU;           // 源操作数 2
    Reg#(WriteBackEntry) wb_r       <- mkReg(defaultWB()); // 写回结果

    // 状态机
    Reg#(Bool)           loaded_r   <- mkReg(False);     // 指令已加载
    Reg#(Bool)           ready_r    <- mkReg(False);     // 操作数就绪
    Reg#(Bool)           valid_r    <- mkReg(False);     // 结果有效

    // --------------------------------------------------------
    // 辅助函数：128-bit 算术运算
    // --------------------------------------------------------

    // 128-bit 加法（带截断）
    function Bit#(128) add128(Bit#(128) a, Bit#(128) b);
        return a + b;
    endfunction

    // 128-bit 减法（带截断）
    function Bit#(128) sub128(Bit#(128) a, Bit#(128) b);
        return a - b;
    endfunction

    // 64-bit 算术运算（常用路径）
    function Bit#(64) add64(Bit#(64) a, Bit#(64) b);
        return a + b;
    endfunction

    function Bit#(64) sub64(Bit#(64) a, Bit#(64) b);
        return a - b;
    endfunction

    // --------------------------------------------------------
    // 规则：ALU 计算（组合逻辑）
    // 守卫：loaded && ready（指令和操作数都就绪）
    // --------------------------------------------------------

    rule alu_compute (loaded_r && ready_r);
        // ★ 统一走纯组合函数 alu_execute（目的字段宽度语义 + 越界防护）
        WriteBackEntry wb = alu_execute(insn_r, param_r, s1_r, s2_r, 0);
        wb_r <= wb;
        valid_r <= True;

        // 清除 ready 标志（等待下一个指令）
        ready_r <= False;
        loaded_r <= False;
    endrule

    // --------------------------------------------------------
    // 接口方法实现
    // --------------------------------------------------------

    // 加载指令和参数
    method Action load(ALUInsn insn, Bit#(64) param) if (!loaded_r);
        insn_r <= insn;
        param_r <= param;
        loaded_r <= True;
        valid_r <= False;  // 清除旧结果
    endmethod

    // 提供操作数
    method Action operands(FieldValue s1, FieldValue s2) if (loaded_r && !ready_r);
        s1_r <= s1;
        s2_r <= s2;
        ready_r <= True;
    endmethod

    // 获取写回结果
    method WriteBackEntry result if (valid_r);
        return wb_r;
    endmethod

    // 状态查询
    method Bool ready;
        return !loaded_r;  // 可以接受新指令
    endmethod

    method Bool valid;
        return valid_r;    // 结果有效
    endmethod

endmodule

// ============================================================
//                      测试辅助模块
// ============================================================

// ALU 测试台（用于单元测试）
module mkALUTester(Empty);
    ALUIfc alu <- mkALU;

    Reg#(Bit#(32)) cycle_r <- mkReg(0);
    Reg#(Bool) test_done_r <- mkReg(False);

    // 测试序列
    rule run_test (!test_done_r);
        cycle_r <= cycle_r + 1;

        case (cycle_r)
            0: begin
                $display("[ALU Test] Cycle 0: Testing ALU_ADD");
                // 加载 ADD 指令：fd=10, fs1=20, fs2=30
                ALUInsn insn = ALUInsn {
                    op: ALU_ADD,
                    fd: 10,
                    fs1: 20,
                    fs2: 30,
                    fbase: 0,
                    stride: 0,
                    imm: 0,
                    use_param: False,
                    pidx: 0
                };
                alu.load(insn, 0);
            end

            1: begin
                $display("[ALU Test] Cycle 1: Providing operands");
                // 提供操作数：s1=100, s2=200
                FieldValue s1 = FieldValue { value: 100, bitlen: 64 };
                FieldValue s2 = FieldValue { value: 200, bitlen: 64 };
                alu.operands(s1, s2);
            end

            2: begin
                $display("[ALU Test] Cycle 2: Checking result");
                let wb = alu.result;
                if (wb.kind == WB_FIELD) begin
                    Bit#(64) result = wb.val.value[63:0];
                    $display("[ALU Test] Result: %d (expected 300)", result);
                    if (result == 300)
                        $display("[ALU Test] PASS");
                    else
                        $display("[ALU Test] FAIL");
                end
                test_done_r <= True;
            end

            default: begin
                if (cycle_r > 10) test_done_r <= True;
            end
        endcase

        if (test_done_r) begin
            $display("[ALU Test] Test completed at cycle %d", cycle_r);
            $finish;
        end
    endrule

endmodule

endpackage
