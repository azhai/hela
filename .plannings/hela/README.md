# Hela 实施记录

本目录记录「把 Hela 的内存布局所见即所得做成工程链路」这一轮实施的过程与结论。按里程碑编号阅读：

| 文档 | 内容 |
|---|---|
| `00-plan.md` | 总览、进度表（M0–M28）、端到端链路、下一步 |
| `01-m1-emit-layout.md` | `-emit-layout` 布局清单：schema、设计决定、验证数据 |
| `02-m2-dialect-marker.md` | 文件头方言标识 `#+dialect hela`：为什么放弃 `.hel` 扩展名、按定义处文件判定 |
| `03-m3-struct-explicit.md` | `struct #explicit`：逐字节显式、错误信息、方言门控 |
| `04-m4-layout-intrinsics.md` | `intrinsics.layout_*`：编译期常量与 `#assert` 闭环 |
| `05-m5-layout-library.md` | `core:hela/layout` 与 `hela-layout`：字节地图、diff |
| `06-verification.md` | 回归结果与已知限制 |
| `07-m7-abi-gate.md` | 清单过滤、`-layout-cache-line`、相对路径、`golden.hash` ABI 门禁 |
| `08-m8-ring.md` | `core:hela/ring`：布局即文档的 SPSC 环，伪共享实测 3.5–4.4x |
| `09-m9-split.md` | `struct #split(N)`：一个标签取代手算 padding，与手工版字节等价 |
| `10-m10-field-align.md` | 字段级 `#align(N)`：逐字段的行边界、与 `#explicit`/`#split` 的互斥、清单 v3 |
| `11-m11-aosoa.md` | `#aosoa[W][N]T`：block 转置的语法糖、两个 count、数组 hash 的修正 |
| `12-m12-sharing.md` | `#share(label)` + `#+analysis sharing`：静态伪共享检查、判定规则与开关 |
| `13-m13-offset-and-waste.md` | 原提案逐条对照（采纳/修正/拒绝）、`#offset(N)`、`hela-layout --waste` |
| `14-m15-runtime.md` | 先从「事件·督程·消息·队列·缓存·日志」写出一套运行时，再反推语言改造；三个参考项目的取舍、M15/M16、8 个库族、验证方式 |
| `15-m19-exec.md` | `core:hela/exec` thread-per-core / shared-nothing：为什么是 N×N SPSC、**零语言改动**的结论、布局契约、两个真坑（编译器偏移缓存 / 有界 SPSC 启动死锁）、验证与取舍 |
| `16-m20-io.md` | 真实 IO 事件源：为什么复用上游 kqueue/poll 而不自己写 reactor、`Completion` 32 B wire format 与有损投影、确定性分派不变量、三个平台后端、三个真坑（`#assert` 抓到布局漂移）、全链路 litmus 与跨平台验证 |
| `17-m21-cross-target.md` | 跨 target 布局真源：为何本轮不做 epoll、清单 v6 的 `target`/`pointer_size`、`layout_hash` 为何不含 target、`--stable` 与 5 份 `golden.<target>.hash`、以及「`#offset` 钉不住结构体对齐」的实测发现 |
| `18-m22-bit-patterns.md` | 位级布局真源与可复用按位匹配：为何清单需要导出「位」、两个编译期 intrinsic、清单 v7 的 `bit_mask` 与 `--bits` 位地图、`core:hela/pattern` 的规则代数与决策表、两个真坑（叶子必须终验 / 32 位对齐漂移）、穷举与跨 target 验证 |
| `19-m23-forward-progress.md` | exec 泵前向进展：满环 push 的 pump 化、`core:hela/flow` 的两阶段拓扑穷举（无线程证明 Spin 死锁 / Pump 完成）、容量 8 < burst 256 的实测 |
| `20-m24-cross-type-sharing.md` | 跨类型 sharing 分析：拍平嵌套 struct 补上「两个 writer 各住一个类型」的盲区、报告归属原则、安全 `base_type`（半初始化 Named 的垃圾 base）、以及「分析不得触碰布局」的教训（M15 偏移缓存坑在分析侧复现） |
| `21-m25-array-elements.md` | 数组元素伪共享：`[N]T` / `make([]T,n)` 重复 T 的相邻性盲区、类型级 size/align 规则与机械修法、40 B vs 64 B 元素的 1.79x 实测、xrep `match_lists` 的应用与「dense 场景被单线程归并掩盖」的诚实负面结论 |
| `22-m26-layout-hash.md` | 布局指纹的单一真源与运行时握手：`src/layout_hash.cpp` 抽取（6 份 golden 未变即证明）、`layout_hash_of` 编译期常量、`core:hela/abi` 的 24 B `Stamp` 与 8 类拒绝原因、整包 16 类型的清单对账；两个真坑（别名必须 `base_type` 否则 hash 假一致、`#split(N)` 会抬高 align） |
| `23-m27-membw.md` | 内存层次的实测曲线：本机延迟台阶 1.4/5.5/100 ns、单核 63 GB/s / 10 线程 100 GB/s、SSD 1.8（1 读者）→3.1 GB/s、`read` 9.6 vs `mmap` 13.2、单趟 vs 两趟扫描 63 vs 30 GB/s；三个"测出来像结论"的坑与「cache line 是 128 而默认是 64」 |
| `24-m28-cache-line-assumption.md` | 让清单说出它的假设：清单 **v8** 的 `cache_line_explicit`（bool 而非三态枚举的取舍）、`line_banner` 的三种措辞、`--cache-line:N` 让同一份清单给两个答案（0 冲突 vs `owner=CONFLICT`）、`straddle_summary` 客户端重算 M25 不变量、`cbor_lint.py` 守手写的 map 长度、membw 断言抓到自己（「内层读得比 DRAM 快」实测 1.02x 被推翻） |

