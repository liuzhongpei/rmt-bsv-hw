// ============================================================
// SessionTracker.bsv - TCP 会话跟踪表
//
// ★ 修复内容（相对原实现）：
//   1. 数据面查找与删除查找原共用一条 lookup_req/lookup_resp 通道，
//      删除请求与报文查找的响应会错配（删除丢失/删错会话、报文误用
//      他会话命中结果）。现在为删除提供**独立通道**（delete_lookup_*）。
//   2. lookup_req 增加 "!pending" 守卫，请求严格串行化：消除
//      "lookup_req 与 do_lookup 同拍写 pending 标志" 的 shadow 歧义
//      （BSC 会告警，行为依赖调度顺序）。
//   3. create() 满表返回 Invalid；update/get_session/delete 增加索引范围检查。
//   4. ★ 仿真规模缩小：256 会话 → 8 会话。
// ============================================================

package SessionTracker;

import Vector :: *;
import FIFOF :: *;
import SpecialFIFOs :: *;
import DefaultValue :: *;
import RMTInterfaces :: *;
`include "RMTConfig.bh"

// 会话数（仿真缩小：256 → 8）
`define SESS_SIM_NUM 8

// ============================================================
//                       接口定义
// ============================================================

interface SessionTrackerIfc;
    // 数据面查找接口
    method Action lookup_req(TCP5Tuple key);
    method ActionValue#(Tuple2#(Bool, Bit#(8))) lookup_resp;  // (hit, session_id)

    // ★ 删除查找接口（独立通道，避免与数据面查找串扰）
    method Action delete_lookup_req(TCP5Tuple key);
    method ActionValue#(Tuple2#(Bool, Bit#(8))) delete_lookup_resp;

    // 会话管理（create 返回分配的槽位，满表返回 Invalid；
    //   init_seq = 初始 expected_seq）
    method ActionValue#(Maybe#(Bit#(8))) create(TCP5Tuple key, Bit#(32) init_seq);
    method Action delete(Bit#(8) session_id);
    method Action update(Bit#(8) session_id, TCPSessionEntry entry);

    // 读取会话信息
    method ActionValue#(TCPSessionEntry) get_session(Bit#(8) session_id);

    // 状态
    method Bit#(16) active_count;
endinterface

// ============================================================
//                       实现
// ============================================================

module mkSessionTracker(SessionTrackerIfc);
    // 会话表（仿真 8 条目）
    Vector#(`SESS_SIM_NUM, Reg#(TCPSessionEntry)) session_table <-
        replicateM(mkReg(defaultValue));

    // 活跃会话计数
    Reg#(Bit#(16)) active_count_r <- mkReg(0);

    // 数据面查找 key 与触发
    Reg#(TCP5Tuple) lookup_key_r <- mkRegU;
    Reg#(Bool) lookup_pending_r <- mkReg(False);
    FIFOF#(Tuple2#(Bool, Bit#(8))) lookup_resp_fifo <- mkFIFOF;

    // 删除查找 key 与触发（独立）
    Reg#(TCP5Tuple) del_key_r <- mkRegU;
    Reg#(Bool) del_pending_r <- mkReg(False);
    FIFOF#(Tuple2#(Bool, Bit#(8))) del_resp_fifo <- mkFIFOF;

    // 会话读取 FIFO
    FIFOF#(TCPSessionEntry) session_resp_fifo <- mkFIFOF;

    // --------------------------------------------------------
    // 辅助函数：遍历会话表匹配 5 元组
    // --------------------------------------------------------
    function Tuple2#(Bool, Bit#(8)) find_match(TCP5Tuple k);
        Bool found = False;
        Bit#(8) found_id = 0;

        for (Integer i = 0; i < `SESS_SIM_NUM; i = i + 1) begin
            let sess = session_table[i];
            if (sess.active && sess.key == k) begin
                found = True;
                found_id = fromInteger(i);
            end
        end

        return tuple2(found, found_id);
    endfunction

    // --------------------------------------------------------
    // 规则：数据面查找（由 lookup_req 触发）
    // --------------------------------------------------------
    rule do_lookup (lookup_pending_r);
        lookup_resp_fifo.enq(find_match(lookup_key_r));
        lookup_pending_r <= False;
    endrule

    // --------------------------------------------------------
    // 规则：删除查找（由 delete_lookup_req 触发）
    // --------------------------------------------------------
    rule do_del_lookup (del_pending_r);
        del_resp_fifo.enq(find_match(del_key_r));
        del_pending_r <= False;
    endrule

    // --------------------------------------------------------
    // 辅助函数：查找空闲会话槽位
    // --------------------------------------------------------
    function Bit#(8) find_free_slot;
        Bit#(8) result = 0;
        Bool found = False;

        for (Integer i = 0; i < `SESS_SIM_NUM; i = i + 1) begin
            if (!session_table[i].active && !found) begin
                result = fromInteger(i);
                found = True;
            end
        end

        return result;
    endfunction

    // 是否已满
    function Bool is_full;
        return active_count_r >= `SESS_SIM_NUM;
    endfunction

    // --------------------------------------------------------
    // 接口方法
    // --------------------------------------------------------

    method Action lookup_req(TCP5Tuple key) if (!lookup_pending_r);
        lookup_key_r <= key;
        lookup_pending_r <= True;
    endmethod

    method ActionValue#(Tuple2#(Bool, Bit#(8))) lookup_resp;
        let resp = lookup_resp_fifo.first;
        lookup_resp_fifo.deq;
        return resp;
    endmethod

    method Action delete_lookup_req(TCP5Tuple key) if (!del_pending_r);
        del_key_r <= key;
        del_pending_r <= True;
    endmethod

    method ActionValue#(Tuple2#(Bool, Bit#(8))) delete_lookup_resp;
        let resp = del_resp_fifo.first;
        del_resp_fifo.deq;
        return resp;
    endmethod

    method ActionValue#(Maybe#(Bit#(8))) create(TCP5Tuple key, Bit#(32) init_seq);
        Maybe#(Bit#(8)) result = tagged Invalid;
        if (!is_full) begin
            let slot = find_free_slot;
            TCPSessionEntry new_sess = defaultValue;
            new_sess.key = key;
            new_sess.state = TCP_SESS_SYN;
            new_sess.active = True;
            new_sess.expected_seq = init_seq;
            new_sess.age_counter = 0;

            session_table[slot] <= new_sess;
            active_count_r <= active_count_r + 1;
            result = tagged Valid slot;
        end
        return result;
    endmethod

    method Action delete(Bit#(8) session_id);
        if (session_id < `SESS_SIM_NUM && session_table[session_id].active) begin
            TCPSessionEntry empty = defaultValue;
            session_table[session_id] <= empty;
            active_count_r <= active_count_r - 1;
        end
    endmethod

    method Action update(Bit#(8) session_id, TCPSessionEntry entry);
        if (session_id < `SESS_SIM_NUM) begin
            session_table[session_id] <= entry;
        end
    endmethod

    method ActionValue#(TCPSessionEntry) get_session(Bit#(8) session_id);
        if (session_id < `SESS_SIM_NUM) begin
            return session_table[session_id];
        end
        else begin
            return defaultValue;
        end
    endmethod

    method Bit#(16) active_count;
        return active_count_r;
    endmethod

endmodule

endpackage
