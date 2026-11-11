// ============================================================
// TCAMArray.bsv - TCAM 三态内容寻址存储器
//
// 16 条目 × 128 key + 128 mask
// 支持 Exact 和 LPM 匹配
//
// ★ 修复内容（相对原实现）：
//   1. 原实现用 key==0 判空 + 寄存器 mkRegU(未初始化)：
//      - 空槽 mask=0 时 (key&0)==(entry.key&0) 恒成立 → 空槽匹配一切；
//      - entry_count 永不增加（未初始化 key != 0），clear 后下溢到 65535。
//      现在每个槽单独维护 valid 位，空槽/已删槽永不命中，计数按 valid 维护。
//   2. lookup/result 严格 1 拍配对（lookup 写 key，下一拍 result 组合读）。
// ============================================================

package TCAMArray;

import Vector :: *;
import BRAM :: *;
import FIFOF :: *;
import SpecialFIFOs :: *;
import RMTInterfaces :: *;
`include "RMTConfig.bh"

// ============================================================
//                       接口定义
// ============================================================

interface TCAMArrayIfc;
    // 查找接口
    method Action lookup(Bit#(128) key);
    method ActionValue#(Tuple2#(Bool, Bit#(10))) result;  // (hit, index)

    // 配置接口
    method Action write(Bit#(10) idx, TCAMEntry entry);
    method Action clear(Bit#(10) idx);

    // 状态
    method Bit#(16) entry_count;
endinterface

// ============================================================
//                       实现
// ============================================================

module mkTCAMArray(TCAMArrayIfc);
    // 空槽条目（只在 invalid 槽存在，永不参与匹配）
    function TCAMEntry emptyEntry();
        TCAMEntry e;
        e.key = 0; e.mask = 0; e.action_id = 0; e.params = 0;
        return e;
    endfunction

    // TCAM 存储：16 条目（仿真规模）+ 独立有效位
    Vector#(16, Reg#(TCAMEntry)) tcam_array <- replicateM(mkReg(emptyEntry));
    Vector#(16, Reg#(Bool))      valid      <- replicateM(mkReg(False));

    // 查找 key（result 组合读取）
    Reg#(Bit#(128)) lookup_key_r <- mkReg(0);

    // 条目计数（按 valid 维护，不会与空槽内容耦合）
    Reg#(Bit#(16)) entry_count_r <- mkReg(0);

    // --------------------------------------------------------
    // 辅助函数：优先编码器（只在命中集内选择）
    // 掩码超集比较：候选条目 mask 含有当前最优 mask 没有的关心位 → 前缀更长。
    // 对嵌套前缀掩码（LPM）等价于最长前缀优先；Exact 表平手取最低索引。
    // --------------------------------------------------------
    function Bit#(10) priority_encode(Bit#(16) hit_vec);
        Bit#(10)  best_idx  = 0;
        Bit#(128) best_mask = 0;
        Bool found = False;

        for (Integer i = 0; i < 16; i = i + 1) begin
            if (hit_vec[i] == 1) begin
                let m = tcam_array[i].mask;
                if (!found) begin
                    found = True;
                    best_idx = fromInteger(i);
                    best_mask = m;
                end
                else if ((m & ~best_mask) != 0) begin
                    best_idx = fromInteger(i);
                    best_mask = m;
                end
            end
        end

        return best_idx;
    endfunction

    // --------------------------------------------------------
    // 接口方法
    // --------------------------------------------------------

    method Action lookup(Bit#(128) key);
        lookup_key_r <= key;
    endmethod

    method ActionValue#(Tuple2#(Bool, Bit#(10))) result;
        // 组合计算命中（lookup 写入 key 后的下一拍读到正确结果）
        Bit#(16) hit_vec = 0;

        for (Integer i = 0; i < 16; i = i + 1) begin
            if (valid[i]) begin
                let entry = tcam_array[i];
                // TCAM 匹配逻辑：(key & mask) == (entry.key & mask)
                Bit#(128) key_masked   = lookup_key_r & entry.mask;
                Bit#(128) entry_masked = entry.key & entry.mask;
                if (key_masked == entry_masked) begin
                    hit_vec[i] = 1;
                end
            end
        end

        let hit_idx = priority_encode(hit_vec);
        Bool hit = (hit_vec != 0);
        return tuple2(hit, hit_idx);
    endmethod

    method Action write(Bit#(10) idx, TCAMEntry entry);
        // ★ 索引范围检查：10-bit 接口承载 16 项存储
        if (idx < 16) begin
            tcam_array[idx[3:0]] <= entry;
            if (!valid[idx[3:0]]) begin
                valid[idx[3:0]] <= True;
                entry_count_r <= entry_count_r + 1;
            end
        end
    endmethod

    method Action clear(Bit#(10) idx);
        if (idx < 16) begin
            if (valid[idx[3:0]]) begin
                entry_count_r <= entry_count_r - 1;
            end
            valid[idx[3:0]] <= False;
            tcam_array[idx[3:0]] <= emptyEntry;
        end
    endmethod

    method Bit#(16) entry_count;
        return entry_count_r;
    endmethod

endmodule

endpackage
