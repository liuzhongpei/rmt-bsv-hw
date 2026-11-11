# RMT-BSV Hardware Pipeline Makefile
# Bluespec SystemVerilog Build System

# bsc 是 GHC(Haskell) 程序：+RTS -K1G（栈） -M24G（堆封顶；机器 30G 内存，
#   留余量防换页抖动。TCAM 优先编码器改集合运算后应远低于此上限）
# -Xc++ -O0：Bluesim 生成的 C++ 用 -O3 编译约 1 小时（852MB），-O0 只需约 4 分钟
BSC = /home/gf/opt/bsc-2026.01-ubuntu-26.04/bin/bsc +RTS -K1G -M24G -RTS
BSC_LIB = /home/gf/opt/bsc-2026.01-ubuntu-26.04/lib/Libraries
BSC_CPP_FAST = -Xc++ -O0
# -steps：全设计（含 SRH/VXLAN 解封装）elaboration 超过 bsc 默认 1M 步限制
BSC_FLAGS = -u -p src:test:$(BSC_LIB) -bdir build -simdir build -info-dir build -steps 20000000 -steps-max-intervals 50
BSC_VERILOG_FLAGS = -verilog -vdir verilog
BSC_SIM_FLAGS = -sim

SRC_DIR = src
TEST_DIR = test
BUILD_DIR = build
VERILOG_DIR = verilog

# Source files in dependency order (excluding .bh header files)
SOURCES = \
	$(SRC_DIR)/RMTInterfaces.bsv \
	$(SRC_DIR)/ALU.bsv \
	$(SRC_DIR)/PHVBank.bsv \
	$(SRC_DIR)/PHVRegFile.bsv \
	$(SRC_DIR)/ParserStateTable.bsv \
	$(SRC_DIR)/ProgrammableParser.bsv \
	$(SRC_DIR)/PacketBuffer.bsv \
	$(SRC_DIR)/Deparser.bsv \
	$(SRC_DIR)/TCAMArray.bsv \
	$(SRC_DIR)/MatchEngine.bsv \
	$(SRC_DIR)/ActionEngine.bsv \
	$(SRC_DIR)/SessionTracker.bsv \
	$(SRC_DIR)/SessionFSM.bsv \
	$(SRC_DIR)/ReorderBuffer.bsv \
	$(SRC_DIR)/PayloadConcat.bsv \
	$(SRC_DIR)/NDNEngine.bsv \
	$(SRC_DIR)/TCPReorderEngine.bsv \
	$(SRC_DIR)/PipelineController.bsv \
	$(SRC_DIR)/AXILiteSlave.bsv \
	$(SRC_DIR)/ControlPlane.bsv \
	$(SRC_DIR)/RMTTop.bsv

# Test files
TEST_SOURCES = \
	$(TEST_DIR)/TestFramework.bsv \
	$(TEST_DIR)/TestSRv6.bsv \
	$(TEST_DIR)/TestVXLAN.bsv \
	$(TEST_DIR)/TestNDN.bsv \
	$(TEST_DIR)/TestDNN.bsv \
	$(TEST_DIR)/TestTCPReorder.bsv \
	$(TEST_DIR)/TestFixes.bsv \
	$(TEST_DIR)/TestbenchTop.bsv

.PHONY: all compile compile-tests verilog sim clean help test test-srv6 test-vxlan test-ndn test-dnn test-tcp test-fixes

all: compile

# Create build directory
$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(VERILOG_DIR):
	mkdir -p $(VERILOG_DIR)

# Compile all BSV source files
compile: $(BUILD_DIR)
	@echo "========================================"
	@echo "Compiling RMT-BSV Hardware Pipeline..."
	@echo "========================================"
	@for src in $(SOURCES); do \
		echo "Compiling $$src..."; \
		$(BSC) $(BSC_FLAGS) $$src || exit 1; \
	done
	@echo "========================================"
	@echo "Compilation complete!"
	@echo "========================================"

# Compile test files
compile-tests: compile
	@echo "========================================"
	@echo "Compiling Test Suite..."
	@echo "========================================"
	@for test in $(TEST_SOURCES); do \
		echo "Compiling $$test..."; \
		$(BSC) $(BSC_FLAGS) $$test || exit 1; \
	done
	@echo "========================================"
	@echo "Test compilation complete!"
	@echo "========================================"

# Generate Verilog
verilog: compile $(VERILOG_DIR)
	@echo "Generating Verilog..."
	$(BSC) $(BSC_FLAGS) $(BSC_VERILOG_FLAGS) $(SRC_DIR)/RMTTop.bsv
	@echo "Verilog generated in $(VERILOG_DIR)/"

# Build and run main simulation
# 注意：bsc 需要先 -g 做 elaboration，再用 -e 链接生成可执行文件（原 Makefile 缺链接步骤）
sim: compile
	@echo "Building simulation..."
	$(BSC) $(BSC_FLAGS) $(BSC_SIM_FLAGS) -g mkTestbenchTop $(SRC_DIR)/RMTTop.bsv
	$(BSC) $(BSC_FLAGS) $(BSC_CPP_FAST) $(BSC_SIM_FLAGS) -e mkTestbenchTop -o build/mkTestbenchTop
	@echo "Running simulation..."
	./build/mkTestbenchTop