## 快速验证

```sh
cd /opt/repos/hela
CXX=/usr/bin/clang++ LLVM_CONFIG=/opt/homebrew/opt/llvm@22/bin/llvm-config \
    ./build_odin.sh release      # homebrew LLVM 23 的 clang 与 macOS 26.5 SDK 不兼容
./tests/hela/run.sh              # 二十九步回归（host + 5 个 target 的 ABI 门禁、ring、
                                 # 25 个负例（sharing_fail 含跨类型伪共享）、#atomic、#+analysis alloc、array 元素实测、
                                 # --contract / --stable / --bits、13 个包严格 vet、pattern 穷举、
                                 # runtime + io + exec 端到端）
HELA_TSAN=1 ./tests/hela/run.sh  # 追加 thread sanitizer：ring + MPMC 2P/2C + io + exec SPSC 矩阵
ODIN_DONT_DOWNLOAD_TEST_ASSETS=1 ./odin test tests/core -all-packages   # 1072 tests

# 手工看一眼
./odin check tests/hela/layout -emit-layout:json -emit-layout-file:/tmp/layout.json
./odin build cmd/hela-layout -out:/tmp/hela-layout
/tmp/hela-layout /tmp/layout.json Ring_Header
/tmp/hela-layout --hashes /tmp/layout.json    # 基线格式，可直接 diff
/tmp/hela-layout --waste /tmp/layout.json     # 哪个 struct 最浪费字节，声明的 padding 单独标出
/tmp/hela-layout --bits /tmp/layout.json      # 位地图：每个 bit_field 段的范围 / 掩码 / 未用位，
                                             # 并独立重算每个掩码（mask mismatches: 0）
/tmp/hela-layout --contract /tmp/atomic.json  # 按 cache line 看「谁拥有哪一行 + 原子字段」

# 并发契约：谁写哪个字段，是不是原子的
./odin check tests/hela/atomic -no-entry-point -emit-layout:json \
    -emit-layout-file:/tmp/atomic.json
/tmp/hela-layout --contract /tmp/atomic.json

# 伪共享到底值多少钱
./odin run tests/hela/ring -o:speed

# #split / #align / #offset 与手写 padding 是不是同一批字节
./odin run tests/hela/split
./odin run tests/hela/field_align
./odin run tests/hela/field_offset

# #aosoa 与 [N/W]#soa[W] 是不是同一批字节
./odin run tests/hela/aosoa

# 按位匹配：规则从 bit_field 声明派生，16/32 位两种字宽各穷举 65536 个字
./odin run tests/hela/pattern -o:speed
./odin check tests/hela/pattern -no-entry-point -emit-layout:json \
    -emit-layout-file:/tmp/pattern.json
/tmp/hela-layout --bits /tmp/pattern.json          # Header / Frame 的位地图
./odin check core/hela/pattern -no-entry-point -emit-layout:json \
    -emit-layout-file:/tmp/pattern_lib.json
/tmp/hela-layout /tmp/pattern_lib.json Table_4    # 可复用结构自身的 752 B 逐字节声明

# 8 个运行时库：编译期布局断言 + 行为断言 + 2 生产者/2 消费者 litmus
./odin run tests/hela/runtime -o:speed

# 真实内核事件：pipe -> kqueue/poll -> Completion(32 B) -> event.Loop
./odin run tests/hela/io -o:speed
./odin check core/hela/io -no-entry-point -emit-layout:json \
    -emit-layout-file:/tmp/io.json
/tmp/hela-layout --contract /tmp/io.json     # hela_io::Source 的 owner=owner 行
/tmp/hela-layout /tmp/io.json Completion    # 32 B 逐字节声明的 OS 事件 wire format

# thread-per-core：4 worker × 16 条 SPSC 通道，4096 条投递全部由真实 IO completion 驱动
./odin run tests/hela/exec -o:speed
./odin check core/hela/exec -no-entry-point -emit-layout:json \
    -emit-layout-file:/tmp/exec.json
/tmp/hela-layout --contract /tmp/exec.json   # 每行一个 owner：workers / controller / worker

# 布局指纹：清单里的值 == 编译期常量，`core:hela/abi` 把它带进运行中的进程
./odin build tests/hela/hash -o:speed -out:/tmp/hash && /tmp/hash /tmp
./odin check tests/hela/hash -emit-layout:json -emit-layout-file:/tmp/hash.json
/tmp/hela-layout --hashes /tmp/hash.json     # 与上面打印的 <Name>\t<hash> 逐行相同

# 跨平台后端能编译（host 是 darwin_arm64）
./odin check core/hela/io -no-entry-point -target:linux_amd64
./odin check core/hela/exec -no-entry-point -target:windows_amd64

# 跨 target 字节等价：哪些类型可以当 wire format，哪些会随 target 漂移
for t in darwin_arm64 linux_amd64 windows_amd64 linux_i386 wasi_wasm32; do
    ./odin check tests/hela/cross -no-entry-point -target:$t \
        -emit-layout:json -emit-layout-file:/tmp/cross_$t.json
done
/tmp/hela-layout --stable /tmp/cross_darwin_arm64.json /tmp/cross_linux_amd64.json \
    /tmp/cross_windows_amd64.json /tmp/cross_linux_i386.json /tmp/cross_wasi_wasm32.json
#   STABLE  cross::Fixed_Wire       （#explicit + #offset + #align(8)）
#   DRIFT   cross::Unpinned_Wire    （只钉 #offset，32 位 target 改写 struct align）

# 伪共享能不能在编译期被抓到
./odin check tests/hela/sharing_fail        # 必须失败，信息里有 "False sharing"
./odin check tests/hela/sharing_off         # 关掉分析后必须通过
./odin check tests/hela/alloc_fail          # 隐式 context.allocator 必须失败
./odin check tests/hela/alloc_fail -no-alloc-analysis   # 关闭后通过
```

