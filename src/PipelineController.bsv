// ============================================================
// PipelineController.bsv - 全局流水线编排
//
// Credit-based 流控、丢包计数、延迟测量
//
// ★ 修复内容（相对原实现）：
//   原 rx/tx/drop/latency 计数器从不更新（无任何规则写入），统计恒 0。
//   现在新增 inc_rx/inc_tx/inc_drop 方法，由 RMTTop 数据通路调用。
// ============================================================

package PipelineController;

import Vector :: *;
import FIFOF :: *;
import SpecialFIFOs :: *;
import DefaultValue :: *;
import RMTInterfaces :: *;
`include "RMTConfig.bh"

// ============================================================
//                       接口定义
// ============================================================

interface PipelineControllerIfc;
    // 信用管理
    method Action acquire_credit(Bit#(3) stage_id);
    method Action release_credit(Bit#(3) stage_id);
    method Bool has_credit(Bit#(3) stage_id);

    // 统计计数入口（★ 新增，由数据通路调用）
    method Action inc_rx;
    method Action inc_tx;
    method Action inc_drop;

    // 统计读取
    method Bit#(64) rx_count;
    method Bit#(64) tx_count;
    method Bit#(64) drop_count;
    method Bit#(32) avg_latency;

    // 流水线控制
    method Action stall;
    method Action resume;
    method Bool is_stalled;
endinterface

// ============================================================
//                       实现
// ============================================================

module mkPipelineController(PipelineControllerIfc);
    // 每级的信用计数
    Vector#(8, Reg#(Bit#(8))) credits <- replicateM(mkReg(16));  // 初始 16 个信用

    // 统计计数器
    Reg#(Bit#(64)) rx_count_r <- mkReg(0);
    Reg#(Bit#(64)) tx_count_r <- mkReg(0);
    Reg#(Bit#(64)) drop_count_r <- mkReg(0);
    Reg#(Bit#(64)) latency_sum_r <- mkReg(0);
    Reg#(Bit#(32)) pkt_processed_r <- mkReg(0);

    // 流水线状态
    Reg#(Bool) stalled_r <- mkReg(False);

    // ★ 延迟统计：周期计数 + 入口时间戳（原实现 latency_sum 从不更新 → 恒 0）
    Reg#(Bit#(32)) cyc_r       <- mkReg(0);
    Reg#(Bit#(32)) rx_stamp_r  <- mkReg(0);

    rule tick (True);
        cyc_r <= cyc_r + 1;
    endrule

    // --------------------------------------------------------
    // 接口方法
    // --------------------------------------------------------

    method Action acquire_credit(Bit#(3) stage_id);
        if (credits[stage_id] > 0) begin
            credits[stage_id] <= credits[stage_id] - 1;
        end
    endmethod

    method Action release_credit(Bit#(3) stage_id);
        credits[stage_id] <= credits[stage_id] + 1;
    endmethod

    method Bool has_credit(Bit#(3) stage_id);
        return credits[stage_id] > 0 && !stalled_r;
    endmethod

    method Action inc_rx;
        rx_count_r <= rx_count_r + 1;
        rx_stamp_r <= cyc_r;
    endmethod

    method Action inc_tx;
        tx_count_r <= tx_count_r + 1;
        latency_sum_r <= latency_sum_r + zeroExtend(cyc_r - rx_stamp_r);
        pkt_processed_r <= pkt_processed_r + 1;
    endmethod

    method Action inc_drop;
        drop_count_r <= drop_count_r + 1;
    endmethod

    method Bit#(64) rx_count;
        return rx_count_r;
    endmethod

    method Bit#(64) tx_count;
        return tx_count_r;
    endmethod

    method Bit#(64) drop_count;
        return drop_count_r;
    endmethod

    method Bit#(32) avg_latency;
        if (pkt_processed_r == 0)
            return 0;
        else
            return truncate(latency_sum_r / zeroExtend(pkt_processed_r));
    endmethod

    method Action stall;
        stalled_r <= True;
    endmethod

    method Action resume;
        stalled_r <= False;
    endmethod

    method Bool is_stalled;
        return stalled_r;
    endmethod

endmodule

endpackage
