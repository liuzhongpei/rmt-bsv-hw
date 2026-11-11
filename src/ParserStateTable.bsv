// ============================================================
// ParserStateTable.bsv - 解析器配置存储（简化版）
//
// 32 条目，使用 Reg 数组实现
// ============================================================

package ParserStateTable;

import Vector :: *;
import FIFOF :: *;
import RMTInterfaces :: *;
`include "RMTConfig.bh"

// ============================================================
//                       接口定义
// ============================================================

interface ParserStateTableIfc;
    // 读接口（解析 FSM 使用）
    method Action read_req(Bit#(5) state_id);
    method ActionValue#(ParseState) read_resp;

    // 写接口（控制面配置）
    method Action write(Bit#(5) state_id, ParseState state);
endinterface

// ============================================================
//                       实现（简化版）
// ============================================================

module mkParserStateTable(ParserStateTableIfc);
    // ★ 默认状态：无操作 + ACCEPT（未配置的状态直接接受，避免垃圾配置导致
    //   解析 FSM 读取未初始化 nops/ops）
    function ParseState defaultParseState();
        ParseState s;
        s.name_id = 0;
        s.ops = replicate(ParseOp {
            kind: POP_EXTRACT, hdr_id: 0, count_field: 0, count_add: 0
        });
        s.nops = 0;
        s.sel_field = 8'hFF;
        s.cases = replicate(SelCase { sel_val: 0, next_state: 0 });
        s.ncases = 0;
        s.def_next = 5'h1F;   // PS_ACCEPT
        return s;
    endfunction

    // 使用 Reg 数组存储 32 个解析状态
    Vector#(32, Reg#(ParseState)) storage <- replicateM(mkReg(defaultParseState));

    // 读响应 FIFO
    FIFOF#(ParseState) resp_fifo <- mkFIFOF;

    // 读请求
    method Action read_req(Bit#(5) state_id);
        resp_fifo.enq(storage[state_id]);
    endmethod

    // 读响应
    method ActionValue#(ParseState) read_resp;
        resp_fifo.deq;
        return resp_fifo.first;
    endmethod

    // 写操作
    method Action write(Bit#(5) state_id, ParseState state);
        storage[state_id] <= state;
    endmethod

endmodule

endpackage
