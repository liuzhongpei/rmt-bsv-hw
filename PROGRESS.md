# RMT-BSV 实现进度

## 完成状态

### ✅ Phase 1: 基础设施 (已完成)

#### 1.1-1.3 工程基础 ✅
- [x] 创建目录结构 `/home/gf/Project/rmt-bsv-hw/`
- [x] `RMTConfig.bh` - 全局配置宏（160+ 行）
- [x] `RMTInterfaces.bsv` - 类型定义和接口（700+ 行）
- [x] `README.md` - 项目文档

**关键类型定义：**
- `FieldValue` - 128-bit 字段值（右对齐）
- `PHV` - Packet Header Vector（160 字段 + hvalid + dirty）
- `PktDesc` - 报文描述符
- `ALUOpcode` - 29 种 ALU 操作码
- `ALUInsn` - ALU 指令
- `VLIWWord` - 16 条并行指令
- `ActionProgram` - 动作微码（8 个 VLIW word）
- `MatchType` - Exact/LPM 匹配类型
- `TableConfig` - 表配置
- `TCAMEntry` - TCAM 条目
- `TCP5Tuple` - TCP 5 元组
- `TCPSessionEntry` - TCP 会话条目
- `ReorderSlot` - 重排缓冲条目
- 所有接口定义（PHVRegFileIfc, ALUIfc, MatchEngineIfc 等）

#### 1.4 ALU 模块 ✅
- [x] `ALU.bsv` - 单个 RISC ALU（350+ 行）

**实现的功能：**
- 29 种操作码（NOP, MOVI, MOV, ADD, SUB, AND, OR, XOR, SHL, SHR, ADDI, SUBI, ANDI, ORI, XORI, SHLI, SHRI, MOVX, VALID, INVALID, 以及 9 个有状态 extern 操作）
- Read-Before-Write 语义（两相提交）
- 128-bit 算术运算
- 立即数和动作参数支持
- 按字段位宽截断（fv_mask 语义）
- 单元测试台（mkALUTester）

#### 1.5-1.6 PHV 寄存器堆 ✅
- [x] `PHVBank.bsv` - 单个 PHV bank（150+ 行）
  - BRAM 实现（40 条目 × 136 bits）
  - 双端口读写
  - 1 周期读延迟
  - 寄存器实现备选（用于仿真）

- [x] `PHVRegFile.bsv` - 4-bank PHV 寄存器堆（400+ 行）
  - 4 个 bank 交错存储（field_id % 4）
  - 4 个读端口 + 4 个写端口
  - hvalid 位图（64-bit）
  - dirty 位图（160 bits）
  - 模板复位
  - PHV 快照/恢复
  - 简化版本（寄存器实现，用于仿真）

## 下一步：Phase 2 - 解析器与逆解析器

### 计划实现

#### 2.1 ParserStateTable.bsv
- 32 条目 × 400 bits BRAM
- 配置写接口
- 解析 FSM 读接口

#### 2.2 ProgrammableParser.bsv
- 表驱动 FSM 解析器
- EXTRACT 操作（字节对齐快路径 + 位精确慢路径）
- EXTRACT_ARRAY 操作（运行时数量的头栈）
- Select/转换逻辑
- ACCEPT 状态检测
- PHV 写回

#### 2.3 PacketBuffer.bsv
- AXI-Stream slave（RX）
- AXI-Stream master（TX）
- 内部报文存储（512 × 256-bit）
- 报文对齐读写
- SOF/EOF 跟踪

#### 2.4 Deparser.bsv
- 完整逆解析模式
- 快速路径原位模式
- 有效载荷追加

## 代码统计

| 文件 | 行数 | 状态 |
|------|------|------|
| RMTConfig.bh | ~100 | ✅ |
| RMTInterfaces.bsv | ~700 | ✅ |
| ALU.bsv | ~350 | ✅ |
| PHVBank.bsv | ~150 | ✅ |
| PHVRegFile.bsv | ~400 | ✅ |
| README.md | ~200 | ✅ |
| **总计** | **~1,900** | |

## 编译测试

要编译这些 BSV 文件，需要安装 Bluespec Compiler (BSC)。

```bash
cd /home/gf/Project/rmt-bsv-hw
# 假设 BSC 已安装
bsc -u -p src src/RMTInterfaces.bsv
bsc -u -p src src/ALU.bsv
bsc -u -p src src/PHVBank.bsv
bsc -u -p src src/PHVRegFile.bsv
```

## 架构亮点

### BSV 规则守卫提升
所有模块都遵循"条件提升为守卫"原则，例如 ALU.bsv：
```bluespec
rule alu_compute (loaded_r && ready_r);
    // 所有计算逻辑
endrule
```

