// ============================================================
// TCPReorderEngine.bsv - TCP 乱序重排与会话重组引擎
//
// 集成 SessionTracker + SessionFSM + ReorderBuffer + PayloadConcat
//
// ★ 修复内容（相对原实现）：
//   1. reassemble_output 原硬编码 has_sequential(session_id_r, 0)，从不读
//      会话 expected_seq → 改用会话的 expected_seq，并在按序输出后推进。
//   2. 原 process_hit 按序输出后从不 update 会话 expected_seq → 已更新。
//   3. 原 reassemble_output 转到 TCP_OUTPUT 状态但无规则处理 → 死锁。
//      已删除该状态，重组直接输出。
//   4. 原 insert_buffer 以 buf_idx=0 插入、报文数据丢失 → 现把报文数据存进
//      本地 ooo_data，buf_idx 指向之。
//   5. 原 insert_pkt 写入的 input_fifo 无人消费 → 已删除（引擎为单报文状态机）。
//   6. 原 delete_session 空操作 → 实现按 key 查找并删除。
// ============================================================

package TCPReorderEngine;

import Vector :: *;
import FIFOF :: *;
import SpecialFIFOs :: *;
import DefaultValue :: *;
import RMTInterfaces :: *;
import SessionTracker :: *;
import SessionFSM :: *;
import ReorderBuffer :: *;
import PayloadConcat :: *;
`include "RMTConfig.bh"

// ============================================================
//                       状态机
// ============================================================

typedef enum {
    TCP_IDLE,
    TCP_LOOKUP_SESSION,
    TCP_PROCESS_HIT,
    TCP_PROCESS_MISS,
    TCP_INSERT_BUFFER,
    TCP_DELETE_REQ,
    TCP_DELETE_RESP
} TCPEngineState deriving (Bits, Eq, FShow);

// ============================================================
//                       实现
// ============================================================

module mkTCPReorderEngine(TCPReorderEngineIfc);
    // 子模块
    SessionTrackerIfc tracker <- mkSessionTracker;
    ReorderBufferIfc reorder_buf <- mkReorderBuffer;
    PayloadConcatIfc payload_concat <- mkPayloadConcat;
    // 会话状态转换使用纯函数 fsm_transition（模块 mkSessionFSM 的三拍握手
    // 守卫时序易死锁，且原先实例化后从未被驱动 → 会话状态永远停在 SYN）

    // 状态寄存器
    Reg#(TCPEngineState) state_r <- mkReg(TCP_IDLE);
    Reg#(PktDesc) desc_r <- mkRegU;
    Reg#(PHV) phv_r <- mkRegU;
    Reg#(Vector#(64, Bit#(256))) pkt_data_r <- mkRegU;
    Reg#(Bit#(8)) session_id_r <- mkRegU;
    Reg#(Bit#(32)) expected_seq_r <- mkReg(0);
    Reg#(Bool) session_active_r <- mkReg(False);   // 至少处理过一个会话

    // 乱序报文缓冲（16 项，buf_idx 索引）：数据 + 其自身 desc/phv
    // ★ 原实现重组输出用的是"最后插入包"的 desc/phv，与缓存包不匹配
    // ★ 占用管理：ooo_free_r 位图（1=空闲）。原实现 ooo_alloc_r 自由环回
    //   计数、输出后从不释放 → 超过 16 个缓存包时 buf_idx 别名覆盖。
    Reg#(Bit#(16)) ooo_free_r <- mkReg(16'hFFFF);
    Vector#(16, Reg#(Vector#(64, Bit#(256)))) ooo_data <- replicateM(mkRegU);
    Vector#(16, Reg#(PktDesc)) ooo_desc <- replicateM(mkRegU);
    Vector#(16, Reg#(PHV)) ooo_phv <- replicateM(mkRegU);

    // 查找最低空闲 ooo 槽位（从高到低扫描，最后赋值即最低命中）
    function Maybe#(Bit#(4)) find_free_ooo(Bit#(16) free_map);
        Maybe#(Bit#(4)) result = tagged Invalid;
        for (Integer i = 15; i >= 0; i = i - 1) begin
            if (free_map[i] == 1'b1) begin
                result = tagged Valid fromInteger(i);
            end
        end
        return result;
    endfunction

    // 删除会话请求
    Reg#(TCP5Tuple) del_key_r <- mkRegU;
    Reg#(Bool) del_pending_r <- mkReg(False);
    Reg#(Bool) del_wait_r <- mkReg(False);

    // 输出 FIFO
    FIFOF#(Tuple3#(PktDesc, PHV, Vector#(64, Bit#(256)))) output_fifo <- mkFIFOF;

    // --------------------------------------------------------
    // 规则：会话查找（非 TCP 报文直接旁路，不进会话表）
    // --------------------------------------------------------
    rule session_lookup (state_r == TCP_LOOKUP_SESSION);
        if (desc_r.is_tcp) begin
            tracker.lookup_req(build_tcp_5tuple(phv_r));
            state_r <= TCP_PROCESS_HIT;
        end
        else begin
            output_fifo.enq(tuple3(desc_r, phv_r, pkt_data_r));
            state_r <= TCP_IDLE;
        end
    endrule

    // 规则：处理会话命中
    rule process_hit (state_r == TCP_PROCESS_HIT);
        let lookup_result <- tracker.lookup_resp;
        let hit = tpl_1(lookup_result);
        let session_id = tpl_2(lookup_result);

        if (hit) begin
            session_id_r <= session_id;
            session_active_r <= True;
            let tcp_seq = extract_tcp_seq(phv_r);
            let sess <- tracker.get_session(session_id);

            // ★ 应用会话状态转换（SYN→ESTABLISHED 等），始终更新会话状态
            TCPSessionEntry sess2 = fsm_transition(sess, phv_r);

            // 单次写 expected_seq_r（避免 G0004 多写冲突）
            // ★ 报文短于头部（畸形包）时 payload_len 取 0，防止下溢成超大值
            let payload_len = (desc_r.pkt_len > desc_r.hdr_bytes)
                            ? desc_r.pkt_len - desc_r.hdr_bytes : 0;
            Bit#(32) new_expected = sess.expected_seq;
            Bool is_inorder = (tcp_seq == sess.expected_seq);
            if (is_inorder)
                new_expected = sess.expected_seq + zeroExtend(payload_len);
            expected_seq_r <= new_expected;

            // 更新会话（状态 + 序列号）
            TCPSessionEntry ns = sess2;
            ns.expected_seq = new_expected;
            tracker.update(session_id, ns);

            if (is_inorder) begin
                // 按序到达：输出并推进 expected_seq
                output_fifo.enq(tuple3(desc_r, phv_r, pkt_data_r));
                state_r <= TCP_IDLE;
            end
            // ★ 有符号差值比较：正确处理 32 位序号回绕
            else if (unpack(tcp_seq - sess.expected_seq) > 0) begin
                // 超前到达：插入重排缓冲
                state_r <= TCP_INSERT_BUFFER;
            end
            else begin
                // 重复报文：丢弃
                state_r <= TCP_IDLE;
            end
        end
        else begin
            // 未命中：检查是否是 SYN
            state_r <= TCP_PROCESS_MISS;
        end
    endrule

    // 规则：处理会话未命中
    rule process_miss (state_r == TCP_PROCESS_MISS);
        if (is_tcp_syn(phv_r)) begin
            // 新会话：创建并输出
            // ★ expected_seq 从 SYN 初始化：SYN 自身消耗 1 个序号，
            //   expected = SYN.seq + payload_len + 1（原实现恒 0，
            //   握手后真实数据流的序号会被误判为超前/重复）
            Bit#(32) payload_len = zeroExtend(desc_r.pkt_len - desc_r.hdr_bytes);
            Bit#(32) init_seq = extract_tcp_seq(phv_r)
                              + payload_len + 32'd1;
            let created <- tracker.create(build_tcp_5tuple(phv_r), init_seq);
            case (created) matches
                tagged Valid .sid: begin
                    session_id_r    <= sid;
                    expected_seq_r  <= init_seq;
                    session_active_r <= True;
                end
                tagged Invalid: begin
                    // 会话表满：仅旁路输出，不建会话
                    noAction;
                end
            endcase
            output_fifo.enq(tuple3(desc_r, phv_r, pkt_data_r));
            state_r <= TCP_IDLE;
        end
        else begin
            // 非 SYN 且无会话：旁路
            output_fifo.enq(tuple3(desc_r, phv_r, pkt_data_r));
            state_r <= TCP_IDLE;
        end
    endrule

    // 规则：插入重排缓冲（报文数据 + 自身 desc/phv 存入 ooo 缓冲）
    // ★ 无空闲槽位时丢包（原实现环回计数会覆盖未输出的缓存包）
    rule insert_buffer (state_r == TCP_INSERT_BUFFER);
        let tcp_seq = extract_tcp_seq(phv_r);
        let payload_len = (desc_r.pkt_len > desc_r.hdr_bytes)
                        ? desc_r.pkt_len - desc_r.hdr_bytes : 0;
        let midx = find_free_ooo(ooo_free_r);
        if (isValid(midx)) begin
            let idx = validValue(midx);
            // ★ 先确认重排缓冲接收成功，再占用 ooo 数据槽（原实现先清位、
            //   插入被拒时 ooo 槽永久泄漏）
            let ok <- reorder_buf.insert(session_id_r, tcp_seq, desc_r.pkt_len,
                                         payload_len, zeroExtend(idx));
            if (ok) begin
                ooo_data[idx] <= pkt_data_r;
                ooo_desc[idx] <= desc_r;
                ooo_phv[idx]  <= phv_r;
                ooo_free_r    <= ooo_free_r & ~(16'h1 << idx);
            end
        end
        state_r <= TCP_IDLE;
    endrule

    // 规则：重组输出（按会话 expected_seq 依次吐出连续报文）
    // ★ 输出使用缓存包自身的 desc/phv（原用最后插入包的，元数据不匹配）
    rule reassemble_output (state_r == TCP_IDLE && session_active_r
                            && !del_pending_r
                            && reorder_buf.has_sequential(session_id_r, expected_seq_r));
        let slot <- reorder_buf.get_next(session_id_r, expected_seq_r);
        let sess <- tracker.get_session(session_id_r);
        TCPSessionEntry ns = sess;
        ns.expected_seq = sess.expected_seq + zeroExtend(slot.payload_len);
        tracker.update(session_id_r, ns);
        expected_seq_r <= ns.expected_seq;
        // ★ 释放缓存槽位（原实现从不释放）
        ooo_free_r <= ooo_free_r | (16'h1 << slot.buf_idx[3:0]);
        output_fifo.enq(tuple3(ooo_desc[slot.buf_idx[3:0]],
                               ooo_phv[slot.buf_idx[3:0]],
                               ooo_data[slot.buf_idx[3:0]]));
    endrule

    // 规则：多会话轮询 drain
    // ★ session_id_r/expected_seq_r 原来只跟随最后命中的会话 → 交错流量下，
    //   无后续报文的会话其缓存包永远不会被输出（饿死）。本规则在当前会话
    //   无连续可输出包时，轮询切换到下一个有缓存包的会话（含当前会话有
    //   空洞、其他会话可推进的情况）。守卫与 reassemble_output 互斥
    //   （has_sequential 取反），不会抢输出；无其他会话缓存则空转不动。
    rule drain_scan (state_r == TCP_IDLE && session_active_r && !del_pending_r
                     && !reorder_buf.has_sequential(session_id_r, expected_seq_r));
        case (reorder_buf.next_buffered(session_id_r + 1)) matches
            tagged Valid .sid: begin
                let sess <- tracker.get_session(sid);
                session_id_r   <= sid;
                expected_seq_r <= sess.expected_seq;
            end
            tagged Invalid: noAction;   // 无其他会话有缓存
        endcase
    endrule

    // 规则：超时释放（★ 回收被老化清掉的槽位对应的 ooo 数据槽）
    rule timeout_release (state_r == TCP_IDLE && reorder_buf.has_timeout);
        let s <- reorder_buf.get_timeout;
        ooo_free_r <= ooo_free_r | (16'h1 << s.buf_idx[3:0]);
    endrule

    // 规则：删除会话——查找
    rule delete_req (state_r == TCP_IDLE && del_pending_r && !del_wait_r);
        // ★ 删除走独立查找通道，与数据面 lookup_resp 不再错配
        tracker.delete_lookup_req(del_key_r);
        del_wait_r <= True;
    endrule

    // 规则：删除会话——执行删除
    rule delete_resp (state_r == TCP_IDLE && del_wait_r);
        let r <- tracker.delete_lookup_resp;
        if (tpl_1(r)) begin
            tracker.delete(tpl_2(r));
        end
        del_pending_r <= False;
        del_wait_r <= False;
    endrule

    // --------------------------------------------------------
    // 接口方法
    // --------------------------------------------------------

    method Action insert_pkt(PktDesc desc, PHV phv,
                             Vector#(64, Bit#(256)) pkt_data)
                             if (state_r == TCP_IDLE && !del_pending_r);
        desc_r <= desc;
        phv_r <= phv;
        pkt_data_r <= pkt_data;
        state_r <= TCP_LOOKUP_SESSION;
    endmethod

    method ActionValue#(Tuple3#(PktDesc, PHV, Vector#(64, Bit#(256)))) get_reassembled;
        let res = output_fifo.first;
        output_fifo.deq;
        return res;
    endmethod

    method Action create_session(TCP5Tuple key, Bit#(32) init_seq);
        // 控制面预建会话：init_seq 由控制面给出（未知时传 0）
        let _sid <- tracker.create(key, init_seq);
    endmethod

    method Action delete_session(TCP5Tuple key) if (!del_pending_r);
        del_key_r <= key;
        del_pending_r <= True;
    endmethod

    method Bit#(16) active_sessions;
        return tracker.active_count;
    endmethod

    method Bit#(32) reorder_latency;
        return 0;  // 简化
    endmethod

    method Bool insert_ready;
        return state_r == TCP_IDLE;
    endmethod

    method Bool output_available;
        return output_fifo.notEmpty;
    endmethod

endmodule

endpackage
