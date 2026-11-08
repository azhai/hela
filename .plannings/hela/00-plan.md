# Hela 实施计划

> 目标：在 `/opt/repos/hela`（Odin `dev-2026-11` fork）上，把「内存布局所见即所得」做成一条可验证的工程链路。
> 原则：编译器是布局的唯一真源；新增能力走「属性/指令 + 独立 pass 文件 + 独立 flag」；可持续合并上游。

## 进度

| 编号 | 交付物 | 状态 | 验收 |
|---|---|---|---|
| M0 | 基线构建与冒烟测试 | ✅ | `./odin version` → `dev-2026-11:63aac30`；Hello World 可跑 |
| M1 | `-emit-layout:<json\|cbor>` | ✅ | 确定性 JSON；逐类型 size/align/字段 offset/padding/cache line/`layout_hash` |
| M2 | 文件头方言标识 `#+dialect hela` | ✅ | 扩展名保持 `.odin`（`.hel` 已移除）；无方言头的普通文件可引用 Hela 库 |
| M3 | `struct #explicit` | ✅ | 隐式 padding 报错并给出字节区间；无方言头时拒绝 |
| M4 | `intrinsics.layout_*` | ✅ | 12 条 `#assert` 编译期通过 |
| M5 | `core:hela/layout` + `hela-layout` | ✅ | 字节地图渲染、manifest diff、退出码可用于 CI |
| M6 | 回归测试与文档 | ✅ | `tests/hela/run.sh` 四步全绿 |
| M7 | 清单可用性 + ABI 门禁 | ✅ | `-emit-layout-for`、`-layout-cache-line:N`、相对路径、`golden.hash` 门禁；`run.sh` 七步全绿 |
| M8 | `core:hela/ring` | ✅ | SPSC 环：13 条布局 `#assert`、双线程正确性、TSAN 干净、伪共享实测 3.5–4.1x |
| M9 | `struct #split(N)` | ✅ | 一个标签取代手算 padding；与手工版字节等价（编译期 + 运行时双重断言）；`run.sh` 九步全绿 |
| M10 | 字段级 `#align(N)` | ✅ | `core:hela/ring` 的布局改为逐字段声明（字节不变）；清单 v3 增 `declared_align`；`run.sh` 十步全绿 |
| M11 | `#aosoa[W][N]T` | ✅ | 语法糖等价于 `[N/W]#soa[W]T`（同 `layout_hash`）；清单报 `aosoa_width`/`elements`；不需要改 codegen |
| M12 | `#share(label)` + `#+analysis sharing` | ✅ | 不同 writer 共线 → 编译错误；`-layout-cache-line` 同时改清单与判定；`run.sh` 十二步全绿 |
| M13 | 字段级 `#offset(N)` | ✅ | 绝对字节位置；`#explicit` 接受 pin 声明的空隙；清单 v4 增 `declared_offset`；5 个负例 |
| M14 | `hela-layout --waste` | ✅ | 按 padding 排行，区分声明式 padding 与可重排回收；顺手修无字段类型的渲染 bug；`run.sh` 十四步全绿 |
| M15 | `#atomic` + 清单 v5 并发契约 | ✅ | 编译器校验字段可原子类型/互斥/必须带 `#share`；清单加 `atomic`/`share`（CBOR map 长度同步改）；`hela-layout --contract` 按 cache line 输出 owner/原子字段；**`layout_hash` 不变，ABI 基线不刷新** |
| M16 | `#+analysis alloc` | ✅ | 隐式 `context.allocator` 默认参数一律编译错误；`AnalysisFlag_Alloc = 1<<3` 且**不并入 All**（默认关）；`-no-alloc-analysis` / `#+analysis !alloc` 可关；复用已有 `-vet-explicit-allocators` 判定 |
| M17 | `core:hela/*` 运行时库族 | ✅ | 8 个包：`mem` / `queue` / `msg` / `event` / `supervise` / `cache` / `log` / `bench`；Vyukov MPMC 2P/2C litmus、注入时钟 + DST 确定性、generational handle + 重启滑窗、分代 slot 缓存零拷贝读、批量日志、bench 中位数/p99/JSON；全部 Hela 方言并用 M3–M15 的布局语法 |
| M18 | 端到端回归与验证 | ✅ | `tests/hela/runtime` 编译期布局断言 + 行为断言；`run.sh` 扩到 **20 步**（22 个负例 + 严格 vet + ABI 门禁 + TSAN）；`HELA_TSAN=1` 下 MPMC 2P/2C 无 data race；`./odin test tests/core -all-packages` 1072 tests 全绿 |
| M19 | `core:hela/exec` thread-per-core / shared-nothing | ✅ | **零语言改动**：N×N SPSC 邮箱矩阵 + 每 worker 独占 arena/event.Loop/cache；4096 投递唯一值求和 litmus、`--contract` 逐行 owner 校验、每 worker 行为断言；`run.sh` **21 步**、`HELA_TSAN=1` 下 exec 矩阵无 data race；host ~7.9 M msg/s |
| M20 | `core:hela/io` 真实 IO 事件源 | ✅ | **再次零语法改动**：复用上游 `core:sys/kqueue` / `core:sys/posix/poll` 接真实 fd；32 B `Completion #explicit` wire format → `event.post` → `event.loop_tick` 确定性分派；`exec` 每 worker 独占一个 poller，4096 条投递全由内核 completion 驱动；`run.sh` **22 步**、TSAN / 1072 核心测试 / `linux_amd64`+`windows_amd64`+`freebsd_amd64` 交叉 check 全绿 |
| M21 | 跨 target 布局真源（清单 v6 + 多 target ABI 门禁） | ✅ | 清单顶层加 `target` / `pointer_size`（CBOR 顶层 map 4→6）；**`layout_hash` 刻意不含 target**，于是同 hash = 跨机器字节等价；`hela-layout --stable` 比较 N 份清单输出 STABLE/DRIFT/MISSING；`tests/hela/cross` + 5 份 `golden.<target>.hash`（含 `linux_i386` / `wasi_wasm32`）；`run.sh` **23 步**、TSAN / 1072 核心测试 / CBOR 3904 B 完整解码全绿；既有 `golden.hash` 未刷新 |

