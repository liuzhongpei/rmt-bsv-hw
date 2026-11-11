// ============================================================
// ReorderBuffer.bsv - TCP 重排缓冲
//
// ★ 修复内容（相对原实现）：
//   1. insert 改为返回 Bool（成功/拒绝）。原实现静默拒绝满会话插入，
//      但 TCPReorderEngine 已经分配了 ooo 数据槽 → 永久泄漏。
//   2. 超时槽位不再"就地静默清除"：每周期最多回收 1 个超时槽并放入
//      timeout FIFO，TCPReorderEngine 据此释放对应 ooo 数据槽（原实现
//      超时清除从不通知引擎 → ooo 槽同样泄漏）。
//   3. get_next 增加 expected_seq 参数，按等式选择（原实现取最小 tcp_seq，
//      TCP 序号回绕时为错）。
//   4. remove 只在槽位有效时递减计数（原实现可下溢）；索引全部按
//      会话数/槽位数截断，防止越界。
//   5. ★ 仿真规模缩小：256×64 → 8×8 槽位。
// ============================================================

package ReorderBuffer;

import Vector :: *;
import FIFOF :: *;
import SpecialFIFOs :: *;
import DefaultValue :: *;
import RMTInterfaces :: *;
`include "RMTConfig.bh"

// 仿真规模（会话数 × 每会话槽位数）
`define RB_SESS_NUM  8
`define RB_SLOT_NUM  8

// 超时阈值（周期）
`define RB_TIMEOUT   1000

// ============================================================
//                       接口定义
// ============================================================