## 一句话结论

M1–M14 做的是**把编译器已经知道的事情导出、断言、可 diff、可排序**：没有新增布局算法，也没改对齐规则。
M15–M18 往前走了一步——先照着 tina / oboe / opus 的实现写出一套能跑的高吞吐运行时，才发现两处真正缺的语言能力：
清单只说「字节在哪」不说「谁写它」（补 `#atomic` + 当时的清单 v5 + `--contract`，现为 v7），
以及「不许偷偷分配」没有机器可检查的语义（补 `#+analysis alloc`，复用已有的隐式 allocator 判定）。
8 个库不是 demo：它们用 M3–M15 的语法把 wire format、cache line 归属和分配方式写成编译器能验证的声明，
再用 2P/2C litmus、注入时钟 DST、TSAN 和 1072 个核心测试验证行为。

M19 往后走了一步，也停了一步：**`core:hela/exec` 用这些语法搭出了一个 thread-per-core /
shared-nothing 运行时（N×N SPSC 矩阵、每 worker 独占 arena/事件循环/缓存），却一行语言都没改**——
这本身就是结论，说明 M3–M16 的契约能力够用了。`--contract` 打印的逐行 owner 被 run.sh 直接 grep 成断言，
而不是留在 README 里等人自觉。代价是踩到两个真坑：编译器在 `Runtime` 内嵌「含惰性多态类型」的
Worker 数组时会缓存错误偏移（改用显式分配的切片绕开），以及有界 SPSC 全员先生产会启动死锁
（改用声明式工作预算）。两者都记在 `15-m19-exec.md`。

