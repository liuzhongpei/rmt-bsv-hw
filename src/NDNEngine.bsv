// ============================================================
// NDNEngine.bsv - NDN 转发引擎（内容存储 CS + 待定兴趣表 PIT）
//
// 处理 NDN 报文（解析器 hdr_id 7，hvalid[7] 有效）：
//   Interest (type=1)：
//     - CS 命中   → 本地 Data 回复（类型置 Data、IP 源/目的互换、
//                    出端口 = 入端口），通过标准逆解析补丁输出
//     - CS 未命中 → 登记 PIT（name_hash → 请求者入端口），
//                    hop_limit-1 转发；hop_limit==0 丢弃
//   Data (type=2)：
//     - PIT 命中  → 写入 CS，转发给请求者（出端口 = PIT 记录端口）
//     - PIT 未命中 → 丢弃（无等待者）
//   未知类型 → 丢弃
//
// CS/PIT 均为 name_hash 直接映射（仿真 8 项）。丢弃通过 PktDesc.dropped
// 传出，由 RMTTop 计数并拦截。
// ============================================================

package NDNEngine;

import Vector :: *;
import FIFOF :: *;
import SpecialFIFOs :: *;
import DefaultValue :: *;
import RMTInterfaces :: *;
`include "RMTConfig.bh"

// CS/PIT 容量（仿真规模）
`define NDN_CS_ENTRIES   8
`define NDN_PIT_ENTRIES  8

// NDN 包类型
`define NDN_TYPE_INTEREST 8'd1
`define NDN_TYPE_DATA     8'd2

// ============================================================
//                       接口定义
// ============================================================

interface NDNEngineIfc;
    // 数据面输入（来自 Match-Action 流水线最后一级）
    method Action insert_pkt(PktDesc desc, PHV phv,
                             Vector#(64, Bit#(256)) pkt_data);
    // 处理后输出（到 Deparser；dropped 的包由 RMTTop 拦截计数）
    method ActionValue#(Tuple3#(PktDesc, PHV, Vector#(64, Bit#(256)))) get_output;
    // 状态
    method Bool insert_ready;
    method Bool output_available;
    method Bit#(16) cs_count;
    method Bit#(16) pit_count;
endinterface

// ============================================================
//                       实现
// ============================================================

module mkNDNEngine(NDNEngineIfc);
    // CS：name_hash 直接映射，★ 存储名字哈希并比对（原实现只查 valid 位，
    // 不同名字哈希到同一槽位会误命中 → 错误本地回复）。
    // 缓存内容不做存储/拼接——回复报文由原 Interest 补丁变换生成。
    Vector#(`NDN_CS_ENTRIES, Reg#(Bool)) cs_valid <- replicateM(mkReg(False));
    Vector#(`NDN_CS_ENTRIES, Reg#(Bit#(32))) cs_name <- replicateM(mkRegU);

    // PIT：name_hash → 请求者入端口（★ 同样存储并比对名字哈希，
    // 防止不同名字的 Data 误消费他人 PIT 表项）
    Vector#(`NDN_PIT_ENTRIES, Reg#(Bool)) pit_valid <- replicateM(mkReg(False));
    Vector#(`NDN_PIT_ENTRIES, Reg#(Bit#(32))) pit_name <- replicateM(mkRegU);
    Vector#(`NDN_PIT_ENTRIES, Reg#(Bit#(10))) pit_face <- replicateM(mkReg(0));

    Reg#(Bit#(16)) cs_count_r <- mkReg(0);
    Reg#(Bit#(16)) pit_count_r <- mkReg(0);

    // 单报文处理状态机（与 TCPReorderEngine 同构）
    Reg#(Bool) busy_r <- mkReg(False);
    Reg#(PktDesc) desc_r <- mkRegU;
    Reg#(PHV) phv_r <- mkRegU;
    Reg#(Vector#(64, Bit#(256))) pkt_data_r <- mkRegU;

    FIFOF#(Tuple3#(PktDesc, PHV, Vector#(64, Bit#(256)))) output_fifo <- mkFIFOF;

    // --------------------------------------------------------
    // 规则：处理当前报文（每报文一拍）
    // --------------------------------------------------------
    rule process (busy_r);
        Bit#(32) name_hash = phv_r.fields[51].value[31:0];
        Bit#(8)  ntype     = phv_r.fields[50].value[7:0];
        Bit#(8)  hop       = phv_r.fields[53].value[7:0];
        Bit#(3)  idx       = truncate(name_hash);

        // ★ 命中 = 槽位有效 且 名字哈希匹配（防直接映射冲突误命中）
        Bool cs_hit  = cs_valid[idx]  && (cs_name[idx] == name_hash);
        Bool pit_hit = pit_valid[idx] && (pit_name[idx] == name_hash);

        PktDesc d = desc_r;
        PHV p = phv_r;

        if (ntype == `NDN_TYPE_INTEREST) begin
            if (cs_hit) begin
                // ---- CS 命中：本地 Data 回复 ----
                // NDN type 置 Data
                p.fields[50] = FieldValue { value: 128'h2, bitlen: 8 };
                p.dirty = p.dirty | (160'h1 << 50);
                // IP 源/目的互换（回复走反方向）
                FieldValue f10 = p.fields[10];
                p.fields[10]   = p.fields[11];
                p.fields[11]   = f10;
                p.dirty = p.dirty | (160'h1 << 10) | (160'h1 << 11);
                // ★ UDP 端口同步互换（NDN over UDP 的本地应答）
                FieldValue f20 = p.fields[20];
                p.fields[20]   = p.fields[21];
                p.fields[21]   = f20;
                p.dirty = p.dirty | (160'h1 << 20) | (160'h1 << 21);
                d.out_port = d.in_port;
                d.dropped = False;
            end
            else begin
                // ---- CS 未命中：登记 PIT 后转发 ----
                if (hop == 0) begin
                    d.dropped = True;   // hop 耗尽
                end
                else begin
                    // 登记/刷新 PIT（★ 记录名字哈希；不同名字同槽位时覆盖）
                    if (!pit_valid[idx]) begin
                        pit_count_r <= pit_count_r + 1;
                    end
                    pit_valid[idx] <= True;
                    pit_name[idx]  <= name_hash;
                    pit_face[idx]  <= d.in_port;
                    // hop_limit - 1（写回字段并置脏，逆解析补丁输出）
                    p.fields[53] = FieldValue {
                        value: zeroExtend(hop - 8'd1), bitlen: 8
                    };
                    p.dirty = p.dirty | (160'h1 << 53);
                    d.dropped = False;
                end
            end
        end
        else if (ntype == `NDN_TYPE_DATA) begin
            if (pit_hit) begin
                // ---- PIT 命中：写入 CS，转发给请求者 ----
                pit_valid[idx] <= False;
                pit_count_r    <= pit_count_r - 1;
                // CS 插入：新槽位计数 +1；替换不同名字的旧条目计数不变
                if (!cs_valid[idx]) begin
                    cs_count_r <= cs_count_r + 1;
                end
                cs_valid[idx] <= True;
                cs_name[idx]  <= name_hash;
                d.out_port = pit_face[idx];
                d.dropped = False;
            end
            else begin
                d.dropped = True;   // 无等待者（或名字不匹配的冲突）
            end
        end
        else begin
            d.dropped = True;       // 未知类型
        end

        output_fifo.enq(tuple3(d, p, pkt_data_r));
        busy_r <= False;
    endrule

    // --------------------------------------------------------
    // 接口方法
    // --------------------------------------------------------

    method Action insert_pkt(PktDesc desc, PHV phv,
                             Vector#(64, Bit#(256)) pkt_data) if (!busy_r);
        desc_r     <= desc;
        phv_r      <= phv;
        pkt_data_r <= pkt_data;
        busy_r     <= True;
    endmethod

    method ActionValue#(Tuple3#(PktDesc, PHV, Vector#(64, Bit#(256)))) get_output;
        let res = output_fifo.first;
        output_fifo.deq;
        return res;
    endmethod

    method Bool insert_ready;
        return !busy_r;
    endmethod

    method Bool output_available;
        return output_fifo.notEmpty;
    endmethod

    method Bit#(16) cs_count;
        return cs_count_r;
    endmethod

    method Bit#(16) pit_count;
        return pit_count_r;
    endmethod

endmodule

endpackage