### Read-Before-Write 语义
ALU 三阶段执行保证 VLIW 的 RBW 语义：
1. Phase 1 (READ): 所有 ALU 读操作数
2. Phase 2 (EXEC): 组合逻辑计算
3. Phase 3 (COMMIT): 同时写回 PHV

### 4-Bank PHV 架构
- 字段按 field_id % 4 分布到 4 个 bank
- 每周期可并行读写 4 个字段
- 避免 bank 冲突

---

## 代码审查与修复记录（2026-09-14）

对全部 21 个 src 模块做了逐行审查，修复以下问题（修复前基线：TCP/SRv6/VXLAN 三个 e2e 全部 PASS）：

### 正确性修复

| # | 文件 | 问题 | 影响 |
|---|------|------|------|
| 1 | MatchEngine.bsv | insert_entry 以 count[9:0] 索引仅 16 项的仿真 TCAM，第 17 次插入越界崩溃 | 运行时崩溃 |
| 2 | TCAMArray.bsv | LPM 优先级取最低索引命中，非最长前缀优先 | LPM 路由选路错误 |
| 3 | ActionEngine.bsv | MOVX 索引（如 SRH 的 SL）来自报文数据，越出 160 字段时运行时越界 | 恶意/畸形报文崩溃 |
| 4 | TCPReorderEngine.bsv | 乱序缓存 16 槽用自由环回计数，输出后从不释放 → 超 16 包 buf_idx 别名覆盖 | 缓存包数据损坏 |
| 5 | ReorderBuffer.bsv | 会话槽满时静默覆盖槽 0；get_next 空表递减 slot_count 下溢回绕 255 | 计数漂移/覆盖 |
| 6 | ControlPlane.bsv | CP_CMD_PARSER_CONFIG 入队后无人消费，FIFO 堆满 16 条 → AXI 写通道死锁 | 控制面死锁 |
| 7 | RMTTop.bsv | axi_read 状态寄存器读 ControlPlane 死计数器（数据面从不更新）→ 恒 0 | 状态查询失真 |

### 功能完备性修复

