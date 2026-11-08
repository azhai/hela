# M21：跨 target 布局真源（清单 v6 + 多 target ABI 门禁）

> 本轮回答一个问题：**编译器导出的清单，能不能证明「这段字节在每台机器上都一样」？**
> 结论是原来的清单不能——它连自己是给哪个 target 算的都没写。补上这一点后，
> `layout_hash` 从「本机 ABI 指纹」升级成「跨机器字节等价判据」，不需要改哈希算法本身。

---

## 1. 方向修正：为什么这一轮不是 epoll

M20 结尾把「Linux 换 epoll / io_uring / IOCP」列为下一轮最自然的推进点。开工前查了三件事，结论是**不该现在做**：

| 检查 | 结果 |
|---|---|
| 上游有没有 epoll 绑定 | **没有**。`core/sys/linux/` 只有 `bits/constants/syscall_*/types/helpers/wrappers/uring`，`find -iname '*epoll*'` 为空；`core:sys/posix/poll` 与 `core:sys/kqueue` 才是现成绑定 |
| 有没有现成 syscall 封装可复用 | `core/sys/linux/*.odin` 里没有 `epoll_create1`/`epoll_ctl`/`epoll_wait` 的封装；要写就得自己声明 syscall 号与 `struct epoll_event` 的 ABI |
| 本机能否实机验证 | `uname` = Darwin arm64，**没有 docker、没有 qemu**。Linux 后端只能 `-target:linux_amd64 check`，编译通过不代表 `epoll_event` 的 packed 布局、字段偏移、事件位都对 |

而 `00-plan.md` 的「不做什么」里已经写了：**不自己声明 syscall / 不复制平台 struct ABI**。一个只能编译、不能运行、又必须靠手写平台 ABI 的后端，正好是 Hela 最该避免的「布局不可见」。所以这一轮改为推进计划里排第一、**完全可在本机验证**、且直接强化「编译器是布局唯一真源」的那一项。

> epoll / io_uring / IOCP 仍然只是换 `backend_*.odin` 一个文件的事（`Completion` 与 `event.Loop` 不用动）。
> 前置条件是有上游绑定或有 Linux 实机验证环境，缺一个都不做。这不是放弃，是不拿编译通过冒充正确。

---

## 2. 语言改造：清单 v6

### 2.1 缺什么

`odin check <pkg> -target:linux_amd64 -emit-layout:json` 本来就能跑（实测可行），但导出的清单顶层只有
`version / generator / cache_line / types`。于是：

- 把一份交叉 check 的清单和 host 清单放一起，无法区分谁是谁；
- 无法回答「同一个类型在 32 位 target 上是不是同一串字节」；
- ABI 门禁只有一份 `golden.hash`，覆盖不到 `align_of` 随 target 变化这件事。

### 2.2 做了什么

`src/layout_writer.cpp`：

```cpp
// 6: adds `target` (`ODIN_OS`_`ODIN_ARCH`) and `pointer_size` to the manifest root. Both are
// metadata about which target was checked, not about the bytes: `layout_hash` is unchanged,
// so existing golden files stay valid and the same hash can be compared across targets.
LAYOUT_VERSION = 6,
```

```cpp
String layout_target = concatenate3_strings(permanent_allocator(),
                                           build_context.ODIN_OS, str_lit("_"),
                                           build_context.ODIN_ARCH);
sw_map(&w, 6);
sw_key(&w, "version");      sw_int(&w, LAYOUT_VERSION);
sw_key(&w, "generator");    sw_string(&w, str_lit("hela"));
sw_key(&w, "target");       sw_string(&w, layout_target);
sw_key(&w, "pointer_size"); sw_int(&w, build_context.ptr_size);
sw_key(&w, "cache_line");   sw_int(&w, layout_cache_line());
sw_key(&w, "types");
```

`core/hela/layout/layout.odin` 的 `Manifest` 同步加 `target: string` / `pointer_size: int`。
`cmd/hela-layout` 与 `--hashes` 的输出格式**不变**，已提交的 `golden.hash` 不需要刷新。

### 2.3 关键取舍：`layout_hash` 不含 target

哈希描述的是**字节**，不是「谁被要求去摆这些字节」。所以：

| 现象 | 含义 |
|---|---|
| 两个 target 同 hash | 这两个 target 上字节形状真的一样 → 可以当 wire format |
| 两个 target 不同 hash | 某个 size / align / offset 变了 → 不能跨平台直传 |

如果把 target 混进哈希，所有跨 target 比较都会得到「不同」，这个判据就没了；而且每次加 target 都要刷新全部 golden。
`target` / `pointer_size` 只是给读清单的人（或模型）解释差异用的元数据。

> CBOR 顶层 `sw_map(&w, 4) → 6` 必须同步改：JSON 容忍长度错，CBOR 会直接坏。
> 已用自定义解码器验证 `3904 / 3904` 字节完整消费、根 6 键、字段仍 14 键。

---

## 3. 工具：`hela-layout --stable`

```txt
hela-layout --stable <a.json> <b.json>...
```

`core/hela/layout/stable.odin` 把所有清单里 `pkg::name` 的并集按（已稳定排序的）清单顺序列出，
逐类型比较哈希，输出 `STABLE` / `DRIFT` / `MISSING` 三类行；`DRIFT` 会列出每个 target 的
hash / size / align。固定容量 `[512]` 键表，零动态分配，输出确定性。

- 要求至少 2 份清单、且都是 **v6 且有 `target`**；否则 `exit 2`。拿着 host 清单跟自己比是假的跨 target 验证。
- `DRIFT` 不是错误（有些类型本来就该跟着 target 变），它是**信息**；是否算失败由调用方用 grep 决定。

