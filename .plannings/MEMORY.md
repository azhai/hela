# Hela 项目长期约定

## 项目定位
- `/opt/repos/hela` 是 Odin dev-2026-11 的 fork，目标派生新方言 **Hela**（扩展名仍是 `.odin`，靠文件头 `#+dialect hela` 标识）。
- 核心主张：内存布局所见即所得，编译器是布局的唯一真源；产出确定性、机器可读的布局清单，让 AI 读清单而非从源码猜 padding/对齐/伪共享，并用 `#assert` 验证 AI 的布局判断。
- 用途：学习和实践高并发、高性能、高吞吐的库与项目，以及前沿方法（thread-per-core / shared-nothing、io_uring、无锁与 RCU、AoS/SoA/AoSoA、SIMD、NUMA、尾延迟测量）。

## 工程约束
- 以 Odin 最新版月度 tag（dev-YYYY-MM）为基础，需可持续合并上游。因此新增能力优先走「属性 + 独立 pass 文件 + 独立 flag」，尽量不改 `src/types.cpp` / `src/check_type.cpp` 主干。
- 扩展名一律 `.odin`，新特性用文件级 `#+dialect hela` 门控（不接受 `.hel`）；避免全仓重命名、破坏 `foo_linux.odin` 平台后缀约定与 CI。
- 布局清单必须确定性输出（稳定排序 + `layout_hash`），否则 AI 输入是噪声。
- 并发正确性不能只靠布局：必须配 litmus / 线性一致性检查 / TSAN，避免「对齐完美但内存序错误」。
- 不引入 Rust 式生命周期/借用检查：与 Odin 隐式 `context` + 手动分配模型冲突，成本过高。

## 已有事实基线（dev-2026-11）
- 布局控制：`#soa`、`#packed`、`#align/#min_field_align/#max_field_align`、`bit_field`、`#simd`、`matrix`、变量级 `@(align=N)`；单一真源 `src/types.cpp:4769 type_set_offsets_of`。
- 编译期：`size_of/align_of/offset_of/type_info_of`、`#assert`；运行时反射 `base/runtime/core.odin` 的 `Type_Info`（offsets/soa_kind/is_packed）+ `core:reflect`。
- 编译器导出：`src/semantics_writer.cpp` 的 `-export-semantics`（JSON/CBOR，已含 size/align/字段 offset），其 `sw_*` 写函数可复用；`src/json.cpp` 仅只读解析，无通用 JSON writer。
- 并发：`core:sync`（futex/原子/channel）、`core:nbio`（Linux io_uring / BSD kqueue / Windows IOCP）、`core/nbio/mpsc.odin`；`core/thread.Pool` 是单共享队列 + mutex/sema，非 work-stealing。
- 移植蓝本：编译器自身的 `src/thread_pool.cpp`（work-stealing）与 `src/queue.cpp`（MPSC/MPMC + cache-line padding），Odin 层尚无对应实现。
