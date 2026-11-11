// ============================================================
// TestDNN.bsv - DNN 推理真实端到端测试
//
// 直接实例化 mkRMTTop：
//   解析图 Eth→IPv4→TCP 提取特征（total_len/ttl/flags/window）
//   级 0 默认动作 = DNN 推理（写类别到 field 60）+ ALU_DROP（field 60
//   非零则丢）
//   注入正常流量（len=60, ttl=64, window=64240）→ 类别 0 → 转发
//   注入攻击流量（len=40, ttl=47, window=128）  → 类别 1 → 丢弃
//   校验：正常包原样输出；攻击包不出现在 TX，drop_count=1
// ============================================================

package TestDNN;

import Vector :: *;
import FIFOF :: *;
import DefaultValue :: *;
import RMTInterfaces :: *;
import RMTTop :: *;
`include "RMTConfig.bh"

// ============================================================
//                       测试平台
// ============================================================

module mkTestDNN(Empty);
    RMTTopIfc dut <- mkRMTTop;

    Reg#(Bit#(32)) st <- mkReg(0);
    Reg#(Bit#(32)) err <- mkReg(0);
    Reg#(Bit#(4)) cfg_tbl_r <- mkReg(0);
    Reg#(Bit#(3)) act_cnt_r <- mkReg(0);
    Reg#(Bit#(256)) out_b0_r <- mkReg(0);
    Reg#(Bit#(256)) out_b1_r <- mkReg(0);
    Reg#(Bit#(32)) delay_r <- mkReg(0);
    Reg#(Bit#(32)) cy <- mkReg(0);

    rule tick (True);
        cy <= cy + 1;
    endrule

    rule watchdog (cy > 3000 && st < 14);
        $display("DNN E2E TIMEOUT cy=%d st=%d tx=%d drop=%d",
                 cy, st, dut.get_tx_count, dut.get_drop_count);
        $finish(0);
    endrule

    function Bit#(8) pkt_byte(Bit#(256) beat, Integer off);
        Bit#(8) msb = 8'hFF - (fromInteger(off) * 8);
        return beat[msb : msb - 7];
    endfunction

    // 54B TCP 包：Eth(14)+IPv4(20)+TCP(20)，特征可变
    function Tuple2#(Bit#(256), Bit#(256)) make_pkt(Bit#(16) total_len,
                                                    Bit#(8) ttl,
                                                    Bit#(16) window);
        Vector#(64, Bit#(8)) byt = replicate(0);
        byt[16] = total_len[15:8]; byt[17] = total_len[7:0];  // IPv4 total_len
        byt[22] = ttl;                                        // IPv4 ttl
        byt[26] = 8'h0A; byt[27] = 8'h00; byt[28] = 8'h00; byt[29] = 8'h01; // src_ip
        byt[30] = 8'h0A; byt[31] = 8'h00; byt[32] = 8'h00; byt[33] = 8'h02; // dst_ip
        byt[34] = 8'hC3; byt[35] = 8'h50;  // sport=50000
        byt[36] = 8'h00; byt[37] = 8'h50;  // dport=80
        byt[38] = 8'h00; byt[39] = 8'h00; byt[40] = 8'h03; byt[41] = 8'hE8; // seq
        byt[47] = 8'h02;                                      // flags=SYN
        byt[48] = window[15:8]; byt[49] = window[7:0];        // tcp.window
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

    // ---- 配置解析图：state0(Eth)→state1(IPv4)→state2(TCP)→ACCEPT ----
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
        ParseOp o3; o3.kind = POP_EXTRACT; o3.hdr_id = 3; o3.count_field = 0; o3.count_add = 0;
        s2.ops[0] = o3;
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

    // ---- 配置 4 张表：级 0 默认动作 1(DNN+DROP)；级 1-3 默认 0(NOP) ----
    rule cfg_tables (st == 4 && cfg_tbl_r < 4);
        TableConfig cfg;
        cfg.table_id = 0;
        cfg.keys = newVector;
        cfg.nkeys = 0;
        cfg.action_ids = newVector;
        cfg.action_ids[0] = 0;
        cfg.nactions = 1;
        cfg.default_action = (cfg_tbl_r == 4'd0) ? 5'd1 : 5'd0;
        cfg.def_params = replicate(0);
        cfg.stage = 0;
        cfg.pred_hdr = 6'h3F;
        dut.config_table(cfg_tbl_r, cfg);
        cfg_tbl_r <= cfg_tbl_r + 1;
        if (cfg_tbl_r == 4'd3) st <= 5;
    endrule

    // 动作程序构造（多 word 支持）
    function ActionProgram mk_prog1(ALUInsn w0insn);
        ActionProgram p;
        p.action_id = 0; p.nparams = 0;
        p.prog = newVector;
        VLIWWord w0 = newVector;
        w0[0] = w0insn;
        p.prog[0] = w0;
        p.nslots = newVector; p.nslots[0] = 1;
        p.nwords = 1;
        return p;
    endfunction

    // DNN+DROP 动作：word0 = DNN_INFER(fd=60)，word1 = DROP(fs1=60)
    // （分两个 word：RBW 语义下同 word 读不到本 word 写回的类别）
    function ActionProgram mk_dnn_drop_prog;
        ActionProgram p;
        p.action_id = 0; p.nparams = 0;
        p.prog = newVector;
        ALUInsn insn;
        VLIWWord w0 = newVector;
        insn.op = ALU_DNN_INFER; insn.fd = 60; insn.fs1 = 0; insn.fs2 = 0;
        insn.fbase = 0; insn.stride = 0; insn.imm = 0;
        insn.use_param = False; insn.pidx = 0;
        w0[0] = insn;
        p.prog[0] = w0;
        VLIWWord w1 = newVector;
        insn.op = ALU_DROP; insn.fd = 0; insn.fs1 = 60; insn.fs2 = 0;
        insn.fbase = 0; insn.stride = 0; insn.imm = 0;
        insn.use_param = False; insn.pidx = 0;
        w1[0] = insn;
        p.prog[1] = w1;
        p.nslots = newVector; p.nslots[0] = 1; p.nslots[1] = 1;
        p.nwords = 2;
        return p;
    endfunction

    // ---- 加载动作：act0 = NOP ×4 引擎；act1 = DNN+DROP 进引擎 0 ----
    rule cfg_actions (st == 5);
        if (act_cnt_r < 3'd4) begin
            ALUInsn nop;
            nop.op = ALU_NOP; nop.fd = 0; nop.fs1 = 0; nop.fs2 = 0;
            nop.fbase = 0; nop.stride = 0; nop.imm = 0;
            nop.use_param = False; nop.pidx = 0;
            dut.load_action(zeroExtend(act_cnt_r[1:0]), 5'd0, mk_prog1(nop));
        end
        else begin
            dut.load_action(3'd0, 5'd1, mk_dnn_drop_prog);
        end
        act_cnt_r <= act_cnt_r + 1;
        if (act_cnt_r == 3'd4) st <= 6;
    endrule

    // ---- 注入正常流量（类别 0 → 转发） ----
    rule inject_normal0 (st == 6);
        let pk = make_pkt(16'h003C, 8'h40, 16'hFAF0);   // len=60 ttl=64 win=64240
        EthStream s;
        s.data = tpl_1(pk);
        s.keep = '1; s.last = False; s.valid = True; s.first = True;
        dut.rx_data(s);
        st <= 7;
    endrule

    rule inject_normal1 (st == 7);
        let pk = make_pkt(16'h003C, 8'h40, 16'hFAF0);
        EthStream s;
        s.data = tpl_2(pk);
        s.keep = 32'h003FFFFF; s.last = True; s.valid = True; s.first = False;
        dut.rx_data(s);
        st <= 8;
    endrule

    // ---- 收集正常包输出（2 拍） ----
    rule collect_normal (st == 8);
        let s <- dut.tx_data;
        out_b0_r <= s.data;
        st <= 9;
    endrule

    rule collect_normal1 (st == 9);
        let s <- dut.tx_data;
        out_b1_r <= s.data;
        if (!s.last) $display("FAIL: normal out beat1 should be last");
        st <= 10;
    endrule

    // ---- 注入攻击流量（类别 1 → 丢弃） ----
    rule inject_attack0 (st == 10);
        let pk = make_pkt(16'h0028, 8'h2F, 16'h0080);   // len=40 ttl=47 win=128
        EthStream s;
        s.data = tpl_1(pk);
        s.keep = '1; s.last = False; s.valid = True; s.first = True;
        dut.rx_data(s);
        st <= 11;
    endrule

    rule inject_attack1 (st == 11);
        let pk = make_pkt(16'h0028, 8'h2F, 16'h0080);
        EthStream s;
        s.data = tpl_2(pk);
        s.keep = 32'h003FFFFF; s.last = True; s.valid = True; s.first = False;
        dut.rx_data(s);
        delay_r <= 0;
        st <= 12;
    endrule

    // ---- 等待流水线排空 ----
    rule drain_wait (st == 12);
        delay_r <= delay_r + 1;
        if (delay_r > 100) st <= 13;
    endrule

    // ---- 校验 ----
    rule check (st == 13);
        Bit#(32) e = err;
        // 正常包：原样输出（flags 未变）
        if (pkt_byte(out_b1_r, 15) != 8'h02) begin
            $display("FAIL: normal flags byte47=%h expected 02", pkt_byte(out_b1_r, 15)); e = 1;
        end
        else $display("PASS: normal packet forwarded (flags=02)");
        if (pkt_byte(out_b0_r, 29) != 8'h01) begin
            $display("FAIL: normal src_ip byte29"); e = 1;
        end
        else $display("PASS: normal src_ip intact");
        // 攻击包：被 DNN 分类丢弃
        if (dut.get_drop_count != 1) begin
            $display("FAIL: drop_count=%d expected 1 (attack dropped)", dut.get_drop_count); e = 1;
        end
        else $display("PASS: attack packet dropped by DNN");
        if (dut.get_tx_count != 1) begin
            $display("FAIL: tx_count=%d expected 1 (only normal packet)", dut.get_tx_count); e = 1;
        end
        else $display("PASS: only normal packet appeared on TX");
        err <= e;
        st <= 14;
    endrule

    rule finish (st == 14);
        if (err == 0) $display("=== DNN INFERENCE E2E: ALL PASS ===");
        else $display("=== DNN INFERENCE E2E: FAIL ===");
        $finish(0);
    endrule
endmodule

endpackage