这一步把「AI 读清单判断哪些字节能上 wire」变成一条命令，而不是让人去 diff JSON。

---

## 4. 门禁：5 个 target + 每 target 一份 golden

### 4.1 为什么另建 `tests/hela/cross`，而不是复用 `tests/hela/abi`

`tests/hela/abi/main.odin` 的 `#assert` 把 64 位数字写死了（`layout_padding_of(Mixed) == 13` 等），
`-target:linux_i386` 一编译就红。**不削弱已有 host 门禁**，所以新建一个断言处处成立、专门用来跨 target 的包。

| 类型 | 声明 | 期望 |
|---|---|---|
| `Fixed_Wire` | `#explicit` + 每个字段 `#offset` + **`#align(8)`** | `STABLE` |
| `Aligned_Counters` | 字段级 `#align(64)` + `#atomic` + `#share` | `STABLE` |
| `Unpinned_Wire` | 与 `Fixed_Wire` 完全同字节，但**不**钉结构体对齐 | `DRIFT` |
| `Native_Record` | `rawptr` + `int` + `u8` | `DRIFT` |

`golden.<target>.hash` 覆盖 `darwin_arm64`、`linux_amd64`、`windows_amd64`、`linux_i386`、
`wasi_wasm32`：host + Linux 64 + Windows 64 + 32 位 Linux + wasm32，指针宽度 8/4 都有。
`HELA_UPDATE_GOLDEN=1` 一次刷新全部 5 份。

`tests/hela/run.sh` 的 step 8 会：逐个交叉 `check -emit-layout` → grep `"target":"<t>"` /
`"version":6` / `pointer_size` → `--hashes` diff 对应 golden → 5 份清单喂给 `--stable` →
grep 两条 `STABLE`、两条 `DRIFT`、`2 stable, 2 drifting, 0 missing` →
最后用一个改成 v5 的清单验证 `--stable` **必须拒绝**。

> 门禁里刻意保留 `DRIFT` 类型。一份全是 `STABLE` 的报告无法证明这个门禁还看得见漂移。

### 4.2 本轮最有价值的发现：`#offset` 钉不住结构体对齐

`Unpinned_Wire` 每个字段都用 `#offset(N)` 钉死，`layout_padding_of == 0`，`size == 32`，
在 64 位上和 `Fixed_Wire` 的 `layout_hash` 完全一样。但：

| target | `u64` 字段 align | struct align | hash |
|---|---|---|---|
| darwin_arm64 / linux_amd64 / windows_amd64 | 8 | 8 | `eafa21d1…` |
| **linux_i386** | **4** | **4** | `a212108d…` |
| **wasi_wasm32** | 8 | 8 | `eafa21d1…` |

也就是说：**字段偏移全钉死也不等于 wire format 跨平台稳定**——结构体自身的对齐还会被 target 改写，
进而影响数组 stride / 分配器对齐。给 `Fixed_Wire` 补一个结构体级 `#align(8)`，5 个 target 的哈希立刻全部一致。

还有一层反直觉：同为 32 位，`linux_i386` 把 `u64` 对齐降到 4，`wasi_wasm32` 仍是 8。
**不能靠「32 位所以怎样」去猜**，这也正是清单必须由编译器导出、而不能由模型从源码推断的理由。

---

## 5. 验证

| 项 | 结果 |
|---|---|
| `CXX=/usr/bin/clang++ LLVM_CONFIG=…llvm@22… ./build_odin.sh release` | EXIT=0 |
| `./tests/hela/run.sh` | **23 步 EXIT=0**（新增 step 8；step 1 加入 cross 严格 vet；两处 `"version":5` 断言改 6） |
| `HELA_TSAN=1 ./tests/hela/run.sh` | EXIT=0，MPMC / io / exec 三项 clean |
| `ODIN_DONT_DOWNLOAD_TEST_ASSETS=1 ./odin test tests/core -all-packages` | 1072 tests 全绿 |
| CBOR | `3904/3904` 字节完整消费，根 6 键，字段 14 键 |
| 多 target `check -emit-layout` | 7 个 target 实测（darwin_arm64 / linux_amd64 / windows_amd64 / freebsd_amd64 / linux_i386 / wasi_wasm32 / linux_arm64）全部 EXIT=0 |
| `--stable` | 2 stable / 2 drifting / 0 missing；v5 清单被拒绝 |
| 既有 golden | `tests/hela/abi/golden.hash` 未刷新（`layout_hash` 未变） |

`--stable` 实际输出摘要：

```txt
STABLE  cross::Aligned_Counters  8ff9ec0a498467f0
STABLE  cross::Fixed_Wire        eafa21d1227fd386
DRIFT   cross::Native_Record     (24 B / align 8 → 12 B / align 4)
DRIFT   cross::Unpinned_Wire     (align 8 → align 4 on linux_i386)
4 type(s): 2 stable, 2 drifting, 0 missing
```

---

## 6. 明确不做

- **不把 `target` 塞进 `layout_hash`**：会毁掉跨 target 字节等价判据，并让所有 golden 失效。
- **不刷新既有 `golden.hash`**：v6 只加元数据，字节没变；刷新反而会掩盖「摘要没变」这个事实。
- **不把 `tests/hela/abi` 的断言条件化来凑 32 位**：那是故意写死的 host 基线，削弱它就削弱了门禁。
- **这一轮不做 epoll / io_uring / IOCP**：理由见第 1 节；等有上游绑定或 Linux 实机验证环境。
- 不引入新语法、不改 `type_set_offsets_of`、不改后端 codegen、不新增扩展名。

## 7. 剩余项

跨 target 门禁已销。剩下按价值/成本排序：`#share` 跨类型分析、credits/pump 背压、
`#view` 声明式零拷贝视图、以及（有条件时）更高性能的 IO 后端。