| M22 | 位级布局真源 + 可复用的按位匹配结构 | ✅ | `src/bit_layout.cpp` 把位段查询做成 intrinsic 与清单共用的单一真源；`layout_bit_mask_of` / `layout_bit_encode_of` 是编译期常量（值超宽直接报错）；清单 **v7** 字段加 `bit_mask`（`layout_hash` 不变，golden 不刷新）、`hela-layout --bits` 独立重算校验位地图；`core:hela/pattern` 提供规则代数 + 互斥校验 + 泛型只读决策表（`Rule` 24 B / `Node` 16 B / `Table_4` 752 B 全 `#explicit`）；两种字宽各 65536 字穷举与独立 oracle / 线性实现三方一致；`run.sh` **25 步**、25 个负例、TSAN / 1072 核心测试 / CBOR 完整解码 / 7 target `--stable` 全绿。设计、两个真坑与取舍见 `18-m22-bit-patterns.md` |

| M23 | exec 泵前向进展（pump） | ✅ | **零新语法**：`consume_batch` 从 exec 抽出、满环 push 化为 pump 重试；`exec` 挂 `core:hela/flow` 决策表。`core:hela/flow`（Gate 64 B `#explicit #align(64)` + Policy/Action 纯函数 + `simulate` 两阶段拓扑模型）在无线程前提下穷举 160 拓扑证明 Spin 死锁 / Pump 完成两类结局；实测容量 8 < 单次 burst 256 仍完成全部 4096 投递（53605 次满环 push 全由 pump 化解）；`run.sh` **26 步**、TSAN 全绿。见 `19-m23-forward-progress.md` |
| M24 | 跨类型 sharing 分析（nested 展开） | ✅ | **零语法/清单改动**：`check_struct_sharing` 第二阶段把嵌套 by-value struct 的标注字段拍平为绝对字节区间，补上「两个 writer 各住一个类型」的结构性盲区（xrep `worker_data` 实证）；跨字段 pair 报 `False sharing`（点路径定位 `b.head_hot`），错位嵌套报 warning（`#align(64)` 机械修复）；标注预检无副作用，未标注文件的 core 库行为与旧版完全一致；`run.sh` 26 步 + TSAN + 1072 核心测试 + xrep（140 单测 + 78 golden + run2/run3 verify）全绿。两个真坑（过早读/过早算 offsets，后者即 M15 的偏移缓存坑在分析侧复现）见 `20-m24-cross-type-sharing.md` |
| M25 | 数组元素伪共享（writer-bearing 类型必须是整 cache line） | ✅ | **零语法/清单改动**：`#+analysis sharing` 对含标注的类型检查 `size`/`align` 是否为 cache line 整数倍，不满足则警告（数组里元素 i 尾部与 i+1 头部同线——任何以类型为单位的分析都看不见的相邻性）；`tests/hela/array_share` 实测 4 线程 append：40 B 元素 6.8 ms vs 64 B 整线 3.8 ms = **1.79x**；xrep 的 `match_lists`（`make([][dynamic]…)`，40 B 元素）改为 `lib.Match_List #align(64)`，但 dense 场景实测无可测差异——瓶颈是单线程归并（诚实负面结论，作为下一轮输入）；`run.sh` **27 步** + TSAN + 1072 核心测试 + xrep test/verify 全绿。见 `21-m25-array-elements.md` |
| M26 | `layout_hash_of` + 运行时 ABI 握手 | ✅ | **清单 v7 不变、golden 不刷新、零语法改动**：`src/layout_hash.cpp` 把字段枚举与 hash 组合抽成单一真源（`layout_writer` 改为调用，6 份 golden 一字未变即为重构正确的证明）；`intrinsics.layout_hash_of($T)` 把 `layout_hash` 变成编译期常量，于是 `#assert(layout_hash_of(Wire) == 0x…)` 是**不需要 golden 文件**的 ABI 门禁；`core:hela/abi` 用 24 B `Stamp` 把它带进运行中的进程（`verify` 区分 `Bad_Magic`/`Bad_Version`/`Layout_Drift`/`Size_Mismatch`/`Align_Mismatch`，`share_as` 只在 `.OK` 时给指针）；`tests/hela/hash` 把整包 **16 个类型**的清单 hash 与编译期常量逐行 diff，另加 7 条等价/差异断言、2 条 ABI pin、8 类误配与文件 artifact 拒错；`run.sh` **28 步**（M27 起 29 步）、TSAN / 1072 核心测试全绿。两个真坑（别名必须 `base_type` 否则 hash 假一致、`#split(N)` 会抬高 align）见 `22-m26-layout-hash.md` |
| M27 | 内存层次实测（`tests/hela/membw`） | ✅ | **零编译器改动，纯测量**：六段探针给出本机（Apple M4）的依赖加载延迟台阶 **1.4 / 5.5 / 100 ns**（L1 64 KiB → L2 4 MiB → DRAM）、单线程流式读 **63 GB/s**、10 线程聚合 **≈100 GB/s**、复制 84 GB/s、SSD 裸读 **1.8 GB/s（1 读者）/ 3.1 GB/s（≥2 读者）**、热缓存 `read_entire_file` 9.6 vs `mmap` 13.2 GB/s；扫描侧证实**空间在趟数不在向量宽度**（单候选 62 / 双候选两趟 30 / 双候选单趟 63 GB/s）。三个"测出来像结论"的坑：依赖加载环被优化器删掉（全报 0.00 ns）、不设 `F_NOCACHE` 写入则"设备速度"其实是 DRAM（14 GB/s）、本机 **cache line 是 128 而编译器默认 64**。`run.sh` **29 步**，见 `23-m27-membw.md` |