# Run all real protocol tests（顺序运行五个真实端到端测试；
# 原 TestbenchTop 是硬编码"全部通过"的假测试，已弃用）
test: test-tcp test-srv6 test-vxlan test-ndn test-dnn test-fixes
	@echo "========================================"
	@echo "All protocol e2e tests completed."
	@echo "========================================"

# Run individual protocol tests
test-srv6: compile-tests
	@echo "Running SRv6 Tests..."
	$(BSC) $(BSC_FLAGS) $(BSC_SIM_FLAGS) -g mkTestSRv6 $(TEST_DIR)/TestSRv6.bsv
	$(BSC) $(BSC_FLAGS) $(BSC_CPP_FAST) $(BSC_SIM_FLAGS) -e mkTestSRv6 -o build/mkTestSRv6
	./build/mkTestSRv6

test-vxlan: compile-tests
	@echo "Running VXLAN Tests..."
	$(BSC) $(BSC_FLAGS) $(BSC_SIM_FLAGS) -g mkTestVXLAN $(TEST_DIR)/TestVXLAN.bsv
	$(BSC) $(BSC_FLAGS) $(BSC_CPP_FAST) $(BSC_SIM_FLAGS) -e mkTestVXLAN -o build/mkTestVXLAN
	./build/mkTestVXLAN

test-ndn: compile-tests
	@echo "Running NDN Tests..."
	$(BSC) $(BSC_FLAGS) $(BSC_SIM_FLAGS) -g mkTestNDN $(TEST_DIR)/TestNDN.bsv
	$(BSC) $(BSC_FLAGS) $(BSC_CPP_FAST) $(BSC_SIM_FLAGS) -e mkTestNDN -o build/mkTestNDN
	./build/mkTestNDN

test-dnn: compile-tests
	@echo "Running DNN Tests..."
	$(BSC) $(BSC_FLAGS) $(BSC_SIM_FLAGS) -g mkTestDNN $(TEST_DIR)/TestDNN.bsv
	$(BSC) $(BSC_FLAGS) $(BSC_CPP_FAST) $(BSC_SIM_FLAGS) -e mkTestDNN -o build/mkTestDNN
	./build/mkTestDNN

test-tcp: compile-tests
	@echo "Running TCP Reorder Tests..."
	$(BSC) $(BSC_FLAGS) $(BSC_SIM_FLAGS) -g mkTestTCPReorder $(TEST_DIR)/TestTCPReorder.bsv
	$(BSC) $(BSC_FLAGS) $(BSC_CPP_FAST) $(BSC_SIM_FLAGS) -e mkTestTCPReorder -o build/mkTestTCPReorder
	./build/mkTestTCPReorder

# 回归测试：本轮缺陷修复验证（TCAM 空槽/计数、多表项、命中参数、MOVI、
# 解析器 payload_offset 复位、TCP 删除与报文竞争）
test-fixes: compile-tests
	@echo "Running Fix Regression Tests..."
	$(BSC) $(BSC_FLAGS) $(BSC_SIM_FLAGS) -g mkTestFixes $(TEST_DIR)/TestFixes.bsv
	$(BSC) $(BSC_FLAGS) $(BSC_CPP_FAST) $(BSC_SIM_FLAGS) -e mkTestFixes -o build/mkTestFixes
	./build/mkTestFixes

# Clean build artifacts
clean:
	rm -rf $(BUILD_DIR) $(VERILOG_DIR)
	rm -f *.bo *.ba *.c *.h mkTestbenchTop mkTest*

# Help
help:
	@echo "RMT-BSV Hardware Pipeline Build System"
	@echo ""
	@echo "Targets:"
	@echo "  all            - Compile all BSV files (default)"
	@echo "  compile        - Compile all source files"
	@echo "  compile-tests  - Compile test files"
	@echo "  verilog        - Generate Verilog from BSV"
	@echo "  sim            - Build and run main simulation"
	@echo "  test           - Run all tests"
	@echo "  test-srv6      - Run SRv6 tests"
	@echo "  test-vxlan     - Run VXLAN tests"
	@echo "  test-ndn       - Run NDN tests"
	@echo "  test-dnn       - Run DNN tests"
	@echo "  test-tcp       - Run TCP reorder tests"
	@echo "  test-fixes     - Run fix regression tests"
	@echo "  clean          - Remove build artifacts"
	@echo "  help           - Show this help"
	@echo ""
	@echo "Dependencies:"
	@echo "  - Bluespec Compiler (bsc) must be in PATH"
	@echo ""
	@echo "Directory structure:"
	@echo "  src/       - BSV source files"
	@echo "  test/      - Test files"
	@echo "  build/     - Compiled objects"
	@echo "  verilog/   - Generated Verilog"
	@echo ""