M20 补上最后一块：`event.Loop` 之前只有人造事件（用户 `post` + 注入时钟 timer），现在接了真实内核。
做法是复用上游 `core:sys/kqueue` / `core:sys/posix/poll`（不自己声明 syscall），把 `KEvent` / `pollfd`
规范化成固定 32 B、逐字节声明的 `Completion`，再经 `event.post` 排进同一个确定性分派点——
`io.poll` 绝不直接调 handler，所以「同 post + 同时钟 + 同 completion = 同 handler 顺序」在接了 OS 之后
仍然成立。`exec` 给每个 worker 独占一个 poller，4096 条投递全部由真实 pipe 事件驱动，litmus + TSAN 双保险。
另外，加一个 `Config.io_handler` 把 `Config` 从 56 B 撑到 64 B 时，`#assert` 当场拦下了
`Runtime.expected` 被挤出第一行——这是布局契约第一次在真实改动里主动起作用，见 `16-m20-io.md`。

M21 本来打算给 Linux 换 epoll，开查才发现上游**没有** epoll 绑定、本机又没有 Linux 实机可验 ABI，
于是转去做更贴主张的一件事：让清单说清自己是哪个 target 算的。清单 v6 加 `target` / `pointer_size`，
但 `layout_hash` **刻意不含 target**——于是「两个 target 同 hash」直接等价于「字节可以跨平台直传」，
`--stable` 把这件事变成一条命令。实测抓到的反直觉事实是：每个字段都用 `#offset` 钉死、padding 为 0、
size 相同的 `Unpinned_Wire`，在 `linux_i386` 上仍会漂移，因为 32 位把 `u64` 对齐从 8 降到 4、
连结构体对齐一起改了；补一个结构体级 `#align(8)` 才在 5 个 target 上完全一致。而同为 32 位的
`wasi_wasm32` 又保持 8 字节对齐——**这种事不能靠猜，只能由编译器导出**。见 `17-m21-cross-target.md`。