| M28 | 清单声明它的 cache line 假设（v8 + 报告横幅 + `--cache-line` 覆盖） | ✅ | **零语法改动、零 golden 刷新**：清单 **v8** 顶层加 `cache_line_explicit`（bool，能表达"有人给过值/没人给过值"的最小信息；`cache_line` 与它都不进 `layout_hash`，6 份 golden 一字未变）；`core:hela/layout/lines.odin` 把线宽变成带出处的**透镜**（`Line_Source{.Declared,.Default,.Overridden}` + 三种措辞的 `line_banner`），`--contract`/`--waste` 抬头必报按哪条线算；`hela-layout --cache-line:N` 让**同一份清单给两个答案**（`Cursors` 64 B → 0 冲突，128 B → `owner=CONFLICT` + 「192 B 不是 128 的整数倍」），且编译器 `-layout-cache-line:128` 给出同样两条结论（工具不是"第二个意见"）；`straddle_summary` 只用 offsets 重算 M25 不变量，证明清单自足；`tests/hela/cbor_lint.py` 守手写的 CBOR map 长度（改坏 `0xa7→0xa6` 立报）；`membw` 第 7 段把 M27 的曲线变成 5 条断言（失败 `os.exit(1)`）。**断言抓到自己**：上一版「内层读得比 DRAM 快」实测 46.35 vs 45.50 GB/s 被推翻 → 改为 note（单线程流式带宽与层级无关，差别只在延迟 66x 与聚合 2.2x）。`run.sh` **29 步**（第 2 步 CBOR 结构、第 15 步 v8 provenance、第 17 步两条线两个答案、第 28 步曲线断言），见 `24-m28-cache-line-assumption.md` |