| # | 文件 | 内容 |
|---|------|------|
| 8 | RMTInterfaces/MatchEngine/RMTTop | 动作参数通路贯通：MatchResult 增加 params 向量，命中=表项参数、未命中=默认动作 def_params，经 ActionEngine start 传入（use_param 微码从此可用） |
| 9 | AXILiteSlave.bsv | 地址译码补全 TABLE_DELETE(4'h4)/TCP_SESSION_CREATE(5)/DELETE(6)/PHV_TEMPLATE_SET(7)，原来经 AXI 永远不可达 |
| 10 | RMTTop.bsv | 新增 phv_template_set 消费规则（广播到 4 级引擎 load_template），消除控制面另一处死锁隐患 |
| 11 | ProgrammableParser.bsv | parse_done 设置 desc.is_tcp（TCP 头有效位）；引擎对非 TCP 直接旁路，UDP 等不再进 5 元组会话表 |
| 13 | TCPReorderEngine/ReorderBuffer | 多会话轮询 drain：当前会话无连续可输出包时轮询切换到下一个有缓存的会话（新增 next_buffered 查询），消除交错流量下"无后续报文的会话缓存包永远饿死"的限制 |
| 12 | Deparser.bsv | 补丁字段覆盖扩展到全部 17 个支持字段（sport/dport/ack/flags/SID0-7/VNI），并加"所属头有效"防护。★ 实现改用"按拍分组"（每拍独立叠加落在此拍的字节补丁，无跨字段替换链）——原"逐字段链式整向量重写"在 17 字段时 elaboration 内存 >24G，按拍分组后线性开销 |

### 已知限制（记录，非缺陷）

- PayloadConcat 模块已实例化但引擎按"报文粒度"重排输出，未做字节流拼接；
- AXI CP_CMD_ACTION_LOAD 只能装载全 NOP 的占位微码（ActionProgram ~2.5Kbit
  无法经单次 64-bit AXI 写承载），真实微码装载走专用 load_action 接口；
- Deparser 解封装路径（structural）按 payload_offset 原样搬移，不叠加脏字段补丁；
- 会话删除后其重排槽位等待超时老化回收（不做主动清空）；
- PacketBuffer 512 项环形缓冲无满溢保护（仿真规模下足够）；
- TCAM/会话表/重排缓冲/NDN CS/PIT 均为仿真缩小规模（16/8/8×8/8/8），上板前需恢复宏定义规模。

## NDN / DNN 真实实现（2026-09-29）

### DNN 推理（ALU 微码通路）

- 新增 `ALU_DNN_INFER`（6'h1C）：量化 MLP——4 特征 → 4 隐层 ReLU → 2 类 argmax，
  纯组合实现于 ActionEngine（exec 阶段拦截）；
  特征字段：f0=ipv4.total_len(13)、f1=ipv4.ttl(12)、f2=tcp.flags(24)、f3=tcp.window(25)
  （解析器已扩展提取 12/13/25）；权重 8×32-bit 寄存器，复位默认
  dnn_default_weights，可经 `load_dnn_weight` 运行时覆盖
- 新增 `ALU_DROP`（6'h1D）：条件丢弃——字段 fs1 值非零 → 置 PHV.dropped
  （新增 PHV 成员 + WB_DROP 写回类型 + PHVRegFile dropped_r 存储快照）
  ★ 使用模式：DNN 类别写入 field X（word0），DROP fs1=X 须放在**后续 VLIW word**
  （RBW 语义下同 word 读不到本 word 写回）
- RMTTop 末级动作完成后：phv.dropped → inc_drop 并拦截（不再进入后端引擎）
- `load_dnn_weight` 经 RMTTop 广播到全部 4 级引擎

### NDN 转发（独立引擎通路）

- 新增 `src/NDNEngine.bsv`（仿 TCPReorderEngine 架构，单报文 FSM）：
  - CS（8 项直接映射）：Interest 命中 → 本地 Data 回复（type 置 2、IP 源/目的
    互换、出端口=入端口，全部经 PHV dirty 位由逆解析补丁输出）
  - PIT（8 项，name_hash → 请求者入端口）：Interest 未命中 CS → 登记 PIT +
    hop_limit-1 转发（hop==0 丢弃）；Data 命中 PIT → 写入 CS、按记录端口转发
  - Data 无等待者 / 未知类型 → 丢弃（PktDesc.dropped，RMTTop 拦截计数）
- 解析器新增 NDN 头（hdr_id 7，16B）：type/name_hash/nonce/hop_limit → 字段 50-53，
  hvalid[7]
- RMTTop 末级分流：hvalid[7] → NDN 引擎，否则 → TCP 重组；NDN 输出直连逆解析
- Deparser 支持 NDN 偏移推断（ndn_off）与字段 50/53 补丁；补丁字段扩至 19 个

### 测试（TestNDN / TestDNN 已重写为真实 e2e，剔除 mkTestPlatform 桩）

- TestDNN：正常流量（len=60, ttl=64, win=64240）→ 类别 0 转发原样输出；
  攻击流量（len=40, ttl=47, win=128）→ 类别 1 丢弃（drop_count=1, tx_count=1）
- TestNDN：Interest 转发（hop 10→9）→ Data 建 CS（hop 不变）→ 再来 Interest
  CS 命中本地 Data 回复（type→2、源/目的互换、CS=1、PIT=0）
- `make test` 现运行全部 5 个真实协议 e2e（TCP/SRv6/VXLAN/NDN/DNN）

## 第二轮审查修复（2026-09-29，针对 NDN/DNN 新代码 + TCP 重组语义）

| # | 文件 | 问题 | 影响 |
|---|------|------|------|
| 1 | NDNEngine.bsv | CS 命中只查 valid 位、PIT 消费不比对名字哈希 → 直接映射哈希冲突时错误本地回复/误消费他人 PIT 表项 | 命中=valid 且 name_hash 匹配；插入记录哈希 |
| 2 | ActionEngine.bsv | DNN 推理对非 IPv4+TCP 报文（特征字段恒 0）恒判类别 1 → DNN+DROP 作默认动作时误杀全部非特征流量 | 特征有效性防护：hvalid[1]&&hvalid[3] 才推理，否则类别 0 |
| 3 | SessionTracker/TCPReorderEngine | 会话 expected_seq 恒从 0 开始，SYN 未计入（SYN 消耗 1 序号）→ 真实握手后数据流序号被误判超前/重复 | create 增加 init_seq 参数返回槽位；process_miss 以 SYN.seq+payload+1 初始化；TestTCPReorder 同步更新（SYN 1000 → 期望 1011 → 超前 1021） |

### 新增已知限制

- 控制面 AXI 预建 TCP 会话 expected_seq=0（单次 64-bit 写无法携带 SYN 序号）；
  数据面 SYN 自动建会话使用真实序号
- NDN CS/PIT 直接映射：同槽位新名字覆盖旧名字（PIT 覆盖后旧 Interest 的 Data
  将被丢弃；CS 覆盖后旧名字 Interest 不再本地命中）


## 第三轮审查修复（2026-10/11，全部缺陷修复）

> 背景：对全部源文件逐行审查 + Bluesim 探针实测复现，修复下列缺陷；
> 新增 `test/TestFixes.bsv` 回归测试（`make test-fixes`，已并入 `make test`）。

### A. 已实测复现的确定性缺陷

| # | 文件 | 问题 | 修复 |
|---|------|------|------|
| 1 | TCAMArray.bsv | 空槽 / clear() 后的槽（mask=0）满足 `(k&0)==(k'&0)` → 匹配一切；`entry_count` 用 key==0 判空 + mkRegU → 恒 0 / clear 后下溢 65535 | 每槽独立 valid 位；空槽不参与匹配；计数按 valid 维护；所有索引加范围检查 |
| 2 | MatchEngine.bsv | insert_entry 以 entry_count 为写指针 → 第 2 次插入覆盖槽 0（每表只能存 1 条）；delete_entry 10-bit 地址直索 16 项越界 | 计数修正后按序写槽；delete 地址 <16 检查；build_key 字段索引 <160 检查 |
| 3 | TCPReorderEngine/SessionTracker | 删除会话与数据面查找共用 lookup 通道 → 删除与报文同拍时响应错配：删除丢失 / 删错会话 / 报文误用他会话状态 | SessionTracker 增加独立 delete_lookup_req/resp 通道；insert_pkt 守卫加 `!del_pending_r` |
| 4 | ALU.bsv | 写回位宽取源字段 bitlen：MOVI（fs1 未设置）被清零；MOV 不按目的字段宽度截断（覆盖相邻字段） | 新增 `wb_width`：优先目的字段宽度，未设置回退源宽度，MOVI 无源时取 128 |
| 5 | ProgrammableParser.bsv | start() 未复位 payload_offset_r → 上一条 VXLAN 报文的偏移泄漏到下一包，逆解析错误解封装 | start() 复位 payload_offset_r；逆解析解封装条件加 `payload_offset < pkt_len` |

### B. 代码审查修复（资源/控制面/健壮性）

| # | 文件 | 修复 |
|---|------|------|
| 6 | TCPReorderEngine/ReorderBuffer | 乱序缓存 ooo 槽泄漏：insert 返回 Bool 后引擎才占用 ooo 槽；超时槽经 timeout FIFO 通知引擎释放 ooo 槽 |
| 7 | RMTTop.bsv | 控制面命令索引改为「物理级 + 表 0」语义（原来把表号/动作号当引擎号 → AXI 表项永远查不到、动作号≥4 越界）；公开方法索引加 <4/<16 检查 |
| 8 | ControlPlane.bsv | AXI 表项插入的动作号取自 addr[11:8]；ACTION_LOAD 携带物理级；TCP 会话两笔写（IP 对 + 端口对/初始 expected_seq），端口不再恒 0 |
| 9 | MatchEngine/RMTTop | 新增 `load_param` / `load_entry_params`：命中动作参数可装载（原实现命中 params 恒 0） |
| 10 | ActionEngine.bsv | microcode_rom 初始化为全 NOP（未装载动作号不再执行随机微码）；fs1/fs2/fd/pidx 越界防护 |
| 11 | ProgrammableParser/Deparser | 提取并存储 IPv4 IHL（字段14）与 TCP data offset（字段26），解析/逆解析按真实头长计算（支持选项头）；读字节越界防护 |
| 12 | SessionTracker.bsv | lookup_req 增加 `!pending` 守卫（消除 BSC "shadows the effects" 告警与调度依赖）；update/get_session/delete 索引范围检查 |
| 13 | ReorderBuffer.bsv | get_next 按 expected_seq 精确匹配（原取最小 seq，序号回绕时错）；remove 防下溢；索引统一截断 |
| 14 | TCPReorderEngine.bsv | 32 位序号比较改为有符号差值（回绕安全）；payload_len 下溢防护 |
| 15 | NDNEngine.bsv | CS 本地应答同时互换 UDP 端口（原来只换 IP） |
| 16 | PacketBuffer.bsv | 零长报文不再发出 128 拍垃圾 |
| 17 | PipelineController.bsv | 延迟统计真实化（rx 时间戳 + tx 累加）；avg_latency 不再恒 0 |
| 18 | AXILiteSlave.bsv | read_data 增加 notEmpty 守卫（接真实 AXI 读通道不再死锁） |
| 19 | PHVRegFile.bsv | 读/写/模板接口的字段索引越界防护 |
| 20 | PayloadConcat.bsv | 拼接缓冲索引与边界判定修正 |

### 仍属架构性限制（非缺陷，已注明）

- PHV 字段按 4 字节切片建模：IPv6 地址 / SRH SID 只保存/补丁前 4 字节
  （与解析器字段布局一致，扩展需重定义 PHV 字段映射）
- 单端口 TX：`PktDesc.out_port` 无动作写入通路，NDN/路由的出端口仅为元数据
- AXI 单次 64-bit 写无法承载 ParseState/ActionProgram，配置走专用接口
- NDN CS/PIT 无老化、直接映射冲突覆盖
- Deparser 只补丁前 8 拍（256B）

---

**最后更新**: 2026-11-04
**实现进度**: Phase 1-3 完成 + 三轮代码审查修复（含回归测试 TestFixes）
