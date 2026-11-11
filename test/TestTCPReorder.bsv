// ============================================================
// TestTCPReorder.bsv - TCP 重组真实端到端测试
//
// TCP 核心是"报文重组"：按偏移量(seq) + payload length 拼接。
// 会话 expected_seq 从 SYN 初始化（SYN 消耗 1 个序号）：
//   SYN(seq=1000, payload=10B) → 建会话，expected = 1000+10+1 = 1011
//   seq=1021（超前）           → 缓存进重排缓冲
//   seq=1011（期望）           → 按序输出，expected 推进到 1021
//   然后重组吐出缓存的 seq=1021。
// 期望输出顺序：SYN(0xE8), seq=1011(0xF3), seq=1021(0xFD)。
// ============================================================

package TestTCPReorder;

import Vector :: *;
import FIFOF :: *;
import DefaultValue :: *;
import RMTInterfaces :: *;
import RMTTop :: *;
`include "RMTConfig.bh"

// ============================================================
//                       测试平台
// ============================================================

module mkTestTCPReorder(Empty);
    RMTTopIfc dut <- mkRMTTop;

    Reg#(Bit#(32)) st <- mkReg(0);
    Reg#(Bit#(32)) err <- mkReg(0);
    Reg#(Bit#(4)) cfg_tbl_r <- mkReg(0);
    Reg#(Bit#(3)) act_cnt_r <- mkReg(0);
    Reg#(Bit#(3)) inj_r <- mkReg(0);
    Reg#(Bit#(3)) pkt_out_r <- mkReg(0);
    Reg#(Bit#(8)) seq_out_0 <- mkReg(0);
    Reg#(Bit#(8)) seq_out_1 <- mkReg(0);
    Reg#(Bit#(8)) seq_out_2 <- mkReg(0);
    Reg#(Bit#(32)) cy <- mkReg(0);

    rule tick (True);
        cy <= cy + 1;
    endrule

    rule watchdog (cy > 2000 && st < 9);
        $display("TCP E2E TIMEOUT cy=%d st=%d out=%d sessions=%d", cy, st, pkt_out_r, dut.get_tcp_sessions);
        $finish(0);
    endrule

    function Bit#(8) pkt_byte(Bit#(256) beat, Integer off);
        Bit#(8) msb = 8'hFF - (fromInteger(off) * 8);
        return beat[msb : msb - 7];
    endfunction

    // 54B TCP 包：Eth(14)+IPv4(20)+TCP(20)，5 元组固定，seq/flags 可变
    function Tuple2#(Bit#(256), Bit#(256)) make_pkt(Bit#(32) seqn, Bit#(8) flags);
        Vector#(128, Bit#(8)) byt = replicate(0);
        byt[26] = 8'h0A; byt[27] = 8'h00; byt[28] = 8'h00; byt[29] = 8'h01; // src_ip
        byt[30] = 8'h0A; byt[31] = 8'h00; byt[32] = 8'h00; byt[33] = 8'h02; // dst_ip
        byt[34] = 8'hC3; byt[35] = 8'h50;  // sport=50000
        byt[36] = 8'h00; byt[37] = 8'h50;  // dport=80
        byt[38] = seqn[31:24]; byt[39] = seqn[23:16]; byt[40] = seqn[15:8]; byt[41] = seqn[7:0];
        byt[47] = flags;
        // 10 字节 payload（payload_len=10 驱动 expected_seq 按偏移+长度推进）
        byt[54] = 8'hAA; byt[55] = 8'hBB; byt[56] = 8'hCC; byt[57] = 8'hDD;
        byt[58] = 8'hEE; byt[59] = 8'hFF; byt[60] = 8'h11; byt[61] = 8'h22;
        byt[62] = 8'h33; byt[63] = 8'h44;
        Bit#(256) b0 = 0;
        for (Integer i = 0; i < 32; i = i + 1) b0 = (b0 << 8) | zeroExtend(byt[i]);
        Bit#(256) b1 = 0;
        for (Integer i = 0; i < 32; i = i + 1) b1 = (b1 << 8) | zeroExtend(byt[32 + i]);
        return tuple2(b0, b1);
    endfunction

    function ActionProgram mk_prog(ALUOpcode op, Bit#(8) fd, Bit#(8) fs1, Bit#(64) imm);
        ActionProgram p;
        p.action_id = 0; p.nparams = 0;
        p.prog = newVector;
        VLIWWord w0 = newVector;
        ALUInsn insn;
        insn.op = op; insn.fd = fd; insn.fs1 = fs1; insn.fs2 = 0;
        insn.fbase = 0; insn.stride = 0; insn.imm = imm;
        insn.use_param = False; insn.pidx = 0;
        w0[0] = insn;
        p.prog[0] = w0;
        p.nslots = newVector; p.nslots[0] = 1;
        p.nwords = 1;
        return p;
    endfunction

    // ---- 配置解析图 ----
    rule cfg_parser0 (st == 0);
        ParseState s0;
        s0.name_id = 0;
        s0.ops = newVector;
        ParseOp o0; o0.kind = POP_EXTRACT; o0.hdr_id = 0; o0.count_field = 0; o0.count_add = 0;
        ParseOp o1; o1.kind = POP_EXTRACT; o1.hdr_id = 1; o1.count_field = 0; o1.count_add = 0;
        s0.ops[0] = o0; s0.ops[1] = o1;
        s0.nops = 2;
        s0.sel_field = 8'hFF;
        s0.cases = replicate(SelCase { sel_val: 0, next_state: 0 });
        s0.ncases = 0;
        s0.def_next = 1;
        dut.config_parser(0, s0);
        st <= 1;
    endrule

    rule cfg_parser1 (st == 1);
        ParseState s1;
        s1.name_id = 0;
        s1.ops = newVector;
        ParseOp o3; o3.kind = POP_EXTRACT; o3.hdr_id = 3; o3.count_field = 0; o3.count_add = 0;
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

    // ---- 配置 4 张表：级0 默认动作 1(NOP)；5 元组条目→动作0(NOP) ----
    rule cfg_tables (st == 3 && cfg_tbl_r < 4);
        TableConfig cfg;
        cfg.table_id = 0;
        cfg.keys = newVector;
        KeyField kf;
        kf.field_id = 10; kf.match_type = MATCH_EXACT;
        cfg.keys[0] = kf;
        kf.field_id = 11; cfg.keys[1] = kf;
        kf.field_id = 20; cfg.keys[2] = kf;
        kf.field_id = 21; cfg.keys[3] = kf;
        cfg.nkeys = 4;
        cfg.action_ids = newVector;
        cfg.action_ids[0] = 0;
        cfg.nactions = 1;
        cfg.default_action = 5'd1;
        cfg.def_params = replicate(0);
        cfg.stage = 0;
        cfg.pred_hdr = 6'h3F;
        dut.config_table(cfg_tbl_r, cfg);
        cfg_tbl_r <= cfg_tbl_r + 1;
        if (cfg_tbl_r == 4'd3) st <= 4;
    endrule

    // ---- 加载动作：动作0/1 都 NOP（不修改 seq，保证重组偏移干净） ----
    rule cfg_actions (st == 4);
        Bit#(3) stage = zeroExtend(act_cnt_r[1:0]);
        dut.load_action(stage, zeroExtend(act_cnt_r), mk_prog(ALU_NOP, 0, 0, 0));
        act_cnt_r <= act_cnt_r + 1;
        if (act_cnt_r == 3'd7) st <= 5;
    endrule

    // ---- 插入 5 元组表项 → 动作 0 ----
    rule cfg_entry (st == 5);
        TCAMEntry e;
        e.key = 128'h00000000000000000050C35000020001;
        e.mask = '1;
        e.action_id = 0;
        e.params = 0;
        dut.insert_entry(4'd0, e);
        st <= 6;
    endrule

    // ---- 注入 3 个包：SYN(seq1000), seq1021(超前), seq1011(期望) ----
    rule inject (st == 6 && inj_r < 6);
        Bit#(3) pktidx = inj_r >> 1;                 // 0,0,1,1,2,2
        Bit#(1)  beatidx = inj_r[0];                 // 0,1,0,1,0,1
        Bit#(32) seqn  = (pktidx == 0) ? 32'h3E8 : (pktidx == 1) ? 32'h3FD : 32'h3F3;
        Bit#(8)  flags = (pktidx == 0) ? 8'h02 : 8'h00;
        let pk = make_pkt(seqn, flags);
        EthStream s;
        s.data  = (beatidx == 1'b0) ? tpl_1(pk) : tpl_2(pk);
        s.keep  = '1;
        s.last  = (beatidx == 1'b1);
        s.first = (beatidx == 1'b0);
        s.valid = True;
        dut.rx_data(s);
        inj_r <= inj_r + 1;
        if (inj_r == 3'd5) st <= 7;
    endrule

    // ---- 收集输出：每个包（2 拍）结束时记录 byte41（seq 低字节） ----
    rule collect (st == 7);
        let s <- dut.tx_data;
        if (s.last) begin
            Bit#(8) b41 = pkt_byte(s.data, 41 - 32);
            if (pkt_out_r == 0) seq_out_0 <= b41;
            if (pkt_out_r == 1) seq_out_1 <= b41;
            if (pkt_out_r == 2) seq_out_2 <= b41;
            pkt_out_r <= pkt_out_r + 1;
            if (pkt_out_r == 3'd2) st <= 8;
        end
    endrule

    // ---- 比对：输出顺序应为 SYN(0xE8), seq1011(0xF3), seq1021(0xFD) ----
    rule check (st == 8);
        Bit#(32) e = err;
        if (seq_out_0 != 8'hE8) begin $display("FAIL: out0 byte41=%h expected E8 (SYN)", seq_out_0); e = 1; end
        else $display("PASS: out1 = SYN (seq=1000)");
        if (seq_out_1 != 8'hF3) begin $display("FAIL: out1 byte41=%h expected F3 (seq=1011)", seq_out_1); e = 1; end
        else $display("PASS: out2 = seq=1011 (in-order, expected from SYN)");
        if (seq_out_2 != 8'hFD) begin $display("FAIL: out2 byte41=%h expected FD (seq=1021 reassembled)", seq_out_2); e = 1; end
        else $display("PASS: out3 = seq=1021 (out-of-order drained)");
        $display("TCP sessions: %d, TX: %d", dut.get_tcp_sessions, dut.get_tx_count);
        if (dut.get_tcp_sessions != 1) begin $display("FAIL: expected 1 session"); e = 1; end
        else $display("PASS: 1 TCP session");
        err <= e;
        st <= 9;
    endrule

    rule finish (st == 9);
        if (err == 0) $display("=== TCP REASSEMBLY E2E: ALL PASS ===");
        else $display("=== TCP REASSEMBLY E2E: FAIL ===");
        $finish(0);
    endrule
endmodule

endpackage
