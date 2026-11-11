// ============================================================
// ProgrammableParser.bsv - 表驱动 FSM 解析器
//
// 根据解析图状态机提取头部到 PHV
// 支持 EXTRACT, EXTRACT_ARRAY, SELECT
//
// ★ 修复内容（相对原实现）：
//   1. 原 fetch_state 只发一次 read_req，但 select_next 又 read_resp →
//      响应 FIFO 空，规则永不触发（死锁）。现在 read_req/read_resp 严格配对，
//      状态配置在 load_state 读入 state_cfg_r 后由 process_ops 逐 op 处理。
//   2. 原 provide_data 不存数据（自拷贝）。改为整包向量一次写入 pkt_data_r。
//   3. 原 extract_header/get_header_size/get_field_value 是桩。现在实现真实的
//      按字节偏移从报文提取字段到局部 PHV（单规则单次写入，避免 G0004）。
// ============================================================

package ProgrammableParser;

import Vector :: *;
import FIFOF :: *;
import SpecialFIFOs :: *;
import DefaultValue :: *;
import RMTInterfaces :: *;
import ParserStateTable :: *;
`include "RMTConfig.bh"

// ============================================================
//                       状态机
// ============================================================

typedef enum {
    PARSE_IDLE,
    PARSE_FETCH_STATE,   // 发出 read_req
    PARSE_LOAD_STATE,    // 读取 read_resp 到 state_cfg_r
    PARSE_PROCESS_OPS,   // 逐 op 执行提取 + 选择下一状态
    PARSE_DONE,
    PARSE_ERROR
} ParserState deriving (Bits, Eq, FShow);

// ============================================================
//                       实现
// ============================================================

module mkProgrammableParser(ProgrammableParserIfc);
    // 子模块
    ParserStateTableIfc state_table <- mkParserStateTable;

    // --------------------------------------------------------
    // 辅助函数（必须在规则之前定义）
    // --------------------------------------------------------

    // 从报文 d 的字节偏移 off 处读取 n 字节（大端），返回右对齐 Bit#(128)
    // ★ 越界防护：off 超出 2048 字节缓冲时返回 0（原实现截断索引越界读）
    function Bit#(128) read_bytes(Vector#(64, Bit#(256)) d, Bit#(12) off, Integer n);
        Bit#(128) result = 0;
        for (Integer i = 0; i < n; i = i + 1) begin
            Bit#(12) b = off + fromInteger(i);
            Bit#(8)  bval = 0;
            if (b < 2048) begin
                Bit#(7)  beat = truncate(b >> 5);
                Bit#(5)  bbi  = truncate(b);   // 拍内字节号 0-31
                Bit#(8)  msb  = 8'hFF - (zeroExtend(bbi) * 8);  // 大端：字节0在[255:248]
                bval = d[beat][msb : msb - 7];
            end
            result = (result << 8) | zeroExtend(bval);
        end
        return result;
    endfunction

    // 各头部字节长度（与 Deparser 的布局一致）
    function Bit#(12) header_size(Bit#(6) hdr_id);
        return case (hdr_id)
            6'd0: 14;    // Ethernet
            6'd1: 20;    // IPv4
            6'd2: 40;    // IPv6
            6'd3: 20;    // TCP
            6'd4: 8;     // UDP
            6'd5: 72;    // SRH（8 + 16×4 SID，仿真固定 4 个）
            6'd6: 8;     // VXLAN
            6'd7: 16;    // NDN（固定 16B 头）
            default: 14;
        endcase;
    endfunction

    // ★ 实际头长：IPv4 用 IHL、TCP 用 data offset（支持选项头）；
    //   非法/缺省（0）时回退到默认 20 字节
    function Bit#(12) ipv4_header_size(Vector#(64, Bit#(256)) d, Bit#(12) off);
        Bit#(8) ihl = truncate(read_bytes(d, off, 1)) & 8'h0F;
        return (ihl == 0) ? 20 : (zeroExtend(ihl) << 2);
    endfunction

    function Bit#(12) tcp_header_size(Vector#(64, Bit#(256)) d, Bit#(12) off);
        Bit#(8) doff = truncate(read_bytes(d, off + 12, 1)) >> 4;
        return (doff == 0) ? 20 : (zeroExtend(doff) << 2);
    endfunction

    function Bit#(12) actual_header_size(Bit#(6) hdr_id,
                                         Vector#(64, Bit#(256)) d, Bit#(12) off);
        return case (hdr_id)
            6'd1: ipv4_header_size(d, off);
            6'd3: tcp_header_size(d, off);
            default: header_size(hdr_id);
        endcase;
    endfunction

    // 提取头部 hdr_id（位于字节偏移 off）到 PHV p，返回修改后的 p
    // 字段布局与 RMTInterfaces.build_tcp_5tuple/extract_tcp_seq 等一致：
    //   field 10/11 = src_ip/dst_ip，20/21 = sport/dport，
    //   22 = tcp.seq，23 = tcp.ack，24 = tcp.flags，
    //   12 = ipv4.ttl，13 = ipv4.total_len（DNN 特征），
    //   25 = tcp.window（DNN 特征），
    //   50 = ndn.type，51 = ndn.name_hash，52 = ndn.nonce，53 = ndn.hop_limit
    function PHV extract_into(PHV p, Bit#(6) hdr_id, Bit#(12) off,
                              Vector#(64, Bit#(256)) d);
        case (hdr_id)
            6'd0: begin
                p.hvalid = p.hvalid | (1 << 0);   // Ethernet
            end
            6'd1: begin               // IPv4
                p.fields[10] = FieldValue { value: read_bytes(d, off + 12, 4), bitlen: 32 };
                p.fields[11] = FieldValue { value: read_bytes(d, off + 16, 4), bitlen: 32 };
                p.fields[12] = FieldValue { value: read_bytes(d, off + 8,  1), bitlen: 8 };  // ttl
                p.fields[13] = FieldValue { value: read_bytes(d, off + 2,  2), bitlen: 16 }; // total_len
                // ★ IHL（字节0 低4位）：供解析器/逆解析器计算真实头长（支持选项）
                Bit#(8) b0 = truncate(read_bytes(d, off, 1));
                p.fields[14] = FieldValue { value: zeroExtend(b0[3:0]), bitlen: 4 };
                p.hvalid = p.hvalid | (1 << 1);
            end
            6'd2: begin               // IPv6
                p.fields[10] = FieldValue { value: read_bytes(d, off + 8, 4), bitlen: 32 };
                p.fields[11] = FieldValue { value: read_bytes(d, off + 24, 4), bitlen: 32 };
                p.hvalid = p.hvalid | (1 << 2);
            end
            6'd3: begin               // TCP
                p.fields[20] = FieldValue { value: read_bytes(d, off + 0, 2), bitlen: 16 };
                p.fields[21] = FieldValue { value: read_bytes(d, off + 2, 2), bitlen: 16 };
                p.fields[22] = FieldValue { value: read_bytes(d, off + 4, 4), bitlen: 32 };
                p.fields[23] = FieldValue { value: read_bytes(d, off + 8, 4), bitlen: 32 };
                p.fields[24] = FieldValue { value: read_bytes(d, off + 13, 1), bitlen: 8 };
                p.fields[25] = FieldValue { value: read_bytes(d, off + 14, 2), bitlen: 16 }; // window
                // ★ data offset（字节12 高4位）：同理支持 TCP 选项
                Bit#(8) b12 = truncate(read_bytes(d, off + 12, 1));
                p.fields[26] = FieldValue { value: zeroExtend(b12[7:4]), bitlen: 4 };
                p.hvalid = p.hvalid | (1 << 3);
            end
            6'd4: begin               // UDP
                p.fields[20] = FieldValue { value: read_bytes(d, off + 0, 2), bitlen: 16 };
                p.fields[21] = FieldValue { value: read_bytes(d, off + 2, 2), bitlen: 16 };
                p.hvalid = p.hvalid | (1 << 4);
            end
            6'd5: begin               // SRH（SRv6 段路由头）
                // SL = 字节3；SID[0..3] 取高 4 字节（与 field11"dst 首4字节"语义一致，
                // 且避免 16 字节×4 的大动态读取导致 elaboration 内存爆炸）
                p.fields[30] = FieldValue { value: read_bytes(d, off + 3, 1), bitlen: 8 };
                p.fields[31] = FieldValue { value: read_bytes(d, off + 8,  4), bitlen: 32 };
                p.fields[32] = FieldValue { value: read_bytes(d, off + 24, 4), bitlen: 32 };
                p.fields[33] = FieldValue { value: read_bytes(d, off + 40, 4), bitlen: 32 };
                p.fields[34] = FieldValue { value: read_bytes(d, off + 56, 4), bitlen: 32 };
                p.hvalid = p.hvalid | (1 << 5);
            end
            6'd6: begin               // VXLAN
                // VNI = 字节2-4（24-bit）
                p.fields[40] = FieldValue { value: read_bytes(d, off + 2, 3), bitlen: 24 };
                p.hvalid = p.hvalid | (1 << 6);
            end
            6'd7: begin               // NDN（固定 16B 头）
                // type@0(1B) name_hash@4(4B) nonce@8(4B) hop_limit@12(1B)
                p.fields[50] = FieldValue { value: read_bytes(d, off + 0,  1), bitlen: 8 };
                p.fields[51] = FieldValue { value: read_bytes(d, off + 4,  4), bitlen: 32 };
                p.fields[52] = FieldValue { value: read_bytes(d, off + 8,  4), bitlen: 32 };
                p.fields[53] = FieldValue { value: read_bytes(d, off + 12, 1), bitlen: 8 };
                p.hvalid = p.hvalid | (1 << 7);
            end
            default: begin
                p.hvalid = p.hvalid | (64'h1 << hdr_id);
            end
        endcase
        return p;
    endfunction

    // 从构建中的 PHV 读取字段低 64 位
    function Bit#(64) field_value(PHV p, Bit#(8) field_id);
        return p.fields[field_id].value[63:0];
    endfunction

    // --------------------------------------------------------
    // 状态寄存器
    // --------------------------------------------------------
    Reg#(ParserState) state_r <- mkReg(PARSE_IDLE);
    Reg#(Bit#(5)) current_state_r <- mkReg(0);  // 当前解析状态
    Reg#(Bit#(5)) start_state_r <- mkReg(0);
    Reg#(PktDesc) desc_r <- mkRegU;
    Reg#(Bool) accept_r <- mkReg(False);
    Reg#(Bool) data_ready_r <- mkReg(False);

    // 报文数据缓冲（整包）
    Reg#(Vector#(64, Bit#(256))) pkt_data_r <- mkRegU;
    Reg#(Bit#(12)) byte_offset_r <- mkReg(0);
    // ★ VXLAN 内层起始偏移（提取 VXLAN 头后记录，供逆解析解封装用）
    Reg#(Bit#(12)) payload_offset_r <- mkReg(0);

    // 当前解析状态配置（由 load_state 从 read_resp 读入）
    Reg#(ParseState) state_cfg_r <- mkRegU;
    // 操作计数
    Reg#(Bit#(3)) op_idx_r <- mkReg(0);

    // 构建中的 PHV（每包重置为默认值，逐 op 累积）
    Reg#(PHV) phv_build_r <- mkReg(defaultValue);

    // 结果 FIFO
    FIFOF#(Tuple2#(PktDesc, Bool)) result_fifo <- mkFIFOF;

    // --------------------------------------------------------
    // 规则：状态机
    // --------------------------------------------------------

    // 规则：取解析状态配置（发 read_req）
    rule fetch_state (state_r == PARSE_FETCH_STATE && data_ready_r);
        state_table.read_req(current_state_r);
        state_r <= PARSE_LOAD_STATE;
    endrule

    // 规则：读取状态配置（消费 read_resp，与 fetch_state 的 read_req 配对）
    rule load_cfg (state_r == PARSE_LOAD_STATE);
        let st <- state_table.read_resp;
        state_cfg_r <= st;
        op_idx_r <= 0;
        state_r <= PARSE_PROCESS_OPS;
    endrule

    // 规则：逐 op 执行（每周期一个 op，单次写入各寄存器）
    rule process_ops (state_r == PARSE_PROCESS_OPS);
        if (current_state_r == 5'h1F) begin   // PS_ACCEPT
            accept_r <= True;
            state_r <= PARSE_DONE;
        end
        // ★ nops 为 3 bit（0-7）而 ops 只有 4 项：同时限制 op 索引，防越界
        else if (op_idx_r < state_cfg_r.nops && op_idx_r < 4) begin
            // 执行当前 op
            let op = state_cfg_r.ops[op_idx_r];
            PHV p = phv_build_r;
            Bit#(12) off = byte_offset_r;

            case (op.kind)
                POP_EXTRACT: begin
                    p   = extract_into(p, op.hdr_id, off, pkt_data_r);
                    off = off + actual_header_size(op.hdr_id, pkt_data_r, off);
                end
                POP_EXTRACT_ARRAY: begin
                    // 简化：提取一个实例（原实现的循环多写会触发 G0004）
                    p   = extract_into(p, op.hdr_id, off, pkt_data_r);
                    off = off + actual_header_size(op.hdr_id, pkt_data_r, off);
                end
            endcase

            phv_build_r <= p;
            byte_offset_r <= off;
            // ★ 提取 VXLAN 头后：记录该头结束偏移 = 内层报文起始
            if (op.hdr_id == 6) begin
                payload_offset_r <= off;
            end
            op_idx_r <= op_idx_r + 1;
        end
        else begin
            // 本状态所有 op 执行完：选择下一状态
            Bit#(5) next_state = state_cfg_r.def_next;
            if (state_cfg_r.sel_field != 8'hFF) begin
                let sel_val = field_value(phv_build_r, state_cfg_r.sel_field);
                for (Integer i = 0; i < 16; i = i + 1) begin
                    if (fromInteger(i) < state_cfg_r.ncases) begin
                        if (sel_val == state_cfg_r.cases[i].sel_val) begin
                            next_state = state_cfg_r.cases[i].next_state;
                        end
                    end
                end
            end

            current_state_r <= next_state;
            op_idx_r <= 0;
            if (next_state == 5'h1F) begin   // PS_ACCEPT
                accept_r <= True;
                state_r <= PARSE_DONE;
            end
            else begin
                state_r <= PARSE_FETCH_STATE;
            end
        end
    endrule

    // 规则：解析完成（单次写 desc_r，避免 G0004 多写冲突）
    rule parse_done (state_r == PARSE_DONE);
        PktDesc d = desc_r;
        d.hdr_bytes = byte_offset_r;
        d.payload_offset = payload_offset_r;
        // ★ 标记 TCP 报文（TCP 头有效位 = hdr_id 3），TCP 重组引擎据此
        //   对非 TCP 流量直接旁路，避免 UDP 等借用 5 元组字段误入会话表
        d.is_tcp = (phv_build_r.hvalid[3] == 1'b1);
        desc_r <= d;
        result_fifo.enq(tuple2(d, accept_r));
        data_ready_r <= False;
        state_r <= PARSE_IDLE;
    endrule

    // --------------------------------------------------------
    // 接口方法
    // --------------------------------------------------------

    method Action start(PktDesc desc) if (state_r == PARSE_IDLE);
        desc_r <= desc;
        current_state_r <= start_state_r;
        byte_offset_r <= 0;
        accept_r <= False;
        op_idx_r <= 0;
        // ★ 复位 VXLAN 内层偏移：原实现不复位 → 上一包的 payload_offset
        //   泄漏到下一个包，逆解析会错误解封装
        payload_offset_r <= 0;
        phv_build_r <= defaultValue;
        state_r <= PARSE_FETCH_STATE;
    endmethod

    method Action provide_data(Vector#(64, Bit#(256)) data) if (!data_ready_r);
        pkt_data_r <= data;
        data_ready_r <= True;
    endmethod

    method ActionValue#(Tuple2#(PktDesc, Bool)) result;
        let res = result_fifo.first;
        result_fifo.deq;
        return res;
    endmethod

    method Action load_state(Bit#(5) idx, ParseState st);
        state_table.write(idx, st);
    endmethod

    method Action set_start_state(Bit#(5) state);
        start_state_r <= state;
    endmethod

    method PHV get_phv;
        return phv_build_r;
    endmethod

endmodule

endpackage