> 注：25/26 是 `run.sh` 的**测试步骤**数，不是里程碑编号。M15/M16 的语言改造与库族取舍见 `14-m15-runtime.md`；
> M19 的运行时设计、两个真坑与「为何零语法改动」见 `15-m19-exec.md`；
> M20 的平台后端取舍、`Completion` 投影与三个真坑见 `16-m20-io.md`；
> M21 的方向修正（为何不做 epoll）、「`#offset` 钉不住结构体对齐」的发现与多 target 门禁见 `17-m21-cross-target.md`；
> M22 的位级 intrinsic、按位匹配决策树与「叶子必须终验」的实测发现见 `18-m22-bit-patterns.md`；
> M24 的报告归属原则、安全 `base_type` 与「分析不得触碰布局」的教训见 `20-m24-cross-type-sharing.md`；
> M25 的数组边界规则、1.79x 实测与 xrep 的负面结论见 `21-m25-array-elements.md`；
> M26 的单一真源抽取、`#split` 与 align 的关系、以及「别名会撞 hash」的实测见 `22-m26-layout-hash.md`；
> M28 的 v8 取舍（bool 而非枚举、为何默认不能抬到 128）、`--cache-line` 的两次读法与「断言抓到自己」见 `24-m28-cache-line-assumption.md`。

## 端到端链路

```
#+dialect hela               编译器（布局唯一真源）            机器可读输出                 工具 / 库
#explicit/#split/#offset →  type_set_offsets_of          →  清单 v7 (JSON/CBOR)      →  hela-layout: 渲染 / --diff
#align/#aosoa               ├ 位段: bit_layout.cpp            size/align/offset/          --waste / --hashes (ABI 门禁)
#atomic/#share              │        layout_bit_mask_of        padding/layout_hash        --contract (行→owner→原子字段)
#+analysis sharing/alloc    ├ 编译期: intrinsics.layout_*     bit_offset/bit_size/       --stable (跨 target 字节等价)
                            │          #assert                 bit_mask/atomic/share      --bits (位地图 + 独立重算)
                            └ 静态分析: 伪共享 / 隐式分配      target/pointer_size          ↓
                                                                                       core:hela/* 13 个包
                                                                                       ├ pattern: 派生规则 → 只读决策表
                                                                                       ├ io: kqueue/poll → Completion
                                                                                       │     → event.post（不调 handler）
                                                                                       └ exec: 每核一个 Worker +
                                                                                          一个独占 poller + N×N SPSC
        AI / 人读清单与契约写库 ─────── 改完的代码被同一批断言 + litmus + TSAN 重新验证 ──────────────┘
```

