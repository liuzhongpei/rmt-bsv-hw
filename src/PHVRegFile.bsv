// ============================================================
// PHVRegFile.bsv - 4-Bank PHV 寄存器堆（简化版）
//
// 160 字段 × 128-bit，4 个 bank 交错存储
// ============================================================

package PHVRegFile;

import Vector :: *;
import FIFOF :: *;
import SpecialFIFOs :: *;
import RMTInterfaces :: *;
import PHVBank :: *;
`include "RMTConfig.bh"

// ============================================================
//                   PHV 寄存器堆实现（简化版）
// ============================================================

module mkPHVRegFileSimple(PHVRegFileIfc);
    // 使用寄存器数组直接存储所有 160 个字段
    Vector#(160, Reg#(FieldValue)) fields_r <- replicateM(mkReg(FieldValue { value: 0, bitlen: 0 }));

    Reg#(Bit#(64)) hvalid_r <- mkReg(0);
    Reg#(Bit#(160)) dirty_r <- mkReg(0);
    Reg#(Bool) structural_r <- mkReg(False);
    Reg#(Bool) dropped_r <- mkReg(False);     // ★ ALU_DROP 丢弃标志

    Vector#(160, Reg#(FieldValue)) template_r <- replicateM(mkReg(FieldValue { value: 0, bitlen: 0 }));

    // 读响应 FIFO
    FIFOF#(FieldValue) rd_resp0_fifo <- mkFIFOF;
    FIFOF#(FieldValue) rd_resp1_fifo <- mkFIFOF;
    FIFOF#(FieldValue) rd_resp2_fifo <- mkFIFOF;
    FIFOF#(FieldValue) rd_resp3_fifo <- mkFIFOF;

    // 读端口 0（★ 索引越界防护）
    method Action read_req_0(Bit#(8) fid);
        if (fid < 160) rd_resp0_fifo.enq(fields_r[fid]);
    endmethod

    method ActionValue#(FieldValue) read_resp_0;
        rd_resp0_fifo.deq;
        return rd_resp0_fifo.first;
    endmethod

    // 读端口 1
    method Action read_req_1(Bit#(8) fid);
        if (fid < 160) rd_resp1_fifo.enq(fields_r[fid]);
    endmethod

    method ActionValue#(FieldValue) read_resp_1;
        rd_resp1_fifo.deq;
        return rd_resp1_fifo.first;
    endmethod

    // 读端口 2
    method Action read_req_2(Bit#(8) fid);
        if (fid < 160) rd_resp2_fifo.enq(fields_r[fid]);
    endmethod

    method ActionValue#(FieldValue) read_resp_2;
        rd_resp2_fifo.deq;
        return rd_resp2_fifo.first;
    endmethod

    // 读端口 3
    method Action read_req_3(Bit#(8) fid);
        if (fid < 160) rd_resp3_fifo.enq(fields_r[fid]);
    endmethod

    method ActionValue#(FieldValue) read_resp_3;
        rd_resp3_fifo.deq;
        return rd_resp3_fifo.first;
    endmethod

    // 写端口（★ 索引越界防护）
    method Action write_0(Bit#(8) fid, FieldValue val);
        if (fid < 160) begin
            fields_r[fid] <= val;
            Bit#(160) new_dirty = dirty_r;
            new_dirty[fid] = 1'b1;
            dirty_r <= new_dirty;
        end
    endmethod

    method Action write_1(Bit#(8) fid, FieldValue val);
        if (fid < 160) begin
            fields_r[fid] <= val;
            Bit#(160) new_dirty = dirty_r;
            new_dirty[fid] = 1'b1;
            dirty_r <= new_dirty;
        end
    endmethod

    method Action write_2(Bit#(8) fid, FieldValue val);
        if (fid < 160) begin
            fields_r[fid] <= val;
            Bit#(160) new_dirty = dirty_r;
            new_dirty[fid] = 1'b1;
            dirty_r <= new_dirty;
        end
    endmethod

    method Action write_3(Bit#(8) fid, FieldValue val);
        if (fid < 160) begin
            fields_r[fid] <= val;
            Bit#(160) new_dirty = dirty_r;
            new_dirty[fid] = 1'b1;
            dirty_r <= new_dirty;
        end
    endmethod

    // hvalid 操作
    method Bit#(64) get_hvalid;
        return hvalid_r;
    endmethod

    method Action set_hvalid(Bit#(64) mask);
        hvalid_r <= mask;
    endmethod

    method Action set_hdr_valid(Bit#(6) hdr_id);
        hvalid_r <= hvalid_r | (1 << hdr_id);
    endmethod

    method Action clr_hdr_valid(Bit#(6) hdr_id);
        hvalid_r <= hvalid_r & ~(1 << hdr_id);
    endmethod

    // 批量操作
    method Action reset_from_template;
        for (Integer i = 0; i < 160; i = i + 1) begin
            fields_r[i] <= template_r[i];
        end
        hvalid_r <= 0;
        dirty_r <= 0;
        dropped_r <= False;
    endmethod

    method Action load_template(Bit#(8) fid, FieldValue val);
        if (fid < 160) template_r[fid] <= val;
    endmethod

    // PHV 快照
    method PHV snapshot;
        PHV phv;
        phv.hvalid = hvalid_r;
        // ★ 修复：structural 原先硬编码 False 且 restore 不保存 → 动作置位的
        //   结构变更标志无法传播到逆解析器（VXLAN 解封装因此失效）
        phv.structural = structural_r;
        phv.has_inject = False;
        phv.dropped = dropped_r;

        Vector#(160, FieldValue) temp_fields = newVector;
        for (Integer i = 0; i < 160; i = i + 1) begin
            temp_fields[i] = fields_r[i];
        end
        phv.fields = temp_fields;
        phv.dirty = dirty_r;

        return phv;
    endmethod

    method Action restore(PHV phv);
        for (Integer i = 0; i < 160; i = i + 1) begin
            fields_r[i] <= phv.fields[i];
        end
        hvalid_r <= phv.hvalid;
        dirty_r <= phv.dirty;
        structural_r <= phv.structural;
        dropped_r <= phv.dropped;
    endmethod

endmodule

endpackage