interface ReorderBufferIfc;
    // 插入报文（返回是否成功）
    method ActionValue#(Bool) insert(Bit#(8) session_id, Bit#(32) tcp_seq,
                                     Bit#(12) pkt_len, Bit#(12) payload_len,
                                     Bit#(16) buf_idx);

    // 读取指定序列号的报文
    method ActionValue#(ReorderSlot) get_next(Bit#(8) session_id,
                                              Bit#(32) expected_seq);

    // 查询状态
    method Bool has_sequential(Bit#(8) session_id, Bit#(32) expected_seq);
    method Bool has_timeout;
    method ActionValue#(ReorderSlot) get_timeout;

    // 会话缓存查询（多会话轮询 drain 用）
    method Bit#(8) buffered_count(Bit#(8) session_id);
    method Maybe#(Bit#(8)) next_buffered(Bit#(8) start);

    // 删除
    method Action remove(Bit#(8) session_id, Bit#(16) slot_idx);
endinterface

// ============================================================
//                       实现
// ============================================================

module mkReorderBuffer(ReorderBufferIfc);
    // 重排缓冲：8 会话 × 8 槽位
    Vector#(`RB_SESS_NUM, Vector#(`RB_SLOT_NUM, Reg#(ReorderSlot))) buffer <-
        replicateM(replicateM(mkReg(defaultRS())));

    // 每会话的槽位计数
    Vector#(`RB_SESS_NUM, Reg#(Bit#(8))) slot_count <- replicateM(mkReg(0));

    // 超时槽位 FIFO（引擎据此回收 ooo 数据槽）
    FIFOF#(ReorderSlot) timeout_fifo <- mkFIFOF;

    // --------------------------------------------------------
    // 辅助函数：查找空闲槽位（0..SLOT_NUM-1）
    // --------------------------------------------------------
    function Bit#(3) find_free_slot(Bit#(3) sid3);
        Bit#(3) result = 0;
        Bool found = False;

        for (Integer i = 0; i < `RB_SLOT_NUM; i = i + 1) begin
            if (!buffer[sid3][i].valid && !found) begin
                result = fromInteger(i);
                found = True;
            end
        end

        return result;
    endfunction

    // --------------------------------------------------------
    // 规则：每周期统一老化；每周期最多回收 1 个超时槽位
    // --------------------------------------------------------
    rule age_and_timeout (True);
        Bool exp = False;
        ReorderSlot exp_slot = defaultRS();

        for (Integer s = 0; s < `RB_SESS_NUM; s = s + 1) begin
            for (Integer i = 0; i < `RB_SLOT_NUM; i = i + 1) begin
                let slot = buffer[s][i];
                if (slot.valid) begin
                    if (slot.age >= `RB_TIMEOUT && !exp) begin
                        exp = True;
                        exp_slot = slot;
                        buffer[s][i] <= defaultRS();
                        slot_count[s] <= slot_count[s] - 1;
                    end
                    else if (slot.age < `RB_TIMEOUT) begin
                        ReorderSlot ns = slot;
                        ns.age = slot.age + 1;
                        buffer[s][i] <= ns;
                    end
                end
            end
        end

        if (exp) timeout_fifo.enq(exp_slot);
    endrule

    // --------------------------------------------------------
    // 接口方法
    // --------------------------------------------------------

    method ActionValue#(Bool) insert(Bit#(8) session_id, Bit#(32) tcp_seq,
                                     Bit#(12) pkt_len, Bit#(12) payload_len,
                                     Bit#(16) buf_idx);
        Bit#(3) sid3 = session_id[2:0];
        Bool ok = False;

        if (session_id < `RB_SESS_NUM) begin
            Bool free_slot = False;
            for (Integer i = 0; i < `RB_SLOT_NUM; i = i + 1) begin
                if (!buffer[sid3][i].valid) free_slot = True;
            end

            if (free_slot) begin
                let slot_idx = find_free_slot(sid3);
                ReorderSlot slot = ReorderSlot {
                    tcp_seq: tcp_seq,
                    pkt_len: pkt_len,
                    payload_len: payload_len,
                    buf_idx: buf_idx,
                    session_id: session_id,
                    valid: True,
                    age: 0
                };
                buffer[sid3][slot_idx] <= slot;
                slot_count[sid3] <= slot_count[sid3] + 1;
                ok = True;
            end
        end

        return ok;
    endmethod

    method ActionValue#(ReorderSlot) get_next(Bit#(8) session_id,
                                              Bit#(32) expected_seq);
        Bit#(3) sid3 = session_id[2:0];
        ReorderSlot result = defaultRS();
        Bool found = False;

        for (Integer i = 0; i < `RB_SLOT_NUM; i = i + 1) begin
            let slot = buffer[sid3][i];
            if (slot.valid && slot.tcp_seq == expected_seq && !found) begin
                found = True;
                result = slot;
                buffer[sid3][i] <= defaultRS();
                slot_count[sid3] <= slot_count[sid3] - 1;
            end
        end

        return result;
    endmethod

    method Bool has_sequential(Bit#(8) session_id, Bit#(32) expected_seq);
        Bool result = False;
        Bit#(3) sid3 = session_id[2:0];
        for (Integer i = 0; i < `RB_SLOT_NUM; i = i + 1) begin
            let slot = buffer[sid3][i];
            if (slot.valid && slot.tcp_seq == expected_seq) begin
                result = True;
            end
        end
        return result;
    endmethod

    method Bool has_timeout;
        return timeout_fifo.notEmpty;
    endmethod

    method ActionValue#(ReorderSlot) get_timeout;
        let slot = timeout_fifo.first;
        timeout_fifo.deq;
        return slot;
    endmethod

    method Bit#(8) buffered_count(Bit#(8) session_id);
        return slot_count[session_id[2:0]];
    endmethod

    // 从 start+1 起轮询第一个有缓存包的会话（模 RB_SESS_NUM 回绕，
    // 不含 start 本身；从高位向低位扫描使最低位置的命中成为最终结果）
    method Maybe#(Bit#(8)) next_buffered(Bit#(8) start);
        Maybe#(Bit#(8)) result = tagged Invalid;
        for (Integer i = `RB_SESS_NUM - 1; i >= 1; i = i - 1) begin
            Bit#(3) idx3 = start[2:0] + fromInteger(i);
            if (slot_count[idx3] > 0) begin
                result = tagged Valid zeroExtend(idx3);
            end
        end
        return result;
    endmethod

    method Action remove(Bit#(8) session_id, Bit#(16) slot_idx);
        Bit#(3) sid3 = session_id[2:0];
        Bit#(3) i3   = slot_idx[2:0];
        if (buffer[sid3][i3].valid) begin
            buffer[sid3][i3] <= defaultRS();
            slot_count[sid3] <= slot_count[sid3] - 1;
        end
    endmethod

endmodule

endpackage
