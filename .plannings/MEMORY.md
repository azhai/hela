# Hela 项目长期约定

## 定位
- `/opt/repos/hela` = Odin dev-2026-11 的 fork，派生方言 **Hela**：扩展名仍是 `.odin`，靠文件头 `#+dialect hela` 标识。
- 主张：内存布局所见即所得，编译器是布局唯一真源；导出确定性机器可读清单，让 AI 读清单而非猜 padding/对齐/伪共享，并用 `#assert` 验证。
- 用途：学习高并发/高性能/高吞吐库（shared-nothing、无锁、AoSoA、SIMD、NUMA、尾延迟）。

## 工程约束
- 可持续合并上游：新能力优先「属性 + 独立 pass 文件 + 独立 flag」；尽量不改 `src/types.cpp`/`check_type.cpp` 主干；新特性必须 `#+dialect hela` 门控。
- 方言判定看**定义处**文件（`ast->thread_safe_file()`），不能用 `ctx->file`（多态 struct 在实例化点重检查会误报）。
- 清单必须确定性（稳定排序 + `layout_hash`）；并发正确性必须配 litmus/TSAN，不能只靠布局。
- 不引入 Rust 式生命周期。
- 构建：`CXX=/usr/bin/clang++ LLVM_CONFIG=/opt/homebrew/opt/llvm@22/bin/llvm-config ./build_odin.sh release`（homebrew LLVM 23 与 macOS 26.5 SDK 不兼容）。`./odin` 二进制被 .gitignore 忽略，不入库。

## 上游事实基线
- 布局唯一真源 `src/types.cpp: type_set_offsets_of` / `type_size_of_internal` / `type_align_of_internal`；padding 单一定义 `type_padding_size()`。
- 已有：`#soa`/`#packed`/`#align/#min_field_align/#max_field_align`/bit field/`#simd`/`matrix`/变量级 `@(align=N)`；`-export-semantics` 的 `sw_*` 写入原语可复用（`src/semantics_writer.cpp`）。
- 并发：`core:sync`、`core:nbio`；`core/thread.Pool` 是单共享队列+mutex（非 work-stealing）。

## 已落地里程碑（细节全在 `.plannings/hela/`，已入 git；M0–M28，分支 design）
- 清单 `-emit-layout:<json|cbor>` + `-emit-layout-file` + `-emit-layout-for` + `-layout-cache-line`。版本 v2 explicit/split → v3 declared_align → v4 declared_offset → v5 atomic/share → v6 target/pointer_size → v7 bit_mask → v8 cache_line_explicit；**都不改字节 → layout_hash 与 golden 不刷新**。`layout_hash` 不含 target/派生元数据 → 跨 target 同 hash = 字节可直传。
- 语法：`struct #explicit`、`#split(N)`、字段级 `#align/#offset/#share/#atomic`、`#aosoa[W][N]T`（=`[N/W]#soa[W]T`，不改 codegen）、`#+analysis sharing|alloc`（alloc 默认关，不并入 All）。
- intrinsics（皆编译期常量）：`layout_padding_of/tail_padding_of/cache_lines_of`、`layout_bit_mask_of/encode_of`、`layout_hash_of($T)`。
- 工具：`core:hela/layout` + `cmd/hela-layout`（`--diff/--hashes/--waste/--contract/--stable/--bits/--cache-line:N`）。
- 运行时库 `core:hela/*` 15 包：mem/queue/msg/event/supervise/cache/log/bench/ring/layout/exec/io/flow/pattern/abi。
- ABI 门禁：`tests/hela/abi/golden.hash`（`HELA_UPDATE_GOLDEN=1` 刷新）+ `tests/hela/cross/golden.<target>.hash`（5 target：darwin_arm64/linux_amd64/windows_amd64/linux_i386/wasi_wasm32）。hash 跳过名为 `_` 的字段。
- 回归：`tests/hela/run.sh` **29 步**（含 CBOR 结构自检、内存曲线断言），任意 cwd 可跑；`HELA_TSAN=1` 追加 TSAN；核心测试 1072。

