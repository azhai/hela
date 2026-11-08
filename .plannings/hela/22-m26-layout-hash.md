# M26：`layout_hash_of` —— 把清单里的指纹变成编译期常量，并带进运行中的进程

> 一句话：`layout_hash` 以前只存在于「构建产物」里（清单 JSON/CBOR），程序自己不知道自己是哪个形状；
> 现在它是编译期常量，`#assert` 就是 ABI 门禁，运行时握手可以拿它当版本号。

## 1. 为什么缺这一块

前 25 个里程碑把「字节在哪」做得很完整：清单导出、`--hashes` / `--diff` / `--stable` / `--contract` /
`--bits`、`golden.hash` 门禁、`#assert` 里的 size/align/padding/bit_mask。但 `layout_hash` 一直是
**单向**的：

- 构建期：`odin check -emit-layout` 写一份清单，CI 拿它跟仓库里的 `golden.hash` 比。
- 运行期：无。程序被问到「你手里这个 `Record` 还是不是对方写的那 32 字节」时，什么都不知道。

于是真实的失败模式仍然是「读到错位的字段」，只是发生在构建之后：陈旧的二进制、混装的两个版本、
共享内存里上一个进程留下的东西、别人机器写出的文件。这类错误的表现形式是数据不对，而不是一个错误码。

M21 已经把 `layout_hash` 定义成「只描述字节、不含 target」，所以它天然可以当**字节级版本号**。
缺的只是让它从清单走进代码。

## 2. 做了什么

### 2.1 `src/layout_hash.cpp`：指纹的单一真源

把原先埋在 `layout_writer.cpp` 里的整条链路抽出来：

| 移出 | 说明 |
|---|---|
| `LayoutField` | 字节地图的一行（清单要显示 align/atomic/share，hash 只取 name/offset/size/bit 范围） |
| `layout_fields_of_type` | struct / union / bit_field 的字段枚举（含 `type_set_offsets`） |
| `layout_kind_name` / `layout_soa_name` | hash 里参与的两个字符串 |
| `layout_hash_combine(bt, fields)` | **唯一的**组合函数 |
| `layout_hash_of_type(bt)` | 建字段 + 组合，供 intrinsic 直接调用 |

`layout_writer.cpp` 现在只做「遍历实体 → 取字段 → 调 `layout_hash_combine` → 写 JSON/CBOR」。
这个文件由 `checker.cpp` 在 `bit_layout.cpp` 之后 include（与 M22 同样的位置），于是
`check_builtin.cpp`（求值 intrinsic）和 `layout_writer.cpp`（写清单，在 `main.cpp` 里更晚 include）
看到的是同一份函数。

**重构正确性的证明就是 ABI 门禁**：`tests/hela/abi/golden.hash` 与 5 份
`tests/hela/cross/golden.<target>.hash` 在重构后一字未变。如果我把字段顺序、分隔符或 `_` 跳过规则
抄错一位，这 6 个文件会立刻红。

### 2.2 `intrinsics.layout_hash_of($T) -> u64`

编译期常量，返回值与清单里的 `layout_hash` 逐位相同（同一次函数调用，不是「按同样的规则再算一遍」）。
可以直接写：

```odin
WIRE_HASH :: 0x2873f36e4697a61d
#assert(intrinsics.layout_hash_of(Wire) == WIRE_HASH)
```

这就把「ABI 门禁」从仓库里的 golden 文件搬进了源码：**改布局 = 编译失败**，不需要先跑一次
`odin check -emit-layout` 再 diff。golden 文件仍然有用（它覆盖整包、且能跨 target 比较），但不再
是唯一入口。

不变式与 M21 一致：`layout_hash` 不含 target，所以同一个 `#assert` 在 `darwin_arm64` / `linux_i386` /
`wasi_wasm32` 上都成立——「同一个常量在 7 个 target 上编译通过」直接等于「这些字节可以跨平台直传」。

### 2.3 `core:hela/abi`：24 字节的戳

