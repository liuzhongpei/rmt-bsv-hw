// ============================================================
// PHVBank.bsv - 单个 PHV Bank 模块（简化版）
//
// 40 条目 × 136 bits 的存储
// 使用 Reg 数组实现
// ============================================================

package PHVBank;

import Vector :: *;
import FIFOF :: *;
import SpecialFIFOs :: *;
import RMTInterfaces :: *;
`include "RMTConfig.bh"

// ============================================================
//                       类型定义
// ============================================================

typedef Bit#(6)  BankIdx;           // 40 条目索引（0-39）
typedef Bit#(136) BankEntry;        // 128-bit 值 + 8-bit 位宽

// 将 FieldValue 转换为 BankEntry
function BankEntry fv_to_entry(FieldValue fv);
    return {fv.value, fv.bitlen};
endfunction

// 将 BankEntry 转换为 FieldValue
function FieldValue entry_to_fv(BankEntry e);
    return FieldValue {
        value: e[135:8],
        bitlen: e[7:0]
    };
endfunction

// ============================================================
//                     PHV Bank 接口
// ============================================================

interface PHVBankIfc;
    // 读端口
    method Action read_req(Bit#(6) idx);
    method ActionValue#(FieldValue) read_resp;

    // 写端口
    method Action write(Bit#(6) idx, FieldValue val);
endinterface

// ============================================================
//                     PHV Bank 实现（简化版）
// ============================================================

module mkPHVBank#(Bit#(6) bank_id)(PHVBankIfc);
    // 使用 Reg 数组存储 40 个条目
    Vector#(40, Reg#(BankEntry)) storage <- replicateM(mkReg({128'h0, 8'h0}));

    // 读响应 FIFO
    FIFOF#(FieldValue) resp_fifo <- mkFIFOF;

    // 读请求
    method Action read_req(Bit#(6) idx);
        resp_fifo.enq(entry_to_fv(storage[idx]));
    endmethod

    // 读响应
    method ActionValue#(FieldValue) read_resp;
        resp_fifo.deq;
        return resp_fifo.first;
    endmethod

    // 写操作
    method Action write(Bit#(6) idx, FieldValue val);
        storage[idx] <= fv_to_entry(val);
    endmethod

endmodule

endpackage
