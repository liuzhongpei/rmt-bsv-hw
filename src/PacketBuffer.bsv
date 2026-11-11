// ============================================================
// PacketBuffer.bsv - AXI-Stream 报文缓冲（简化版）
//
// 使用 Reg 数组存储报文数据
// ============================================================

package PacketBuffer;

import Vector :: *;
import FIFOF :: *;
import SpecialFIFOs :: *;
import DefaultValue :: *;
import RMTInterfaces :: *;
`include "RMTConfig.bh"

// ============================================================
//                       接口定义
// ============================================================

// 接口已在 RMTInterfaces.bsv 中定义

// ============================================================
//                       实现
// ============================================================

module mkPacketBuffer(PacketBufferIfc);
    // --------------------------------------------------------
    // 报文数据缓冲：使用 Reg 数组（512 × 32B = 16KB，环形复用）
    // 注：按 COMPILATION_COMPLETE.md 建议缩小到仿真友好规模（原 4096 项
    //     会使 bsc elaboration 函数展开步数超限）。逻辑不受影响。
    // --------------------------------------------------------
    Vector#(512, Reg#(Bit#(256))) data_store <- replicateM(mkRegU);

    // 接收 FIFO（AXI-Stream 输入）
    FIFOF#(EthStream) rx_fifo <- mkFIFOF;
    // 发送 FIFO（AXI-Stream 输出），深度 64 支持整包多拍入队
    FIFOF#(EthStream) tx_fifo <- mkSizedFIFOF(64);

    // 内部报文接口 FIFO
    FIFOF#(Tuple2#(PktDesc, Bit#(9))) ingress_fifo <- mkFIFOF;  // (desc, start_addr)
    FIFOF#(Tuple2#(PktDesc, Vector#(64, Bit#(256)))) egress_fifo <- mkFIFOF;

    // 状态寄存器
    Reg#(Bit#(16)) rx_count_r <- mkReg(0);   // 总接收拍数（统计用）
    Reg#(Bit#(16)) tx_count_r <- mkReg(0);   // 总发送拍数（统计用）
    Reg#(Bit#(9))  write_addr_r <- mkReg(0); // 写指针（512 项）
    Reg#(Bit#(9))  read_addr_r <- mkReg(0);
    Reg#(Bit#(12)) pkt_beat_r <- mkReg(0);   // ★ 当前报文已写入拍数（每包独立）
    Reg#(Bit#(9))  pkt_start_r <- mkReg(0);  // ★ 当前报文起始地址

    // Egress 流式发送状态（egress_pkt 只登记，egress_send 逐拍发出）
    Reg#(PktDesc)                    egress_desc_r <- mkRegU;
    Reg#(Vector#(64, Bit#(256)))     egress_data_r <- mkRegU;
    Reg#(Bit#(7))                    egress_idx_r  <- mkReg(0);
    Reg#(Bool)                       egress_busy_r <- mkReg(False);

    // 统计 keep 中有效字节数（0-32）
    function Bit#(6) count_ones(Bit#(32) x);
        Bit#(6) n = 0;
        for (Integer i = 0; i < 32; i = i + 1) begin
            if (x[i] == 1) n = n + 1;
        end
        return n;
    endfunction

    // 根据报文长度构造第 idx 拍（idx 从 0 起）的 AXI-Stream 拍
    function EthStream make_egress_beat(Bit#(12) pkt_len, Bit#(256) beat, Bit#(7) idx);
        Bit#(12) beats = (pkt_len + 31) >> 5;
        EthStream s;
        s.data  = beat;
        s.valid = True;
        s.first = (idx == 0);
        if (idx == truncate(beats - 1)) begin
            // 末拍：keep 只标记最后剩余的字节
            Bit#(12) rem = pkt_len - (zeroExtend(idx) * 32);
            Bit#(32) k = 0;
            for (Integer b = 0; b < 32; b = b + 1) begin
                if (fromInteger(b) < rem) k[b] = 1'b1;
            end
            s.keep = k;
            s.last = True;
        end
        else begin
            s.keep = '1;
            s.last = False;
        end
        return s;
    endfunction

    // --------------------------------------------------------
    // 规则：egress 逐拍发送（每周期一拍，避免单规则多次 enq 的 G0004）
    // --------------------------------------------------------
    rule egress_send (egress_busy_r && tx_fifo.notFull);
        Bit#(12) beats = (egress_desc_r.pkt_len + 31) >> 5;
        if (egress_desc_r.pkt_len == 0) begin
            // ★ 零长报文：不发送任何拍（原实现 beats-1 截断后发出 128 拍垃圾）
            egress_busy_r <= False;
            egress_idx_r  <= 0;
        end
        else begin
            tx_fifo.enq(make_egress_beat(egress_desc_r.pkt_len,
                                         egress_data_r[egress_idx_r],
                                         egress_idx_r));
            tx_count_r <= tx_count_r + 1;
            if (egress_idx_r == truncate(beats - 1)) begin
                egress_busy_r <= False;
                egress_idx_r  <= 0;
            end
            else begin
                egress_idx_r <= egress_idx_r + 1;
            end
        end
    endrule

    // --------------------------------------------------------
    // 规则：接收报文（AXI-Stream → 存储）
    // 每包独立计数：pkt_beat_r 记录已写拍数，last 时由 keep 算字节长度
    // --------------------------------------------------------
    rule rx_accept (rx_fifo.notEmpty);
        let s = rx_fifo.first;
        rx_fifo.deq;

        // 每包独立计数：first 时复位，last 时复位，否则 +1
        // 单次写入 pkt_beat_r（避免 G0004 多写冲突）
        Bit#(12) prev_beats = s.first ? 0 : pkt_beat_r;   // 本拍之前的拍数
        Bit#(12) next_beats = s.last ? 0 : prev_beats + 1;
        Bit#(9)  pkt_start  = s.first ? write_addr_r : pkt_start_r;

        if (s.first) pkt_start_r <= pkt_start;

        // 写入存储（环形回绕）
        data_store[write_addr_r] <= s.data;
        write_addr_r <= write_addr_r + 1;
        rx_count_r  <= rx_count_r + 1;
        pkt_beat_r  <= next_beats;

        if (s.last) begin
            // 报文结束：长度 = 本拍前拍数×32 + 末拍 keep 有效字节数
            PktDesc desc = defaultValue;
            desc.pkt_len = (prev_beats << 5) + zeroExtend(count_ones(s.keep));
            desc.in_port = 0;
            ingress_fifo.enq(tuple2(desc, pkt_start));
        end
    endrule

    // --------------------------------------------------------
    // 接口方法
    // --------------------------------------------------------

    method Action rx_data(EthStream s);
        rx_fifo.enq(s);
    endmethod

    method ActionValue#(EthStream) tx_data;
        let s = tx_fifo.first;
        tx_fifo.deq;
        return s;
    endmethod

    method ActionValue#(Tuple2#(PktDesc, Vector#(64, Bit#(256)))) ingress_pkt;
        let pkt_entry = ingress_fifo.first;
        ingress_fifo.deq;
        let desc = tpl_1(pkt_entry);
        let start_addr = tpl_2(pkt_entry);

        // 只读取该报文的实际拍数（ceil(pkt_len/32)），避免读到未初始化数据
        Bit#(12) beats = (desc.pkt_len + 31) >> 5;
        Vector#(64, Bit#(256)) pkt_data = newVector;
        for (Integer i = 0; i < 64; i = i + 1) begin
            if (fromInteger(i) < beats) begin
                pkt_data[i] = data_store[(start_addr + fromInteger(i)) & 9'h1FF];
            end
            else begin
                pkt_data[i] = 0;
            end
        end

        return tuple2(desc, pkt_data);
    endmethod

    method Action egress_pkt(Tuple2#(PktDesc, Vector#(64, Bit#(256))) pkt) if (!egress_busy_r);
        // 只登记待发送报文，由 egress_send 规则逐拍发出
        egress_desc_r <= tpl_1(pkt);
        egress_data_r <= tpl_2(pkt);
        egress_idx_r  <= 0;
        egress_busy_r <= True;
    endmethod

    method Bit#(16) rx_occupancy;
        return rx_count_r;
    endmethod

    method Bit#(16) tx_occupancy;
        return tx_count_r;
    endmethod

    method Bool rx_ready;
        return rx_fifo.notFull;
    endmethod

    method Bool tx_ready;
        return tx_fifo.notEmpty;
    endmethod

endmodule

endpackage
