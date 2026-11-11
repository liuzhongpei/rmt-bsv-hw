// ============================================================
// TestVXLAN.bsv - VXLAN decap真实端到端测试
//
// ★ 原实现是假测试。现在直接实例化 mkRMTTop：
//     配置解析图(Eth+IPv4+UDP+VXLAN) → VNI 匹配表 → 动作 INVALID 外层头
//     （触发结构变更）→ 逆解析按 payload_offset 输出内层报文 → 比对。
// ============================================================

package TestVXLAN;

import Vector :: *;
import FIFOF :: *;
import DefaultValue :: *;
import RMTInterfaces :: *;
import RMTTop :: *;
`include "RMTConfig.bh"

// ============================================================
//                       测试平台
// ============================================================

module mkTestVXLAN(Empty);
    RMTTopIfc dut <- mkRMTTop;

    Reg#(Bit#(32)) st <- mkReg(0);
    Reg#(Bit#(32)) err <- mkReg(0);
    Reg#(Bit#(4)) cfg_tbl_r <- mkReg(0);
    Reg#(Bit#(3)) act_cnt_r <- mkReg(0);
    Reg#(Bit#(256)) b0_r <- mkReg(0);
    Reg#(Bit#(256)) b1_r <- mkReg(0);
    Reg#(Bit#(7)) beat_cnt_r <- mkReg(0);
    Reg#(Bool) last_keep_ok_r <- mkReg(False);

    function Bit#(8) pkt_byte(Bit#(256) beat, Integer off);
        Bit#(8) msb = 8'hFF - (fromInteger(off) * 8);
        return beat[msb : msb - 7];
    endfunction

    // 88B VXLAN 包：外层 Eth(14)+IPv4(20)+UDP(8)+VXLAN(8) + 内层 Eth(14)+IPv4(20)+payload(4)
    //   VNI=5001 @字节44-46；内层起始 @50
    function Tuple3#(Bit#(256), Bit#(256), Bit#(256)) make_pkt;
        Vector#(128, Bit#(8)) byt = replicate(0);
        // 外层 IPv4 src/dst（字段10/11）
        byt[26] = 8'h0A; byt[29] = 8'h01;   // 10.0.0.1
        byt[30] = 8'h0A; byt[33] = 8'h02;   // 10.0.0.2
        // UDP dport=4789（字节38-39=12B5）
        byt[38] = 8'h12; byt[39] = 8'hB5;
        // VXLAN VNI=5001 @44-46 = 00 13 89
        byt[44] = 8'h00; byt[45] = 8'h13; byt[46] = 8'h89;
        // 内层 Eth dmac @50
        byt[50] = 8'hAA; byt[51] = 8'hBB; byt[52] = 8'hCC;
        byt[53] = 8'hDD; byt[54] = 8'hEE; byt[55] = 8'h01;
        // 内层 IPv4 src @76 = 0B000001, dst @80 = 0B000002
        byt[76] = 8'h0B; byt[79] = 8'h01;
        byt[80] = 8'h0B; byt[83] = 8'h02;
        Vector#(64, Bit#(256)) d = replicate(0);
        for (Integer j = 0; j < 3; j = j + 1) begin
            Bit#(256) beat = 0;
            for (Integer i = 0; i < 32; i = i + 1) beat = (beat << 8) | zeroExtend(byt[j*32 + i]);
            d[j] = beat;
        end
        return tuple3(d[0], d[1], d[2]);
    endfunction

    // ---- 配置解析图：state0(Eth)→state1(IPv4)→state2(UDP)→state3(VXLAN)→ACCEPT ----
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
        ParseOp o1; o1.kind = POP_EXTRACT; o1.hdr_id = 1; o1.count_field = 0; o1.count_add = 0;
        s1.ops[0] = o1;
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
        ParseOp o4; o4.kind = POP_EXTRACT; o4.hdr_id = 4; o4.count_field = 0; o4.count_add = 0;
        s2.ops[0] = o4;
        s2.nops = 1;
        s2.sel_field = 8'hFF;
        s2.cases = replicate(SelCase { sel_val: 0, next_state: 0 });
        s2.ncases = 0;
        s2.def_next = 3;
        dut.config_parser(2, s2);
        st <= 3;
    endrule
    rule cfg_p3 (st == 3);
        ParseState s3;
        s3.name_id = 0;
        s3.ops = newVector;
        ParseOp o6; o6.kind = POP_EXTRACT; o6.hdr_id = 6; o6.count_field = 0; o6.count_add = 0;
        s3.ops[0] = o6;
        s3.nops = 1;
        s3.sel_field = 8'hFF;
        s3.cases = replicate(SelCase { sel_val: 0, next_state: 0 });
        s3.ncases = 0;
        s3.def_next = 5'h1F;   // ACCEPT
        dut.config_parser(3, s3);
        st <= 4;
    endrule

    rule cfg_start (st == 4);
        dut.set_start_state(0);
        st <= 5;
    endrule

    // ---- 配置 4 张表：级0 默认动作 1(NOP，插 VNI 条目→动作0)；级1-3 NOP ----
    rule cfg_tables (st == 5 && cfg_tbl_r < 4);
        TableConfig cfg;
        cfg.table_id = 0;
        cfg.keys = newVector;
        KeyField kf;
        kf.field_id = 40; kf.match_type = MATCH_EXACT;
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
        if (cfg_tbl_r == 4'd3) st <= 6;
    endrule

    // ---- 加载动作：动作0=INVALID 外层头(0,1,4,6)→触发结构变更；动作1=NOP ----
    rule cfg_actions (st == 6);
        Bit#(3) stage = zeroExtend(act_cnt_r[1:0]);
        Bool is_dec = (act_cnt_r < 3'd4);
        ActionProgram p;
        p.action_id = 0; p.nparams = 0;
        p.prog = newVector;
        VLIWWord w0 = newVector;
        ALUInsn insn;
        if (is_dec) begin
            // 4 槽位：INVALID hdr 0/1/4/6
            insn.op = ALU_INVALID; insn.fd = 0; insn.fs1 = 0; insn.fs2 = 0;
            insn.fbase = 0; insn.stride = 0; insn.imm = 0; insn.use_param = False; insn.pidx = 0;
            w0[0] = insn;
            insn.fd = 1; w0[1] = insn;
            insn.fd = 4; w0[2] = insn;
            insn.fd = 6; w0[3] = insn;
            p.nslots = newVector; p.nslots[0] = 4;
        end
        else begin
            insn.op = ALU_NOP; insn.fd = 0; insn.fs1 = 0; insn.fs2 = 0;
            insn.fbase = 0; insn.stride = 0; insn.imm = 0; insn.use_param = False; insn.pidx = 0;
            w0[0] = insn;
            p.nslots = newVector; p.nslots[0] = 1;
        end
        p.prog[0] = w0;
        p.nwords = 1;
        dut.load_action(stage, is_dec ? 5'd0 : 5'd1, p);
        act_cnt_r <= act_cnt_r + 1;
        if (act_cnt_r == 3'd7) st <= 7;
    endrule

    // ---- 插入 VNI=5001（field40=0x001389）→ 动作0（解封装） ----
    rule cfg_entry (st == 7);
        TCAMEntry e;
        e.key = 128'h000000000000000000000000001389;
        e.mask = '1;
        e.action_id = 0;
        e.params = 0;
        dut.insert_entry(4'd0, e);
        st <= 8;
    endrule

    // ---- 注入 VXLAN 包（3 拍） ----
    rule inject0 (st == 8);
        EthStream s;
        s.data = tpl_1(make_pkt);
        s.keep = '1; s.last = False; s.valid = True; s.first = True;
        dut.rx_data(s);
        st <= 9;
    endrule
    rule inject1 (st == 9);
        EthStream s;
        s.data = tpl_2(make_pkt);
        s.keep = '1; s.last = False; s.valid = True; s.first = False;
        dut.rx_data(s);
        st <= 10;
    endrule
    rule inject2 (st == 10);
        EthStream s;
        s.data = tpl_3(make_pkt);
        s.keep = 32'h00FFFFFF; s.last = True; s.valid = True; s.first = False;
        dut.rx_data(s);
        st <= 11;
    endrule

    // ---- 收集输出（直到 last），保存 beat0/beat1 与末拍 keep ----
    rule collect (st == 11);
        let s <- dut.tx_data;
        if (beat_cnt_r == 0) b0_r <= s.data;
        if (beat_cnt_r == 1) b1_r <= s.data;
        beat_cnt_r <= beat_cnt_r + 1;
        if (s.last) begin
            last_keep_ok_r <= (s.keep == 32'h0000003F);   // 38B → 末拍 6 字节
            st <= 12;
        end
    endrule

    // ---- 比对：输出 = 内层报文（从字节50 起，38B） ----
    rule check (st == 12);
        Bit#(32) e = err;
        // 输出 beat0 = 原字节 50-81；内层 Eth dmac @50 → 输出 beat0 字节0 = AA
        if (pkt_byte(b0_r, 0) != 8'hAA) begin $display("FAIL: inner dmac byte0=%h expected AA", pkt_byte(b0_r, 0)); e = 1; end
        else $display("PASS: output starts with inner Eth (dmac=AA)");
        // 内层 IPv4 src @76 → 输出 beat0 字节 26 = 0B
        if (pkt_byte(b0_r, 26) != 8'h0B) begin $display("FAIL: inner ip src byte26=%h expected 0B", pkt_byte(b0_r, 26)); e = 1; end
        else $display("PASS: inner IPv4 src kept (0B000001)");
        // 末拍 keep = 6 字节（38B = 32 + 6）
        if (!last_keep_ok_r) begin $display("FAIL: last beat keep should be 6 bytes"); e = 1; end
        else $display("PASS: output 38B (outer 50B stripped)");
        err <= e;
        st <= 13;
    endrule

    rule finish (st == 13);
        if (err == 0) $display("=== VXLAN E2E: ALL PASS ===");
        else $display("=== VXLAN E2E: FAIL ===");
        $finish(0);
    endrule
endmodule

endpackage