```odin
Stamp :: struct #explicit #align(8) {
	magic:   u32,   // "HELA"
	version: u16,   // 信封版本
	flags:   u16,   // 调用方语义，精确比较
	hash:    u64,   // layout_hash_of(T)
	size:    u32,   // size_of(T)
	align:   u32,   // align_of(T)
}
#assert(size_of(Stamp) == 24)
#assert(align_of(Stamp) == 8)
#assert(intrinsics.layout_padding_of(Stamp) == 0)
```

- `stamp_of($T)` 每个字段都是编译期常量，热路径上会直接折掉。
- `stamp_encode` / `stamp_decode` 是**手写的小端**编解码，不 reinterpret 结构体：wire format 不能
  依赖本机的端序和对齐规则。
- `verify(got, want) -> Verdict` 按「信息量」排序报告：`Bad_Magic` → `Bad_Version` → `Bad_Flags` →
  （同信封才看类型）`Size_Mismatch` / `Align_Mismatch` / `Layout_Drift`。一个改名是 `Layout_Drift`，
  一个把 `u64` 换成两个 `u32` 是同一个 size，也是 `Layout_Drift`，但一个多出 8 字节的类型会被报成
  `Size_Mismatch`——比「hash 不相等」有用得多。
- `publish(buf, stamp) -> payload` / `share_as(buf, $T) -> (^T, Verdict)`：**只有 `.OK` 才给指针**，
  其余情况返回 `nil` + 原因，所以「忘了判空就解引用别人的字节」这条路被堵住了。24 是 8 的倍数，
  所以 payload 天然按 8 对齐；`share_as` 仍会检查地址，不满足就报 `.Misaligned_Payload`。

## 3. 两个真坑

### 3.1 必须对 `base_type` 取 hash，否则别名会互相撞

第一版直接 `layout_hash_of_type(t)`，`t` 是 `check_expr_or_type` 拿到的类型。对
`Wire :: struct #explicit {...}` 来说它可能是 `Type_Named`，于是：

- `layout_kind_name(Named)` 落到 `default` → `"other"`（而不是 `"struct"`）；
- 字段枚举只看 `Type_Struct`，别名不是 → **字段列表为空**；
- 结果：所有「别名」类型得到同一个 hash（只有 size/align/packed/soa 参与），而清单里是分开的。

实测现象是 `Wire` 与 `Wire_Reordered`（字段顺序相反）hash 相同——比报错更危险的一致。修法是在
`layout_hash_of_type` 内部 `bt = base_type(bt)`，与清单侧 `base_type(e->type)` 对齐。
判定「两个 hash 相等」的能力必须靠负例来守：`Wire != Wire_Swapped` 这条断言就是这次的守门人。

### 3.2 `#split(N)` 会改对齐，于是「同一批字节」这句话得打补丁

`Padded :: struct #explicit { n: u64, _: [56]u8 }` 与 `Padded :: struct #split(64) { n: u64 }`
看起来是同一批 64 字节，但：

| 声明 | size | align (host) | hash |
|---|---|---|---|
| `#explicit` + `_: [56]u8` | 64 | **8**（`linux_i386` 上是 4） | `395ed03c6c9100d1` |
| `#align(64) #explicit` + `_: [56]u8` | 64 | 64 | `5ecec7d5f263b439` |
| `#split(64)` | 64 | 64 | `5ecec7d5f263b439` |

`#split(64)` 的语义是「每个字段各占一条 64 字节线」，它**同时**把结构体对齐提到 64。M9 说的
「与手工版字节等价」在 size/offset 意义上是真的，但 align 不同——而 align 决定 `[N]T` 的 stride，
所以它确实是布局的一部分，hash 看见它是正确的。测试里保留 `Padded_Loose` 这个负例，把这条区分
写成断言而不是注释。

### 3.3 （附）泛型里能用，但全局 `#assert` 里不能包一层

`layout_hash_of(T)` 在泛型过程里正常工作：Odin 只对**特化后**的过程体做检查（未特化的多态过程会被
`checker.cpp` 直接报 `Unspecialized polymorphic procedure`），所以 `$T` 到时已经是具体类型。
但 `#assert(hash_of(Wire) == ...)` 这种「用泛型过程包装一层再放进全局 `#assert`」不行：过程调用需要
`context`，全局作用域没有。于是这条等价性放在运行时断言里，而 ABI pin 一律直接写 intrinsic。

