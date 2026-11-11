// ============================================================
// PayloadConcat.bsv - 有效载荷拼接
//
// 从 ReorderBuffer 按序读取报文并拼接有效载荷
// ============================================================

package PayloadConcat;

import Vector :: *;
import FIFOF :: *;
import SpecialFIFOs :: *;
import RMTInterfaces :: *;
`include "RMTConfig.bh"

// ============================================================
//                       接口定义
// ============================================================

interface PayloadConcatIfc;
    // 输入报文数据
    method Action provide_data(Bit#(8) session_id, Vector#(64, Bit#(256)) pkt_data,
                              Bit#(12) payload_offset, Bit#(12) payload_len);

    // 输出拼接后的有效载荷
    method ActionValue#(Vector#(64, Bit#(256))) get_payload;

    // 状态
    method Bool has_output;
endinterface

// ============================================================
//                       实现
// ============================================================

module mkPayloadConcat(PayloadConcatIfc);
    // 输出 FIFO
    FIFOF#(Vector#(64, Bit#(256))) output_fifo <- mkFIFOF;

    // 当前拼接缓冲
    Reg#(Vector#(64, Bit#(256))) concat_buf_r <- mkReg(replicate(0));
    Reg#(Bit#(12)) concat_offset_r <- mkReg(0);

    // --------------------------------------------------------
    // 接口方法
    // --------------------------------------------------------

    method Action provide_data(Bit#(8) session_id, Vector#(64, Bit#(256)) pkt_data,
                              Bit#(12) payload_offset, Bit#(12) payload_len);
        // 提取有效载荷（跳过 TCP 头部）
        Vector#(64, Bit#(256)) payload = replicate(0);

        // 按拍提取有效载荷（payload_offset 指向 payload 起始）
        Bit#(12) start_beat = zeroExtend(payload_offset[11:5]);
        Bit#(12) nbeats     = (payload_len + 31) >> 5;
        for (Integer i = 0; i < 64; i = i + 1) begin
            Bit#(12) beat_idx = fromInteger(i);
            if (beat_idx >= start_beat) begin
                Bit#(12) off_in = beat_idx - start_beat;
                if (off_in[11:6] == 0 && off_in < nbeats) begin
                    payload[off_in[5:0]] = pkt_data[i];
                end
            end
        end

        // 拼接到缓冲（按字节偏移换算拍号）
        Vector#(64, Bit#(256)) new_buf = concat_buf_r;
        for (Integer i = 0; i < 64; i = i + 1) begin
            Bit#(12) dst_beat = zeroExtend(concat_offset_r[11:5]) + fromInteger(i);
            if (dst_beat < 64) begin
                new_buf[dst_beat[5:0]] = payload[i];
            end
        end

        concat_buf_r <= new_buf;
        concat_offset_r <= concat_offset_r + payload_len;

        // 如果缓冲满，输出
        if (concat_offset_r + payload_len >= 2048) begin
            output_fifo.enq(concat_buf_r);
            concat_buf_r <= replicate(0);
            concat_offset_r <= 0;
        end
    endmethod

    method ActionValue#(Vector#(64, Bit#(256))) get_payload;
        let data = output_fifo.first;
        output_fifo.deq;
        return data;
    endmethod

    method Bool has_output;
        return output_fifo.notEmpty;
    endmethod

endmodule

endpackage
