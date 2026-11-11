// ============================================================
// TestSRv6.bsv - SRv6 End 行为真实端到端测试
//
// ★ 原实现是假测试。现在直接实例化 mkRMTTop：
//     配置解析图(Eth+IPv6+SRH) → IPv6 dst 匹配表 → SRv6 End 动作
//     (dst=seg[SL], SL-1) → 注入真实 SRv6 包 → 比对输出 dst 跳转 + SL 递减。
// ============================================================

package TestSRv6;

import Vector :: *;
import FIFOF :: *;
import DefaultValue :: *;
import RMTInterfaces :: *;
import RMTTop :: *;
`include "RMTConfig.bh"

// ============================================================
//                       测试平台
// ============================================================

module mkTestSRv6(Empty);
    RMTTopIfc dut <- mkRMTTop;

    Reg#(Bit#(32)) st <- mkReg(0);
    Reg#(Bit#(32)) err <- mkReg(0);
    Reg#(Bit#(4)) cfg_tbl_r <- mkReg(0);
    Reg#(Bit#(3)) act_cnt_r <- mkReg(0);
    Reg#(Bit#(256)) b0_r <- mkReg(0);
    Reg#(Bit#(256)) b1_r <- mkReg(0);
    Reg#(Bit#(7)) beat_cnt_r <- mkReg(0);

    function Bit#(8) pkt_byte(Bit#(256) beat, Integer off);
        Bit#(8) msb = 8'hFF - (fromInteger(off) * 8);
        return beat[msb : msb - 7];
    endfunction

    // 126B SRv6 包：Eth(14)+IPv6(40)+SRH(72)
    //   IPv6 dst = 1111::1（字节38 起），SRH: SL=2（字节57），
    //   SID0=1111::1, SID1=2222::2, SID2=3333::3, SID3=4444::4
    function Tuple4#(Bit#(256), Bit#(256), Bit#(256), Bit#(256)) make_pkt;
        Vector#(128, Bit#(8)) byt = replicate(0);
        // IPv6 dst (bytes 38-53) = 1111::1
        byt[38] = 8'h11; byt[39] = 8'h11; byt[53] = 8'h01;
        // SRH @54
        byt[57] = 8'h02;   // SL = 2
        // SID0 @62 = 1111::1, SID1 @78 = 2222::2, SID2 @94 = 3333::3, SID3 @110 = 4444::4
        byt[62] = 8'h11; byt[63] = 8'h11; byt[77] = 8'h01;
        byt[78] = 8'h22; byt[79] = 8'h22; byt[93] = 8'h02;
        byt[94] = 8'h33; byt[95] = 8'h33; byt[109] = 8'h03;
        byt[110] = 8'h44; byt[111] = 8'h44; byt[125] = 8'h04;
        Vector#(64, Bit#(256)) d = replicate(0);
        for (Integer j = 0; j < 4; j = j + 1) begin
            Bit#(256) beat = 0;
            for (Integer i = 0; i < 32; i = i + 1) beat = (beat << 8) | zeroExtend(byt[j*32 + i]);
            d[j] = beat;
        end
        return tuple4(d[0], d[1], d[2], d[3]);
    endfunction

    // ---- 配置解析图：state0(Eth)→state1(IPv6)→state2(SRH)→ACCEPT ----
    rule cfg_p0 (st == 0);
        ParseState s0;
        s0.name_id = 0;
        s0.ops = newVector;
        ParseOp o0; o0.kind = POP_EXTRACT; o0.hdr_id = 0; o0.count_field = 0; o0.count_add = 0;
        s0.ops[0] = o0;
        s0.nops = 1;
        s0.sel_field = 8'hFF;
        s0.cases = replicate(SelCase { sel_val: 0, next_state: 0 });
        s0.ncases = 0;
        s0.def_next = 1;
        dut.config_parser(0, s0);
        st <= 1;
    endrule

    rule cfg_p1 (st == 1);
        ParseState s1;
        s1.name_id = 0;
        s1.ops = newVector;
        ParseOp o2; o2.kind = POP_EXTRACT; o2.hdr_id = 2; o2.count_field = 0; o2.count_add = 0;
        s1.ops[0] = o2;
        s1.nops = 1;
        s1.sel_field = 8'hFF;
        s1.cases = replicate(SelCase { sel_val: 0, next_state: 0 });
        s1.ncases = 0;
        s1.def_next = 2;
        dut.config_parser(1, s1);
        st <= 2;
    endrule

    rule cfg_p2 (st == 2);
        ParseState s2;
        s2.name_id = 0;
        s2.ops = newVector;
        ParseOp o5; o5.kind = POP_EXTRACT; o5.hdr_id = 5; o5.count_field = 0; o5.count_add = 0;
        s2.ops[0] = o5;
        s2.nops = 1;
        s2.sel_field = 8'hFF;
        s2.cases = replicate(SelCase { sel_val: 0, next_state: 0 });
        s2.ncases = 0;
        s2.def_next = 5'h1F;   // ACCEPT
        dut.config_parser(2, s2);
        st <= 3;
    endrule

    rule cfg_start (st == 3);
        dut.set_start_state(0);
        st <= 4;
    endrule

    // ---- 配置 4 张表：级0 默认动作 1(NOP，插 IPv6 dst 条目→动作0)；级1-3 NOP ----
    rule cfg_tables (st == 4 && cfg_tbl_r < 4);
        TableConfig cfg;
        cfg.table_id = 0;
        cfg.keys = newVector;
        KeyField kf;
        kf.field_id = 11; kf.match_type = MATCH_EXACT;
        cfg.keys[0] = kf;
        cfg.nkeys = 1;
        cfg.action_ids = newVector;
        cfg.action_ids[0] = 0;
        cfg.nactions = 1;
        cfg.default_action = 5'd1;
        cfg.def_params = replicate(0);
        cfg.stage = 0;
        cfg.pred_hdr = 6'h3F;
        dut.config_table(cfg_tbl_r, cfg);
        cfg_tbl_r <= cfg_tbl_r + 1;
        if (cfg_tbl_r == 4'd3) st <= 5;
    endrule

    // ---- 加载动作：动作0=SRv6 End；动作1=NOP；进 4 引擎 ----
    rule cfg_actions (st == 5);
        Bit#(3) stage = zeroExtend(act_cnt_r[1:0]);
        Bool is_end = (act_cnt_r < 3'd4);
        ActionProgram p;
        p.action_id = 0; p.nparams = 0;
        p.prog = newVector;
        VLIWWord w0 = newVector;
        ALUInsn insn;
        if (is_end) begin
            // slot0: MOVX fd=11 fbase=31 fs1=30 stride=1 → dst=seg[SL]
            insn.op = ALU_MOVX; insn.fd = 11; insn.fs1 = 30; insn.fs2 = 0;
            insn.fbase = 31; insn.stride = 1; insn.imm = 0; insn.use_param = False; insn.pidx = 0;
            w0[0] = insn;
            // slot1: SUBI fd=30 fs1=30 imm=1 → SL-1
            insn.op = ALU_SUBI; insn.fd = 30; insn.fs1 = 30; insn.fs2 = 0;
            insn.fbase = 0; insn.stride = 0; insn.imm = 1; insn.use_param = False; insn.pidx = 0;
            w0[1] = insn;
            p.nslots = newVector; p.nslots[0] = 2;
        end
        else begin
            insn.op = ALU_NOP; insn.fd = 0; insn.fs1 = 0; insn.fs2 = 0;
            insn.fbase = 0; insn.stride = 0; insn.imm = 0; insn.use_param = False; insn.pidx = 0;
            w0[0] = insn;
            p.nslots = newVector; p.nslots[0] = 1;
        end
        p.prog[0] = w0;
        p.nwords = 1;
        dut.load_action(stage, is_end ? 5'd0 : 5'd1, p);
        act_cnt_r <= act_cnt_r + 1;
        if (act_cnt_r == 3'd7) st <= 6;
    endrule

    // ---- 插入 IPv6 dst=1111::1（field11=0x11110000）→ 动作0 ----
    rule cfg_entry (st == 6);
        TCAMEntry e;
        e.key = 128'h00000000000000000000000011110000;
        e.mask = '1;
        e.action_id = 0;
        e.params = 0;
        dut.insert_entry(4'd0, e);
        st <= 7;
    endrule

    // ---- 注入 SRv6 包（4 拍） ----
    rule inject0 (st == 7);
        EthStream s;
        s.data = tpl_1(make_pkt);
        s.keep = '1; s.last = False; s.valid = True; s.first = True;
        dut.rx_data(s);
        st <= 8;
    endrule
    rule inject1 (st == 8);
        EthStream s;
        s.data = tpl_2(make_pkt);
        s.keep = '1; s.last = False; s.valid = True; s.first = False;
        dut.rx_data(s);
        st <= 9;
    endrule
    rule inject2 (st == 9);
        EthStream s;
        s.data = tpl_3(make_pkt);
        s.keep = '1; s.last = False; s.valid = True; s.first = False;
        dut.rx_data(s);
        st <= 10;
    endrule
    rule inject3 (st == 10);
        EthStream s;
        s.data = tpl_4(make_pkt);
        s.keep = 32'h3FFFFFFF; s.last = True; s.valid = True; s.first = False;
        dut.rx_data(s);
        st <= 11;
    endrule

    // ---- 收集输出（直到 last），保存 beat0/beat1 ----
    rule collect (st == 11);
        let s <- dut.tx_data;
        if (beat_cnt_r == 0) b0_r <= s.data;
        if (beat_cnt_r == 1) b1_r <= s.data;
        beat_cnt_r <= beat_cnt_r + 1;
        if (s.last) st <= 12;
    endrule

    // ---- 比对：IPv6 dst 从 1111::1 跳到 seg[SL=2]=3333::3（字节38-41=33 33 00 00），
    //      SL 从 2 → 1（字节57） ----
    rule check (st == 12);
        Bit#(32) e = err;

        if (pkt_byte(b1_r, 38 - 32) != 8'h33) begin $display("FAIL: dst byte38=%h expected 33 (seg[SL])", pkt_byte(b1_r, 6)); e = 1; end
        else $display("PASS: IPv6 dst=3333::3 (jump to seg[SL])");
        if (pkt_byte(b1_r, 41 - 32) != 8'h00) begin $display("FAIL: dst byte41"); e = 1; end
        else $display("PASS: dst byte41=00");
        if (pkt_byte(b1_r, 57 - 32) != 8'h01) begin $display("FAIL: SL byte57=%h expected 01 (SL-1)", pkt_byte(b1_r, 25)); e = 1; end
        else $display("PASS: SL=1 (SL decremented from 2)");
        err <= e;
        st <= 13;
    endrule

    rule finish (st == 13);
        if (err == 0) $display("=== SRV6 E2E: ALL PASS ===");
        else $display("=== SRV6 E2E: FAIL ===");
        $finish(0);
    endrule
endmodule

endpackage