（也顺手加了保护：真给一个未特化的多态类型，`layout_hash_of` 会报
`needs a concrete type`，而不是去算一个半初始化的布局——那正是 M24 里毒化偏移缓存的来源。）

### 3.4 ABI pin 想跨 target 成立，就得自己钉 `#align(8)`

`Record`（`u64` + `u32` + `u32` + `[16]u8`）的第一个版本没有 `#align(8)`，`RECORD_HASH` 这条 pin 在
host 上成立，`linux_i386` 上不成立——32 位把 `u64` 对齐从 8 降到 4，结构体对齐跟着变，而 align 是
hash 的一部分。补一个 `#align(8)` 之后，同一条 `#assert(layout_hash_of(Record) == 0x520c…)` 在
`darwin_arm64` / `linux_amd64` / `windows_amd64` / `linux_i386` / `wasi_wasm32` 上一次通过。

这就是「hash 不含 target」的可操作版本：**同一个常量在 5 个 target 上编译通过 = 这些字节可以跨平台直传**，
而它之所以成立，是因为源码里钉了对齐——不是因为编译器碰巧同意。`run.sh` 把这条循环成 5 次 `check`。

反过来，`Padded_Loose` 的对齐断言不能写成 `== 8`（`linux_i386` 上是 4），只能写成 `!= 64`：
一条断言如果依赖「本机 u64 怎么对齐」，它就不是跨 target 的断言。

## 4. 验证

`tests/hela/hash` 做三件事：

1. **全量对账**：包里 16 个类型，程序打印 `<Name>\t<hash>`，`run.sh` 用
   `hela-layout --hashes | sed 's/^[^:]*:://'` 取清单侧的值，两个文件 `diff`。这样覆盖的是
   **整包每一个类型**，而不是我挑出来的那几个——新增一个类型却忘了打印，diff 会红。
2. **性质断言**（`#assert`，全部编译期）：同字节不同名相等、换序不等、命名 padding 不可见、
   `#aosoa[8][32]Vec3 == [4]#soa[8]Vec3`、`[8]u64 != [2][4]u64`、位段边界移动即变、
   `#atomic`/`#share` 不影响（`Hot == Hot_Plain`），以及两条 ABI pin。
3. **运行时握手**：编码/解码往返、`publish`/`share_as` 载荷保真、8 类误配各自的原因码、
   截断在给指针之前就被拦住、`share` 解出信封、以及写到文件再读回来的 artifact 在 hash 被改一位后
   报 `Layout_Drift` 而不是被当成数据。

`run.sh` 从 27 步扩到 **28 步**（新步骤 27，TSAN 后移为 28），并额外把 `core:hela/abi` 加进
「严格 vet」的循环。步骤 27 里还有一条 5 个 target 的 `check` 循环：同一批 pin 在
`darwin_arm64` / `linux_amd64` / `windows_amd64` / `linux_i386` / `wasi_wasm32` 上都要编译通过。

## 5. 取舍

- **不做**「把清单嵌进二进制」：`layout_hash_of` 是常量，直接落在代码里，不需要新的只读段、
  不需要运行时解析、也不需要把 JSON 大小算进产物。
- **不做**自动握手协议（谁先发、超时、重传）：那是传输层的事。这里只保证「拿到 24 字节就能判定」，
  管道/socket/文件怎么搬是调用方的事——测试里用文件搬了一遍。
- **不改** `layout_hash` 的定义。M26 没有新增字段、没有改版本号（仍是 v7）、没有刷新任何 golden。
  这正是「单一真源」的收益：加一个消费者不需要动生产者的输出。
- `flags: u16` 留白给调用方（例如「只读映射」/「生产者侧」），`verify` 精确比较——语义不同就该拒绝，
  宁可多一个 `Bad_Flags` 也不要猜。
