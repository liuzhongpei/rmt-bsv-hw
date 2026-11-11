// ============================================================
// Deparser.bsv - 头部序列化 + 有效载荷
//
// 快速路径：按脏字段位图把修改的字段补丁回原始报文
// 结构变更路径：VXLAN 解封装（按 desc.payload_offset 搬移输出内层报文）
//
// ★ 本次改造：
//   1. 字段补丁偏移改为按 phv.hvalid 推断各头部字节偏移（支持
//      Eth/IPv4/IPv6/TCP/UDP/SRH/VXLAN 任意组合），不再硬编码单一布局。
//   2. 新增结构变更路径：phv.structural && desc.payload_offset>0 →
//      从 payload_offset 起搬移内层报文输出（解封装）。
// ============================================================

package Deparser;

import Vector :: *;
import FIFOF :: *;
import SpecialFIFOs :: *;
import DefaultValue :: *;
import RMTInterfaces :: *;
`include "RMTConfig.bh"

// ============================================================
//                       状态机
// ============================================================

typedef enum {
    DEPARSE_IDLE,
    DEPARSE_BUILD,     // 组合生成输出报文
    DEPARSE_STREAM,    // 逐拍输出
    DEPARSE_DONE
} DeparserState deriving (Bits, Eq, FShow);

// ============================================================
//                       实现
// ============================================================

// 各头字节偏移（由 hvalid 推断，按标准顺序累计）
typedef struct {
    Bit#(12) ip_off;     // IP 头偏移
    Bit#(12) l4_off;     // TCP/UDP 偏移
    Bit#(12) tcp_off;    // TCP 偏移（无 TCP 时为 0）
    Bit#(12) srh_off;    // SRH 偏移
    Bit#(12) vxlan_off;  // VXLAN 偏移
    Bit#(12) ndn_off;    // NDN 偏移
    Bool     ip_is_v4;   // IPv4 还是 IPv6
} HdrOff deriving (Bits);

module mkDeparser(DeparserIfc);
    // 状态寄存器
    Reg#(DeparserState) state_r <- mkReg(DEPARSE_IDLE);
    Reg#(PktDesc) desc_r <- mkRegU;
    Reg#(PHV) phv_r <- mkRegU;
    Reg#(Vector#(64, Bit#(256))) orig_data_r <- mkRegU;
    Reg#(Vector#(64, Bit#(256))) out_data_r <- mkRegU;
    Reg#(Bit#(12)) out_len_r <- mkReg(0);
    Reg#(Bit#(7)) out_idx_r <- mkReg(0);
    Reg#(Bit#(12)) decap_off_r <- mkReg(0);   // 解封装偏移（0 = 无解封装）

    // 输出 FIFO
    FIFOF#(EthStream) output_fifo <- mkFIFOF;

    // --------------------------------------------------------
    // 辅助函数
    // --------------------------------------------------------

    // ★ 只接收所需字段（传整个 PHV 会在大函数/多次调用时放大 elaboration）
    function HdrOff compute_hdr_offsets(Bit#(64) hvalid, Bit#(4) ihl_nib,
                                        Bit#(4) doff_nib);
        Bit#(12) off = 0;
        HdrOff h;
        h.ip_off = 0; h.l4_off = 0; h.tcp_off = 0;
        h.srh_off = 0; h.vxlan_off = 0; h.ndn_off = 0; h.ip_is_v4 = False;

        if (hvalid[0] == 1'b1) off = off + 14;            // Ethernet
        if (hvalid[1] == 1'b1) begin                      // IPv4
            h.ip_off = off; h.ip_is_v4 = True;
            // ★ 按 IHL 取真实 IPv4 头长（0 = 未提取 → 20）
            Bit#(12) ihl = 20;
            if (ihl_nib != 0) begin
                ihl = zeroExtend(ihl_nib) << 2;
            end
            off = off + ihl;
        end
        if (hvalid[2] == 1'b1) begin                      // IPv6
            h.ip_off = off;
            off = off + 40;
        end
        if (hvalid[3] == 1'b1) begin                      // TCP
            h.tcp_off = off; h.l4_off = off;
            // ★ 按 data offset 取真实 TCP 头长（0 = 未提取 → 20）
            Bit#(12) doff = 20;
            if (doff_nib != 0) begin
                doff = zeroExtend(doff_nib) << 2;
            end
            off = off + doff;
        end
        if (hvalid[4] == 1'b1) begin                      // UDP
            h.l4_off = off;
            off = off + 8;
        end
        if (hvalid[5] == 1'b1) begin                      // SRH
            h.srh_off = off;
            off = off + 72;
        end
        if (hvalid[6] == 1'b1) begin                      // VXLAN
            h.vxlan_off = off;
            off = off + 8;
        end
        if (hvalid[7] == 1'b1) begin                      // NDN
            h.ndn_off = off;
            off = off + 16;
        end
        return h;
    endfunction

    // 字段在报文中的字节偏移（根据头部偏移推断）
    function Bit#(12) field_byte_offset(Bit#(8) fid, HdrOff h);
        return case (fid)
            8'd10: h.ip_off + (h.ip_is_v4 ? 12 : 8);        // IP src
            8'd11: h.ip_off + (h.ip_is_v4 ? 16 : 24);       // IP dst
            8'd20: h.l4_off;                                // sport
            8'd21: h.l4_off + 2;                            // dport
            8'd22: h.tcp_off + 4;                           // tcp seq
            8'd23: h.tcp_off + 8;                           // tcp ack
            8'd24: h.tcp_off + 13;                          // tcp flags
            8'd30: h.srh_off + 3;                           // SRH SL
            8'd31: h.srh_off + 8;                           // SID0
            8'd32: h.srh_off + 24;                          // SID1
            8'd33: h.srh_off + 40;                          // SID2
            8'd34: h.srh_off + 56;                          // SID3
            8'd35: h.srh_off + 72;                          // SID4
            8'd36: h.srh_off + 88;                          // SID5
            8'd37: h.srh_off + 104;                         // SID6
            8'd38: h.srh_off + 120;                         // SID7
            8'd40: h.vxlan_off + 2;                         // VXLAN VNI
            8'd50: h.ndn_off;                               // NDN type
            8'd51: h.ndn_off + 4;                           // NDN name_hash
            8'd52: h.ndn_off + 8;                           // NDN nonce
            8'd53: h.ndn_off + 12;                          // NDN hop_limit
            default: 12'hFFF;
        endcase;
    endfunction

    // 需要补丁的字段列表（与 field_byte_offset 支持的对应）
    // ★ 覆盖全部支持字段（19 个）：修改 sport/dport/ack/flags/SID0-7/VNI/
    //   NDN type/hop_limit 的动作均会反映到输出报文
    function Bit#(8) patch_fid(Integer k);
        return case (k)
            0:  8'd10;  1:  8'd11;             // IP src/dst
            2:  8'd20;  3:  8'd21;             // sport/dport (TCP/UDP)
            4:  8'd22;  5:  8'd23;  6: 8'd24;  // tcp seq/ack/flags
            7:  8'd30;                         // SRH SL
            8:  8'd31;  9:  8'd32; 10: 8'd33;  // SID0-2
            11: 8'd34; 12:  8'd35; 13: 8'd36;  // SID3-5
            14: 8'd37; 15:  8'd38;             // SID6-7
            16: 8'd40;                         // VXLAN VNI
            17: 8'd50; 18:  8'd53;             // NDN type / hop_limit
            default: 8'd40;                    // 不可达
        endcase;
    endfunction

    // 字段所属头部是否有效（防无头时按偏移 0 补丁破坏 Ethernet）
    function Bool field_hdr_valid(Bit#(8) fid, Bit#(64) hvalid);
        if (fid == 10 || fid == 11)
            return hvalid[1] == 1'b1 || hvalid[2] == 1'b1;        // IPv4/IPv6
        else if (fid == 20 || fid == 21)
            return hvalid[3] == 1'b1 || hvalid[4] == 1'b1;        // TCP/UDP
        else if (fid >= 22 && fid <= 24)
            return hvalid[3] == 1'b1;                             // TCP
        else if (fid >= 30 && fid <= 38)
            return hvalid[5] == 1'b1;                             // SRH
        else if (fid == 40)
            return hvalid[6] == 1'b1;                             // VXLAN
        else if (fid >= 50 && fid <= 53)
            return hvalid[7] == 1'b1;                             // NDN
        else
            return False;
    endfunction

    // ★ 单拍补丁：把所有落在第 b 拍内的脏字段字节叠加到 base 上
    //   （替代原"逐字段链式整向量重写"——后者每个补丁产生一层完整
    //     Vector#(64,Bit#(256)) 替换链，17 字段时 elaboration 内存 >24G；
    //     本实现每拍独立计算、无跨字段替换链，elaboration 开销线性）
    function Bit#(256) patch_beat(Integer b, Bit#(256) base,
                                  PHV phv, HdrOff h);
        Bit#(256) acc = base;
        for (Integer k = 0; k < 19; k = k + 1) begin
            Bit#(8) fid = patch_fid(k);
            if (phv.dirty[fid] == 1'b1 && field_hdr_valid(fid, phv.hvalid)) begin
                FieldValue fv = phv.fields[fid];
                Bit#(12) bo = field_byte_offset(fid, h);
                for (Integer j = 0; j < 4; j = j + 1) begin
                    // 只补完整字节（字段按字节对齐提取，bitlen 均为 8 的倍数；
                    // 非整字节情况跳过，避免位下越界）
                    if (fv.bitlen >= fromInteger(8*j + 8)) begin
                        Bit#(12) byte_idx = bo + fromInteger(j);
                        Bit#(7)  beat_of  = truncate(byte_idx >> 5);
                        if (beat_of == fromInteger(b)) begin
                            Bit#(8) hi   = fv.bitlen - 8'h01 - fromInteger(8*j);
                            Bit#(8) bval = fv.value[hi : hi - 7];
                            Bit#(5)  bbi = truncate(byte_idx);
                            Bit#(8)  msb = 8'hFF - (zeroExtend(bbi) * 8);
                            Bit#(256) mask = 256'hFF << (msb - 7);
                            acc = (acc & ~mask) | (zeroExtend(bval) << (msb - 7));
                        end
                    end
                end
            end
        end
        return acc;
    endfunction

    // 快速路径：把所有脏字段补丁进原始报文
    // 前 8 拍（256 字节）覆盖全部可补丁字段的最大偏移
    // （最远 = SRH SID7 @ srh_off+120 ≤ 14+40+120 = 174 字节）
    function Vector#(64, Bit#(256)) build_output(Vector#(64, Bit#(256)) orig,
                                                 PHV phv);
        HdrOff h = compute_hdr_offsets(phv.hvalid,
                                       phv.fields[14].value[3:0],
                                       phv.fields[26].value[3:0]);
        Vector#(64, Bit#(256)) d = orig;
        for (Integer b = 0; b < 8; b = b + 1) begin
            d[b] = patch_beat(b, orig[b], phv, h);
        end
        return d;
    endfunction

    // 从报文 d 的字节偏移 start 起读一拍（32 字节），对齐到 beat0
    // ★ 供解封装流式逐拍读取，避免整包移位向量的 2048 层展开（elaboration 超时）
    function Bit#(256) read_beat(Vector#(64, Bit#(256)) d, Bit#(12) start);
        Bit#(256) beat = 0;
        for (Integer j = 0; j < 32; j = j + 1) begin
            Bit#(12) b = start + fromInteger(j);
            Bit#(7)  beat_in = truncate(b >> 5);
            Bit#(5)  bbi     = truncate(b);
            Bit#(8)  msb8    = 8'hFF - (zeroExtend(bbi) * 8);
            Bit#(8)  bval    = d[beat_in][msb8 : msb8 - 7];
            Bit#(8)  omb     = 8'hFF - (fromInteger(j) * 8);
            Bit#(256) mask   = (256'hFF << (omb - 7));
            beat = (beat & ~mask) | (zeroExtend(bval) << (omb - 7));
        end
        return beat;
    endfunction

    // --------------------------------------------------------
    // 规则：组合生成输出报文
    // --------------------------------------------------------
    rule deparse_build (state_r == DEPARSE_BUILD);
        // ★ 解封装条件收紧：结构变更 + 确实解析到内层起始偏移（解析器已保证
        //   非 VXLAN 报文 payload_offset=0）+ 偏移不超过包长
        Bool decap = phv_r.structural
                  && (desc_r.payload_offset > 0)
                  && (desc_r.payload_offset < desc_r.pkt_len);

        if (decap) begin
            // ★ 结构变更 + 有内层偏移：解封装（流式逐拍从 orig_data 偏移读取）
            decap_off_r <= desc_r.payload_offset;
            out_len_r   <= desc_r.pkt_len - desc_r.payload_offset;
        end
        else begin
            // 快速路径（无结构变更）：补丁脏字段
            out_data_r <= build_output(orig_data_r, phv_r);
            out_len_r  <= desc_r.pkt_len;
            decap_off_r <= 0;
        end
        out_idx_r <= 0;
        if (desc_r.pkt_len == 0)
            state_r <= DEPARSE_DONE;
        else
            state_r <= DEPARSE_STREAM;
    endrule

    // --------------------------------------------------------
    // 规则：逐拍输出（每周期一拍，按包长）
    // --------------------------------------------------------
    rule deparse_stream (state_r == DEPARSE_STREAM);
        Bit#(12) beats = (out_len_r + 31) >> 5;
        if (out_idx_r < truncate(beats)) begin
            EthStream s;
            if (decap_off_r > 0)
                s.data = read_beat(orig_data_r, decap_off_r + (zeroExtend(out_idx_r) * 32));
            else
                s.data = out_data_r[out_idx_r];
            s.valid = True;
            s.first = (out_idx_r == 0);
            s.last  = (out_idx_r == truncate(beats - 1));
            if (s.last) begin
                // 末拍 keep 只标记剩余字节
                Bit#(12) rem = out_len_r - (zeroExtend(out_idx_r) * 32);
                Bit#(32) k = 0;
                for (Integer b = 0; b < 32; b = b + 1) begin
                    if (fromInteger(b) < rem) k[b] = 1'b1;
                end
                s.keep = k;
                state_r <= DEPARSE_DONE;
            end
            else begin
                s.keep = '1;
            end
            output_fifo.enq(s);
            out_idx_r <= out_idx_r + 1;
        end
    endrule

    // 规则：完成
    rule deparse_done (state_r == DEPARSE_DONE);
        state_r <= DEPARSE_IDLE;
    endrule

    // --------------------------------------------------------
    // 接口方法
    // --------------------------------------------------------

    method Action start(PktDesc desc, PHV phv) if (state_r == DEPARSE_IDLE);
        desc_r <= desc;
        phv_r <= phv;
        state_r <= DEPARSE_BUILD;
    endmethod

    method ActionValue#(EthStream) get_output;
        let s = output_fifo.first;
        output_fifo.deq;
        return s;
    endmethod

    method Bool busy;
        return state_r != DEPARSE_IDLE;
    endmethod

    method Action set_original_data(Vector#(64, Bit#(256)) orig);
        orig_data_r <= orig;
    endmethod

    method Action set_dirty_bitmap(Bit#(160) dirty);
        // 脏位图已由 PHV 携带（phv.dirty），此处无需单独设置
    endmethod

endmodule

endpackage
