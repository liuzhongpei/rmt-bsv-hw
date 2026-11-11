// ============================================================
// TestNDN.bsv - NDN 转发真实端到端测试
//
// 直接实例化 mkRMTTop：
//   解析图 Eth→IPv6→UDP→NDN；4 级默认 NOP 动作
//   注入 3 个报文（同一 name_hash）：
//     1. Interest (hop=10)  → CS 未命中：登 PIT，hop 10→9 转发
//     2. Data (hop=8)       → PIT 命中：写入 CS，转发（hop 不变）
//     3. Interest (hop=10)  → CS 命中：本地 Data 回复（type→2，
//                              IP 源/目的互换，hop 不变）
//   校验：3 个输出报文的 type/hop 字节与源/目的互换结果
// ============================================================

package TestNDN;

import Vector :: *;
import FIFOF :: *;
import DefaultValue :: *;
import RMTInterfaces :: *;
import RMTTop :: *;
`include "RMTConfig.bh"

// ============================================================
//                       测试平台
// ============================================================

module mkTestNDN(Empty);
    RMTTopIfc dut <- mkRMTTop;

    Reg#(Bit#(32)) st <- mkReg(0);
    Reg#(Bit#(32)) err <- mkReg(0);
    Reg#(Bit#(4)) cfg_tbl_r <- mkReg(0);
    Reg#(Bit#(3)) act_cnt_r <- mkReg(0);
    Reg#(Bit#(4)) inj_r <- mkReg(0);        // 注入进度：pkt*3 + beat
    Reg#(Bit#(3)) beat_idx_r <- mkReg(0);   // 当前输出报文内拍号
    Reg#(Bit#(256)) b0_r <- mkReg(0);
    Reg#(Bit#(256)) b1_r <- mkReg(0);
    Reg#(Bit#(256)) b2_r <- mkReg(0);
    Reg#(Bit#(32)) cy <- mkReg(0);

    rule tick (True);
        cy <= cy + 1;
    endrule

    rule watchdog (cy > 4000 && st < 14);
        $display("NDN E2E TIMEOUT cy=%d st=%d cs=%d pit=%d",
                 cy, st, dut.get_ndn_cs_entries, dut.get_ndn_pit_entries);
        $finish(0);
    endrule

    function Bit#(8) pkt_byte(Bit#(256) beat, Integer off);
        Bit#(8) msb = 8'hFF - (fromInteger(off) * 8);
        return beat[msb : msb - 7];
    endfunction

    // 78B NDN 包：Eth(14)+IPv6(40)+UDP(8)+NDN(16) = 3 拍
    function Tuple3#(Bit#(256), Bit#(256), Bit#(256))
            make_pkt(Bit#(8) ntype, Bit#(8) hop);
        Vector#(96, Bit#(8)) byt = replicate(0);
        // IPv6 src 首4字节 @22-25，dst 首4字节 @38-41
        byt[22] = 8'h0A; byt[23] = 8'h00; byt[24] = 8'h00; byt[25] = 8'h01;
        byt[38] = 8'h0A; byt[39] = 8'h00; byt[40] = 8'h00; byt[41] = 8'h02;
        // UDP @54：sport=8080 dport=4000
        byt[54] = 8'h1F; byt[55] = 8'h90;
        byt[56] = 8'h0F; byt[57] = 8'hA0;
        // NDN @62：type@0 name_hash@4 nonce@8 hop_limit@12
        byt[62] = ntype;
        byt[66] = 8'hDE; byt[67] = 8'hAD; byt[68] = 8'hBE; byt[69] = 8'hEF;
        byt[70] = 8'h12; byt[71] = 8'h34; byt[72] = 8'h56; byt[73] = 8'h78;
        byt[74] = hop;
        Vector#(3, Bit#(256)) beats = replicate(0);
        for (Integer j = 0; j < 3; j = j + 1) begin
            Bit#(256) beat = 0;
            for (Integer i = 0; i < 32; i = i + 1) begin
                beat = (beat << 8) | zeroExtend(byt[j*32 + i]);
            end
            beats[j] = beat;
        end
        return tuple3(beats[0], beats[1], beats[2]);
    endfunction

    // ---- 配置解析图：state0(Eth)→state1(IPv6)→state2(UDP)→state3(NDN)→ACCEPT ----
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
        ParseOp o7; o7.kind = POP_EXTRACT; o7.hdr_id = 7; o7.count_field = 0; o7.count_add = 0;
        s3.ops[0] = o7;
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

    // ---- 配置 4 张表：默认动作 0（NOP） ----
    rule cfg_tables (st == 5 && cfg_tbl_r < 4);
        TableConfig cfg;
        cfg.table_id = 0;
        cfg.keys = newVector;
        cfg.nkeys = 0;
        cfg.action_ids = newVector;
        cfg.action_ids[0] = 0;
        cfg.nactions = 1;
        cfg.default_action = 5'd0;
        cfg.def_params = replicate(0);
        cfg.stage = 0;
        cfg.pred_hdr = 6'h3F;
        dut.config_table(cfg_tbl_r, cfg);
        cfg_tbl_r <= cfg_tbl_r + 1;
        if (cfg_tbl_r == 4'd3) st <= 6;
    endrule

    // ---- 加载 8 个 NOP 动作 ----
    rule cfg_actions (st == 6);
        ALUInsn nop;
        nop.op = ALU_NOP; nop.fd = 0; nop.fs1 = 0; nop.fs2 = 0;
        nop.fbase = 0; nop.stride = 0; nop.imm = 0;
        nop.use_param = False; nop.pidx = 0;
        ActionProgram p;
        p.action_id = 0; p.nparams = 0;
        p.prog = newVector;
        VLIWWord w0 = newVector;
        w0[0] = nop;
        p.prog[0] = w0;
        p.nslots = newVector; p.nslots[0] = 1;
        p.nwords = 1;
        dut.load_action(zeroExtend(act_cnt_r[1:0]), zeroExtend(act_cnt_r), p);
        act_cnt_r <= act_cnt_r + 1;
        if (act_cnt_r == 3'd7) st <= 7;
    endrule

    // ---- 注入 3 个报文 × 3 拍（收集与校验逐包交替） ----
    // 报文 0: Interest hop=10；报文 1: Data hop=8；报文 2: Interest hop=10
    // 注入状态：st 7 一次性注入 9 拍；收集状态：8/10/12；校验：9/11/13
    rule inject (st == 7 && inj_r < 9);
        // 按 inj_r 逐拍：0,1,2 = pkt0 三拍；3,4,5 = pkt1；6,7,8 = pkt2
        Bit#(8) ntype = (inj_r < 3) ? 8'd1 : (inj_r < 6) ? 8'd2 : 8'd1;
        Bit#(8) hop   = (inj_r < 3) ? 8'd10 : (inj_r < 6) ? 8'd8 : 8'd10;
        let pk = make_pkt(ntype, hop);
        Bit#(4) beatno = inj_r % 3;
        EthStream s;
        s.data  = (beatno == 0) ? tpl_1(pk) : (beatno == 1) ? tpl_2(pk) : tpl_3(pk);
        s.keep  = (beatno == 2) ? 32'h00003FFF : '1;   // 末拍 14 字节
        s.last  = (beatno == 2);
        s.first = (beatno == 0);
        s.valid = True;
        dut.rx_data(s);
        inj_r <= inj_r + 1;
        if (inj_r == 8) st <= 8;
    endrule

    // ---- 收集当前输出报文（3 拍），收完进入对应校验状态 ----
    rule collect (st == 8 || st == 10 || st == 12);
        let s <- dut.tx_data;
        if (s.first) begin
            b0_r <= s.data;
            beat_idx_r <= 3'd1;
        end
        else begin
            if (beat_idx_r == 3'd1) begin
                b1_r <= s.data;
                beat_idx_r <= 3'd2;
            end
            else begin
                b2_r <= s.data;
                beat_idx_r <= 3'd0;
            end
        end
        if (s.last) st <= st + 1;
    endrule

    // ---- 报文 0 校验：Interest 转发，hop 10→9 ----
    rule check0 (st == 9);
        Bit#(32) e = err;
        if (pkt_byte(b1_r, 30) != 8'd1) begin
            $display("FAIL: pkt0 type byte62=%h expected 01 (Interest fwd)",
                     pkt_byte(b1_r, 30)); e = 1;
        end
        else $display("PASS: pkt0 Interest forwarded");
        if (pkt_byte(b2_r, 10) != 8'd9) begin
            $display("FAIL: pkt0 hop byte74=%h expected 09 (decremented)",
                     pkt_byte(b2_r, 10)); e = 1;
        end
        else $display("PASS: pkt0 hop_limit 10 -> 9");
        err <= e;
        st <= 10;
    endrule

    // ---- 报文 1 校验：Data 转发（PIT 命中 → 建 CS），hop 不变 ----
    rule check1 (st == 11);
        Bit#(32) e = err;
        if (pkt_byte(b1_r, 30) != 8'd2) begin
            $display("FAIL: pkt1 type byte62=%h expected 02 (Data fwd)",
                     pkt_byte(b1_r, 30)); e = 1;
        end
        else $display("PASS: pkt1 Data forwarded");
        if (pkt_byte(b2_r, 10) != 8'd8) begin
            $display("FAIL: pkt1 hop byte74=%h expected 08 (unchanged)",
                     pkt_byte(b2_r, 10)); e = 1;
        end
        else $display("PASS: pkt1 hop_limit unchanged (8)");
        err <= e;
        st <= 12;
    endrule

    // ---- 报文 2 校验：CS 命中 → 本地 Data 回复（type→2，源/目的互换） ----
    rule check2 (st == 13);
        Bit#(32) e = err;
        if (pkt_byte(b1_r, 30) != 8'd2) begin
            $display("FAIL: pkt2 type byte62=%h expected 02 (CS hit -> Data reply)",
                     pkt_byte(b1_r, 30)); e = 1;
        end
        else $display("PASS: pkt2 CS hit -> local Data reply");
        if (pkt_byte(b0_r, 22) != 8'h0A || pkt_byte(b0_r, 23) != 8'h00
            || pkt_byte(b0_r, 24) != 8'h00 || pkt_byte(b0_r, 25) != 8'h02) begin
            $display("FAIL: pkt2 src bytes22-25 swapped from dst expected 0A000002");
            e = 1;
        end
        else $display("PASS: pkt2 IP src <- original dst (0A000002)");
        if (pkt_byte(b1_r, 6) != 8'h0A || pkt_byte(b1_r, 7) != 8'h00
            || pkt_byte(b1_r, 8) != 8'h00 || pkt_byte(b1_r, 9) != 8'h01) begin
            $display("FAIL: pkt2 dst bytes38-41 swapped from src expected 0A000001");
            e = 1;
        end
        else $display("PASS: pkt2 IP dst <- original src (0A000001)");
        if (dut.get_ndn_cs_entries != 1) begin
            $display("FAIL: CS entries=%d expected 1", dut.get_ndn_cs_entries); e = 1;
        end
        else $display("PASS: CS has 1 entry");
        if (dut.get_ndn_pit_entries != 0) begin
            $display("FAIL: PIT entries=%d expected 0 (consumed)", dut.get_ndn_pit_entries); e = 1;
        end
        else $display("PASS: PIT consumed (0 entries)");
        err <= e;
        st <= 14;
    endrule

    rule finish (st == 14);
        if (err == 0) $display("=== NDN FORWARDING E2E: ALL PASS ===");
        else $display("=== NDN FORWARDING E2E: FAIL ===");
        $finish(0);
    endrule
endmodule

endpackage
