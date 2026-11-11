// ============================================================
// RMTTop.bsv - RMT BSV 硬件流水线顶层模块
//
// 集成所有子模块：Parser → Stages → TCP Reorder → Deparser → TX
// 100G 以太网接口（AXI-Stream）
//
// ★ 修复内容（相对原实现）：
//   1. staging_r 从未置 True → Match-Action 级永不执行。改为完整的
//      PIPE_ACQUIRE→MATCH_REQ→MATCH_RESP→ACTION_START→ACTION_DONE 状态机，
//      lookup_req/lookup_resp、action start/done 分拍调用（消除同规则
//      方法往返的死锁）。
//   2. tx_packet 把输出回环到 pkt_buf.rx_data，且 egress_pkt 无人调用
//      → TX 路径恒空。改为收集逆解析输出后调 pkt_buf.egress_pkt，
//      tx_data 从 pkt_buf 读取。
//   3. parser.provide_data 旧接口按拍传数据（单规则 64 次调用触发 G0004），
//      改为整包向量一次传入（配合新 ProgrammableParserIfc）。
// ============================================================

package RMTTop;

import Vector :: *;
import FIFOF :: *;
import SpecialFIFOs :: *;
import GetPut :: *;
import DefaultValue :: *;
import RMTInterfaces :: *;
import PacketBuffer :: *;
import ProgrammableParser :: *;
import PHVRegFile :: *;
import MatchEngine :: *;
import ActionEngine :: *;
import TCPReorderEngine :: *;
import NDNEngine :: *;
import Deparser :: *;
import PipelineController :: *;
import ControlPlane :: *;
`include "RMTConfig.bh"

// ============================================================
//                       顶层接口
// ============================================================

interface RMTTopIfc;
    // 100G 以太网 RX（AXI-Stream Slave）
    method Action rx_data(EthStream s);

    // 100G 以太网 TX（AXI-Stream Master）
    method ActionValue#(EthStream) tx_data;

    // 控制面接口
    method Action axi_write(Bit#(32) addr, Bit#(64) data);
    method ActionValue#(Bit#(64)) axi_read(Bit#(32) addr);

    // ★ 配置入口（控制面/测试台配置解析图、匹配表、动作微码）
    method Action config_parser(Bit#(5) idx, ParseState st);
    method Action set_start_state(Bit#(5) s);
    method Action config_table(Bit#(4) tidx, TableConfig cfg);
    method Action insert_entry(Bit#(4) tidx, TCAMEntry e);
    method Action load_action(Bit#(3) stage, Bit#(5) aidx, ActionProgram p);

    // 状态
    method Bit#(64) get_rx_count;
    method Bit#(64) get_tx_count;
    method Bit#(64) get_drop_count;
    method Bit#(16) get_tcp_sessions;
    method Bit#(16) get_ndn_cs_entries;
    method Bit#(16) get_ndn_pit_entries;

    // ★ DNN 权重加载（广播到全部 4 级引擎）
    method Action load_dnn_weight(Bit#(4) idx, Bit#(32) w);

    // ★ 命中动作参数装载（engine=物理级，idx=SRAM 表项槽位，pidx=参数号）
    method Action load_entry_params(Bit#(4) engine, Bit#(8) idx,
                                    Bit#(4) pidx, Bit#(64) val);

    // ★ 控制面预建 TCP 会话（带初始 expected_seq）
    method Action create_tcp_session(TCP5Tuple key, Bit#(32) init_seq);
endinterface

// ============================================================
//                       顶层实现
// ============================================================

// Match-Action 流水线阶段状态
typedef enum {
    PIPE_ACQUIRE,     // 从 stage_to_tcp_fifo 取报文
    PIPE_MATCH_REQ,   // 发 lookup_req
    PIPE_MATCH_RESP,  // 收 lookup_resp
    PIPE_ACTION_START,// 发 action start
    PIPE_ACTION_DONE  // 收 action done，推进或完成
} PipePhase deriving (Bits, Eq);

module mkRMTTop(RMTTopIfc);
    // --------------------------------------------------------
    // 子模块实例化
    // --------------------------------------------------------
    PacketBufferIfc pkt_buf <- mkPacketBuffer;
    ProgrammableParserIfc parser <- mkProgrammableParser;

    // 4 级 Match-Action 流水线（每级 MatchEngine + ActionEngine）
    Vector#(4, MatchEngineIfc)  match_engines  <- replicateM(mkMatchEngine);
    Vector#(4, ActionEngineIfc) action_engines <- replicateM(mkActionEngine);

    TCPReorderEngineIfc tcp_reorder <- mkTCPReorderEngine;
    NDNEngineIfc ndn_engine <- mkNDNEngine;
    DeparserIfc deparser <- mkDeparser;
    PipelineControllerIfc pipeline_ctrl <- mkPipelineController;
    ControlPlaneIfc ctrl_plane <- mkControlPlane;

    // --------------------------------------------------------
    // 内部 FIFO（级间连接）
    // --------------------------------------------------------
    FIFOF#(Tuple2#(PktDesc, Vector#(64, Bit#(256)))) parser_to_stage_fifo <- mkFIFOF;
    FIFOF#(Tuple3#(PktDesc, PHV, Vector#(64, Bit#(256)))) stage_to_tcp_fifo <- mkFIFOF;
    FIFOF#(Tuple3#(PktDesc, PHV, Vector#(64, Bit#(256)))) tcp_to_deparse_fifo <- mkFIFOF;

    // --------------------------------------------------------
    // 解析状态
    // --------------------------------------------------------
    Reg#(Bool) parsing_r <- mkReg(False);
    Reg#(Vector#(64, Bit#(256))) cur_pkt_data_r <- mkRegU;   // 当前解析的报文数据

    // --------------------------------------------------------
    // Match-Action 流水线状态机
    // --------------------------------------------------------
    Reg#(PipePhase) pipe_phase_r <- mkReg(PIPE_ACQUIRE);
    Reg#(Bool) staging_busy_r <- mkReg(False);
    Reg#(Bit#(3)) stage_idx_r <- mkReg(0);
    Reg#(PktDesc) cur_desc_r <- mkRegU;
    Reg#(PHV) cur_phv_r <- mkRegU;
    Reg#(Vector#(64, Bit#(256))) cur_pipe_data_r <- mkRegU;
    Reg#(MatchResult) match_result_r <- mkReg(defaultMR);

    // ★ 各引擎的匹配响应 / 动作完成信号收集（固定索引 drain 规则 →
    //   管道只操作本地 FIFO，规避"数组接口上带守卫方法"的调度陷阱）
    FIFOF#(Tuple2#(Bit#(3), MatchResult)) match_resp_fifo <- mkFIFOF;
    FIFOF#(Bit#(3)) action_done_fifo <- mkFIFOF;

    // --------------------------------------------------------
    // 逆解析 / TX 状态
    // --------------------------------------------------------
    Reg#(Bit#(7)) tx_beat_r <- mkReg(0);
    Reg#(Vector#(64, Bit#(256))) tx_buf_r <- mkRegU;
    Reg#(Bit#(12)) tx_pkt_len_r <- mkReg(0);

    // 统计 keep 中有效字节数（0-32）
    function Bit#(6) count_ones(Bit#(32) x);
        Bit#(6) n = 0;
        for (Integer i = 0; i < 32; i = i + 1) begin
            if (x[i] == 1) n = n + 1;
        end
        return n;
    endfunction

    // --------------------------------------------------------
    // 规则：接收报文（PacketBuffer → 解析器）
    // --------------------------------------------------------
    rule rx_packet (pkt_buf.rx_ready);
        let pkt <- pkt_buf.ingress_pkt;
        parser_to_stage_fifo.enq(pkt);
        pipeline_ctrl.inc_rx;
    endrule

    // --------------------------------------------------------
    // 规则：解析报文（整包数据一次传入）
    // --------------------------------------------------------
    rule parse_packet (!parsing_r && parser_to_stage_fifo.notEmpty);
        let e = parser_to_stage_fifo.first;
        parser_to_stage_fifo.deq;
        let desc = tpl_1(e);
        let pkt_data = tpl_2(e);
        cur_pkt_data_r <= pkt_data;
        parser.start(desc);
        parser.provide_data(pkt_data);
        parsing_r <= True;
    endrule

    // 规则：解析完成
    rule parse_done (parsing_r);
        let parse_result <- parser.result;
        let desc = tpl_1(parse_result);
        let accept = tpl_2(parse_result);
        if (accept) begin
            let phv = parser.get_phv;
            stage_to_tcp_fifo.enq(tuple3(desc, phv, cur_pkt_data_r));
        end
        else begin
            pipeline_ctrl.inc_drop;
        end
        parsing_r <= False;
    endrule

    // --------------------------------------------------------
    // 规则：Match-Action 流水线状态机
    // --------------------------------------------------------

    // 取报文进入流水线
    rule pipe_acquire (pipe_phase_r == PIPE_ACQUIRE && !staging_busy_r
                       && stage_to_tcp_fifo.notEmpty);
        let e = stage_to_tcp_fifo.first;
        stage_to_tcp_fifo.deq;
        cur_desc_r <= tpl_1(e);
        cur_phv_r <= tpl_2(e);
        cur_pipe_data_r <= tpl_3(e);
        staging_busy_r <= True;
        stage_idx_r <= 0;
        pipe_phase_r <= PIPE_MATCH_REQ;
    endrule

    // 发匹配请求（lookup_req 守卫为 IDLE，各引擎初始/完成后均 IDLE，可安全分派）
    rule pipe_match_req (pipe_phase_r == PIPE_MATCH_REQ);
        case (stage_idx_r)
            3'd0: match_engines[0].lookup_req(0, cur_phv_r);
            3'd1: match_engines[1].lookup_req(0, cur_phv_r);
            3'd2: match_engines[2].lookup_req(0, cur_phv_r);
            default: match_engines[3].lookup_req(0, cur_phv_r);
        endcase
        pipe_phase_r <= PIPE_MATCH_RESP;
    endrule

    // 收匹配结果（从本地收集 FIFO 读，按 stage 匹配）
    rule pipe_match_resp (pipe_phase_r == PIPE_MATCH_RESP
                          && match_resp_fifo.notEmpty
                          && tpl_1(match_resp_fifo.first) == stage_idx_r);
        let e = match_resp_fifo.first;
        match_resp_fifo.deq;
        let mr = tpl_2(e);
        match_result_r <= mr;
        pipe_phase_r <= PIPE_ACTION_START;
    endrule

    // 启动动作（★ 先把当前报文的 PHV 载入引擎，动作才在真实字段上运算；
    //   ★ 动作参数取匹配结果 params（命中=表项参数，未命中=默认动作参数），
    //     原来恒传 replicate(0) → use_param 微码与 def_params 全部失效）
    rule pipe_action_start (pipe_phase_r == PIPE_ACTION_START);
        case (stage_idx_r)
            3'd0: action_engines[0].phv.restore(cur_phv_r);
            3'd1: action_engines[1].phv.restore(cur_phv_r);
            3'd2: action_engines[2].phv.restore(cur_phv_r);
            default: action_engines[3].phv.restore(cur_phv_r);
        endcase
        case (stage_idx_r)
            3'd0: action_engines[0].start(match_result_r.action_id, match_result_r.params);
            3'd1: action_engines[1].start(match_result_r.action_id, match_result_r.params);
            3'd2: action_engines[2].start(match_result_r.action_id, match_result_r.params);
            default: action_engines[3].start(match_result_r.action_id, match_result_r.params);
        endcase
        pipe_phase_r <= PIPE_ACTION_DONE;
    endrule

    // 动作完成：从本地收集 FIFO 读，推进到下一级或进入后端引擎
    rule pipe_action_done (pipe_phase_r == PIPE_ACTION_DONE
                           && action_done_fifo.notEmpty
                           && action_done_fifo.first == stage_idx_r);
        action_done_fifo.deq;
        PHV phv_new;
        case (stage_idx_r)
            3'd0: phv_new = action_engines[0].phv.snapshot;
            3'd1: phv_new = action_engines[1].phv.snapshot;
            3'd2: phv_new = action_engines[2].phv.snapshot;
            default: phv_new = action_engines[3].phv.snapshot;
        endcase
        if (stage_idx_r == 3) begin
            // 最后一级：按类型分流到后端引擎
            if (phv_new.dropped) begin
                // ★ 动作丢弃（如 DNN 分类为攻击流量）
                pipeline_ctrl.inc_drop;
            end
            else if (phv_new.hvalid[7] == 1'b1) begin
                // ★ NDN 报文：进入 NDN 转发引擎（CS/PIT）
                ndn_engine.insert_pkt(cur_desc_r, phv_new, cur_pipe_data_r);
            end
            else begin
                // TCP/其他报文：进入 TCP 重组
                tcp_reorder.insert_pkt(cur_desc_r, phv_new, cur_pipe_data_r);
            end
            staging_busy_r <= False;
            stage_idx_r <= 0;
            pipe_phase_r <= PIPE_ACQUIRE;
        end
        else begin
            cur_phv_r <= phv_new;
            stage_idx_r <= stage_idx_r + 1;
            pipe_phase_r <= PIPE_MATCH_REQ;
        end
    endrule

    // --------------------------------------------------------
    // 规则：TCP 重组输出 → 逆解析
    // --------------------------------------------------------
    rule tcp_output (tcp_reorder.output_available);
        let tcp_result <- tcp_reorder.get_reassembled;
        tcp_to_deparse_fifo.enq(tcp_result);
    endrule

    // --------------------------------------------------------
    // 规则：NDN 引擎输出 → 逆解析（丢弃的包拦截计数）
    // --------------------------------------------------------
    rule ndn_output (ndn_engine.output_available);
        let r <- ndn_engine.get_output;
        if (!tpl_1(r).dropped) begin
            tcp_to_deparse_fifo.enq(r);
        end
        else begin
            pipeline_ctrl.inc_drop;
        end
    endrule

    // --------------------------------------------------------
    // 规则：逆解析
    // --------------------------------------------------------
    rule deparse_packet (!deparser.busy && tcp_to_deparse_fifo.notEmpty);
        let e = tcp_to_deparse_fifo.first;
        tcp_to_deparse_fifo.deq;
        let desc = tpl_1(e);
        let phv = tpl_2(e);
        let pkt_data = tpl_3(e);
        deparser.set_original_data(pkt_data);
        deparser.start(desc, phv);
    endrule

    // --------------------------------------------------------
    // 规则：TX —— 收集逆解析输出拍，整包交给 egress（不再回环到 RX）
    // --------------------------------------------------------
    rule tx_collect (deparser.busy);
        let s <- deparser.get_output;
        // 先落寄存器（供后续拍使用）
        tx_buf_r[tx_beat_r] <= s.data;
        if (s.last) begin
            // ★ 末拍数据当拍写入寄存器不可见，必须在局部向量里补上再交给 egress
            Vector#(64, Bit#(256)) final_buf = tx_buf_r;
            final_buf[tx_beat_r] = s.data;

            PktDesc od = defaultValue;
            // 长度 = 本拍前拍数×32 + 末拍 keep 有效字节数
            od.pkt_len = (zeroExtend(tx_beat_r) << 5) + zeroExtend(count_ones(s.keep));
            pkt_buf.egress_pkt(tuple2(od, final_buf));
            pipeline_ctrl.inc_tx;
            tx_beat_r <= 0;
        end
        else begin
            tx_beat_r <= tx_beat_r + 1;
        end
    endrule

    // --------------------------------------------------------
    // 规则：控制面配置通路（原 RMTTop 从不消费这些 FIFO，控制面无法触达数据面）
    // --------------------------------------------------------
    // ★ 控制面下发的索引是"物理级/引擎号"，表固定为 0（流水线只查表 0）；
    //   原实现把表号当引擎号、把动作号当引擎号 → 表项永远查不到 / 越界
    rule cp_table_insert;
        let e <- ctrl_plane.table_insert.get;
        if (tpl_1(e) < 4) begin
            match_engines[tpl_1(e)[1:0]].insert_entry(0, tpl_2(e));
        end
    endrule

    rule cp_table_delete;
        let e <- ctrl_plane.table_delete.get;
        if (tpl_1(e) < 4) begin
            match_engines[tpl_1(e)[1:0]].delete_entry(0, tpl_2(e));
        end
    endrule

    rule cp_action_load;
        let e <- ctrl_plane.action_load.get;
        action_engines[tpl_1(e)].load_action(tpl_2(e), tpl_3(e));
    endrule

    rule cp_tcp_create;
        let e <- ctrl_plane.tcp_session_create.get;
        tcp_reorder.create_session(tpl_1(e), tpl_2(e));
    endrule

    rule cp_tcp_delete;
        let k <- ctrl_plane.tcp_session_delete.get;
        tcp_reorder.delete_session(k);
    endrule

    // ★ PHV 模板设定：广播到各级引擎（原 FIFO 无人消费 → 堆满后控制面卡死）
    rule cp_phv_template;
        let e <- ctrl_plane.phv_template_set.get;
        action_engines[0].phv.load_template(tpl_1(e), tpl_2(e));
        action_engines[1].phv.load_template(tpl_1(e), tpl_2(e));
        action_engines[2].phv.load_template(tpl_1(e), tpl_2(e));
        action_engines[3].phv.load_template(tpl_1(e), tpl_2(e));
    endrule

    // --------------------------------------------------------
    // 规则：匹配响应 / 动作完成收集（固定索引，无守卫歧义）
    // --------------------------------------------------------
    rule drain_m0;
        let mr <- match_engines[0].lookup_resp;
        match_resp_fifo.enq(tuple2(3'd0, mr));
    endrule
    rule drain_m1;
        let mr <- match_engines[1].lookup_resp;
        match_resp_fifo.enq(tuple2(3'd1, mr));
    endrule
    rule drain_m2;
        let mr <- match_engines[2].lookup_resp;
        match_resp_fifo.enq(tuple2(3'd2, mr));
    endrule
    rule drain_m3;
        let mr <- match_engines[3].lookup_resp;
        match_resp_fifo.enq(tuple2(3'd3, mr));
    endrule

    rule drain_a0;
        let d <- action_engines[0].done;
        action_done_fifo.enq(3'd0);
    endrule
    rule drain_a1;
        let d <- action_engines[1].done;
        action_done_fifo.enq(3'd1);
    endrule
    rule drain_a2;
        let d <- action_engines[2].done;
        action_done_fifo.enq(3'd2);
    endrule
    rule drain_a3;
        let d <- action_engines[3].done;
        action_done_fifo.enq(3'd3);
    endrule

    // --------------------------------------------------------
    // 接口方法
    // --------------------------------------------------------

    method Action rx_data(EthStream s);
        pkt_buf.rx_data(s);
    endmethod

    method ActionValue#(EthStream) tx_data;
        let result <- pkt_buf.tx_data;
        return result;
    endmethod

    method Action config_parser(Bit#(5) idx, ParseState st);
        parser.load_state(idx, st);
    endmethod

    method Action set_start_state(Bit#(5) s);
        parser.set_start_state(s);
    endmethod

    method Action config_table(Bit#(4) tidx, TableConfig cfg);
        // ★ 流水线所有级都查表 0，因此配置固定落到各引擎的表 0
        //   （tidx = 物理级 0-3；越界不动作）
        if (tidx < 4) begin
            match_engines[tidx[1:0]].config_table(0, cfg);
        end
    endmethod

    method Action insert_entry(Bit#(4) tidx, TCAMEntry e);
        if (tidx < 4) begin
            match_engines[tidx[1:0]].insert_entry(0, e);
        end
    endmethod

    method Action load_action(Bit#(3) stage, Bit#(5) aidx, ActionProgram p);
        if (stage < 4) begin
            action_engines[stage[1:0]].load_action(aidx, p);
        end
    endmethod

    method Action axi_write(Bit#(32) addr, Bit#(64) data);
        ctrl_plane.axi_write(addr, data);
    endmethod

    method ActionValue#(Bit#(64)) axi_read(Bit#(32) addr);
        // ★ 状态寄存器直读数据面真实计数（ControlPlane 内部计数器从不被
        //   数据面更新，原经它读恒 0）
        return case (addr[15:12])
            4'hA: pipeline_ctrl.rx_count;
            4'hB: pipeline_ctrl.tx_count;
            4'hC: pipeline_ctrl.drop_count;
            4'hD: zeroExtend(tcp_reorder.active_sessions);
            4'hE: zeroExtend(ndn_engine.cs_count);
            4'hF: zeroExtend(ndn_engine.pit_count);
            default: 0;
        endcase;
    endmethod

    method Bit#(64) get_rx_count;
        return pipeline_ctrl.rx_count;
    endmethod

    method Bit#(64) get_tx_count;
        return pipeline_ctrl.tx_count;
    endmethod

    method Bit#(64) get_drop_count;
        return pipeline_ctrl.drop_count;
    endmethod

    method Bit#(16) get_tcp_sessions;
        return tcp_reorder.active_sessions;
    endmethod

    method Bit#(16) get_ndn_cs_entries;
        return ndn_engine.cs_count;
    endmethod

    method Bit#(16) get_ndn_pit_entries;
        return ndn_engine.pit_count;
    endmethod

    method Action load_dnn_weight(Bit#(4) idx, Bit#(32) w);
        action_engines[0].load_dnn_weight(idx, w);
        action_engines[1].load_dnn_weight(idx, w);
        action_engines[2].load_dnn_weight(idx, w);
        action_engines[3].load_dnn_weight(idx, w);
    endmethod

    method Action load_entry_params(Bit#(4) engine, Bit#(8) idx,
                                    Bit#(4) pidx, Bit#(64) val);
        if (engine < 4) begin
            case (engine[1:0])
                2'd0: match_engines[0].load_param(0, idx, pidx, val);
                2'd1: match_engines[1].load_param(0, idx, pidx, val);
                2'd2: match_engines[2].load_param(0, idx, pidx, val);
                default: match_engines[3].load_param(0, idx, pidx, val);
            endcase
        end
    endmethod

    method Action create_tcp_session(TCP5Tuple key, Bit#(32) init_seq);
        tcp_reorder.create_session(key, init_seq);
    endmethod

endmodule

// ============================================================
//                       仿真顶层（真实端到端测试）
// ★ 原测试台是桩：不注入报文、只打印 0 计数 → "通过"无验证意义。
//   现在：配置解析图/匹配表/动作 → 注入真实 54B TCP 包 →
//   取回 TX 输出逐字节比对（NOP 动作 + 无脏字段 → 应原样输出）。
// ============================================================

module mkTestbenchTop(Empty);
    RMTTopIfc dut <- mkRMTTop;

    Reg#(Bit#(32)) st <- mkReg(0);
    Reg#(Bit#(32)) err <- mkReg(0);
    Reg#(Bit#(4)) cfg_tbl_r <- mkReg(0);   // 表配置计数
    Reg#(Bit#(3)) act_cnt_r <- mkReg(0);   // 动作加载计数
    Reg#(Bit#(256)) out_b0_r <- mkReg(0);
    Reg#(Bit#(256)) out_b1_r <- mkReg(0);
    Reg#(Bit#(32)) cy <- mkReg(0);

    // 周期计数 + 看门狗（流水线若死锁则报超时退出，避免无限挂起）
    rule tick (True);
        cy <= cy + 1;
    endrule

    rule watchdog (cy > 500 && st < 10);
        $display("E2E TIMEOUT at cy=%d st=%d tx=%d tcp_sessions=%d",
                 cy, st, dut.get_tx_count, dut.get_tcp_sessions);
        $finish(0);
    endrule

    // 读取输出报文字节 off（0-31 内）
    function Bit#(8) pkt_byte(Bit#(256) beat, Integer off);
        Bit#(8) msb = 8'hFF - (fromInteger(off) * 8);
        return beat[msb : msb - 7];
    endfunction

    // 构造 54B TCP SYN 包的两个 beat
    function Tuple2#(Bit#(256), Bit#(256)) make_pkt;
        Vector#(64, Bit#(8)) byt = replicate(0);
        byt[26] = 8'h0A; byt[27] = 8'h00; byt[28] = 8'h00; byt[29] = 8'h01; // src_ip
        byt[30] = 8'h0A; byt[31] = 8'h00; byt[32] = 8'h00; byt[33] = 8'h02; // dst_ip
        byt[34] = 8'hC3; byt[35] = 8'h50;  // sport=50000
        byt[36] = 8'h00; byt[37] = 8'h50;  // dport=80
        byt[38] = 8'h00; byt[39] = 8'h00; byt[40] = 8'h03; byt[41] = 8'hE8; // seq
        byt[42] = 8'h00; byt[43] = 8'h00; byt[44] = 8'h00; byt[45] = 8'h00; // ack
        byt[47] = 8'h02;  // flags=SYN
        Bit#(256) b0 = 0;
        for (Integer i = 0; i < 32; i = i + 1) begin
            b0 = (b0 << 8) | zeroExtend(byt[i]);
        end
        Bit#(256) b1 = 0;
        for (Integer i = 0; i < 32; i = i + 1) begin
            b1 = (b1 << 8) | zeroExtend(byt[32 + i]);
        end
        return tuple2(b0, b1);
    endfunction

    // ---- 配置：解析器状态 0（Eth+IPv4 → 状态1） ----
    rule cfg_parser0 (st == 0);
        ParseState s0;
        s0.name_id = 0;
        s0.ops = newVector;
        ParseOp o0;
        o0.kind = POP_EXTRACT; o0.hdr_id = 0; o0.count_field = 0; o0.count_add = 0;
        ParseOp o1;
        o1.kind = POP_EXTRACT; o1.hdr_id = 1; o1.count_field = 0; o1.count_add = 0;
        s0.ops[0] = o0; s0.ops[1] = o1;
        s0.nops = 2;
        s0.sel_field = 8'hFF;
        s0.cases = replicate(SelCase { sel_val: 0, next_state: 0 });
        s0.ncases = 0;
        s0.def_next = 1;
        dut.config_parser(0, s0);
        st <= 1;
    endrule

    // ---- 配置：解析器状态 1（TCP → ACCEPT） ----
    rule cfg_parser1 (st == 1);
        ParseState s1;
        s1.name_id = 0;
        s1.ops = newVector;
        ParseOp o3;
        o3.kind = POP_EXTRACT; o3.hdr_id = 3; o3.count_field = 0; o3.count_add = 0;
        s1.ops[0] = o3;
        s1.nops = 1;
        s1.sel_field = 8'hFF;
        s1.cases = replicate(SelCase { sel_val: 0, next_state: 0 });
        s1.ncases = 0;
        s1.def_next = 5'h1F;   // ACCEPT
        dut.config_parser(1, s1);
        st <= 2;
    endrule

    rule cfg_start (st == 2);
        dut.set_start_state(0);
        st <= 3;
    endrule

    // 构造单槽位动作程序（供测试台使用）
    function ActionProgram mk_prog(ALUOpcode op, Bit#(8) fd, Bit#(8) fs1, Bit#(64) imm);
        ActionProgram p;
        p.action_id = 0;
        p.nparams = 0;
        p.prog = newVector;
        VLIWWord w0 = newVector;
        ALUInsn insn;
        insn.op = op; insn.fd = fd; insn.fs1 = fs1; insn.fs2 = 0;
        insn.fbase = 0; insn.stride = 0; insn.imm = imm;
        insn.use_param = False; insn.pidx = 0;
        w0[0] = insn;
        p.prog[0] = w0;
        p.nslots = newVector;
        p.nslots[0] = 1;
        p.nwords = 1;
        return p;
    endfunction

    // ---- 配置：4 张表（nkeys=0 → 恒走默认动作；级 0 → 动作 0(改字段)，
    //      级 1-3 → 动作 1(NOP)） ----
    rule cfg_tables (st == 3 && cfg_tbl_r < 4);
        TableConfig cfg;
        cfg.table_id = 0;
        cfg.keys = newVector;
        cfg.nkeys = 0;
        cfg.action_ids = newVector;
        cfg.action_ids[0] = 0;
        cfg.nactions = 1;
        cfg.default_action = (cfg_tbl_r == 4'd0) ? 5'd0 : 5'd1;
        cfg.def_params = replicate(0);
        cfg.stage = 0;
        cfg.pred_hdr = 6'h3F;
        dut.config_table(cfg_tbl_r, cfg);
        cfg_tbl_r <= cfg_tbl_r + 1;
        if (cfg_tbl_r == 3) st <= 4;
    endrule

    // ---- 配置：向 4 个引擎加载动作 0（src_ip+1）和动作 1（NOP） ----
    rule cfg_actions (st == 4);
        let stage = zeroExtend(act_cnt_r[1:0]);      // 引擎 0-3
        Bool is_add = (act_cnt_r < 3'd4);            // 前 4 次：动作 0
        Bit#(5) aidx = is_add ? 5'd0 : 5'd1;
        dut.load_action(stage, aidx,
                        mk_prog(is_add ? ALU_ADDI : ALU_NOP,
                                is_add ? 10 : 0,     // fd=10 (src_ip)
                                is_add ? 10 : 0,     // fs1=10
                                is_add ? 1 : 0));    // +1
        act_cnt_r <= act_cnt_r + 1;
        if (act_cnt_r == 3'd7) st <= 5;
    endrule

    // ---- 注入 54B TCP SYN 包（拍 0） ----
    rule inject0 (st == 5);
        let pk = make_pkt;
        EthStream s;
        s.data = tpl_1(pk);
        s.keep = '1;
        s.last = False;
        s.valid = True;
        s.first = True;
        dut.rx_data(s);
        st <= 6;
    endrule

    // ---- 注入拍 1（末拍，22 字节） ----
    rule inject1 (st == 6);
        let pk = make_pkt;
        EthStream s;
        s.data = tpl_2(pk);
        s.keep = 32'h003FFFFF;   // 22 字节
        s.last = True;
        s.valid = True;
        s.first = False;
        dut.rx_data(s);
        st <= 7;
    endrule

    // ---- 取输出拍 0 ----
    rule out0 (st == 7);
        let s <- dut.tx_data;
        out_b0_r <= s.data;
        st <= 8;
    endrule

    // ---- 取输出拍 1 ----
    rule out1 (st == 8);
        let s <- dut.tx_data;
        out_b1_r <= s.data;
        if (!s.last) $display("FAIL: out beat1 should be last");
        else $display("PASS: out beat1 last");
        st <= 9;
    endrule

    // ---- 逐字节比对：级 0 动作把 src_ip +1（0A000001 → 0A000002），
    //      其余字段不变（验证 解析→动作→脏位→逆解析补丁 全链路） ----
    rule check (st == 9);
        Bit#(32) e = err;
        if (pkt_byte(out_b0_r, 26) != 8'h0A) begin $display("FAIL: byte26=%h", pkt_byte(out_b0_r,26)); e = 1; end
        else $display("PASS: byte26=0A (src_ip)");
        if (pkt_byte(out_b0_r, 27) != 8'h00) begin $display("FAIL: byte27"); e = 1; end
        else $display("PASS: byte27=00");
        if (pkt_byte(out_b0_r, 28) != 8'h00) begin $display("FAIL: byte28"); e = 1; end
        else $display("PASS: byte28=00");
        if (pkt_byte(out_b0_r, 29) != 8'h02) begin $display("FAIL: byte29=%h expected 02 (src_ip+1)", pkt_byte(out_b0_r,29)); e = 1; end
        else $display("PASS: byte29=02 (src_ip after action +1)");
        if (pkt_byte(out_b0_r, 30) != 8'h0A) begin $display("FAIL: byte30"); e = 1; end
        else $display("PASS: byte30=0A (dst_ip unchanged)");
        if (pkt_byte(out_b1_r, 34 - 32) != 8'hC3) begin $display("FAIL: byte34"); e = 1; end
        else $display("PASS: byte34=C3 (sport unchanged)");
        if (pkt_byte(out_b1_r, 47 - 32) != 8'h02) begin $display("FAIL: byte47 flags"); e = 1; end
        else $display("PASS: byte47=02 (SYN flags)");
        $display("TX count: %d, TCP sessions: %d", dut.get_tx_count, dut.get_tcp_sessions);
        err <= e;
        st <= 10;
    endrule

    rule finish (st == 10);
        if (err == 0) $display("=== RMTTOP E2E: ALL PASS ===");
        else $display("=== RMTTOP E2E: FAIL ===");
        $finish(0);
    endrule

endmodule

endpackage