M15 之前，清单只回答「字节在哪」；M15 之后，清单还回答「谁写它、是不是原子的」——
这是把 tina / oboe / opus 三个参考项目里靠注释和 `#assert` 人肉维护的并发契约，交回给编译器。
M20 之后，`event.Loop` 里的事件不再全是人造的：真实内核就绪通知被规范化成固定 32 B 的
`Completion`，仍然只在 `loop_tick` 内分派，所以「同 post + 同时钟 + 同 completion = 同 handler 顺序」
在接了 OS 之后依旧成立。M21 之后，清单还会说明自己是给哪个 target 算的，而 `layout_hash` 保持
「只描述字节」——于是**两个 target 同 hash 就等价于「这些字节可以跨平台直传」**。实测发现字段
`#offset` 全部钉死也挡不住 32 位 target 改写结构体对齐，必须再钉 `#align(8)`；这正是不该让模型
从源码猜布局的理由。M22 之后，清单还回答「每个字段占哪几位、掩码是什么」，而规则表从这些位段
**派生**出来：改 `bit_field` 声明会同时改变规则、`#assert`、清单和 `--bits` 的位地图，
没有第二处可以漂移。M26 之后，那个描述字节的指纹不再只是构建产物：`layout_hash_of(T)` 让它在
编译期可断言（`#assert` 就是 ABI 门禁，不需要 golden 文件），`core:hela/abi` 的 24 B `Stamp`
让它跟着进程走——于是「你手里这段字节还是不是我要的形状」第一次变成运行时可回答的问题，
而且答案带着原因（漂移/变大/对齐变了/信封版本不同）。

## 关键文件