M22 把「可复用」从库级惯例提升成**语言结构 + 数据结构**：位段掩码/编码成为编译期常量
（`layout_bit_mask_of` / `layout_bit_encode_of`），由新增的 `src/bit_layout.cpp` 与清单共用同一份真源；
清单 v7 导出 `bit_mask`，`--bits` 把位地图渲染出来并独立重算每个掩码。`core:hela/pattern` 则把
「规则」做成可命名、可组合、可跨类型复用的值（`term` / `and_rule` / `Table($N)`），全部字节用
`#explicit` 钉住。这里有两个值得记住的实测发现：判别树的叶子**必须再做一次完整匹配**，否则
「排除掉其它规则」会被误当成「这条规则命中」（`word=0` 当场复现）；以及 `Rule` 里的 `u64` 在
`linux_i386` 上仍会把对齐降到 4，得补结构体级 `#align(8)` 才能让 7 个 target 的 hash 一致。
两者都不是靠读源码猜得出来的，见 `18-m22-bit-patterns.md`。

M23–M26 是同一件事的四个面：把「已经能算出来的东西」推到它能起作用的地方。M23 把满环 push
变成可证明的 pump；M24/M25 把 sharing 分析越过「同一个 struct」和「一个元素」，补上
「两个 writer 各住一个类型」与「`[N]T` 里相邻的两个元素」两个结构性盲区（后者实测 1.79x）；
M26 则给 `layout_hash` 加了第二条出口——以前它只写在构建产物里，现在还是编译期常量
（`#assert` 即可当 ABI 门禁）和 24 字节的运行时戳（`core:hela/abi`）。这一步最有意思的收获是
两个「一致性」的坑：直接对别名取 hash 会因为 `kind` 变成 `other` 且字段列表为空，让所有别名
**撞成同一个 hash**（比报错危险）；而 `#split(N)` 除了排版还会抬高结构体对齐，所以「和手写
padding 同一批字节」这句话只在 size/offset 意义上成立。两者都写在 `22-m26-layout-hash.md`。

M27 转了一次方向：不再往编译器里加东西，先把自己**依据的那条曲线**测出来。因为 `#align(64)`、
`#share`、「writer-bearing 类型必须整条线」全都在赌一条曲线，而这条曲线以前是**引用**
（"x86 是 64"）而不是测量。六段探针给出 Apple M4 的依赖加载延迟台阶 **1.4 / 5.5 / 100 ns**
（L1 64 KiB → L2 4 MiB → DRAM）、单线程流式读 63 GB/s、10 线程聚合 ≈100 GB/s、SSD 裸读
**1.8 GB/s（1 读者）/ 3.1 GB/s（≥2 读者）**。三个坑都很有教育意义：依赖加载环被优化器整个删掉
（全报 0.00 ns）、不设 `F_NOCACHE` 写入测到的是 DRAM（14 GB/s）、以及**本机 cache line 是 128
而编译器默认 64**。见 `23-m27-membw.md`。

M28 处理的就是最后那一条带来的后果。`cache_line: 64` 在清单里长得像测量值，实际上分不清
「有人判断过」与「编译器兜底」，而本机的线是它的一倍。于是清单 **v8** 加一个
`cache_line_explicit` 布尔、`hela-layout` 的报告开头必须自报按哪条线算、并支持
`--cache-line:N` 换一个透镜重读——**同一份清单、两条线、两个答案**：`Cursors` 在 64 B 下
0 冲突，在 128 B 下立刻变成 `owner=CONFLICT` 加「192 B 不是 128 的整数倍」。同时把 M27 的曲线
变成 `membw` 里的断言（失败即非零退出，`run.sh` 第 28 步守着）。这一轮最值得记的不是新增的
字段，而是**断言抓到了我自己**：上一版断言「内层读得比 DRAM 快」，实测 46.35 vs 45.50 GB/s ——
单线程流式带宽与数据在哪一级无关，一个核的 load 通路先饱和；cache→DRAM 的差别只在延迟（66x）
与多线程聚合（2.2x）上体现。断言改成 note，数字留在输出里。见 `24-m28-cache-line-assumption.md`。

**依然没有改后端 codegen，也没有新增扩展名**，M22/M26/M28 连新语法 token 都没加——所有改动仍是
「声明 + 校验 + 导出 + 报告」或纯库。
