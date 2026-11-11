// ============================================================
// TestbenchTop.bsv - 主测试平台（已弃用假实现）
//
// ★ 原实现各 phase 硬编码 "passed+3/4/6（假设全部通过）"，是假测试。
//   真实协议端到端测试已改为三个独立模块（TestTCPReorder/TestSRv6/
//   TestVXLAN），由 make test 顺序运行（见 Makefile test 目标）。
//   本模块仅保留说明性占位，不再宣称任何通过。
// ============================================================

package TestbenchTop;

import Vector :: *;
import DefaultValue :: *;
import RMTInterfaces :: *;
import TestSRv6 :: *;
import TestVXLAN :: *;
import TestNDN :: *;
import TestDNN :: *;
import TestTCPReorder :: *;
`include "RMTConfig.bh"

// ============================================================
//                       主测试平台（占位）
// ============================================================

module mkTestbenchTop(Empty);
    rule run_all_tests (True);
        $display("========================================");
        $display("RMT-BSV - protocol e2e tests, run:");
        $display("  make test-tcp   (TCP 5-tuple match + seq+1)");
        $display("  make test-srv6  (SRv6 End: dst=seg[SL], SL-1)");
        $display("  make test-vxlan (VXLAN decap)");
        $display("========================================");
        $finish(0);
    endrule
endmodule

// ============================================================
//                       独立测试包装（供 -g 使用）
// ============================================================

module mkTestSRv6Standalone(Empty);
    Empty test <- mkTestSRv6;
endmodule

module mkTestVXLANStandalone(Empty);
    Empty test <- mkTestVXLAN;
endmodule

module mkTestNDNStandalone(Empty);
    Empty test <- mkTestNDN;
endmodule

module mkTestDNNStandalone(Empty);
    Empty test <- mkTestDNN;
endmodule

module mkTestTCPReorderStandalone(Empty);
    Empty test <- mkTestTCPReorder;
endmodule

endpackage