| 文件 | 作用 |
|---|---|
| `src/layout_hash.cpp` | **新增 M26**。指纹的单一真源：`LayoutField`、`layout_fields_of_type`、`layout_hash_combine`、`layout_hash_of_type`；由 `checker.cpp` 在 `bit_layout.cpp` 之后 include，于是 intrinsic 与清单调用同一函数 |
| `src/layout_writer.cpp` | **新增**。布局清单导出 pass（M26 起字段枚举与 `layout_hash` 都改为调 `layout_hash.cpp`）（复用 `semantics_writer.cpp` 的 `sw_*`）；M15 升 v5 加字段 `atomic`/`share`，M21 升 v6 加顶层 `target`/`pointer_size`（`sw_map(&w, 4) → 6`），**M22 升 v7** 给 bit_field 字段加 `bit_mask`（`sw_map(14 → 15)`）；`layout_hash` 两次都不变 |
| `src/types.cpp` | 新增 `type_padding_size()`：padding 的单一定义，清单与 intrinsic 共用 |
| `src/check_type.cpp` | `check_struct_explicit_layout()` / `check_struct_split_*()` / `check_field_align()` / `check_field_offset()` / `check_struct_offset_fields()` / `check_struct_sharing()` / `check_field_atomic()`：布局标签与并发契约的校验；`hela_file_of()` 按定义处文件判定方言 |
| `src/check_expr.cpp` | M16：默认参数隐式 `context` 判定处（约 7472 行）加 `#+analysis alloc` 分支，复用已有 `-vet-explicit-allocators` 逻辑，不写 AST 遍历器 |
| `src/check_builtin.cpp` | 三个 `layout_*` 常量的求值 |
| `src/parser.cpp` | `#+dialect`、`#explicit`、`#split`、`#aosoa`、字段级 `#align`/`#offset`/`#share`/`#atomic`（`FieldPrefixArgs` 统一带参前缀、`FieldFlag_atomic` 裸前缀） |
| `src/build_settings.cpp` / `src/main.cpp` | `AnalysisFlag_Alloc = 1u<<3`（刻意不并入 `AnalysisFlag_All`）、`-no-alloc-analysis`、`analysis` 名字表 |
| `core/hela/layout/` | 清单解析 / 字节地图 / diff / `--waste` 排行 / **`contract.odin`**（按 cache line 输出 owner、CONFLICT、无 `#atomic` 提示）/ **`stable.odin`**（M21：跨 target STABLE/DRIFT/MISSING）；`Manifest` 增 `target`/`pointer_size` |
| `cmd/hela-layout/` | CLI（渲染 / `--diff` / `--hashes` / `--waste` / `--contract` / **`--stable`**；`--stable` 拒绝无 `target` 的 v5 清单） |
| `core/hela/ring/` | SPSC 环形队列，布局即文档 |
| `core/hela/{mem,queue,msg,event,supervise,cache,log,bench}/` | **新增 M17**。8 个可组合运行时包，全部 `#+dialect hela` + 布局断言 |
| `core/hela/exec/exec.odin` | **新增 M19，M20 扩展**。thread-per-core 运行时：N×N SPSC 邮箱矩阵、`start`/`wait_idle`/`stop`、`Worker_Stats` 快照、`report_failure`；每 worker 增加独占 `io.Source` 与 `Config.io_handler`，批由真实 IO 事件驱动；零编译器改动 |
| `core/hela/io/io.odin` | **新增 M20**。32 B `Completion #explicit` wire format、`Source` 逐行 owner 契约、`Completion ↔ Event` 投影、`add`/`remove`/`poll`；`poll` 只发布不调 handler |
| `core/hela/io/backend_kqueue.odin` / `backend_poll.odin` / `backend_stub.odin` / `posix_common.odin` | **新增 M20**。复用上游 `core:sys/kqueue` / `core:sys/posix/poll` 的真实后端 + fd helper + 诚实的 `FULLY_SUPPORTED=false` stub |
| `core/hela/event/event.odin` | M20：`Loop` 增 `user: rawptr`，让 handler 拿到自己的 worker，不改 `Event` 形状 |
| `tests/hela/runtime/main.odin` | **新增 M18**。端到端：wire format `#assert` + 8 个库的行为断言 + 2P/2C MPMC litmus |
| `tests/hela/exec/main.odin` | **新增 M19，M20 改造**。真实 pipe → kqueue → `event.Loop` → SPSC 全链路，4096 条投递全部由内核 completion 驱动；唯一值求和 litmus + 每 worker cache/loop/IO/supervise/log 断言 |
| `tests/hela/io/main.odin` | **新增 M20**。真实内核 completion 的 wire format、投影往返、注销、EOF、`handler 只在 loop_tick 内` |
| `tests/hela/cross/main.odin` + `golden.<target>.hash` | **新增 M21**。断言处处成立的跨 target ABI pin（2 个稳定类型 + 2 个故意漂移的控制类型），5 个 target 各一份 golden |
| `src/bit_layout.cpp` | **新增 M22**。位段查询单一真源（`bit_field_lookup` / `bit_field_mask`），由 `checker.cpp` 在 `types.cpp` 后 include，intrinsic 与清单共用 |
| `base/intrinsics/intrinsics.odin` / `src/check_builtin.cpp` | **M22**。`layout_bit_mask_of` / `layout_bit_encode_of` 编译期常量；值超宽、非 bit_field、字段不存在分别报错 |
| `core/hela/layout/bits.odin` + `cmd/hela-layout/main.odin` | **新增 M22**。`--bits` 位地图，独立重算每个 `bit_mask` 并拒绝 v6 清单 |
| `core/hela/abi/abi.odin` | **新增 M26**。24 B `Stamp #explicit #align(8)`、`stamp_of`/`stamp_encode`/`stamp_decode`/`verify`/`publish`/`share_as`/`share`；固定小端 wire，8 类拒绝原因 |
| `tests/hela/membw/main.odin` | **新增 M27**。内存层次探针：依赖加载延迟 / 流式读 / 复制 / 多线程聚合 / 单趟 vs 两趟 SIMD 扫描 / `read` vs `mmap` vs `F_NOCACHE` 裸设备；`quick` 模式 <1 s 供 `run.sh` 用 |
| `tests/hela/hash/main.odin` | **新增 M26**。整包 16 个类型的清单 hash 与 `layout_hash_of` 逐行对账 + 7 条等价/差异 `#assert` + 2 条 ABI pin + 运行时握手与 artifact 拒错 |
| `core/hela/pattern/pattern.odin` | **新增 M22**。规则代数（`term`/`and_rule`/`decode`）+ 互斥 `validate` + 泛型 `#explicit` 决策表；叶子保留规则索引并做最终匹配 |
| `tests/hela/pattern/main.odin` + `tests/hela/bit_*` | **新增 M22**。两种字宽各 65536 字穷举（tree / linear / 独立 oracle）、重叠规则负例、3 个 intrinsic 负例 |
| `tests/hela/` | 回归测试（`layout`/`split`/`field_align`/`field_offset`/`aosoa`/`sharing`/`atomic`/`alloc`/`pattern` 断言，`abi` host ABI 基线 + `cross` 多 target 基线，25 个负例，`ring` 并发库，`runtime` + `io` + `exec` 端到端，`membw` 内存层次探针）；`run.sh` **29 步** |

