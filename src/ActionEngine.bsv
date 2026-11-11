// ============================================================
// ActionEngine.bsv - VLIW ALU 阵列控制器
//
// 16 路并行 ALU，3 阶段流水线（Read/Exec/Commit）
// 支持 Read-Before-Write 语义
//
// ★ 修复内容（相对原实现）：
//   原 read_phase 在同一规则内先 phv_reg.read_req_0（enq）后
//   <- read_resp_0（deq 同 FIFO），且 alus[i].load 后才调 alus[i].operands
//   （守卫要求 loaded_r）→ 双重死锁，引擎永远无法执行。
//   现在改为：
//     - READ：一次 snapshot 捕获 PHV + 当前 VLIW word（无 FIFO 往返）
//     - EXEC：用纯组合函数 alu_execute 并行算出 16 个写回条目（单次向量写）
//     - COMMIT：在捕获的 PHV 上局部修改后 restore 一次（单次写回，无冲突）
//   彻底消除同规则多方法调用（G0004）与守卫死锁。
// ============================================================

package ActionEngine;

import Vector :: *;
import FIFOF :: *;
import SpecialFIFOs :: *;
import DefaultValue :: *;
import RMTInterfaces :: *;
import ALU :: *;
import PHVRegFile :: *;
`include "RMTConfig.bh"

// ============================================================
//                       状态机
// ============================================================

typedef enum {
    ACTION_IDLE,
    ACTION_READ_PHASE,
    ACTION_EXEC_PHASE,
    ACTION_COMMIT_PHASE,
    ACTION_DONE
} ActionState deriving (Bits, Eq, FShow);

// ============================================================
//          DNN 推理（量化 MLP：4 特征 → 4 隐层 ReLU → 2 类 argmax）
//
// 特征约定（与解析器提取的字段一致）：
//   f0 = ipv4.total_len (field 13)   f1 = ipv4.ttl (field 12)
//   f2 = tcp.flags (field 24)        f3 = tcp.window (field 25)
// 权重语义（可经 load_dnn_weight 覆盖，默认值即下表）：
//   w0 = ttl 偏置        h0 = relu(f1 - w0)
//   w1 = window 偏置     h1 = relu((f3 >> 8) - w1)
//   w2 = len 偏置        h2 = relu(w2 - (f0 >> w3))
//   w3 = len 移位量      h3 = (f2 & SYN) ? 1 : 0
//   w4..w7 = 输出层系数  out = w4*h2 - w5*h0 - w6*h1 + w7*h3
//   class = out > 0 ? 1 : 0 （1 = 异常/攻击流量）
// ============================================================

function Int#(64) dnn_relu(Int#(64) x);
    return (x > 0) ? x : 0;
endfunction

function Vector#(8, Bit#(32)) dnn_default_weights;
    Vector#(8, Bit#(32)) w = newVector;
    w[0] = 32'd56;  // ttl 偏置（正常 OS 初始 TTL ≥ 64）
    w[1] = 32'd16;  // window>>8 偏置（正常窗口 >>8 远大于 16）
    w[2] = 32'd6;   // len 偏置
    w[3] = 32'd3;   // len 移位量
    w[4] = 32'd8;   // 输出层：h2（短包）加分
    w[5] = 32'd4;   // h0（正常 TTL）减分
    w[6] = 32'd4;   // h1（大窗口）减分
    w[7] = 32'd2;   // h3（SYN）加分
    return w;
endfunction

function Bit#(32) dnn_infer(Bit#(32) f0, Bit#(32) f1, Bit#(32) f2, Bit#(32) f3,
                            Vector#(8, Bit#(32)) w);
    Int#(64) h0 = dnn_relu(unpack(zeroExtend(f1)) - unpack(zeroExtend(w[0])));
    Int#(64) h1 = dnn_relu(unpack(zeroExtend(f3 >> 5'd8))
                           - unpack(zeroExtend(w[1])));
    Int#(64) h2 = dnn_relu(unpack(zeroExtend(w[2]))
                           - unpack(zeroExtend(f0 >> w[3][4:0])));
    Int#(64) h3 = ((f2 & 32'h02) != 0) ? 1 : 0;
    Int#(64) out1 = unpack(zeroExtend(w[4])) * h2
                  - unpack(zeroExtend(w[5])) * h0
                  - unpack(zeroExtend(w[6])) * h1
                  + unpack(zeroExtend(w[7])) * h3;
    return (out1 > 0) ? 32'd1 : 32'd0;
endfunction

// ============================================================
//                       实现
// ============================================================

module mkActionEngine(ActionEngineIfc);
    // PHV 寄存器堆
    PHVRegFileIfc phv_reg <- mkPHVRegFileSimple;

    // 微码 ROM（32 个动作 × 8 个 VLIW word）
    // ★ 未装载的动作号用 loaded 位图拦截后按空动作（NOP）处理：既避免
    //   mkRegU 随机微码导致的越界读写，也避免为 32×4 个 ROM 条目生成
    //   巨大的复位常量（elaboration/面积爆炸）
    Vector#(32, Reg#(ActionProgram)) microcode_rom <- replicateM(mkRegU);
    Vector#(32, Reg#(Bool)) microcode_loaded <- replicateM(mkReg(False));

    // ★ DNN 权重（8 个 32-bit，复位默认值即 dnn_default_weights，可运行时加载）
    function Bit#(32) dnn_w_default(Integer i);
        Vector#(8, Bit#(32)) w = dnn_default_weights;
        return w[i];
    endfunction
    Vector#(8, Reg#(Bit#(32))) dnn_w <- mapM(mkReg, genWith(dnn_w_default));

    // 状态寄存器
    Reg#(ActionState) state_r <- mkReg(ACTION_IDLE);
    Reg#(Bit#(5)) action_id_r <- mkRegU;
    Reg#(Bit#(4)) word_idx_r <- mkReg(0);
    Reg#(Vector#(8, Bit#(64))) params_r <- mkRegU;

    // READ 阶段捕获：PHV 快照 + 当前 VLIW word + 有效槽位数
    Reg#(PHV)      phv_snapshot_r <- mkRegU;
    Reg#(VLIWWord) vliw_word_r <- mkRegU;
    Reg#(Bit#(5))  vliw_nslots_r <- mkReg(0);

    // Write-back 缓冲（ALU_NUM_PER_STAGE 个 ALU 的结果）
    Reg#(Vector#(`ALU_NUM_PER_STAGE, WriteBackEntry)) wb_buf_r <- mkReg(replicate(defaultWB()));

    // 完成信号
    FIFOF#(Bool) done_fifo <- mkFIFOF;

    // --------------------------------------------------------
    // 规则：Read 阶段（捕获 PHV 快照和当前 VLIW word）
    // --------------------------------------------------------
    rule read_phase (state_r == ACTION_READ_PHASE);
        if (!microcode_loaded[action_id_r]) begin
            // ★ 未装载的动作号：按空动作（NOP）处理
            state_r <= ACTION_DONE;
        end
        else begin
            let prog = microcode_rom[action_id_r];
            phv_snapshot_r <= phv_reg.snapshot;   // 组合读全部 160 字段
            vliw_word_r <= prog.prog[word_idx_r];
            vliw_nslots_r <= prog.nslots[word_idx_r];
            state_r <= ACTION_EXEC_PHASE;
        end
    endrule

    // --------------------------------------------------------
    // 规则：Exec 阶段（16 个 ALU 并行计算，纯组合函数）
    // --------------------------------------------------------
    rule exec_phase (state_r == ACTION_EXEC_PHASE);
        Vector#(`ALU_NUM_PER_STAGE, WriteBackEntry) wb_vec = replicate(defaultWB());
        for (Integer i = 0; i < `ALU_NUM_PER_STAGE; i = i + 1) begin
            // ★ 只执行有效槽位（nslots 内），跳过微码未初始化的垃圾槽位
            if (fromInteger(i) < vliw_nslots_r) begin
                let insn = vliw_word_r[i];
                // ★ 微码字段越界防护（fs1/fs2/fd/pidx 来自可能未装载的微码）
                FieldValue s1 = FieldValue { value: 0, bitlen: 0 };
                FieldValue s2 = FieldValue { value: 0, bitlen: 0 };
                Bit#(8) dstb = 0;
                if (insn.fs1 < 160) s1 = phv_snapshot_r.fields[insn.fs1];
                if (insn.fs2 < 160) s2 = phv_snapshot_r.fields[insn.fs2];
                if (insn.fd  < 160) dstb = phv_snapshot_r.fields[insn.fd].bitlen;
                Bit#(64) param = (insn.use_param && insn.pidx < 8)
                               ? params_r[insn.pidx[2:0]] : 0;
                if (insn.op == ALU_DNN_INFER) begin
                    // ★ DNN 推理：特征取自约定字段，类别写回 insn.fd 字段
                    // ★ 特征有效性防护：非 IPv4+TCP 报文强制类别 0
                    Bool feat_ok = (phv_snapshot_r.hvalid[1] == 1'b1)
                                && (phv_snapshot_r.hvalid[3] == 1'b1);
                    Bit#(32) cls = 32'd0;
                    if (feat_ok) begin
                        Bit#(32) f0 = phv_snapshot_r.fields[13].value[31:0]; // total_len
                        Bit#(32) f1 = phv_snapshot_r.fields[12].value[31:0]; // ttl
                        Bit#(32) f2 = phv_snapshot_r.fields[24].value[31:0]; // flags
                        Bit#(32) f3 = phv_snapshot_r.fields[25].value[31:0]; // window
                        Vector#(8, Bit#(32)) wvec = newVector;
                        for (Integer j = 0; j < 8; j = j + 1) begin
                            wvec[j] = dnn_w[j];
                        end
                        cls = dnn_infer(f0, f1, f2, f3, wvec);
                    end
                    WriteBackEntry wb = defaultWB();
                    wb.kind = WB_FIELD;
                    wb.fd = insn.fd;
                    wb.val = FieldValue { value: zeroExtend(cls), bitlen: 8 };
                    wb_vec[i] = wb;
                end
                else if (insn.op == ALU_DROP) begin
                    // ★ 条件丢弃：fs1 字段值非零 → 置丢弃标志
                    WriteBackEntry wb = defaultWB();
                    wb.kind = (s1.value != 0) ? WB_DROP : WB_NONE;
                    wb_vec[i] = wb;
                end
                else if (insn.op == ALU_MOVX) begin
                    // ★ 索引 idx 来自报文数据（如 SRH 的 SL），不可信：
                    //   src 越出 160 字段范围时按 NOP 处理，防运行时越界
                    Bit#(8)  idx    = truncate(s1.value[7:0]);
                    Bit#(16) src16  = zeroExtend(insn.fbase)
                                    + zeroExtend(idx) * zeroExtend(insn.stride);
                    if (src16 < 160) begin
                        s1 = phv_snapshot_r.fields[src16[7:0]];
                        wb_vec[i] = alu_execute(insn, param, s1, s2, dstb);
                    end
                end
                else begin
                    wb_vec[i] = alu_execute(insn, param, s1, s2, dstb);
                end
            end
        end
        wb_buf_r <= wb_vec;
        state_r <= ACTION_COMMIT_PHASE;
    endrule

    // --------------------------------------------------------
    // 规则：Commit 阶段（基于 READ 快照一次性写回 PHV，保证 RBW）
    // --------------------------------------------------------
    rule commit_phase (state_r == ACTION_COMMIT_PHASE);
        PHV phv = phv_snapshot_r;

        for (Integer i = 0; i < `ALU_NUM_PER_STAGE; i = i + 1) begin
            let wb = wb_buf_r[i];
            case (wb.kind)
                WB_FIELD: begin
                    // ★ 目的字段越界防护（fd 来自微码）
                    if (wb.fd < 160) begin
                        phv.fields[wb.fd] = wb.val;
                        // ★ 置脏位：逆解析器据此补丁该字段
                        phv.dirty = phv.dirty | (160'h1 << wb.fd);
                    end
                end
                WB_VALIDITY: begin
                    if (wb.valid)
                        phv.hvalid = phv.hvalid | (64'h1 << wb.fd[5:0]);
                    else
                        phv.hvalid = phv.hvalid & ~(64'h1 << wb.fd[5:0]);
                    // ★ 头部集合变化 → 需完整逆解析
                    phv.structural = True;
                end
                WB_DROP: begin
                    // ★ 条件丢弃命中（ALU_DROP + 字段非零）
                    phv.dropped = True;
                end
                WB_NONE: begin
                    // 无操作
                end
            endcase
        end

        phv_reg.restore(phv);   // 单次写回全部字段

        // 检查是否有下一个 VLIW word
        let prog = microcode_rom[action_id_r];
        if (microcode_loaded[action_id_r] && word_idx_r + 1 < prog.nwords) begin
            word_idx_r <= word_idx_r + 1;
            state_r <= ACTION_READ_PHASE;
        end
        else begin
            state_r <= ACTION_DONE;
        end
    endrule

    // 规则：完成
    rule action_done (state_r == ACTION_DONE);
        done_fifo.enq(True);
        state_r <= ACTION_IDLE;
    endrule

    // --------------------------------------------------------
    // 接口方法
    // --------------------------------------------------------

    method Action start(Bit#(5) action_id, Vector#(8, Bit#(64)) params) if (state_r == ACTION_IDLE);
        action_id_r <= action_id;
        params_r <= params;
        word_idx_r <= 0;
        state_r <= ACTION_READ_PHASE;
    endmethod

    method ActionValue#(Bool) done;
        let d = done_fifo.first;
        done_fifo.deq;
        return d;
    endmethod

    interface PHVRegFileIfc phv = phv_reg;

    method Action load_action(Bit#(5) idx, ActionProgram prog);
        microcode_rom[idx] <= prog;
        microcode_loaded[idx] <= True;
    endmethod

    method Action load_dnn_weight(Bit#(4) idx, Bit#(32) w);
        dnn_w[idx[2:0]] <= w;
    endmethod

endmodule

endpackage
