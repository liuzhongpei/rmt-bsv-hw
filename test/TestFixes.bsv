// ============================================================
// TestFixes.bsv - 回归测试：本轮缺陷修复验证
//
//   A. TCAM：空槽不命中 / 计数正确 / clear 后不命中 / LPM 最长前缀
//   B. MatchEngine：多表项不互相覆盖 / 命中动作参数可装载
//   C. ALU：MOVI 立即数不被清零 / MOV 按目的字段宽度截断
//   D. 解析器：payload_offset 跨报文复位
//   E. TCP 重组：删除会话与报文同拍到达时删除不丢失
// ============================================================

package TestFixes;

import Vector :: *;
import FIFOF :: *;
import DefaultValue :: *;
import RMTInterfaces :: *;
import TCAMArray :: *;
import MatchEngine :: *;
import ProgrammableParser :: *;
import TCPReorderEngine :: *;
import ALU :: *;
`include "RMTConfig.bh"

module mkTestFixes(Empty);
    TCAMArrayIfc          tcam   <- mkTCAMArray;
    MatchEngineIfc        me     <- mkMatchEngine;
    ProgrammableParserIfc parser <- mkProgrammableParser;
    TCPReorderEngineIfc   tcp    <- mkTCPReorderEngine;

    Reg#(Bit#(8))  st     <- mkReg(0);
    Reg#(Bit#(16)) cy     <- mkReg(0);
    Reg#(Bit#(16)) wait_r <- mkReg(0);
    Reg#(Bit#(32)) err    <- mkReg(0);

    rule tick (True);
        cy <= cy + 1;
        if (cy > 8000) begin
            $display("WD: timeout st=%0d", st);
            $finish(0);
        end
    endrule

    // ---------------- 构造辅助 ----------------
    function TCAMEntry mkEntry(Bit#(128) k, Bit#(128) m, Bit#(5) a);
        TCAMEntry e;
        e.key = k; e.mask = m; e.action_id = a; e.params = 0;
        return e;
    endfunction

    function TableConfig mkCfg1;
        TableConfig cfg;
        cfg.table_id = 0;
        cfg.keys = newVector;
        KeyField kf;
        kf.field_id = 10; kf.match_type = MATCH_EXACT;
        cfg.keys[0] = kf;
        cfg.nkeys = 1;
        cfg.action_ids = newVector;
        cfg.action_ids[0] = 0;
        cfg.nactions = 1;
        cfg.default_action = 5'd3;
        cfg.def_params = replicate(0);
        cfg.stage = 0;
        cfg.pred_hdr = 6'h3F;
        return cfg;
    endfunction

    function ParseState mkPState(Bit#(6) hdr, Bit#(3) nops);
        ParseState s;
        s.name_id = 0;
        Vector#(4, ParseOp) ops = newVector;
        ParseOp op;
        op.kind = POP_EXTRACT; op.hdr_id = hdr;
        op.count_field = 0; op.count_add = 0;
        ops[0] = op;
        s.ops = ops;
        s.nops = nops;
        s.sel_field = 8'hFF;
        s.cases = replicate(SelCase { sel_val: 0, next_state: 0 });
        s.ncases = 0;
        s.def_next = 5'h1F;
        return s;
    endfunction

    function TCP5Tuple mkKey(Bit#(32) sip, Bit#(32) dip, Bit#(16) sp, Bit#(16) dp);
        TCP5Tuple k;
        k.src_ip = sip; k.dst_ip = dip; k.src_port = sp; k.dst_port = dp;
        return k;
    endfunction

    function PHV mkTcpPHV(Bit#(32) sip, Bit#(32) dip, Bit#(16) sp, Bit#(16) dp);
        PHV p = defaultValue;
        p.fields[10] = FieldValue { value: zeroExtend(sip), bitlen: 32 };
        p.fields[11] = FieldValue { value: zeroExtend(dip), bitlen: 32 };
        p.fields[20] = FieldValue { value: zeroExtend(sp), bitlen: 16 };
        p.fields[21] = FieldValue { value: zeroExtend(dp), bitlen: 16 };
        p.fields[22] = FieldValue { value: zeroExtend(32'd0), bitlen: 32 };
        p.fields[24] = FieldValue { value: zeroExtend(8'd0), bitlen: 8 };   // 非 SYN
        return p;
    endfunction

    function PktDesc mkTcpDesc;
        PktDesc d = defaultValue;
        d.pkt_len = 54; d.hdr_bytes = 54; d.is_tcp = True;
        return d;
    endfunction

    function PHV mkPHV10(Bit#(128) v);
        PHV p = defaultValue;
        p.fields[10] = FieldValue { value: v, bitlen: 32 };
        return p;
    endfunction

    // ============ A. TCAM ============
    rule a0 (st == 0);
        tcam.lookup(128'h1234);   // 无表项
        st <= 1;
    endrule
    rule a1 (st == 1);
        let r <- tcam.result;
        if (tpl_1(r)) begin $display("FAIL A1: empty TCAM reported hit"); err <= err | 1; end
        else $display("PASS A1: empty TCAM miss");
        tcam.write(0, mkEntry(128'hAA, 128'hFF, 5'd7));
        st <= 2;
    endrule
    rule a2 (st == 2);
        tcam.write(1, mkEntry(128'hBB, 128'hFF, 5'd5));
        st <= 3;
    endrule
    rule a3 (st == 3);
        if (tcam.entry_count != 2) begin
            $display("FAIL A2: entry_count=%0d expected 2", tcam.entry_count);
            err <= err | 1;
        end
        else $display("PASS A2: entry_count=2 after 2 writes");
        tcam.lookup(128'hAA);
        st <= 4;
    endrule
    rule a4 (st == 4);
        let r <- tcam.result;
        if (!tpl_1(r) || tpl_2(r) != 0) begin
            $display("FAIL A3: entry0 hit=%0d idx=%0d", tpl_1(r), tpl_2(r));
            err <= err | 1;
        end
        else $display("PASS A3: entry0 matches");
        tcam.lookup(128'hBB);
        st <= 5;
    endrule
    rule a5 (st == 5);
        let r <- tcam.result;
        if (!tpl_1(r) || tpl_2(r) != 1) begin
            $display("FAIL A4: entry1 hit=%0d idx=%0d", tpl_1(r), tpl_2(r));
            err <= err | 1;
        end
        else $display("PASS A4: entry1 matches (no overwrite)");
        tcam.lookup(128'hCC);
        st <= 6;
    endrule
    rule a6 (st == 6);
        let r <- tcam.result;
        if (tpl_1(r)) begin
            $display("FAIL A5: empty slot matched 0xCC");
            err <= err | 1;
        end
        else $display("PASS A5: no wildcard match on empty slot");
        tcam.clear(0);
        st <= 7;
    endrule
    rule a7 (st == 7);
        tcam.lookup(128'hAA);
        st <= 8;
    endrule
    rule a8 (st == 8);
        let r <- tcam.result;
        Bit#(32) e = err;
        if (tpl_1(r)) begin
            $display("FAIL A6: cleared slot still matches");
            e = e | 1;
        end
        else $display("PASS A6: cleared slot does not match");
        if (tcam.entry_count != 1) begin
            $display("FAIL A7: entry_count=%0d expected 1 after clear", tcam.entry_count);
            e = e | 1;
        end
        else $display("PASS A7: entry_count=1 after clear");
        err <= e;
        // LPM：/16 与 /32 同时命中时取更长前缀
        tcam.write(0, mkEntry(128'hAA00, 128'hFF00, 5'd2));
        st <= 9;
    endrule
    rule a9 (st == 9);
        tcam.write(1, mkEntry(128'hAA11, 128'hFFFF, 5'd4));
        st <= 10;
    endrule
    rule a10 (st == 10);
        tcam.lookup(128'hAA11);
        st <= 11;
    endrule
    rule a11 (st == 11);
        let r <- tcam.result;
        if (!tpl_1(r) || tpl_2(r) != 1) begin
            $display("FAIL A8: LPM expected idx1(/32), got hit=%0d idx=%0d", tpl_1(r), tpl_2(r));
            err <= err | 1;
        end
        else $display("PASS A8: LPM longest-prefix wins");
        st <= 12;
    endrule

    // ============ B. MatchEngine ============
    rule b0 (st == 12);
        me.config_table(0, mkCfg1);
        st <= 13;
    endrule
    rule b1 (st == 13);
        me.insert_entry(0, mkEntry(128'hAA, 128'hFF, 5'd7));
        st <= 14;
    endrule
    rule b2 (st == 14);
        me.insert_entry(0, mkEntry(128'hBB, 128'hFF, 5'd5));
        st <= 15;
    endrule
    rule b3 (st == 15);
        if (me.entry_count(0) != 2) begin
            $display("FAIL B1: match entry_count=%0d expected 2", me.entry_count(0));
            err <= err | 1;
        end
        else $display("PASS B1: match table holds 2 entries");
        me.load_param(0, 8'd0, 4'd0, 64'h1234);
        me.lookup_req(0, mkPHV10(128'hAA));
        st <= 16;
    endrule
    rule b4 (st == 16);
        let mr <- me.lookup_resp;
        Bit#(32) e = err;
        if (!mr.hit || mr.action_id != 5'd7) begin
            $display("FAIL B2: lookup AA hit=%0d action=%0d", mr.hit, mr.action_id);
            e = e | 1;
        end
        else $display("PASS B2: lookup AA -> action 7");
        if (mr.params[0] != 64'h1234) begin
            $display("FAIL B3: hit params[0]=%0h expected 1234", mr.params[0]);
            e = e | 1;
        end
        else $display("PASS B3: hit action param loaded");
        err <= e;
        me.lookup_req(0, mkPHV10(128'hBB));
        st <= 17;
    endrule
    rule b5 (st == 17);
        let mr <- me.lookup_resp;
        if (!mr.hit || mr.action_id != 5'd5) begin
            $display("FAIL B4: lookup BB hit=%0d action=%0d", mr.hit, mr.action_id);
            err <= err | 1;
        end
        else $display("PASS B4: lookup BB -> action 5");
        me.lookup_req(0, mkPHV10(128'hCC));
        st <= 18;
    endrule
    rule b6 (st == 18);
        let mr <- me.lookup_resp;
        if (mr.hit) begin $display("FAIL B5: lookup CC should miss"); err <= err | 1; end
        else $display("PASS B5: lookup CC miss (default action)");
        st <= 19;
    endrule

    // ============ C. ALU ============
    rule c0 (st == 19);
        ALUInsn insn = ALUInsn {
            op: ALU_MOVI, fd: 10, fs1: 0, fs2: 0,
            fbase: 0, stride: 0, imm: 64'h1234,
            use_param: False, pidx: 0
        };
        FieldValue s1 = FieldValue { value: 0, bitlen: 0 };
        FieldValue s2 = FieldValue { value: 0, bitlen: 0 };
        Bit#(32) e = err;

        let wb = alu_execute(insn, 0, s1, s2, 0);
        if (wb.kind != WB_FIELD || wb.val.value != 128'h1234) begin
            $display("FAIL C1: MOVI value=0x%0h (expected 0x1234)", wb.val.value);
            e = e | 1;
        end
        else $display("PASS C1: MOVI keeps immediate");

        ALUInsn mv = ALUInsn {
            op: ALU_MOV, fd: 21, fs1: 10, fs2: 0,
            fbase: 0, stride: 0, imm: 0,
            use_param: False, pidx: 0
        };
        FieldValue big = FieldValue { value: 128'hDEADBEEF, bitlen: 32 };
        let wb2 = alu_execute(mv, 0, big, s2, 8'd16);
        if (wb2.val.bitlen != 16 || wb2.val.value != 128'hBEEF) begin
            $display("FAIL C2: MOV dst16 bitlen=%0d value=0x%0h", wb2.val.bitlen, wb2.val.value);
            e = e | 1;
        end
        else $display("PASS C2: MOV truncated to dst width 16");
        err <= e;
        st <= 20;
    endrule

    // ============ D. 解析器 payload_offset ============
    rule d0 (st == 20);
        parser.load_state(0, mkPState(6'd6, 3'd1));   // 提取 VXLAN
        parser.set_start_state(0);
        st <= 21;
    endrule
    rule d1 (st == 21);
        PktDesc d = defaultValue;
        d.pkt_len = 96;
        parser.start(d);
        parser.provide_data(replicate(0));
        st <= 22;
    endrule
    rule d2 (st == 22);
        let r <- parser.result;
        if (tpl_1(r).payload_offset != 12'd8) begin
            $display("FAIL D1: VXLAN payload_offset=%0d expected 8", tpl_1(r).payload_offset);
            err <= err | 1;
        end
        else $display("PASS D1: VXLAN payload_offset=8");
        parser.load_state(0, mkPState(6'd0, 3'd0));   // 不提取任何头
        st <= 23;
    endrule
    rule d3 (st == 23);
        PktDesc d = defaultValue;
        d.pkt_len = 96;
        parser.start(d);
        parser.provide_data(replicate(0));
        st <= 24;
    endrule
    rule d4 (st == 24);
        let r <- parser.result;
        if (tpl_1(r).payload_offset != 12'd0) begin
            $display("FAIL D2: stale payload_offset=%0d expected 0", tpl_1(r).payload_offset);
            err <= err | 1;
        end
        else $display("PASS D2: payload_offset reset per packet");
        st <= 25;
    endrule

    // ============ E. TCP 删除与报文竞争 ============
    rule e0 (st == 25);
        tcp.create_session(mkKey(32'h01010101, 32'h02020202, 16'd100, 16'd200),
                           32'd0);
        st <= 26;
    endrule
    rule e1 (st == 26);
        tcp.delete_session(mkKey(32'h01010101, 32'h02020202, 16'd100, 16'd200));
        st <= 27;
    endrule
    rule e2 (st == 27);
        // 与 delete_req 同拍进入一个其他会话的报文（原实现会抢走查找响应）
        tcp.insert_pkt(mkTcpDesc,
                       mkTcpPHV(32'h03030303, 32'h04040404, 16'd300, 16'd400),
                       replicate(0));
        st <= 28;
    endrule
    rule e3 (st == 28);
        wait_r <= wait_r + 1;
        if (wait_r > 200) st <= 29;
    endrule
    rule e4 (st == 29);
        if (tcp.active_sessions != 0) begin
            $display("FAIL E1: delete lost, active_sessions=%0d", tcp.active_sessions);
            err <= err | 1;
        end
        else $display("PASS E1: delete survives racing packet");
        st <= 30;
    endrule
    rule fin (st == 30);
        if (err == 0) $display("=== FIX REGRESSION: ALL PASS ===");
        else $display("=== FIX REGRESSION: FAIL (%0d) ===", err);
        $finish(0);
    endrule
endmodule
endpackage
