// ============================================================
// MatchEngine.bsv - Match 引擎
//
// TCAM 查找 + Action SRAM
// 支持多 key 级联和门控谓词
//
// ★ 修复内容（相对原实现）：
//   1. build_key 原把 key 恒置 0，从不从 PHV 提取 → 所有查找都匹配 key=0。
//      现在按 table_config[table_id].keys 从 PHV 构建 key：
//        单 key：取该字段全 128 位；多 key：各取低 16 位按顺序拼接。
//   2. 门控谓词 pred_hdr 原未实现。现在若 pred_hdr!=-1 且对应头部无效，
//      跳过匹配直接走默认动作。
//   3. 原接口无 config_table，表配置永远无法设置。新增 config_table 方法。
//   4. insert_entry 原以 entry_count[9:0] 索引仅 64 项的 action_sram → 越界。
//      现在限制 count<64。
// ============================================================

package MatchEngine;

import Vector :: *;
import FIFOF :: *;
import SpecialFIFOs :: *;
import DefaultValue :: *;
import RMTInterfaces :: *;
import TCAMArray :: *;
`include "RMTConfig.bh"

// ============================================================
//                       状态机
// ============================================================

typedef enum {
    MATCH_IDLE,
    MATCH_BUILD_KEY,
    MATCH_LOOKUP,
    MATCH_READ_SRAM,
    MATCH_DONE
} MatchState deriving (Bits, Eq, FShow);

// ============================================================
//                       实现
// ============================================================

module mkMatchEngine(MatchEngineIfc);
    // TCAM 阵列（每表一个，仿真 16 条目）
    Vector#(16, TCAMArrayIfc) tcam_array <- replicateM(mkTCAMArray);

    // Action SRAM：★ 动作号与参数分开存储（原实现为一条 517-bit 元组，
    //   load_param 的"读改写"需要 1024 项动态读 mux → elaboration 爆炸）。
    //   仿真规模 16 项，与 TCAM 深度一致。
    Vector#(16, Vector#(16, Reg#(Bit#(5)))) action_id_sram <-
        replicateM(replicateM(mkRegU));
    Vector#(16, Vector#(16, Reg#(Vector#(8, Bit#(64))))) action_param_sram <-
        replicateM(replicateM(mkRegU));

    // 表配置（★ 初始化默认值：nkeys=0 / 默认动作 0 / 门控恒开）
    function TableConfig defaultTableConfig();
        TableConfig c;
        c.table_id = 0;
        c.keys = replicate(KeyField { field_id: 0, match_type: MATCH_EXACT });
        c.nkeys = 0;
        c.action_ids = replicate(0);
        c.nactions = 0;
        c.default_action = 0;
        c.def_params = replicate(0);
        c.stage = 0;
        c.pred_hdr = 6'h3F;
        return c;
    endfunction
    Vector#(16, Reg#(TableConfig)) table_config <- replicateM(mkReg(defaultTableConfig));

    // 状态寄存器
    Reg#(MatchState) state_r <- mkReg(MATCH_IDLE);
    Reg#(Bit#(4)) table_id_r <- mkRegU;
    Reg#(PHV) phv_r <- mkRegU;              // ★ 保存本次查找的 PHV
    Reg#(Bit#(128)) lookup_key_r <- mkRegU;
    Reg#(Bool) skip_r <- mkReg(False);      // 门控不通过：跳过匹配
    Reg#(MatchResult) result_r <- mkReg(defaultMR);

    // 结果 FIFO
    FIFOF#(MatchResult) result_fifo <- mkFIFOF;

    // --------------------------------------------------------
    // 规则：构建 key（从 PHV 提取 key 字段 + 门控检查）
    // --------------------------------------------------------
    rule build_key (state_r == MATCH_BUILD_KEY);
        let cfg = table_config[table_id_r];

        // 门控谓词：pred_hdr != -1 且对应头部无效 → 跳过匹配
        Bool gated = (cfg.pred_hdr != 6'h3F) &&
                     (phv_r.hvalid[cfg.pred_hdr[5:0]] == 1'b0);

        // 构建 key
        Bit#(128) key = 0;
        if (cfg.nkeys == 1) begin
            // 单 key：全字段宽（★ 字段索引越界检查）
            if (cfg.keys[0].field_id < 160) begin
                key = phv_r.fields[cfg.keys[0].field_id].value;
            end
        end
        else begin
            // 多 key：各取低 16 位按顺序拼接
            for (Integer i = 0; i < 8; i = i + 1) begin
                if (fromInteger(i) < cfg.nkeys && cfg.keys[i].field_id < 160) begin
                    Bit#(128) fv = phv_r.fields[cfg.keys[i].field_id].value;
                    key = key | (zeroExtend(fv[15:0]) << (fromInteger(i) * 16));
                end
            end
        end

        lookup_key_r <= key;
        skip_r <= gated;
        state_r <= MATCH_LOOKUP;
    endrule

    // 规则：TCAM 查找
    rule tcam_lookup (state_r == MATCH_LOOKUP);
        tcam_array[table_id_r].lookup(lookup_key_r);
        state_r <= MATCH_READ_SRAM;
    endrule

    // 规则：读取 Action SRAM
    rule read_sram (state_r == MATCH_READ_SRAM);
        let lookup_result <- tcam_array[table_id_r].result;
        let hit = tpl_1(lookup_result);
        let idx = tpl_2(lookup_result);
        if (!skip_r && hit) begin
            Bit#(8) sram_idx = truncate(idx);
            result_r <= MatchResult {
                hit: True,
                action_id: action_id_sram[table_id_r][sram_idx[3:0]],
                param_base: sram_idx,
                nparams: 8,
                table_id: table_id_r,
                params: action_param_sram[table_id_r][sram_idx[3:0]]
            };
        end
        else begin
            // 未命中或门控不通过：使用默认动作（★ 参数取 cfg.def_params，
            // 原先恒 0 → 默认动作的 runtime data 丢失）
            let cfg = table_config[table_id_r];
            result_r <= MatchResult {
                hit: False,
                action_id: cfg.default_action,
                param_base: 0,
                nparams: 0,
                table_id: table_id_r,
                params: cfg.def_params
            };
        end

        state_r <= MATCH_DONE;
    endrule

    // 规则：完成
    rule match_done (state_r == MATCH_DONE);
        result_fifo.enq(result_r);
        state_r <= MATCH_IDLE;
    endrule

    // --------------------------------------------------------
    // 接口方法
    // --------------------------------------------------------

    method Action lookup_req(Bit#(4) table_id, PHV phv) if (state_r == MATCH_IDLE);
        table_id_r <= table_id;
        phv_r <= phv;
        state_r <= MATCH_BUILD_KEY;
    endmethod

    method ActionValue#(MatchResult) lookup_resp;
        let res = result_fifo.first;
        result_fifo.deq;
        return res;
    endmethod

    method Action insert_entry(Bit#(4) table_id, TCAMEntry entry);
        // ★ TCAMArray 现在按 valid 位计数（原实现计数恒 0，所有插入都覆盖槽 0）。
        let count = tcam_array[table_id].entry_count;
        if (count < 16) begin
            tcam_array[table_id].write(zeroExtend(count[3:0]), entry);

            // 写入 Action SRAM（动作号 + 参数清零）
            action_id_sram[table_id][count[3:0]] <= entry.action_id;
            action_param_sram[table_id][count[3:0]] <= replicate(0);
        end
    endmethod

    method Action delete_entry(Bit#(4) table_id, Bit#(10) addr);
        // ★ 索引范围检查：TCAM 仿真深度 16，原实现 10-bit 直索越界
        if (addr < 16) begin
            tcam_array[table_id].clear(addr);
        end
    endmethod

    // ★ 命中动作参数装载：把 params[idx] 写入 SRAM 表项（原实现恒 0）
    method Action load_param(Bit#(4) table_id, Bit#(8) sram_idx,
                             Bit#(4) pidx, Bit#(64) val);
        if (sram_idx < 16 && pidx < 8) begin
            let cur = action_param_sram[table_id][sram_idx[3:0]];
            Vector#(8, Bit#(64)) np = cur;
            np[pidx[2:0]] = val;
            action_param_sram[table_id][sram_idx[3:0]] <= np;
        end
    endmethod

    method Action config_table(Bit#(4) tidx, TableConfig cfg);
        table_config[tidx] <= cfg;
    endmethod

    method Bit#(16) entry_count(Bit#(4) table_id);
        return tcam_array[table_id].entry_count;
    endmethod

endmodule

endpackage
