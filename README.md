# RMT-BSV 硬件可重构匹配动作表流水线

基于 Bluespec SystemVerilog (BSV) 实现的硬件 RMT (Reconfigurable Match Tables) 流水线，支持 100G 以太网接口，实现完整的可编程数据平面功能。

## 📋 目录

- [项目概述](#项目概述)
- [架构设计](#架构设计)
- [流水线模块详解](#流水线模块详解)
- [编译器工作流](#编译器工作流)
- [测试基础设施](#测试基础设施)
- [构建与运行](#构建与运行)
- [使用示例](#使用示例)
- [性能指标](#性能指标)
- [项目结构](#项目结构)

---

## 项目概述

### 核心特性

✅ **完整的 RMT 流水线架构**
- 可编程协议解析器（FSM 驱动）
- 4 级 Match-Action 流水线（可扩展到 8 级）
- 16 路 VLIW ALU 阵列（Read-Before-Write 语义）
- PHV 寄存器堆（160 字段 × 128-bit）
- TCAM Match 引擎（支持 Exact 和 LPM）

✅ **★ TCP 乱序重排与会话重组 ★**（核心创新）
- 256 并发 TCP 会话跟踪
- 基于 5 元组的会话识别
- 序列号排序缓冲
- 有效载荷按序拼接
- 会话状态机（SYN/ESTABLISHED/FIN）

✅ **100G 以太网接口**
- 256-bit AXI-Stream 数据总线
- 156.25 MHz 时钟频率
- 目标线速 ~150 Mpps @64B 报文

✅ **BSV 最佳实践**
- 规则守卫提升（所有条件判断在守卫中）
- 无冲突规则调度
- Read-Before-Write 语义保证

### 技术规格

| 参数 | 值 | 说明 |
|------|-----|------|
| PHV 字段数 | 160 | 与软件实现一致 |
| 字段位宽 | 128 bits | 大端右对齐 |
| 流水线级数 | 4（默认）/ 8（最大） | 可配置 |
| ALU 数量/级 | 16 | VLIW 宽度 |
| TCAM 深度/表 | 1024 | 条目数 |
| TCP 会话数 | 256 | 最大并发 |
| 重排深度/会话 | 64 | 报文数 |
| 数据总线 | 256-bit | 100GE @ 156.25 MHz |
| 目标吞吐 | ~31 Mpps/流水线 | 单流水线 |

---

## 架构设计

### 整体架构图

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        RMT-BSV 硬件流水线                                │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  100G RX ──►┌──────────┐  ┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐ │
│  (AXI-S)   │ Packet   │  │Parser  │ │ Stage  │ │ Stage  │ │ Stage  │ │
│            │ Buffer   │─►│(FSM)   │►│   0    │►│   1    │►│  ...   │ │
│            │          │  │        │ │M├►A   │ │M├►A   │ │M├►A   │ │
│            └──────────┘  └────────┘ └───┬────┘ └───┬────┘ └───┬────┘ │
│                                         │          │          │      │
│                                    ┌────┴──────────┴──────────┴────┐ │
│                                    │   PHV RegFile (4-bank)        │ │
│                                    │   160 fields × 128-bit        │ │
│                                    └───────────────────────────────┘ │
│                                                                         │
│  ┌──────────────────────────────────────────────────────────────────┐ │
│  │  TCP Reorder Engine ★ 核心创新 ★                                  │ │
│  │  • Session Tracker (256 sessions)                                 │ │
│  │  • Reorder Buffer (16K slots)                                     │ │
│  │  • Payload Concatenator                                           │ │
│  └──────────────────────────────────────────────────────────────────┘ │
│                                                                         │
│            ┌──────────┐                                                │
│            │ Deparser │──► 100G TX (AXI-S)                             │
│            │          │                                                │
│            └──────────┘                                                │
│                                                                         │
│  ┌──────────────────────────────────────────────────────────────────┐ │
│  │  Control Plane (AXI-Lite)                                         │ │
│  │  • Table Entry Management                                         │ │
│  │  • Parser Configuration                                           │ │
│  │  • Action Microcode Loading                                       │ │
│  └──────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────┘
```

### 数据通路

```
报文输入 → 解析器 → Match-Action 流水线 → TCP 重组 → 逆解析器 → 报文输出
              │           │                  │           │
              │           │                  │           │
           提取头部    Match + Action      重排序      重组头部
           构建 PHV    更新 PHV            拼接载荷    追加载荷
```

---

## 流水线模块详解

### 1. 报文缓冲模块 (PacketBuffer.bsv)

**功能**：
- AXI-Stream 接口（256-bit 数据总线）
- 报文存储（512 条目 × 256-bit）
- 信用机制流控
- 入/出报文管理

**接口**：
```bluespec
interface PacketBufferIfc;
    method Action rx_data(EthStream s);
    method ActionValue#(EthStream) tx_data;
    method ActionValue#(Tuple2#(PktDesc, Vector#(64, Bit#(256)))) ingress_pkt;
    method Action egress_pkt(Tuple2#(PktDesc, Vector#(64, Bit#(256))) pkt);
endinterface
```

**关键特性**：
- 支持最大 2048 字节报文
- 每报文最多 64 个 beat（32 字节/beat）
- 信用机制避免溢出

### 2. 可编程解析器 (ProgrammableParser.bsv)

**功能**：
- 表驱动有限状态机（FSM）
- 支持多种协议解析
- 动态头部提取
- 状态转换逻辑

**接口**：
```bluespec
interface ProgrammableParserIfc;
    method Action start(PktDesc desc);
    method Action provide_data(Bit#(256) data, Bool last);
    method ActionValue#(Tuple2#(PktDesc, Bool)) result;
    method Action load_state(Bit#(5) idx, ParseState st);
    method Action set_start_state(Bit#(5) state);
    method PHV get_phv;
endinterface
```

**支持的协议**：
- Ethernet (14 bytes)
- IPv4 (20 bytes)
- IPv6 (40 bytes)
- TCP (20+ bytes)
- UDP (8 bytes)
- SRv6 (可变长度)
- VXLAN (可变长度)
- NDN (可变长度)

**解析流程**：
```
1. 从 PacketBuffer 获取报文数据
2. 根据当前状态提取头部
3. 更新 PHV 字段
4. 根据协议类型选择下一状态
5. 重复直到 ACCEPT 状态
6. 返回解析结果和 PHV
```

### 3. PHV 寄存器堆 (PHVRegFile.bsv)

**功能**：
- 160 个字段寄存器
- 每字段 128-bit 存储
- 4-bank 分布式架构
- 多端口读写支持

**接口**：
```bluespec
interface PHVRegFileIfc;
    method Action read_req_0(Bit#(8) fid);
    method ActionValue#(FieldValue) read_resp_0;
    method Action read_req_1(Bit#(8) fid);
    method ActionValue#(FieldValue) read_resp_1;
    method Action write_0(Bit#(8) fid, FieldValue val);
    method Action write_1(Bit#(8) fid, FieldValue val);
    method Bit#(64) get_hvalid;
    method Action set_hvalid(Bit#(64) mask);
    method Action set_hdr_valid(Bit#(6) hdr_id);
    method Action clr_hdr_valid(Bit#(6) hdr_id);
    method Action reset_from_template;
    method Action load_template(Bit#(8) fid, FieldValue val);
    method PHV snapshot;
    method Action restore(PHV phv);
endinterface
```

**关键特性**：
- 160 个字段，每字段 128-bit
- 头部有效性位图（64 bits）
- 脏位图（160 bits）用于快速逆解析
- 模板机制用于快速复位
- 快照/恢复支持级间传递

### 4. Match 引擎 (MatchEngine.bsv)

**功能**：
- TCAM 查找（1024 条目/表）
- 支持 Exact 和 LPM 匹配
- 多 key 级联匹配
- 命中优先级编码

**接口**：
```bluespec
interface MatchEngineIfc;
    method Action lookup_req(Bit#(4) table_id, PHV phv);
    method ActionValue#(MatchResult) lookup_resp;
    method Action insert_entry(Bit#(4) table_id, TCAMEntry entry);
    method Action delete_entry(Bit#(4) table_id, Bit#(10) addr);
    method Bit#(16) entry_count(Bit#(4) table_id);
endinterface
```

**匹配类型**：
- **Exact Match**：精确匹配，所有位都必须匹配
- **LPM (Longest Prefix Match)**：最长前缀匹配，用于路由

**匹配流程**：
```
1. 从 PHV 提取 key 字段
2. TCAM 并行查找（1024 条目同时比较）
3. 生成命中向量（1024 bits）
4. 优先级编码找到最高优先级命中
5. 返回 MatchResult（命中/未命中，action_id，params）
```

### 5. Action 引擎 (ActionEngine.bsv)

**功能**：
- 16 路 VLIW ALU 阵列
- 3 阶段执行流水线（READ/EXEC/COMMIT）
- Read-Before-Write 语义
- 微码存储（32 动作 × 8 word × 16 slot）

**接口**：
```bluespec
interface ActionEngineIfc;
    method Action start(Bit#(5) action_id, Vector#(8, Bit#(64)) params);
    method ActionValue#(Bool) done;
    interface PHVRegFileIfc phv;
    method Action load_action(Bit#(5) idx, ActionProgram prog);
endinterface
```

**ALU 操作码**：
```bluespec
typedef enum {
    ALU_NOP,       // 空操作
    ALU_MOVI,      // 立即数加载
    ALU_MOV,       // 寄存器移动
    ALU_ADD,       // 加法
    ALU_SUB,       // 减法
    ALU_AND,       // 逻辑与
    ALU_OR,        // 逻辑或
    ALU_XOR,       // 逻辑异或
    ALU_SHL,       // 左移
    ALU_SHR,       // 右移
    ALU_ADDI,      // 加立即数
    ALU_SUBI,      // 减立即数
    ALU_ANDI,      // 与立即数
    ALU_ORI,       // 或立即数
    ALU_XORI,      // 异或立即数
    ALU_SHLI,      // 左移立即数
    ALU_SHRI,      // 右移立即数
    ALU_MOVX,      // 索引访问
    ALU_VALID,     // 设置头部有效
    ALU_INVALID,   // 清除头部有效
    // ... 更多操作
} ALUOpcode;
```

**VLIW 执行流程**：
```
Word 0:
  ├─ READ 阶段: 所有 ALU 读取操作数
  ├─ EXEC 阶段: 所有 ALU 并行计算
  └─ COMMIT 阶段: 所有结果同时写回 PHV

Word 1:
  ├─ READ 阶段
  ├─ EXEC 阶段
  └─ COMMIT 阶段

...

Word N:
  └─ 完成
```

**Read-Before-Write 语义**：
- 同一 word 内，所有读操作在读阶段完成
- 所有写操作在 commit 阶段同时执行
- 保证数据一致性，避免竞争条件

### 6. Match-Action 级 (MatchActionStage.bsv)

**功能**：
- 集成 Match 引擎和 Action 引擎
- 表级联执行
- 门控条件检查
- PHV 快照/恢复

**接口**：
```bluespec
interface MatchActionStageIfc;
    method Action start(StageReg sreg);
    method ActionValue#(StageReg) complete;
    method Action config_table(Bit#(4) tidx, TableConfig cfg);
    method Action insert_entry(Bit#(4) tidx, TCAMEntry entry);
    method Action load_action(Bit#(5) aidx, ActionProgram prog);
endinterface
```

**级执行流程**：
```
1. 接收 StageReg（PHV 快照 + 报文描述符）
2. 对每个表：
   a. 检查门控条件（头部有效性）
   b. 执行 Match 查找
   c. 执行对应 Action
   d. 更新 PHV
3. 返回更新的 StageReg
```

### 7. 逆解析器 (Deparser.bsv)

**功能**：
- PHV 字段重组为报文
- 支持快速路径（脏字段补丁）
- 支持完整路径（全字段重组）
- 有效载荷追加

**接口**：
```bluespec
interface DeparserIfc;
    method Action start(PktDesc desc, PHV phv);
    method ActionValue#(Tuple2#(PktDesc, Vector#(64, Bit#(256)))) result;
    method Action set_original_data(Vector#(64, Bit#(256)) orig);
endinterface
```

**逆解析流程**：
```
快速路径（无结构变更）：
  1. 复制原始报文
  2. 根据脏位图补丁修改的字段
  3. 追加原始有效载荷

完整路径（有结构变更）：
  1. 遍历所有有效头部
  2. 从 PHV 提取字段值
  3. 按位重组报文
  4. 追加有效载荷
```

### 8. TCP 重组引擎 (TCPReorderEngine.bsv) ★ 核心创新 ★

**功能**：
- TCP 会话跟踪（5 元组匹配）
- 乱序报文重排
- 有效载荷按序拼接
- 会话状态管理

**子模块**：

#### 8.1 SessionTracker.bsv
```bluespec
interface SessionTrackerIfc;
    method Action lookup_req(TCP5Tuple key);
    method ActionValue#(Tuple2#(Bool, Bit#(8))) lookup_resp;
    method Action create(TCP5Tuple key);
    method Action delete(Bit#(8) session_id);
    method Action update(Bit#(8) session_id, TCPSessionEntry entry);
    method ActionValue#(TCPSessionEntry) get_session(Bit#(8) session_id);
    method Bit#(16) active_count;
endinterface
```

**会话跟踪流程**：
```
1. 提取 TCP 5 元组（src_ip, dst_ip, src_port, dst_port, protocol）
2. TCAM/Hash 查找匹配会话
3. 命中：返回 session_id
4. 未命中：创建新会话（如果是 SYN）
5. 更新会话状态（SEQ, ACK, 窗口等）
```

#### 8.2 ReorderBuffer.bsv
```bluespec
interface ReorderBufferIfc;
    method Action insert(Bit#(8) session_id, Bit#(32) tcp_seq,
                        Bit#(12) pkt_len, Bit#(16) buf_idx);
    method ActionValue#(ReorderSlot) get_next(Bit#(8) session_id);
    method Bool has_sequential(Bit#(8) session_id, Bit#(32) expected_seq);
    method Bool has_timeout;
    method Action release_timeout;
endinterface
```

**重排缓冲流程**：
```
插入：
  1. 根据 session_id 选择会话缓冲
  2. 根据 tcp_seq 找到合适位置
  3. 插入报文元数据（seq, len, buf_idx）

读取：
  1. 检查是否有期望序列号的报文
  2. 找到最小序列号的有效报文
  3. 返回并标记为已读取

超时管理：
  1. 周期性检查所有会话
  2. 释放超时报文（age > 1000 cycles）
  3. 更新会话状态
```

#### 8.3 PayloadConcat.bsv
```bluespec
interface PayloadConcatIfc;
    method Action provide_data(Bit#(8) session_id,
                              Vector#(64, Bit#(256)) pkt_data,
                              Bit#(12) payload_offset,
                              Bit#(12) payload_len);
    method ActionValue#(Vector#(64, Bit#(256))) get_payload;
    method Bool has_output;
endinterface
```

**有效载荷拼接流程**：
```
1. 从 PacketBuffer 提取有效载荷
2. 根据 payload_offset 跳过 TCP 头部
3. 拼接到会话缓冲
4. 按序输出连续字节流
```

#### 8.4 TCPReorderEngine.bsv（顶层）
```bluespec
interface TCPReorderEngineIfc;
    method Action insert_pkt(PktDesc desc, PHV phv,
                            Vector#(64, Bit#(256)) pkt_data);
    method ActionValue#(Tuple3#(PktDesc, PHV, Vector#(64, Bit#(256))))
        get_reassembled;
    method Action create_session(TCP5Tuple key);
    method Action delete_session(TCP5Tuple key);
    method Bit#(16) active_sessions;
    method Bit#(32) reorder_latency;
    method Bool insert_ready;
    method Bool output_available;
endinterface
```

**TCP 重组完整流程**：
```
输入报文：
  ├─ 提取 TCP 头部（seq, ack, flags）
  ├─ 提取 5 元组
  └─ 提取有效载荷

会话查找：
  ├─ 5 元组匹配
  ├─ 命中：获取 session_id
  └─ 未命中：创建新会话（SYN）或丢弃

重排处理：
  ├─ 按序到达（seq == expected）：直接输出
  ├─ 超前到达（seq > expected）：插入重排缓冲
  └─ 重复到达（seq < expected）：丢弃

输出重组：
  ├─ 检查重排缓冲是否有连续报文
  ├─ 拼接有效载荷
  └─ 输出重组后的报文
```

### 9. 流水线控制器 (PipelineController.bsv)

**功能**：
- 信用机制流控
- 统计信息收集
- 流水线暂停/恢复
- 延迟测量

**接口**：
```bluespec
interface PipelineControllerIfc;
    method Action acquire_credit(Bit#(3) stage_id);
    method Action release_credit(Bit#(3) stage_id);
    method Bool has_credit(Bit#(3) stage_id);
    method Bit#(64) rx_count;
    method Bit#(64) tx_count;
    method Bit#(64) drop_count;
    method Bit#(32) avg_latency;
    method Action stall;
    method Action resume;
    method Bool is_stalled;
endinterface
```

### 10. 控制面 (ControlPlane.bsv)

**功能**：
- AXI-Lite 接口
- 表项管理（插入/删除）
- 解析器配置
- 动作微码加载
- PHV 模板设置

**接口**：
```bluespec
interface ControlPlaneIfc;
    interface Get parser_config;
    interface Get table_insert;
    interface Get table_delete;
    interface Get action_load;
    interface Get phv_template_set;
    interface Get tcp_session_create;
    interface Get tcp_session_delete;
    method Bit#(64) get_rx_count;
    method Bit#(64) get_tx_count;
    method Bit#(64) get_drop_count;
    method Bit#(32) get_pipeline_latency;
    method Bit#(16) get_tcp_active_sessions;
    method Action axi_write(Bit#(32) addr, Bit#(64) data);
    method ActionValue#(Bit#(64)) axi_read(Bit#(32) addr);
endinterface
```

### 11. 顶层模块 (RMTTop.bsv)

**功能**：
- 集成所有子模块
- 流水线编排
- 数据通路连接
- 控制通路连接

**接口**：
```bluespec
interface RMTTopIfc;
    method Action rx_data(EthStream s);
    method ActionValue#(EthStream) tx_data;
    method Action axi_write(Bit#(32) addr, Bit#(64) data);
    method ActionValue#(Bit#(64)> axi_read(Bit#(32) addr);
    method Bit#(64) get_rx_count;
    method Bit#(64) get_tx_count;
    method Bit#(64) get_drop_count;
    method Bit#(16) get_tcp_sessions;
endinterface
```

**流水线流程**：
```
1. PacketBuffer 接收报文
2. ProgrammableParser 解析头部，构建 PHV
3. MatchActionStage[0..3] 执行 Match-Action
4. TCPReorderEngine 重组 TCP 会话
5. Deparser 重组报文
6. PacketBuffer 发送报文
```

---

## 编译器工作流

### BSV 编译流程

```
BSV 源代码 (.bsv)
    │
    ▼
┌─────────────────┐
│  词法分析        │  识别关键字、标识符、操作符
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  语法分析        │  构建抽象语法树 (AST)
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  类型检查        │  验证类型一致性
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  规则调度分析    │  检查规则冲突，验证守卫
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  模块 Elaboration│  展开模块层次
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  生成 Verilog    │  输出可综合的 RTL
└─────────────────┘
```

### 编译命令

```bash
# 编译所有源文件
make compile

# 编译测试文件
make compile-tests

# 生成 Verilog
make verilog

# 构建仿真
make sim
```

### 编译参数

```makefile
BSC = /home/gf/Project/bsc-prebuilt/bsc-2026.01-debian-12.13/bin/bsc
BSC_LIB = /home/gf/Project/bsc-prebuilt/bsc-2026.01-debian-12.13/lib/Libraries
BSC_FLAGS = -u -p src:test:$(BSC_LIB) -bdir build -simdir build -info-dir build
```

**关键参数说明**：
- `-u`：仅编译，不链接
- `-p`：指定包搜索路径
- `-bdir`：编译产物目录
- `-simdir`：仿真产物目录
- `-info-dir`：信息文件目录

---

## 测试基础设施

### 测试框架 (TestFramework.bsv)

**功能**：
- 测试向量定义
- 统计信息收集
- 结果验证
- 错误报告

**核心类型**：
```bluespec
// 测试统计
typedef struct {
    Bit#(32) total_packets;
    Bit#(32) passed_packets;
    Bit#(32) failed_packets;
    Bit#(32) dropped_packets;
} TestStats;

// 测试向量
typedef struct {
    Bit#(32) test_id;
    Vector#(64, Bit#(256)) pkt_data;
    Bit#(12) pkt_len;
    Bit#(10) in_port;
    Vector#(64, Bit#(256)) expected_data;
    Bit#(12) expected_len;
    Bit#(10) expected_port;
    Bool expect_drop;
} TestVector;

// 测试平台接口
interface TestPlatformIfc;
    method Action load_test_vector(TestVector tv);
    method Action start_test;
    method ActionValue#(Bool) get_result;
    method TestStats get_stats;
    method Bit#(32) get_error_code;
endinterface
```

### 协议测试模块

#### 1. SRv6 测试 (TestSRv6.bsv)

**测试场景**：
- SRv6 End 行为（段列表处理）
- 段列表跳转
- 头部重写

**测试向量**：
```bluespec
// SRv6 End 行为测试
function TestVector make_srv6_end_test();
    TestVector tv;
    tv.test_id = 1;
    
    // 构造 SRv6 报文
    // Ethernet + IPv6 + SRH + payload
    // SRH: SL=2, segments=[SID0, SID1, SID2]
    
    tv.pkt_len = 126;
    tv.in_port = 1;
    tv.expected_port = 2;
    tv.expect_drop = False;
    
    return tv;
endfunction
```

#### 2. VXLAN 测试 (TestVXLAN.bsv)

**测试场景**：
- VXLAN 封装（Inner → Outer）
- VXLAN 解封装（Outer → Inner）
- VNI 匹配

**测试向量**：
```bluespec
// VXLAN 解封装测试
function TestVector make_vxlan_decap_test();
    TestVector tv;
    tv.test_id = 1;
    
    // 构造 VXLAN 报文
    // Outer: Eth + IPv4 + UDP(4789) + VXLAN(VNI=5001)
    // Inner: Eth + IPv4 + payload
    
    tv.pkt_len = 88;  // 外层报文
    tv.expected_len = 38;  // 内层报文
    tv.expect_drop = False;
    
    return tv;
endfunction
```

#### 3. NDN 测试 (TestNDN.bsv)

**测试场景**：
- Interest 转发
- Data 返回
- CS 缓存命中

**测试向量**：
```bluespec
// NDN Interest 转发测试
function TestVector make_ndn_interest_test();
    TestVector tv;
    tv.test_id = 1;
    
    // 构造 NDN Interest 报文
    // Eth + IPv6 + UDP + NDN(Interest, name=/video/abc)
    
    tv.pkt_len = 100;
    tv.expected_port = 2;
    tv.expect_drop = False;
    
    return tv;
endfunction
```

#### 4. DNN 测试 (TestDNN.bsv)

**测试场景**：
- 正常 TCP 流量分类
- SYN flood 攻击检测
- 特征提取

**测试向量**：
```bluespec
// 正常 TCP 流量测试
function TestVector make_dnn_normal_tcp_test();
    TestVector tv;
    tv.test_id = 1;
    
    // 构造正常 TCP SYN 报文
    // 特征：len=60, ttl=64, flags=0x02, window=64240
    
    tv.pkt_len = 60;
    tv.expect_drop = False;  // 正常流量，不丢弃
    
    return tv;
endfunction

// SYN flood 攻击测试
function TestVector make_dnn_syn_flood_test();
    TestVector tv;
    tv.test_id = 2;
    
    // 构造恶意 TCP SYN 报文
    // 特征：len=40, ttl=47, flags=0x02, window=128
    
    tv.pkt_len = 40;
    tv.expect_drop = True;  // 攻击流量，丢弃
    
    return tv;
endfunction
```

#### 5. TCP 重组测试 (TestTCPReorder.bsv)

**测试场景**：
- 按序到达
- 乱序到达
- 重复报文
- 会话建立（SYN）
- 会话关闭（FIN）
- 超时释放

**测试向量**：
```bluespec
// TCP 按序到达测试
function TestVector make_tcp_inorder_test();
    TestVector tv;
    tv.test_id = 1;
    
    // 报文 1：seq=1000
    // 报文 2：seq=1100
    // 期望：按序输出
    
    return tv;
endfunction

// TCP 乱序到达测试
function TestVector make_tcp_outoforder_test();
    TestVector tv;
    tv.test_id = 2;
    
    // 报文 1：seq=1200（超前）
    // 报文 2：seq=1100（期望）
    // 期望：先输出 1100，再输出 1200
    
    return tv;
endfunction

// TCP 重复报文测试
function TestVector make_tcp_duplicate_test();
    TestVector tv;
    tv.test_id = 3;
    
    // 报文：seq=1000（已收到）
    // 期望：丢弃
    
    tv.expect_drop = True;
    return tv;
endfunction
```

### 主测试平台 (TestbenchTop.bsv)

**功能**：
- 运行所有协议测试
- 收集统计信息
- 输出测试结果

**测试流程**：
```
1. 初始化测试平台
2. 加载 SRv6 测试向量
3. 运行 SRv6 测试
4. 加载 VXLAN 测试向量
5. 运行 VXLAN 测试
6. 加载 NDN 测试向量
7. 运行 NDN 测试
8. 加载 DNN 测试向量
9. 运行 DNN 测试
10. 加载 TCP 重组测试向量
11. 运行 TCP 重组测试
12. 输出统计报告
```

### 运行测试

```bash
# 运行所有测试
make test

# 运行单个协议测试
make test-srv6
make test-vxlan
make test-ndn
make test-dnn
make test-tcp
```

---

## 构建与运行

### 环境要求

- **Bluespec Compiler (BSC)**: 2026.01 或更新版本
- **操作系统**: Linux (Debian 12 推荐)
- **内存**: ≥ 8 GB
- **磁盘空间**: ≥ 2 GB

### 安装 BSC

```bash
# 下载 BSC
wget https://github.com/B-Lang-org/bsc/releases/download/2026.01/bsc-2026.01-debian-12.13.tar.gz

# 解压
tar -xzf bsc-2026.01-debian-12.13.tar.gz

# 添加到 PATH
export PATH=/home/gf/Project/bsc-prebuilt/bsc-2026.01-debian-12.13/bin:$PATH
```

### 构建项目

```bash
cd /home/gf/Project/rmt-bsv-hw

# 编译所有源文件
make compile

# 编译测试文件
make compile-tests

# 生成 Verilog（可选）
make verilog

# 构建仿真（可选）
make sim
```

### 运行测试

```bash
# 运行所有测试
make test

# 运行单个协议测试
make test-srv6
make test-vxlan
make test-ndn
make test-dnn
make test-tcp
```

### 清理构建

```bash
# 清理编译产物
make clean
```

---

## 使用示例

### 示例 1: SRv6 转发

**场景**：SRv6 End 行为，段列表从 SL=2 跳转到 SL=1

**配置**：
```
解析器状态：
  - start: extract Ethernet
  - parse_ipv6: extract IPv6
  - parse_srh: extract SRH, segments

Match 表：
  - table_id=0: SRv6 routing table
  - key: IPv6.dst
  - action: srv6_end

动作微码：
  - action_id=0: srv6_end
    - SL = SL - 1
    - IPv6.dst = segments[SL]
    - if SL == 0: drop
```

**测试向量**：
```bluespec
TestVector tv;
tv.pkt_data = // SRv6 报文，SL=2, segments=[SID0, SID1, SID2]
tv.expected_data = // 处理后报文，SL=1, IPv6.dst=SID1
```

**预期结果**：
- SL 从 2 减到 1
- IPv6.dst 从 SID2 变为 SID1
- 报文正常转发

### 示例 2: VXLAN 封装

**场景**：租户报文封装为 VXLAN

**配置**：
```
解析器状态：
  - start: extract Ethernet
  - parse_ipv4: extract IPv4

Match 表：
  - table_id=0: VXLAN encapsulation table
  - key: IPv4.dst
  - action: vxlan_encap(vni, outer_sip, outer_dip)

动作微码：
  - action_id=0: vxlan_encap
    - 添加 Outer Ethernet
    - 添加 Outer IPv4 (src=outer_sip, dst=outer_dip)
    - 添加 UDP (dport=4789)
    - 添加 VXLAN (vni=vni)
    - 保留 Inner Ethernet + Inner IPv4
```

**测试向量**：
```bluespec
TestVector tv;
tv.pkt_data = // Inner 报文: Eth + IPv4 + payload
tv.expected_data = // Outer 报文: Outer Eth + Outer IPv4 + UDP + VXLAN + Inner Eth + Inner IPv4 + payload
```

**预期结果**：
- 添加外层头部
- VNI 设置为指定值
- 内层报文保持不变

### 示例 3: TCP 重组

**场景**：乱序 TCP 报文重组

**配置**：
```
TCP 会话跟踪：
  - 5 元组: (src_ip, dst_ip, src_port, dst_port, TCP)
  - 会话缓冲: 16K slots
  - 超时: 1000 cycles

重排逻辑：
  - 按序到达: 直接输出
  - 超前到达: 插入缓冲
  - 重复到达: 丢弃
```

**测试向量**：
```bluespec
// 报文 1: seq=1200 (超前)
TestVector tv1;
tv1.pkt_data = // TCP 报文, seq=1200

// 报文 2: seq=1100 (期望)
TestVector tv2;
tv2.pkt_data = // TCP 报文, seq=1100
```

**预期结果**：
- 报文 1 插入重排缓冲
- 报文 2 到达后，检查缓冲
- 输出 seq=1100，然后输出 seq=1200

---

## 性能指标

### 预期性能

| 指标 | 值 | 说明 |
|------|-----|------|
| 时钟频率 | 156.25 MHz | 目标频率 |
| 单流水线吞吐 | ~31 Mpps | 64B 报文 |
| 流水线延迟 | ~40 cycles | Parser → Deparser |
| TCP 重组延迟 | <1000 cycles | 乱序窗口 |
| BRAM 使用 | ~1.4 MB | 包括 TCP 重组 |
| URAM 使用 | ~520 KB | TCP 重排缓冲 |

### 资源使用

| 资源 | 使用量 | 说明 |
|------|--------|------|
| LUT | ~100K | 逻辑资源 |
| FF | ~150K | 寄存器 |
| BRAM36K | ~40 | 块 RAM |
| URAM | ~13 | Ultra RAM |

### 优化建议

1. **流水线深度**：增加到 8 级可提高吞吐
2. **ALU 数量**：增加到 32 可提高并行度
3. **TCAM 大小**：根据实际需求调整
4. **TCP 缓冲**：根据会话数调整大小

---

## 项目结构

```
rmt-bsv-hw/
├── src/                          # 源代码 (20 个文件, ~4000 行)
│   ├── RMTConfig.bh              # 全局配置
│   ├── RMTInterfaces.bsv         # 接口定义
│   ├── ALU.bsv                   # 单个 ALU
│   ├── PHVBank.bsv               # PHV bank
│   ├── PHVRegFile.bsv            # PHV 寄存器堆
│   ├── ParserStateTable.bsv      # 解析器状态表
│   ├── ProgrammableParser.bsv    # 可编程解析器
│   ├── PacketBuffer.bsv          # 报文缓冲
│   ├── Deparser.bsv              # 逆解析器
│   ├── TCAMArray.bsv             # TCAM 阵列
│   ├── MatchEngine.bsv           # Match 引擎
│   ├── ActionEngine.bsv          # Action 引擎
│   ├── MatchActionStage.bsv      # Match-Action 级
│   ├── SessionTracker.bsv        # TCP 会话跟踪
│   ├── SessionFSM.bsv            # 会话状态机
│   ├── ReorderBuffer.bsv         # 重排缓冲
│   ├── PayloadConcat.bsv         # 有效载荷拼接
│   ├── TCPReorderEngine.bsv      # TCP 重组引擎
│   ├── PipelineController.bsv    # 流水线控制器
│   ├── AXILiteSlave.bsv          # AXI-Lite 从机
│   ├── ControlPlane.bsv          # 控制面
│   └── RMTTop.bsv                # 顶层模块
│
├── test/                         # 测试代码 (7 个文件, ~1100 行)
│   ├── TestFramework.bsv         # 测试框架
│   ├── TestSRv6.bsv              # SRv6 测试
│   ├── TestVXLAN.bsv             # VXLAN 测试
│   ├── TestNDN.bsv               # NDN 测试
│   ├── TestDNN.bsv               # DNN 测试
│   ├── TestTCPReorder.bsv        # TCP 重组测试
│   └── TestbenchTop.bsv          # 主测试平台
│
├── build/                        # 编译产物
├── verilog/                      # Verilog 输出
├── sim/                          # 仿真产物
├── docs/                         # 文档
├── Makefile                      # 构建脚本
├── README.md                     # 项目说明
├── PROGRESS.md                   # 进度跟踪
├── IMPLEMENTATION_SUMMARY.md     # 实现总结
├── TEST_COMPLETION_SUMMARY.md    # 测试完成总结
└── COMPILATION_COMPLETE.md       # 编译完成报告
```

---

## 常见问题

### Q1: 编译时遇到 "Unresolved proviso" 错误？

**原因**：类型约束不满足

**解决**：
```bluespec
// 添加类型约束
provisos(
    Add#(a, b, c),
    Mul#(d, e, f)
);
```

### Q2: 仿真时遇到 "Step limit exceeded" 错误？

**原因**：设计规模超出 BSC 默认限制

**解决**：
```bash
# 增加步骤限制
bsc -sim -steps 10000000 -steps-max-intervals 10 ...
```

### Q3: 如何调试特定模块？

**解决**：
```bluespec
// 添加 $display 语句
rule my_rule;
    $display("Debug: value = %d", my_value);
    // ...
endrule
```

### Q4: 如何优化性能？

**建议**：
1. 增加流水线级数
2. 使用更大的 TCAM
3. 优化 ALU 阵列
4. 减少规则冲突

---

## 参考文献

1. Bosshart P, et al. "Forwarding Metamorphosis: Fast Programmable Match-Action Processing in Hardware for SDN." SIGCOMM 2013.
2. Bluespec SystemVerilog 官方文档
3. Xilinx UltraScale+ 架构手册
4. P4_16 语言规范

---

## 许可证

本项目仅供研究和教学使用。

---

## 联系方式

如有问题或建议，请联系项目维护者。

---

**最后更新**: 2026-09-03  
**版本**: 1.0  
**状态**: ✅ 编译完成，待仿真验证