## 下一步（未做）

提案对照与取舍见 `13-m13-offset-and-waste.md`，M15/M16 的语言改造与库族取舍见 `14-m15-runtime.md`，
M19 的运行时设计见 `15-m19-exec.md`，M20 的 IO 后端与投影取舍见 `16-m20-io.md`，
M21 的方向修正与跨 target 门禁见 `17-m21-cross-target.md`，M22 的位级真源见 `18-m22-bit-patterns.md`，
M26 的指纹单一真源见 `22-m26-layout-hash.md`。原计划的六项欠账已在 M16/M17/M19/M20/M21 完成，
`#share` 跨类型（M24）、数组元素（M25）、泵前向进展（M23）、运行时 ABI 握手（M26）也都已落地。
按价值/成本排序：

1. **让清单说出它的假设**：`cache_line` 来自 `-layout-cache-line`（默认 64），而本机是 128。
   `hela-layout --waste/--contract` 应在报告开头打印"按哪条线算的"，M25 的数组规则也应在
   `-layout-cache-line:128` 下重新跑一遍——现在这条规则在 Apple Silicon 上只覆盖半条线。
2. **把 `membw` 的台阶变成断言**：延迟台阶（L1 < L2 < DRAM 的比例）与"单趟 ≥ 两趟"是
   可判定的性质，适合在 `run.sh` 里做弱断言（例如单趟至少比两趟快 1.3×），避免回归成两趟。
3. `#view`：声明式零拷贝视图（`string` / `[]u8` / mmap → 带字段偏移校验的只读结构）。
   M26 的 `abi.share_as` 已经给出「先验形状再给指针」的骨架，缺的是「把偏移校验也做成声明」。
4. 把 `abi.Stamp` 接进 `core:hela/io` / `exec`：让跨进程投递在 `Completion` 层面就带上指纹，
   而不是等 handler 里解引用才发现版本不对。
5. 更高性能的 IO 后端：Linux 目前是真·`poll()`（O(n)、不给字节数），Windows 是明确的 stub。
   换 epoll / io_uring / IOCP 只动 `backend_*.odin` 一个文件，`Completion` 与 `event.Loop` 不用改。
   **M21 明确后置**：上游没有 epoll 绑定（只有 `core/sys/linux/uring`），自己写就得声明 syscall
   与 `struct epoll_event` ABI；本机 Darwin 且无 docker/qemu，只能交叉 `check`、无法实机验 ABI。
   等有上游绑定或 Linux 实机验证环境再做，不用「编译通过」冒充正确。

明确**不做**（理由见 13、14 号文档）：

- `#aosoa` 的尾 block 部分填充：`#aosoa[8][1001]` 只能退化成 `[126]#soa[8]T`，`len` 会从 1001 变成 1008，静默越界。宁可要求 `N % W == 0`。
- `arena { }` 作用域语法、`par group`、有界 channel 默认、所有权/借用标注：库能力或成本过高，进库不进语法。
- `hela ast/mir --json`：Odin 已有 `-export-semantics`；导出内部 MIR 等于把 fork 钉死在后端实现上。
- OS 信号级容错、绑核、watchdog、持久化 LSM、HTTP 协议栈、async/await：布局不可见或平台分叉过重。

## 不做什么

- 不重命名 `core/`、`base/`、`vendor/` 下的 1000+ 个 `.odin` 文件，也不新增文件扩展名（方言靠文件头标识）
- 不引入 Rust 式生命周期
- 不改 `type_set_offsets_of` 的对齐算法（它是单一真源，只在其后做校验）
- 不改后端 codegen：M1–M21 新增的都是「声明 + 校验 + 导出」或纯库，字节形状不由它们决定
- 不自己声明 syscall / 不复制 `struct kevent` ABI：上游 `core:sys/kqueue` / `core:sys/posix/poll` 已有绑定