## 关键设计取舍
- `#atomic` 只校验+标注不改字节；`#+analysis alloc` 只抓隐式 allocator。
- 32B `Completion → Event` 有损投影（`seq` 不投影，完整记录留 `Source.batch`），保证 handler 只在 `loop_tick` 内跑。
- 不做 epoll/io_uring（上游无 epoll 绑定、本机无 Linux 实机）。
- M22 刻意不加新语法 token（加关键字要同步自举的 `core/odin/parser`+`ast`，成本高）→ 用「独立 helper + `$` intrinsic + 泛型 `#explicit` struct」。

## 踩坑速查（精简）
- **加 struct tag / 字段前缀 / 新语法 token** 必须同步 `core/odin/ast`（字段+Flag+字符串表）与 `core/odin/parser`（`parse_field_prefixes`/`Expr_And_Flags`/`handle_field`），否则 `odin doc` 与 core 测试红 → 优先走「属性+intrinsic+库」。新 builtin 只改 `checker_builtin_procs.hpp`（枚举+名字表严格同序）+`check_builtin.cpp`+`base/intrinsics/intrinsics.odin`，不动 AST/parser。
- **CBOR map 长度全靠手算**：`sw_map(&w, N)` 与字段级都要同步改；JSON 不报错、CBOR 坏。`tests/hela/cbor_lint.py` 守它。
- 含 `u64` 且跨 32 位 target 稳定 → 补结构体级 `#align(8)`（`linux_i386` 把 u64 降到 4；`wasi_wasm32` 仍 8，别猜）。`#split(N)` 会把 struct align 抬到 N。`#offset` 钉不住结构体对齐。
- 别名要 `base_type` 再算 hash（否则 kind 落 other、字段空、全撞同一 hash）。
- 位判别树的**叶子必须再验 `(word&mask)==value`**（树只排除不确认，实测 `word=0` 误命中）。
- 不要内嵌「含惰性实例化多态类型」的 struct 数组（`[8]Worker`）→ offsets 缓存过早、LLVM `offset>=prev_offset` 崩；改 `make([]T,n,allocator)`。
- 分析侧：offsets 裸指针先 `type_set_offsets` 再读；分析前做无副作用标注预检（未标注文件默认全开分析会毒化多态缓存）；`base_type` 半初始化 Named 读垃圾 → 用 `type_name` Entity_State 守卫；`-no-sharing-analysis` 二分。
- `gb_snprintf` 返回值含结尾 NUL → 用 `make_string_c(buf)` 或自己 strlen。
- **PATH 上的 `odin` 是 homebrew 上游版**（不认 `#share`/`#explicit`/`#split`）→ xrep 与所有 Hela 代码必须显式用 `/opt/repos/hela/odin`；`odin test <pkg>` 还要 `-collection:xrep=.`。
- 测伪共享/bench 体不能用 `x += 1`（优化器折叠）→ `sync.atomic_add`；依赖加载环要 `sink ~= cur` 防 DCE。
- `posix.open` 不传 mode 得 `--wx------`；`F_NOCACHE` 写入路径也要设，否则"设备速度"测的是 DRAM。
- BSD/macOS `grep` 不认 `\|`/`\t` → 用 `grep -E` 或 Grep 工具；TSV 用 `awk -F'\t'`。
- 包级 `len`/`cap` 遮蔽内置 → 用 `length`/`capacity`；`read_entire_file` 返回 `(data, os.Error)`。

## xrep（../xrep，分支 hela）
- 用 Hela 编译器零改动可编译（方言按定义处判定）。ADR 0010–0013。
- 0011 并行归并（最小堆 + 全局 rank 精确切分，输出与串行逐条相同且与分区数无关，dense 5.7x）。0012 只计数不归并 + 双候选单趟预筛。0013 预读（读者线程 + 有界 FIFO 深度 2）+ 块内 `select+reduce_min` 定位（1/36 密度 `-i` 3.49x）。
- 负面结论：单文件暖数据并行 pread 无收益；BNDM 建表双向置位 1.01x；`match_rest` 不在热路径（`-i` 开销与模式长度无关）。
- 测量方法本身要先被测量：zsh `$mode` 不词分割会让整轮基准变假；`--stats` 内层 ms vs python 外层 wall 混比会误归因；快路径先证明「被执行过」再看数字。
