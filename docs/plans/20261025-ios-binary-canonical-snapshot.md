# iOS 二进制规范快照（第二阶段）设计预研

- 任务 `20261025-ios-binary-canonical-snapshot`；状态 `design-only`：只做设计、尺寸估算与待决定项，**不改生产代码、不实现编解码、不加依赖、不改版本号**。
- 上游文档：`docs/plans/20261024-ios-large-ledger-scaling.md`（第二阶段 = 用带版本和校验和的紧凑二进制格式替代 NDJSON 规范流缓存，Go 直接还原模型，并 intern 账户名/币种字符串）、`docs/handoffs/20261024-ios-large-ledger-scaling.md`（第一阶段结果与已知项）。
- 基线：`main` @ `d0efc04`（第一阶段 PR #541–#549 已合入）。
- 维护者已选定方向：**Go 侧自研紧凑二进制编码器，Swift 只存文件、不解码**。本文按此设计，不再评估 Swift 解码方案。
- 本文路径一律仓库相对；所有结论来自本次会话真实读到的代码，行号对应当前基线。

## 0. 结论摘要

1. **不是另造模型，是把同一条规范流换一种容器。** 当前 NDJSON 已经把规范模型压得很薄：`_canonical_entry` 不导出 `RawLines` 与 `Postings`，posting 元数据根本不导出，`canonicalSourceKey` 已经声明唯一键是 `File:Line:Kind`。二进制唯一能安全去掉的是"为了当记录容器而存在的骨架"——记录外壳、重复字符串、文件路径、日期全文、Decimal 文本。
2. 收益主要来自三处：JSON 编解码（第一阶段实测 Go 导入 7.8s/19%、Python 导出 6.2s/15%）、重复字符串（账户/币种/文件路径/元数据键）、以及**按条目直读**取代"entry → posting* → end_entry 扇入 + pending 指针"。**活堆收益必须靠字符串 intern + 不发生中间拷贝**，不是自动获得的。
3. 尺寸（按第 1 节字段清单逐项推导，见 §2.5）：合成 10 万笔规格下 NDJSON 约 **49.2 MiB**，二进制 **7.2 MiB（14.7%）**（内联 posting，方案 B2）；分段方案 B1 约 **10.6 MiB（21.5%）**。真实账本若 narration/payee 更长，比例升到 **15%–33%**。
4. **最大风险不在格式，在元数据**：`MetadataValue` 是 `any`，今天靠 JSON 通道兜底，Go 读取路径按具体类型断言（`.(string)`、`metadataString`、`metadataValueToBean` 的 `int`/`float64` 分支）。二进制必须**精确还原 Go 类型的集合**（§1.4、§1.6）；现有 `encodeLedgerMetadataValue` **不可复用**（§1.5）。
5. 解码结果必须与 `ReadLocalCanonicalStream` 的结果 `reflect.DeepEqual` 相等——仓库已有同样的判据（`local_canonical_stream_test.go:111` 的 Python parity 测试），这是实现阶段的第一道门（§6.2）。
6. 与计划/交接文档**不一致、需要先确认**的地方见 §7，其中三条会影响正确性：规范流里的 `File` 是**相对路径**（计划未写明）；`LocalCanonicalStreamCache` 的 entry json **没有格式版本字段**；`document.Filename` 仍是绝对路径（#548）。另有一条**语义差异**会导致"保留整数元数据"改变今天的实际行为（§7.2）。

## 1. 字段清单与有损点（当前 NDJSON 规范流）

### 1.1 记录外壳（`_write_canonical_stream`，`App/LedgerMobile/Runtime/ledger_validator.py:468-539`）

按写出顺序，每行一条 JSON：

| 记录 | 必须字段 | 校验（`ReadLocalCanonicalStream`，`server/internal/app/local_canonical_stream.go:20-131`） |
| --- | --- | --- |
| `{"type":"header","version":1}` | `type`,`version` | 第一条记录，`version` 必须为 `1` |
| `{"type":"option","key":K,"value":V}` | `type`,`key`,`value` | 必须早于任何 entry；`key` 非空；重复 key 直接失败 |
| `{"type":"commodity","value":C}` | `type`,`value` | 必须早于任何 entry；`value` 非空 |
| `{"type":"entry","entry":{...}}` | `type`,`entry` | 前一条必须是 `end_entry`（`pending == nil`）；`Kind` 非空；**流里的 entry 不允许带 `Postings`**（`len(entry.Postings) != 0` 即失败）；`Kind == "transaction"` 时 Go 把它置成空切片 |
| `{"type":"posting","posting":{...}}` | `type`,`posting` | 必须紧跟在 `transaction` 的 entry 之后；`account`、`Quantity.Number`、`Quantity.Currency` 均非空 |
| `{"type":"end_entry"}` | `type` | 必须有一条 `pending` entry |
| `{"type":"footer","entries":N,"sha256":HEX}` | `type`,`entries`,`sha256` | `entries == len(model.Entries)`；`sha256` 等于**前面所有记录（不含 footer）的逐字节 SHA-256**；footer 后不允许任何字节 |

外壳层面的契约：

- 单条记录 ≤ `localCanonicalRecordLimit = 1 << 20`（1 MiB），总量 ≤ `localCanonicalStreamLimit = 256 << 20`（256 MiB）；Python 侧同名常量在 `ledger_validator.py:226-227`。
- JSON 解码启用 `DisallowUnknownFields()`（`local_canonical_stream.go:60`），任何新字段都必须进壳或进 entry，不能"悄悄多一个键"。
- 编码器是 `json.JSONEncoder(ensure_ascii=False, separators=(",", ":"), allow_nan=False)`：**CJK 以 UTF-8 原样写入**，不做 `\uXXXX` 转义。这决定了二进制收益的来源是语法字符与重复字符串，而不是转义。
- `_exported_options`（`ledger_validator.py:436-450`）只保留 string 值，list 取最后一项，跳过非字符串与 `input_hash`，并把 `filename`/`include` 路径相对化——**这是有损的**，见 §1.7。

### 1.2 entry 记录字段（`_canonical_entry`，`ledger_validator.py:171-208`）

Go 侧类型来自 `ledgercore.Entry`（`server/internal/ledgercore/parser.go:61-87`，`BeanEntry = Entry`；`server/internal/app/bean_parser.go:15` 再导出为 `BeanEntry`）。

| JSON 字段 | Go 字段 / 类型 | Python 来源 | 说明 |
| --- | --- | --- | --- |
| `Kind` | `Kind string` | `type(entry).__name__.lower()` | `open`/`close`/`commodity`/`pad`/`balance`/`transaction`/`note`/`event`/`query`/`price`/`document`/`custom` |
| `Date` | `Date string` | `entry.date.isoformat()` | 字符串，非 `time.Time` |
| `File` | `File string` | `meta["filename"]` 经 `_relative_source` | **相对工作区根的路径**；只有 `localCanonicalEntries` 才转绝对路径 |
| `Line` | `Line int` | `meta["lineno"]` | 与 `File`+`Kind` 组成 `canonicalSourceKey`（`server/internal/app/local_canonical.go:110-112`） |
| `Metadata` | `Metadata map[string]MetadataValue` | `meta` 去掉 `filename`/`lineno` 与 `__` 前缀 | 变体见 §1.3 |
| `Account` | `Account string` | `entry.account` | |
| `Account2` | `Account2 string` | `entry.source_account` | `pad` 用 |
| `Currency` | `Currency string` | `entry.currency`；`balance` 用 `entry.amount.currency` 覆盖 | |
| `Flag` | `Flag string` | `entry.flag` | transaction 的 `*`/`!` 也在 `Flag` |
| `Payee` | `Payee string` | `entry.payee` | 空串也会写入（`value is not None`） |
| `Narration` | `Narration string` | `entry.narration`，或 `comment` 字段 | 两者都写 `Narration` 键，后者覆盖前者 |
| `Name` | `Name string` | `entry.name`；`event` 用 `entry.type` | |
| `Value` | `Value string` | `query_string`/`description` | |
| `Filename` | `Filename string` | `entry.filename`（**document**） | 当前**未相对化**，见 §7.4 |
| `Currencies` | `Currencies []string` | `list(entry.currencies)` | 保留顺序 |
| `Tags` | `Tags []string` | `sorted(entry.tags)` | 已排序 |
| `Links` | `Links []string` | `sorted(entry.links)` | 已排序 |
| `AmountValue` | `AmountValue BeanAmount{Number string; Currency string}` | `balance`/`price` 的 `_amount(entry.amount)` | `Number` 是 `str(Decimal)` |
| `Tolerance` | `Tolerance string` | `str(entry.tolerance)`，仅 `balance` 且非 `None` | **字符串**（Decimal 文本） |
| `CustomType` | `CustomType string` | `entry.type` | 仅 `custom` |
| `CustomValues` | `CustomValues []MetadataValue` | `[_metadata_value(v.value) for v in entry.values]` | 复用元数据变体，见 §1.3 |

**不会出现在流里、二进制也不应出现的 entry 字段**（`ledgercore.Entry` 的其余成员）：

- `RawLines`：`_canonical_entry` 不投影；Go 注册后由 `localCanonicalEntries` 按 `canonicalSourceKey` 从源条目**后补**（`local_canonical.go:84-87`）。快照不存它，补不齐的行为与今天一致。
- `Postings`：流里的 entry 记录被显式禁止携带，posting 是独立记录。
- `Amount`（`int` 分）：不是流字段，由 `localCanonicalEntries` 现算 `entry.Amount = entry.AmountValue.Cents()`（`local_canonical.go:67`；`BeanAmount.Cents` 见 `server/internal/ledger/amount.go:22-33`）。
- `QuoteCurrency`：**逐 kind 不同**。`_canonical_entry` 写的是 `result["QuoteCurrency" if isinstance(entry, data.Price) else "Currency"] = entry.amount.currency`（`ledger_validator.py:200`）：`price` 把金额币种写进 `QuoteCurrency`，`balance` 写进 `Currency`；两者都同时写 `AmountValue`（其 `Currency` 字段相同）。快照必须按 kind 分别编码这两个字段（见 §2.5 的逐 kind 字段表）。

### 1.3 `MetadataValue` 的变体（`_metadata_value`，`ledger_validator.py:147-160`）

按分支顺序：

1. `isinstance(value, Amount)` → **`str(value)`**，如 `"123.45 USD"`，即普通字符串。
2. `isinstance(value, Decimal)` → **`float(value)`**，JSON 浮点数。
3. `isinstance(value, date)` → ISO 字符串（先于 `str` 分支，所以日期也是普通 string）。
4. `(set, frozenset, tuple, list)` → **递归 list**，元素是上述任意变体（`Decimal`→float、`Amount`→string、日期→string；`set`/`frozenset` 顺序未定义）。
5. `value is None or isinstance(value, (str, bool, int, float))` → 原值，**`int` 保持整数**（`json` 模块对 `bool` 单独处理，写出 `true`/`false`）。
6. 其它对象 → `str(value)`。

所以**线上变体只有 6 种**：`null`、`bool`、`int`、`float`、`string`、`list（递归）`。`Decimal` 与 `Amount` **不会**原样到达 Go。

补充：beancount AST 里同一个 key 在不同条目上可能是 `int` 也可能被解析成 `Decimal`（后者变成 float），所以编码器必须**按值判断**而不是按 key 判断。

### 1.4 posting 记录字段（`_canonical_posting`，`ledger_validator.py:211-223`）

| JSON 字段 | Go 字段 / 类型 | 来源 | 说明 |
| --- | --- | --- | --- |
| `account` | `Account string`（内嵌 `Posting.Account`，`parser.go:27-32`） | `posting.account` | 空值直接失败 |
| `Quantity` | `Quantity BeanAmount` | `_amount(posting.units)` | 必需 |
| `flag` | `Flag string` | 仅当 truthy 才写 | 注意 `ParsedPosting` 内嵌 `Posting`，两者**都有** `Flag` 字段（`parser.go:27-51`）；外层 `ParsedPosting.Flag` 无 json tag、内层有 `json:"flag,omitempty"`，本项解到外层。快照只需还原外层字段 |
| `Cost` | `Cost BeanAmount` | `_amount(posting.cost)` | `cost is not None` |
| `CostDate` | `CostDate string` | `cost.date.isoformat()` | 仅非 `None` |
| `CostLabel` | `CostLabel string` | `cost.label` | 仅非 `None` |
| `Price` | `Price BeanAmount` | `_amount(posting.price)` | `price is not None` |

**不导出、由 `localCanonicalEntries` 强制归一化**（`local_canonical.go:71-81`）：`Amount`/`Currency` ← `Quantity` 的 `Cents()`/`Currency`；`CostAmount`/`CostCurrency` ← `Cost`；`PriceAmount`/`PriceCurrency` ← `Price`；`Blank`/`TotalCost`/`TotalPrice` 一律 `false`；`Canonical` 一律 `true`。

**结构性有损点（最关键）**：posting 的 `meta` **完全没有导出**。`canonicalSourceKey` 也说明 entries 的唯一键是 `File:Line:Kind`，posting 级身份不存在。二进制必须**保持"posting 无元数据"**；加入它会改变模型与编辑器的契约，属于单独变更（§8 决定 6）。

### 1.5 现有 `encodeLedgerMetadataValue` 不能复用（已核实）

- `server/internal/app/ledger_index_store.go:1094`：`encodeLedgerMetadataValue(value MetadataValue) (string, any, any, any, error)`。接受 `nil`→`"null"`、`string`→`"string"`、`bool`→`"boolean"`、`float64`/`float32`/`int`/`int64`→`"number"`（**统一存成 `float64` 列**）。
- **不接受 `[]any`（list）**，返回 `unsupported value type []any`。
- 配套 `decodeLedgerMetadataValue(kind string, textValue sql.NullString, numberValue sql.NullFloat64, booleanValue sql.NullBool) MetadataValue`（同文件 `1115`）只认 `null`/`string`/`number`/`boolean`，且做**互斥校验**（`string` 分支要求 `textValue.Valid` 且 `number`/`boolean` 均无效）。
- 调用点是 Postgres 索引持久化（同文件 `1077`、`1305`）。

**结论**：它是索引存储的 SQL 编解码，**不能**当二进制快照的元数据编码器：① 没有 `list` 变体，而 `_metadata_value` 会递归产出 list；② `int` 被塌成 `float64`，会让整数语义丢失。二进制采用自己的变体枚举（§2.4），语义以 Python 导出为准，**不改动**这个函数，索引路径行为不变。

### 1.6 解码后必须还原成什么具体 Go 类型（读路径约束）

| 位置 | 断言 / 用法 | 需要还原的类型 |
| --- | --- | --- |
| `server/internal/app/local_transaction_page.go:244-276` | `txn.Metadata["type"].(string)`、`needs_review`/`status` 的 `(string)`；`searchCandidates` 分支**原样保留**元数据（注释：preserves exact scalar types） | `string`、`float64`、`bool`、`nil`，list 需可序列化 |
| `server/internal/app/local_account_page.go:188,256` | `txn.Metadata["type"].(string)`、`localAccountChargeString` | `string` |
| `server/internal/app/import_parsing.go:103-111` | `metadataString(value MetadataValue) string`：`nil`→`""`，`string`→原值，其余 `fmt.Sprint` | 任意（但 `fmt.Sprint` 对 `int`/`float64` 输出不同） |
| `server/internal/app/writer.go:1437-1455` | `metadataValueToBean`：`nil`→`NULL`、`bool`→`TRUE`/`FALSE`、`float64`→`strconvFormatFloat`、`int`→`fmt.Sprint`、`string`→带引号 | **`int` 与 `float64` 走不同分支** |
| `server/internal/app/imports.go:374-399`、`import_alipay_small_purse.go:490-947` | `metadataString(...)` | 同上 |

**必须还原的类型集合（设计约束）**

| 线上变体 | 解码后 Go 动态类型 | 原因 |
| --- | --- | --- |
| `null` | `nil` | `metadataString`、`metadataValueToBean` |
| `true`/`false` | `bool` | 写回时 `TRUE`/`FALSE` |
| 整数 | `float64`（与今天一致；若要 `int` 见 §7.2） | `json.Unmarshal` 到 `any` 今天给出 `float64` |
| 浮点 | `float64` | `metadataValueToBean` 的 `float64` 分支 |
| 字符串（含 `str(Amount)`、ISO 日期） | `string` | 上面所有 `.(string)` 断言 |
| list | `[]MetadataValue`（元素递归同上） | `encoding/json` 对 `any` 的默认结果是 `[]any`；因 `MetadataValue = any`，两者是同一类型，但解码器应显式产出 `[]MetadataValue` 以保证 `DeepEqual` 与语义清晰 |

补充：Swift 侧 `LedgerMetadataValue`（`App/LedgerMobile/Sources/LedgerModels.swift:758-790`）只有 `null/string/number(Double)/bool`，**没有 list**；`TransactionViews.swift:5284` 直接用它 `JSONDecoder` 解元数据，遇到 list 会抛错。今天 JSON 通道已如此，二进制不引入新风险，但也不应扩大 list 使用面。

### 1.7 有损点清单（二进制必须等价，不能"顺手修好"）

| 有损点 | 当前行为 | 二进制要求 |
| --- | --- | --- |
| `_exported_options` 只留 string | list 取最后一项，丢弃非字符串与 `input_hash` | 保持：快照的 options 就是这几十个 string |
| `document.Filename` 绝对路径 | 未相对化（#548） | **原样保留**，不在本阶段修复 |
| posting 无元数据 | 不导出 | 保持；格式里**不留**这个字段 |
| `RawLines` 不导出 | 注册后由源补 | 保持；快照不存 RawLines |
| `Metadata` 的 `__` 前缀过滤 | 过滤 | 保持 |
| `Decimal`→float | JSON number | 必须 `float64`（改成 string 会改变 `metadataValueToBean` 输出） |
| 整数 → `float64` | `json.Unmarshal` 到 `any` 的结果 | 见 §7.2：今天实际已是 `float64`；二进制保留 INT/FLOAT 两个 tag 但解码默认产出 `float64` |

### 1.8 数值表示（Go 如何从文本得到分）

- `BeanAmount{Number string; Currency string}`（`server/internal/ledger/amount.go:10-13`）是**十进制文本**；`Cents()` 用 `big.Rat` 精确计算后 `math.Round` 到分，解析失败回退 `parseCents` 的浮点路径（同文件 `22-37`）。
- `entry.Amount`、`posting.Amount`/`CostAmount`/`PriceAmount` 都是 `int` 分；对应的 `Currency` 字段是冗余副本。
- `Tolerance` 是 `string`，**不是**分。
- 因此 `Number` 在二进制契约上可选"十进制文本 / 定点整数 / 二者并存"。推荐定点整数 + 溢出回退文本（§2.3）。

## 2. 二进制布局

### 2.1 总体结构

```text
MAGIC        8 bytes  "BLWSNAP\x00"
FORMAT       u16 BE   = 1（主版本；不认识即 fail-closed）
FLAGS        u16 BE   可选特性位；解码器不认识的位 → 失败
HEADER LEN   u32 BE   头部段长度
HEADER
  sourceVersion   32 bytes（全部源文件 path+bytes 的哈希；与 Swift 缓存键同源）
  sourceBytes     u64 BE
  entryCount      u32 BE
  stringCount     u32 BE
  exporterID      len-prefixed UTF-8（例 "mibook/beancount@3.2.3"）
  appRuntimeFP    len-prefixed UTF-8（Swift 的 runtimeFingerprint）
  createdAt       u64 BE（仅供诊断，不参与校验）
SECTION TABLE  n × { u16 kind, u32 offset, u32 length }
  1=STRING_TABLE 2=OPTIONS 3=COMMODITIES 4=ENTRIES（B2）  5=POSTINGS（仅 B1）
STRING_TABLE   u32 count，count × { u16 len, bytes }（顺序即 string id）
OPTIONS        u32 count，count × { strId key, strId value }
COMMODITIES    u32 count，count × { strId }
ENTRIES        entryCount × ENTRY RECORD
TRAILER        u32 entryCount，32 bytes sha256(MAGIC..ENTRIES 末尾)
（trailer 之后不允许任何字节）
```

设计要点：

- **目录先于段**：一次读入（或 mmap）后按 offset/length 切片，不必顺序扫描。offset/length 必须落在 payload 内、段之间不重叠、必需段各出现一次，否则失败。
- **sha256 覆盖范围** = `MAGIC` 到 `ENTRIES` 段末尾（含头部与段表），**不含** trailer。语义等价于今天"前面所有字节的 SHA-256"，只是把逐行累积换成一次计算。
- **不用 `encoding/gob` 或 `binary` 反射**：格式必须与 Go 结构升级解耦；`gob` 的类型标签不可控、不稳定、跨语言无法实现。
- **不存 `RawLines`、不存分数字段**：都由归一化现算（§1.2/§1.4）。
- **不压缩**：压缩引入解压分配与 CPU，并阻断将来 mmap 零拷贝；`FLAGS` 位预留可能性（§8 决定 8）。

### 2.2 字符串表与 intern

- 进表：`File`（每个源文件一条）、`account`、各 `Currency`、`Metadata` 的 key、`Tags`/`Links`/`Currencies` 元素、`CustomType`、`Name`/`Value`/`Filename`、以及**重复出现≥2 次**的 `Tolerance`。
- **不进表（内联 length-prefixed UTF-8）**：`Payee`、`Narration`、`Flag`、`CostLabel`。理由：真实账本的 narration 几乎不重复，进表只多一次间接（合成账本才重复）。这是 §2.5 的关键假设，敏感性见该节。
- **id 编码**：无符号 `varint`。字符串表通常 < 1000 条，id 1–2 字节；`File` 240 条也在 2 字节内。
- **Go 侧 intern**：解码时每张表只 `string()` 一次，存 `[]string`，所有引用共享同一值。这样同一账户名在 10 万条目里只有**一个字符串头**，`LedgerCache` 的字符串哈希与 `localModelEstimateFactor` 估算都会受益。**不做**跨模型的全局 intern（会跨 generation 泄漏字符串，与"模型可整体释放"的生命周期冲突）。
- **避免中间拷贝**：若整个文件一次读入，`unsafe.String(&buf[off], n)` 可让字段直接指向 buffer，但**模型会隐式钉住整个文件 buffer**（相当于 mmap 语义，heap 统计看不到、jetsam 看得到）。这是 §8 决定 2 的核心权衡。

### 2.3 整数与文本编码

| 值 | 编码 | 理由 |
| --- | --- | --- |
| 计数/长度 | `varint`（无符号 LEB128） | 绝大多数 < 128 |
| `Line` | `varint` | 最大几千 |
| `Date` | 相对上一条的 `zigzag varint` 日序号 delta，或绝对 `u32 BE` | `"2006-01-01"` 是 10 字节；delta 通常 0–2 字节。**必须与 `entry.Date string` 互相无损转换**（流里只可能是合法 ISO 日期） |
| `Number`（`BeanAmount.Number`） | **定点整数**：1 字节 `sign(1) + scale(3..4 位)` + `varint` 无缩放值；超出 scale 上限或 u64 时置"文本回退"标志 + length-prefixed UTF-8 原文 | 100k 合成账本金额都在 0–4 位小数内，定点后约 1–4 字节。**文本回退是硬要求**：`Cents()` 用 `big.Rat` 精确处理任意文本，不能让编码器的精度假设改变语义 |
| `Tolerance` | length-prefixed UTF-8 原文 | 它参与 `Cents()`，不做定点化 |
| `Flag` | 单字节枚举（`""`/`*`/`!`/其它→内联串） | 取值极少 |
| `CostLabel`/`Payee`/`Narration` | length-prefixed UTF-8 | 见 §2.2 |
| 元数据 `bool` | 单字节 | |
| 元数据整数 | `zigzag varint` | 编码期无损（§2.4） |
| 元数据浮点 | 8 字节 IEEE-754 LE | |
| `TotalCost`/`TotalPrice`/`Blank` | **不分配位** | 规范流里恒为 `false`，且从不出现在流里（§1.4），不能"顺便"变成可编码字段 |

**"缺失"与"空串"**：entry 用字段位图表示"字段是否存在"，字符串位为 0 表示 Go 零值。今天 JSON 里 `Payee: ""`（存在但空）与 `Payee` 缺失**在 Go 结构里没有区别**（都是 `""`），所以二进制只需保存值本身，`DeepEqual` 判等即可。

### 2.4 `MetadataValue` 的二进制变体（对齐 §1.3/§1.5/§1.6）

```text
META VALUE = tag:u8 + payload
  0x00 NULL      无 payload
  0x01 BOOL      u8 0/1
  0x02 INT       zigzag varint（有符号）
  0x03 FLOAT64   8 bytes IEEE-754 LE
  0x04 STRING    len-prefixed UTF-8
  0x05 LIST      u32 count，count × META VALUE
  其它 tag       → 解码失败（fail-closed）
```

- 不复用 `encodeLedgerMetadataValue`，也不复用它"kind + 三个可空列"的形态（§1.5）。
- `date` 与 `str(Amount)` 都走 `0x04 STRING`——这正是 Python 的行为（§1.3 分支 1、3），**不需要**单独 tag。
- 限制：递归深度 ≤ 8，单 list 元素 ≤ 4096，单值实际字节 ≤ 1 MiB；超限失败。
- `INT` 与 `FLOAT64` **编码期区分**（不把 int 塌成 float64）；解码期产物见 §7.2 / §8 决定 5。

### 2.5 记录布局与尺寸估算

**B2（推荐）：条目内联 posting**

```text
ENTRY RECORD = u32 recordLen + kind:u8 + flags:u16 + dayDelta:zigzag
             + fileId:varint + line:varint
             + 字段位图（是否存在 Payee/Narration/Flag/Account/Account2/Currency/
                AmountValue/Tolerance/CustomType/CustomValues/Name/Value/Filename/
                Currencies/Tags/Links）
             + [payee 内联] + [narration 内联]
             + tagIds 计数+ids + linkIds 计数+ids
             + metadata 计数 + (keyId:varint + META VALUE)×
             + 按 kind 特有的字段（逐 kind 字段表见下）
             + postingCount:varint + POSTING×（仅 transaction）
POSTING      = accountId:varint + quantity(定点) + currencyId:varint + flags:u8
             + [cost 定点 + costCurrencyId + costDate delta + costLabel 内联]
             + [price 定点 + priceCurrencyId]
```

逐 kind 的特有字段（来自 §1.2 的 Python 投影，**不要**给所有 kind 都按同一张表编码）：

| kind | 专有字段 |
| --- | --- |
| `open` | `Account`, `Currencies` |
| `close` | `Account` |
| `commodity` | `Currency` |
| `pad` | `Account`, `Account2` |
| `balance` | `Account`, `AmountValue`, `Currency`, `Tolerance`(可缺) |
| `transaction` | `Flag`, `Payee`, `Narration`, `Tags`, `Links` + postings |
| `note` | `Account`, `Narration` |
| `event` | `Name`, `Value` |
| `query` | `Name`, `Value` |
| `price` | `Currency`, `AmountValue`, `QuoteCurrency` |
| `document` | `Account`, `Filename`, `Links` |
| `custom` | `CustomType`, `CustomValues` |

（`Flag`/`Tags`/`Links`/`Metadata` 等跨 kind 字段仍走位图；专有字段只出现在该 kind 的记录布局里，这样不需要为每个 kind 付全部字段的位图开销。）

**B1：条目/posings 分段**

- entry 记录不带 posting，后面跟独立 posting 段，每条带 `u32 recordLen` 与定位信息。
- 优点：与今天"单条记录 ≤ 1 MiB"的逐条边界一一对应，单条超大记录仍能被拒绝；流式解析更接近现状。
- 缺点：每条记录多一个长度前缀，posting 记录要重复条目定位信息。

**尺寸推导（全部为本会话实测口径）**

依据：

- 合成账本的精确形状来自 `scripts/large_ledger_bench.py:127-262`：每笔交易 = 1 行交易头 + 2 行 `_metadata_lines`（`id: "tx-%06d"`、`source: "synthetic"`）+ 2–3 行 posting。混合比例来自 `generate()` 的 `roll` 阈值：工资 4.5%、股票 12%（买/卖各半）、换汇 5.5%、美元消费 7%、港币消费 4%、其余 CNY 67%。
- NDJSON 字节：为每个 shape **按 `_canonical_entry`/`_canonical_posting` 的字段构造真实记录，再用与导出器相同的 `json.dumps(ensure_ascii=False, separators=(",", ":"))` 编码**实测（例如 CNY 交易 entry 记录 248 B、普通 CNY posting 115 B、`end_entry` 21 B；可复算脚本见附录 A）。
- 二进制字节：按 §2.1–2.4 的逐字段宽度累加，**两套独立口径**（[1] 只数 posting 与固定头、[2] 显式把每个字段列进预算）分别得到 69.1 与 73.4 B/交易；本节采用把头部/元数据/标签/记录长度全部显式计入的第三口径 **75.6**（最保守）。
- 字符串表规模：`File` 240 条（`transactions/YYYY-MM.bean`）、账户 18 条、币种 5 条、metadata key 2 条、tag 5 条，payload 合计约 6.1 KB，与条目数无关。

| 指标 | 值 |
| --- | --- |
| NDJSON 字节/交易（加权） | **515.4** |
| 二进制 B2 字节/交易 | **75.6**（口径区间 69.1–75.6） |
| 二进制 B1 字节/交易 | **110.9** |
| 字符串表 | 约 6.1 KB payload + 约 0.4 KB 长度/偏移（只随文件数/账户数增长，与条目数无关） |
| 头部 + 段表 + trailer | 约 0.2 KB（含 32 B sourceVersion 与 32 B sha256） |

| 档位 | NDJSON | B2 | B1 |
| --- | --- | --- | --- |
| 10k | 4.9 MiB | 0.73 MiB（14.7%） | 1.06 MiB（21.5%） |
| **100k** | **49.2 MiB** | **7.2 MiB（14.7%）** | **10.6 MiB（21.5%）** |
| 200k | 98.3 MiB | 14.4 MiB | 21.2 MiB |

**为什么是 6.8 倍而不是 JSON 语法字符的 2.4 倍**：JSON 的膨胀不只来自 `{"type":"entry","entry":{...}}` 外壳，还来自 ① `File`（23 B）在**每条** entry 上重复，② `"Number"`/`"Currency"`/`"account"` 键名在**每条** posting 上重复，③ `"Date":"2006-01-01"` 的 10 字节与 `"Line":123` 的固定开销。二进制把这三类都变成 1–2 字节的 id 或 delta。

**敏感性（估算可靠性边界）**

| payee+narration 载荷 | NDJSON/交易 | B2/交易 | 比例 | B2 @100k |
| --- | --- | --- | --- | --- |
| 合成（5 个汉字，15 B） | 515.4 | 75.6 | 0.15 | 7.2 MiB |
| 短（20 B） | 517.4 | 77.6 | 0.15 | 7.4 MiB |
| 典型（60 B） | 557.4 | 117.6 | 0.21 | 11.2 MiB |
| 冗长（150 B） | 647.4 | 207.6 | 0.32 | 19.8 MiB |

即真实账本下 B2 约为 NDJSON 的 **15%–32%**。这是本设计**最需要在真机数据上校准**的一个数：合成账本的 narration 只有 2–4 个汉字。另外，把 Payee/Narration 放进字符串表的收益在真实账本上接近 0（不重复），**不要**为了"intern 字符串"把短串表化。

**"亚秒导入"的可信度**：本机无法证实或证伪。可推导的是：Go 导入的 CPU 主要花在 `encoding/json` 解码与逐字段分配；二进制后单条记录解码 = 读长度 + 几个 varint + 查表，且总字节从 49.2 MiB 降到 7.2 MiB。第一阶段实测 Go 导入 7.8s（两份流，100k），即约 **39 ms/万条/份**；按 1/3–1/5 系数，10 万条约 **1.6–2.6 s**（宿主 4 核 x86，非真机）。**"亚秒"必须由真机验证，本文不承诺**（§8 决定 7）。

## 3. Go 解码契约与分配上界

### 3.1 校验顺序（任一步失败都返回统一错误，不返回部分模型）

与今天 `ReadLocalCanonicalStream` 的 `fail()` 语义一致（`local_canonical_stream.go:27`：一律 `"invalid or incomplete canonical stream"`，不泄漏内部结构）：

1. 文件尺寸 ≤ `localCanonicalStreamLimit`（与 `RegisterLocalModel` 的 `info.Size()` 检查共用同一常量）。
2. `MAGIC` 匹配、`FORMAT == 1`、`FLAGS` 无未知位。
3. `HEADER LEN` 在界内；解析头部；`entryCount`/`stringCount` 与段内容一致。
4. 段表：每段 `offset+length` 不越界、段间不重叠、必需段各一次。
5. trailer：`entryCount` 与头部一致，`sha256` 与"边解析边算"的摘要一致，trailer 后无字节。
6. **未知 kind / 未知 metadata tag / 未知 flags 位 → 失败**，绝不"跳过未知继续读"。这与 Python 侧 `_check_export_value` 对不支持类型 `raise` 一致：宁可没有缓存，也不给少字段的缓存。
7. **任何失败都回退到 NDJSON 路径**，而不是报错给用户（缓存是派生数据）。

### 3.2 分配上界（禁止用计数直接 `make`）

- 所有 `count`/`length` 先与**剩余字节数**交叉校验（`count * minElementSize ≤ remaining`），否则在 `make` 之前失败。这样 `entryCount = 0xFFFFFFFF` 的文件不会触发巨型分配。
- `Entries` 预分配 `min(entryCount, remaining/minEntrySize)`；每条 entry 的 `Postings` 按内联 `postingCount` 预分配，且 `postingCount ≤ remaining/minPostingSize`。
- 字符串：单条 ≤ `localCanonicalRecordLimit`（1 MiB），整表 ≤ 剩余字节。
- 元数据：单值实际字节 ≤ 1 MiB、递归深度 ≤ 8、单 list 元素 ≤ 4096、单 map 键数 ≤ 剩余字节/2。
- 除一次 `os.ReadFile` 的大 buffer 外，不产生与文件等长的副本（§2.2 的 `unsafe.String` 权衡）。

### 3.3 分派与回退

`RegisterLocalModel`（`server/internal/app/local_model_handle.go:185-256`）今天依次做：文件名检查 → `Lstat`（常规文件、非符号链接、`Size() ≤ 256 MiB`）→ `ledgerVersion` 前后两次校验 → `os.Open` 并 `os.SameFile` 比对身份 → `ReadLocalCanonicalStream` → `bindLocalRegisteredModel(..., opened.Size()*localModelEstimateFactor)`。这些**全部保留**，只把"读文件"按 MAGIC 分流：

```text
读 8 字节：
  "BLWSNAP\0"            → ReadLocalCanonicalSnapshot（新文件）
  其它（第一个字节是 '{'） → ReadLocalCanonicalStream（今天的 NDJSON 路径，一字不改）
```

回退因此是**逐文件、无开关**的：删掉 `.snap`，下一次注册自动走 NDJSON。

### 3.4 与归一化的衔接（`normalizedRoot` 的陷阱）

- 规范流的 `File` 是**相对工作区根**的路径；`localCanonicalEntries` 第一次读取时把它改写成绝对路径并设置 `model.normalizedRoot`（`local_canonical.go:59-92`）；`rebindLocalCanonicalModelRoot`（`local_model_handle.go:429-460`）依赖"绝对路径以 `oldRoot/` 开头"才能重绑（item ⑤ 的 promote 靠它）。
- 因此**解码器绝不能把 `File` 解成绝对路径**：`canonicalAbsoluteSource`（`local_canonical.go:96-108`）会以 `canonical ledger source must be relative` 拒绝。二进制里 `File` 就是相对路径字符串。
- 注册产生的模型都是 `cfg.localCanonicalOwned`，所以二进制模型同样走 owned 分支，无额外处理。

## 4. Swift 侧：只存不解码

### 4.1 现状（`App/LedgerMobile/Sources/LocalCanonicalStreamCache.swift`）

- 目录：`<runtimeRoot>/canonical-cache/<runtimeFingerprint>/`（`init` 把 fingerprint 放进路径）。文件：`<sourceVersion>.records` 与 `<sourceVersion>.json`；`names(for:)` 要求 sourceVersion 是 64 位小写 hex。
- entry json 是 `private struct Entry: Codable { let bytes: Int; let sha256: String }`（`:30`）——**没有格式字段**。
- `store`（`:69`）：link/copy 到临时名 → 校验 `bytes` 与整文件 SHA-256 → 写 entry json → 原子 move → `evict()`。
- `restore`（`:49`）：`verified()` 通过后 link（失败则 copy）到输出路径，并刷新 entry 的 modificationDate 作为 LRU 时间。
- `verified`（`:144`）：先用 `StreamStamp`（流 bytes+mtime、entry bytes+mtime）命中进程内 `VerificationCache`（上限 8），否则整文件重算 SHA-256。
- `evict`（`:177`）：按 `json` 的 modificationDate 保留 `capacity = 4` 个，删除时用 `deletingPathExtension().appendingPathExtension("records")` **假设了一个扩展名**。
- `runtimeFingerprint`（`:208-217`）= `SHA256("<CFBundleShortVersionString>|<CFBundleVersion>|<executable mtime>")` 前 12 字节 hex；Debug 重编也会变。
- `prepareDirectory`（`:159`）会删除 `<runtimeRoot>/canonical-cache/` 下**其它 fingerprint 子目录**。

### 4.2 结论：Swift 不需要任何解码器

Swift 只需三件事：算 sourceVersion、按文件名读写、校验字节数与整文件 SHA-256（`sha256(of:)` 已经存在，`:198`）。格式细节对 Swift 完全不可见，唯一的改动是"扩展名/格式门控"与"让 Go 选择读哪一种"。

### 4.3 格式门控必须放在文件名，不能放在 entry json

- 若只在 entry json 加 `format` 字段：旧 App 的 `JSONDecoder` 会**忽略**未知字段（`Codable` 默认行为），于是旧 App 会把一个它不认识的二进制文件当成 `.records` 交给 Go → `invalid or incomplete canonical stream`。错误更贵，且旧 App 无法分辨"损坏"与"新格式"。
- 因此门控放在**文件名**：`<sourceVersion>.<formatTag>.snap`，`formatTag` 是 Go 代码常量（如 `snap1`）。旧 App 的 `names(for:)` 只找 `.records` → miss → 重新导出 NDJSON，**不读也不删** `.snap`。
- entry json 保持 `{bytes, sha256}` 不变：少动 Swift 的验证逻辑，也不给"在 Swift 里解二进制"留下口子。
- Go 头部里仍保留 `FORMAT=1`，与文件名交叉校验（防人工改名/复制）。

### 4.4 失效矩阵

| 变化 | 今天的失效方式 | 二进制后 |
| --- | --- | --- |
| 源文件改动 | `sourceVersion` 变 → 新文件名 → miss | 同 |
| App 升级（含 Debug 重编） | `runtimeFingerprint` 变 → 换子目录 → 全 miss | 同（`prepareDirectory` 已清旧目录） |
| 格式升级（Go 代码） | 无此概念 | `formatTag` 变 → 文件名变 → miss；旧 `.snap` 由 `evict` 淘汰 |
| 缓存损坏 | entry SHA-256 不匹配 → 删除并重导 | 同（SHA-256 覆盖整文件含 trailer） |
| 删缓存目录 | 下次冷启动重跑 Python | 同 |

### 4.5 容量口径

`capacity = 4` 的注释说"committed generation + 正在发布的 stage + 被替换的 generation"。二进制约小 6.8 倍，**建议容量不动**（避免同时引入未验证的磁盘行为变化），但 `evict` 必须改成按**同一 `<sourceVersion>.<formatTag>` 基名**删配套文件，否则会留下孤儿 `.snap`。

## 5. 与 `.records` 并存、回滚、`model-register` 的最小改动

### 5.1 何时生成二进制

现状：Python 在 `_write_canonical_stream` 中逐条 emit NDJSON 并累计 SHA-256；Swift 在 `LocalLedgerEngine.serializedValidateCanonical` 里"`cache.contains(sourceVersion)` 不命中才导出"，导出后 `cache.store(...)`；注册走 `canonicalStreamScratch` → `model-register`。

两条路：

- **路 1（推荐）：Go 从 NDJSON 转码。** Python 一行不改；Go 新增 `writeLocalCanonicalSnapshot(model, w)`，把内存模型写成 `.snap`。优点：Python 零风险、格式与 Go 模型天然一致、差分测试即"转码→解码→DeepEqual"。代价是一次性多读一遍 NDJSON。
- **路 2：Python 直出二进制。** 省掉一次往返，但要在 Python 里重新实现"与 Go 完全一致"的编码器，且初期仍需要 Go 解码器，等于同时上两套实现——正是第一阶段"导出提速"里最难验证的部分。**不建议**（§8 决定 1）。

推荐时序（路 1）：

```text
Swift: 命中 <sv>.snap1.snap → 交给 Go model-register（Go 读二进制）
       否则命中 <sv>.records → 交给 Go model-register（行为=今天）
       都未命中 → Python 导出 <sv>.records → Swift 存缓存 → Go 注册
Go:    注册成功后，可由独立控制操作把模型写成 .snap（一次性），Swift 只负责
       把它挪进缓存目录并计算 SHA-256（Swift 已经在做这件事，不新增能力）
```

注意：**缓存目录（`canonical-cache/<fp>/`）是 Swift 的私有概念**，`RegisterLocalModel` 只知道 `RuntimeDir/canonical-stream`（`local_model_handle.go:202`）。所以 Go 不能自己去写缓存；快照文件的搬迁必须由 Swift 触发，但 **Swift 不需要理解格式**——它只搬文件、算字节数与摘要。

### 5.2 文件名规则的最小改动

今天 `RegisterLocalModel` 的硬约束（`local_model_handle.go:196-201`）：

```go
if len(streamName) != 40 || !strings.HasSuffix(streamName, ".records") { ... }
if _, err := hex.DecodeString(strings.TrimSuffix(streamName, ".records")); err != nil { ... }
```

同样的规则在 `local_scale_benchmark_test.go:73-88`（`localScaleStream`）与 `LocalLedgerEngine.swift:612-631`（`canonicalStreamScratch` 清理 40 位 hex + `.records`）各复制了一份。

**提议的最小改动**：允许两个已知扩展名，basename 仍是 40 位 hex：

```text
<40 lowercase hex>.records   → NDJSON（今天）
<40 lowercase hex>.snap1     → 二进制，FORMAT=1
```

- Go 按扩展名判格式，再与 MAGIC 交叉校验；两者不一致即失败。
- Swift `canonicalStreamScratch` 按缓存命中类型生成临时名（`.records` 或 `.snap1`），`streamFile` 原样传。
- `localScaleStream` 同样要认识 `.snap1`，否则第二阶段基准测不到新路径。
- **不引入"任意不透明文件名"**：那会让 Go 失去格式线索，只能靠内容嗅探，把"旧 App 读到新文件"从"文件名不匹配"退化成"流损坏"。

### 5.3 兼容矩阵

| 场景 | 结果 |
| --- | --- |
| 旧 App + 目录里只有 `.snap1` | 只找 `.records` → miss → 重新导出 NDJSON。**不读、不删** `.snap1` |
| 旧 App + 两种都有 | 命中 `.records`，正常；`evict` 可能连带删掉配套 `.snap1` |
| 新 App + 只有 `.records` | 命中 `.records`，按今天注册，可选升级 |
| 新 App + 只有 `.snap1` | 二进制注册 |
| 删掉整个 `canonical-cache/` | 回到"冷启动跑一次 Python"，无迁移 |
| 回滚 Go 代码 | 现存 `.snap1` 被忽略；**回滚不需要清理任何数据** |

**不变量**：二进制快照永远只是 `.records` 的替代品。`.bean` 源、sourceVersion、校验语义、413、64MiB/256MiB/1MiB 上限、错误文案全部不变。

### 5.4 改动清单（实现阶段；本文不改）

| 文件 | 改动性质 |
| --- | --- |
| `server/internal/app/local_canonical_snapshot.go`（**新增**） | 编码器/解码器、`FORMAT` 常量与 `formatTag`、`ReadLocalCanonicalSnapshot` |
| `server/internal/app/local_canonical_stream.go` | **只加分派**（读 8 字节 MAGIC 后转发），NDJSON 逻辑不动 |
| `server/internal/app/local_model_handle.go` | 文件名规则由"一个扩展名"改为"已知扩展名集合" |
| `App/LedgerMobile/Sources/LocalCanonicalStreamCache.swift` | `names(for:)` 加 formatTag；`evict`/`store` 的配套扩展名规则 |
| `App/LedgerMobile/Sources/LocalLedgerEngine.swift` | `canonicalStreamScratch` 的临时名扩展名随缓存命中类型 |
| `server/internal/app/local_scale_benchmark_test.go` | 认识 `.snap1`，新增二进制导入阶段 |
| `scripts/large_ledger_bench.py` | 可选：报告二进制尺寸 |

**`estimate` 必须同步复核**：`RegisterLocalModel` 用 `opened.Size()*localModelEstimateFactor`（`local_model_handle.go:246-247`），而 `factor = 6` 的注释明确写着"基于 47MB 规范流实测 237–365MB（5–8×）"。换成 7.2 MiB 的二进制后，同一 factor 会把 100k 模型估成约 **43.2 MiB**，远低于真实活堆（模型仍是 O(N) 的 `[]BeanEntry` + `string`）。这是**必须与格式一起改**的地方：改为按条目数/字符串数估算，或给二进制单独 factor，并以"注册后 HeapAlloc"为门（§6.5）。

## 6. 测试计划

复用现有约定：Go 单测在 `server/internal/app`；Python 测试在 `App/LedgerMobile/Runtime/test_ledger_validator.py`；规模基准走 `BenchmarkLocalScaleStages` 的 opt-in 门控；合成账本由 `scripts/large_ledger_bench.py` 生成（10k/50k/100k，固定 seed）。

### 6.1 golden 夹具（10k）

- 用 `python3 scripts/large_ledger_bench.py generate --tier 10k` 生成合成账本，用真实 `export_canonical_json` 导出 `.records`（**权威流**）。
- 走"Go 转码 → `.snap1` → 解码"，把**最小**夹具入仓：覆盖全部 12 种 kind、全部元数据变体（含嵌套 list）、空字段、无 posting 的 kind、多小数位与负值、`CostDate`/`CostLabel`、`flag`、`Tolerance`、多元素 `Tags`/`Links`/`Currencies`。不要入仓 10k 全量（体积与更新成本）。
- 10k 全量交给 §6.5 的基准。

### 6.2 差分测试（核心门）

```go
ndjsonModel, err := ReadLocalCanonicalStream(bytes.NewReader(records))
snapshotBytes, err := EncodeLocalCanonicalSnapshot(ndjsonModel)
snapshotModel, err := ReadLocalCanonicalSnapshot(bytes.NewReader(snapshotBytes))
reflect.DeepEqual(snapshotModel, ndjsonModel)     // 必须相等
```

- 判据与仓库已有先例一致：`local_canonical_stream_test.go:111` 用 `reflect.DeepEqual` 锁住"Python 导出的流 == legacy canonical"。差分测试等于给"二进制 == NDJSON"再加一层。
- 额外断言 `json.Marshal(model)` 字节相等（`LocalCanonicalModel` 带 json tag），确保对外可见的模型序列化不变。

### 6.3 损坏/截断/版本用例（对 `local_canonical_stream_test.go:58-77` 的形式）

| 用例 | 期望 |
| --- | --- |
| 空文件 | 失败 |
| 头部截断（前 8/16/64 字节） | 失败 |
| 段表 offset/length 越界或段重叠 | 失败 |
| trailer 截掉 | 失败 |
| 改动任意一个数据字节 | 失败（sha256） |
| trailer 后附加 `{}` | 失败 |
| `FORMAT = 2` | 失败（未知版本） |
| 首字节改成 `{`（伪装 NDJSON） | 走 NDJSON 路径并失败（行为一致） |
| 未知 kind / 未知 metadata tag / 未知 FLAGS 位 | 失败 |
| 字符串表 id 越界 | 失败 |
| `entryCount` 远超实际可承载条目 | 失败且不大量分配（`testing.AllocsPerRun` 或内存断言） |
| list 深度 > 8 / 元素 > 4096 / 单值 > 1 MiB | 失败 |
| 扩展名 `.snap1` 但内容是 NDJSON（或反之） | 失败（交叉校验） |

### 6.4 Python 侧

- 采纳路 1 时 Python **不需要新测试**：`_write_canonical_stream` 一行不动，第一阶段 item ④ 的"字节不变"测试继续有效。
- 若将来走 Python 直出二进制，必须新增"与 Go 编码器逐字节一致"的对照测试——这是本文不建议该路径的主要原因之一。

### 6.5 尺寸与分配基准（复用 `BenchmarkLocalScaleStages` 约定）

在 `server/internal/app/local_scale_benchmark_test.go` 同构新增 `BenchmarkLocalCanonicalSnapshotStages`，门控方式与 `:42-49` 完全一致（`LOCAL_LEDGER_SCALE_BENCHMARK=1` + `LOCAL_LEDGER_SCALE_DIR`，可选 `LOCAL_LEDGER_SCALE_RESULT`），**默认 `go test ./...` 只编译不运行**。

阶段：1) NDJSON ingest（今天基线）→ 2) snapshot ingest → 3) snapshot encode（一次性）→ 4) first page / warm page（保持可比）。报告 `entries / streamBytes / snapshotBytes / 每阶段 ms / heapAllocBytes / totalAllocBytes`，与今天 `localScaleResult` 同构。

建议验收门（最终以真机为准）：

- 字节：`snapshotBytes / streamBytes ≤ 0.35`（合成账本实测 0.147，给真实账本 narration 变长留余量；真实账本若 narration 冗长仍可到 0.32）。
- 导入时间：`snapshot ingest ≤ 1/3 × NDJSON ingest`。
- 活堆：注册后 `HeapAlloc` 不高于今天的 100%。**若没有下降，说明 §2.2 的"整文件 buffer 被模型钉住"或 intern 未生效，需重新评估，而不是宣布收益达成。**

### 6.6 必跑回归

- `server/`：`go test ./...`、`go build ./cmd/ledger-web`。
- `App/LedgerMobile/Runtime`：`python3 -m unittest test_ledger_validator`（需 beancount 3.2.3 的 3.12 解释器）。
- `App/LedgerMobile`：`swift test`、`swift build --triple arm64-apple-ios17.0`，以及带 `LedgerCore.xcframework` 的 `canImport(LedgerCore)` 分支编译（第一阶段已知：CI 不编译该分支）。
- 打包前重跑 `scripts/build-ledgercore-xcframework.sh`（新增 Go 导出符号时）。

## 7. 与计划/交接文档不一致、或需要先确认的地方

### 7.1 规范流里的 `File` 是相对路径，计划未写明

- `_relative_source`（`ledger_validator.py:163-168`，函数定义在 `:164`）把 `meta["filename"]` 相对化；Go 的 `canonicalAbsoluteSource`（`local_canonical.go:96-108`）**拒绝**绝对路径；item ⑤ 的 `rebindLocalCanonicalModelRoot`（`local_model_handle.go:429-460`）要求归一化后必为绝对路径。
- 影响：格式里 `File` 必须是相对路径字符串，这条要写成**不变量**。若有人"顺手"存成绝对路径，注册会以 `canonical ledger source must be relative` 失败，而错误信息不会指向格式。

### 7.2 整数元数据在今天的 JSON 通道里已经变成 `float64`

- `ReadLocalCanonicalStream` 把 `Metadata` 解成 `map[string]MetadataValue`（`MetadataValue = any`，`server/internal/ledger/model.go:4`），而 `encoding/json` 对 `any` 的默认行为是**所有 JSON number 都解成 `float64`**。
- 因此今天：Python 写 `id: 3` → JSON `3` → Go `float64(3)`；`metadataValueToBean`（`writer.go:1437`）的 `int` 分支在"从规范流注册的模型"上**实际走不到**（只有 `ParseLines` 等手写路径会产生 `int`）。
- 所以"保留 int 语义"如果体现在**解码结果**上，会改变当前行为（类型断言、`fmt.Sprint`、写回文本路径）。二进制**编码期**必须保留 INT/FLOAT 区分（不把 int 塌成 float64，避免丢失 > 2^53 的整数信息），**解码期**是否产出 `int` 需要拍板（§8 决定 5），默认与今天一致产出 `float64`。

### 7.3 `LocalCanonicalStreamCache` 的 entry json 没有格式/版本字段

- `private struct Entry: Codable { let bytes: Int; let sha256: String }`（`LocalCanonicalStreamCache.swift:30`）只有这两个字段。计划说"以源版本 + 运行时版本 + 格式版本为键"，但代码里**没有"格式版本"这一维**。
- 影响：格式版本必须新增一个维度（本文放在文件名里的 `formatTag`），否则新旧格式会争用同一个 `<sourceVersion>.records`。

### 7.4 `document.Filename` 仍是绝对路径（#548）

- `_canonical_entry` 对 `filename` 字段直接 `getattr(entry, "filename")`，**没有**经过 `_relative_source`；handoff 已列为已知 bug。
- 影响：快照**逐字节保留**这个绝对路径，所以"同一份账本拷到另一个目录 → 快照字节相同"**今天就不成立**。二进制不修复也不扩大它；若第二阶段想利用"快照跨目录复用"，必须先修 #548。建议不放进第二阶段（会改字节与 promote 行为）。

### 7.5 `estimate` 口径必须与格式同步改

见 §5.4 末段：`opened.Size()*6` 的系数是按"47MB 流 / 237–365MB 活堆"标定的，二进制变小 6.8 倍后会把 100k 模型估成约 43 MiB。不同步改会让 LRU 预算失效（可能同时驻留多个大模型）。

### 7.6 计划里的"47MB → 目标比例"没有给出口径

计划只写"流 47MB，把冷启动从秒级降到亚秒"，没有定义"二进制应该多大"或"导入应该多快"。本文 §2.5 与 §6.5 给出可测量口径（字节比、导入时间比、HeapAlloc 不升）。

## 8. 给维护者的待决定项（每项附推荐）

### 决定 1：二进制由 Go 从 NDJSON 转码，还是 Python 直出？

**已定并已实现：Go 转码（路 1）。Python 直出不做。**

原始理由是"Python 零改动、格式与 Go 模型天然一致、失败回退无需迁移"。实现后的实测进一步否掉了 Python 直出这条路：

| 阶段（100k，beancount `log_timings`） | 耗时 | 占比 |
| --- | --- | --- |
| **booking** | **18.35 s** | **68%** |
| parse | 4.32 s | 16% |
| run_transformations | 2.45 s | 9% |
| validate | 1.86 s | 7% |

也就是说**序列化只占首次加载的约 6%**（100k：写出 2.71 s vs 加载 40.95 s），Python 直出最多省下这一小部分，却要承担"两套编码器逐字节一致"的证明成本，收益与代价不匹配。

**首次加载慢的正解是 beancount 自带的 pickle 加载缓存**，不是换编码器：100k 从 20–27 s 降到 1.5–2.4 s（8–15×），已集成。官方 `loader.py` 的注释写明"unless an environment variable disables it, use the pickle load cache automatically"——缓存就是上游给出的答案，booking 算法本身仍是已知的未优化热点（源码里多处 `FIXME`/`TODO` 承认）。

因此首次导入的 20–27 s 属于 beancount 固有成本；想让它"感知上不慢"，方向是把导入放后台并通知，而不是优化序列化。

### 决定 2：Go 侧是否再做词典 intern？文件 buffer 生命周期怎么定？

**推荐：做，分两步。**
- 第一步（必须）：字符串表 id → `[]string` 表 → 所有引用共享同一 `string` 值。这是"intern 账户名/币种"的最小实现，不需要 `unsafe`，也不额外建 map。
- 第二步（可选，需实测）：用 `unsafe.String` 零拷贝指向文件 buffer。省一次 O(N) 拷贝，但模型隐式持有整个 buffer（≈ mmap 语义：heap 统计看不到、jetsam 看得到）。第一阶段已因基准偏低吃过亏，**建议第二步等真机数据**；第一步与第二步在上线前都要在基准里对比 `HeapAlloc`。
- 明确拒绝：跨模型全局 intern（会跨 generation 泄漏字符串，与现有生命周期冲突）。

### 决定 3：迁移期是否保留两种格式？

**推荐：是，但只做"读旧、写新"的单向兼容，并有强制淘汰点。**
- 读：`RegisterLocalModel` 同时接受 `.records` 与 `.snap1`（二进制是缓存，不是权威源）。
- 写：只写 `.snap1`；同一 `<sourceVersion>` 的 `.snap1` 落盘后**立即删除**对应 `.records`，不留两份。
- 淘汰：格式升级时 `formatTag` 变，旧 `.snap1` 由 `evict` 自然淘汰。
- **不做双写两格式**（缓存目录与容量口径翻倍、验证成本翻倍）。

### 决定 4：格式版本与 App runtime fingerprint 谁负责失效？

**推荐：三层各管一层，互不越权。**
- `sourceVersion`（Go，哈希全部源文件）：管**账本内容**变化，Swift 用它做缓存键。不变。
- `runtimeFingerprint`（Swift，版本号+build+可执行文件 mtime）：管**App 构建**变化（含 Debug 重编）；它已在缓存目录路径里，二进制沿用，Go 不参与。
- `FORMAT` + `formatTag`（Go 代码常量）：管**格式**变化。**只有不兼容时才 +1**；新增可选段/字段用 `FLAGS` 位，**不**加主版本，否则每个小改动都等于全量失效。
- 三者都命中才复用；任一不匹配即重新导出/重新转码。**不要**用 App 版本号代替 `FORMAT`，也不要用 `FORMAT` 代替 sourceVersion。

### 决定 5：整数元数据解码后还原成 `int` 还是 `float64`？

**推荐：编码期区分 INT/FLOAT（不塌成 float64），解码期与今天 `json.Unmarshal` 到 `any` 的结果一致（`float64`）；"还原 `int`"作为独立后续变更。**
理由：今天的 `metadataValueToBean` `int` 分支在规范流模型上走不到（§7.2），"修好"它会改变写回账本的文本路径，这类改变应与"schema 扩展/新元数据类型"分开评审。若维护者更看重语义正确，也可直接选"还原 `int`"，但需在同一 PR 补 `metadataValueToBean`/`metadataString` 的类型矩阵测试，并接受与今天不完全一致的行为。两种选择都必须满足 §1.6 的"必须还原的类型集合"，差异只在 int。

### 决定 6：schema 扩展（新 kind、新元数据类型、posting 元数据）怎么处理？

**推荐：`FORMAT` 主版本 +1 + fail-closed，明确不做前向兼容。** 未知 kind / 未知 metadata tag / 未知 FLAGS 位 → 整个快照拒绝并回退 NDJSON。不试"跳过未知继续读"——那会产生少条目的模型，是不可见错误来源，违反"显式失败"。posting 元数据若将来要加，属于**语义变更**（会让 `canonicalSourceKey` 的唯一性假设失效），必须单独设计，不能塞进格式版本升级。

### 决定 7：第二阶段验收口径

**推荐：以真机数据决定，设计阶段不承诺"亚秒"。** 可先定：字节比 ≤ 0.35（合成账本实测 0.147）；二进制导入 ≤ NDJSON 的 1/3；注册后 `HeapAlloc` 不高于今天；真机 10k/50k/100k 四档、Release 包、与第一阶段同样的配对 20 轮。若"冷启首屏亚秒"做不到，**只报告差距，不放宽任何上限、不跳过校验**。

### 决定 8：mmap 与格式内压缩是否现在做？

**推荐：都不在本阶段。** `FLAGS` 位与段目录已让两者将来可以增量加入（新位、旧解码器拒绝）。现在引入 mmap 会改变内存统计口径与 jetsam 行为，需要独立真机验证；压缩会与"少解析"的目标冲突。都留到第二阶段完成、真机数字出来之后再评估。

## 附录 A：尺寸推导脚本

§2.5 的所有数字都由下面这段脚本产出，可独立复算（只用标准库）。它的两个输入分别是：合成账本的形状（`scripts/large_ledger_bench.py:127-262` 的 `generate()`）与 §2.1–2.4 的逐字段宽度。**它不读任何账本数据，也不写入仓库。**

```python
import json

def enc(o):  # 一条流记录的字节数，含行尾 \n
    return len(json.dumps(o, ensure_ascii=False, separators=(",", ":")).encode()) + 1

def entry(kind_meta, payee, narration, tags, links):
    return enc({"type": "entry", "entry": {"Kind": "transaction", "Date": "2006-01-01",
        "File": "transactions/2006-01.bean", "Line": 5, "Metadata": kind_meta,
        "Flag": "*", "Payee": payee, "Narration": narration, "Tags": tags, "Links": links}})

META = {"id": "tx-000000", "source": "synthetic"}
R = {}
R["entry_cny"]      = entry(META, "老王生鲜", "买菜",    ["monthly"], [])
R["entry_salary"]   = entry(META, "雇主",     "月度工资", ["work"],    ["batch-2006-01"])
R["entry_buy"]      = entry(META, "券商",     "买入 HOOL", ["work"],   [])
R["entry_sell"]     = entry(META, "券商",     "卖出 HOOL", ["work"],   [])
R["entry_fx"]       = entry(META, "换汇",     "美元结汇", ["travel"],  [])
R["entry_travelUS"] = entry(META, "外卖平台", "境外消费", ["travel"],  [])
R["entry_travelHK"] = entry(META, "港澳商户", "港币消费", ["travel"],  [])
print("entry_cny NDJSON bytes:", R["entry_cny"])

def P(acct, num, cur, price=None, cost=None):
    p = {"account": acct, "Quantity": {"Number": num, "Currency": cur}}
    if cost:
        p["Cost"] = {"Number": cost[0], "Currency": cost[1]}
        p["CostDate"] = "2006-01-01"
    if price:
        p["Price"] = {"Number": price[0], "Currency": price[1]}
    return enc({"type": "posting", "posting": p})
R["p_plain"]       = P("Expenses:Food:Groceries", "350.00", "CNY")
R["p_simple"]      = P("Assets:Bank:Checking", "-350.00", "CNY")
R["p_usd"]         = P("Expenses:Travel:US", "87.42", "USD")
R["p_fx_price"]    = P("Assets:Bank:USD", "-500", "USD", price=("7.12", "CNY"))
R["p_fx_cny"]      = P("Assets:Bank:Checking", "3560.00", "CNY")
R["p_stock_cost"]  = P("Assets:Broker:Stock", "20", "HOOL", cost=("18.42", "USD"))
R["p_stock_cash"]  = P("Assets:Broker:Cash", "-368.40", "USD")
R["p_stock_price"] = P("Assets:Broker:Cash", "412.00", "USD", price=("20.60", "USD"))
R["p_gain"]        = P("Income:Invest:Gains", "-43.60", "USD")
R["end"]           = enc({"type": "end_entry"})
print("p_plain NDJSON bytes:", R["p_plain"], " end_entry:", R["end"])

# generate() 的 roll 阈值给出的混合比例
MIX = [("entry_salary", 0.045, ["p_simple", "p_plain"]),
       ("entry_buy", 0.060, ["p_stock_cost", "p_stock_cash"]),
       ("entry_sell", 0.060, ["p_stock_cost", "p_stock_price", "p_gain"]),
       ("entry_fx", 0.055, ["p_fx_price", "p_fx_cny"]),
       ("entry_travelUS", 0.070, ["p_usd", "p_plain"]),
       ("entry_travelHK", 0.040, ["p_plain", "p_plain"]),
       ("entry_cny", 0.670, ["p_plain", "p_simple"])]
t = sum(m[1] for m in MIX)
MIX = [(a, b / t, c) for a, b, c in MIX]
ndjson = sum(s * (R[e] + sum(R[p] for p in ps) + R["end"]) for e, s, ps in MIX)

# B2 / B1 的逐字段宽度（见 2.1-2.4）
def varint(n):
    b = 1
    while n >= 128:
        n >>= 7; b += 1
    return b

def posting_b2(cost=False, cost_date=False, price=False):
    b = 2 + 1 + varint(333333) + 1 + 1     # acct id, sign/scale, unscaled, currency id, flags
    if cost:
        b += 1 + varint(333333) + 1 + (2 if cost_date else 0) + 1
    if price:
        b += 1 + varint(333333) + 1
    return b
PW = {"p_plain": posting_b2(), "p_simple": posting_b2(), "p_usd": posting_b2(),
      "p_fx_price": posting_b2(price=True), "p_fx_cny": posting_b2(),
      "p_stock_cost": posting_b2(cost=True, cost_date=True), "p_stock_cash": posting_b2(),
      "p_stock_price": posting_b2(price=True), "p_gain": posting_b2()}
PN = {"entry_cny": ("老王生鲜", "买菜"), "entry_salary": ("雇主", "月度工资"),
      "entry_buy": ("券商", "买入 HOOL"), "entry_sell": ("券商", "卖出 HOOL"),
      "entry_fx": ("换汇", "美元结汇"), "entry_travelUS": ("外卖平台", "境外消费"),
      "entry_travelHK": ("港澳商户", "港币消费")}
def entry_b2(payee, narration, posts):
    return (1 + 2 + 1 + 2 + 2 + 1                    # kind, flags, day delta, file id, line, bitmap
            + 1 + len(payee.encode()) + 1 + len(narration.encode())
            + 1 + 1 + 1 + 1                          # tag count/id, link count/id
            + 1 + (1 + 1 + 9) * 2                     # metadata count, 2 pairs
            + 1 + posts)                              # posting count + postings
b2 = sum(s * entry_b2(*PN[e], sum(PW[p] for p in ps)) for e, s, ps in MIX)

# B1：条目记录 + 独立 posting 记录（各带 u32 长度与定位）+ end 记录
b1 = sum(s * (entry_b2(*PN[e], 0) + 4 + len(ps) * (4 + 2 + 11 + 5) + 4) for e, s, ps in MIX)

CATALOG = 6710   # 240 个文件 + 18 个账户 + 5 个币种 + 2 个 metadata key + 5 个 tag
print("per txn: ndjson=%.1f b2=%.1f b1=%.1f" % (ndjson, b2, b1))
for N in (10_000, 100_000, 200_000):
    print("N=%7d  ndjson=%6.1f MiB  b2=%5.2f MiB  b1=%5.2f MiB"
          % (N, (N*ndjson+CATALOG)/2**20, (N*b2+CATALOG)/2**20, (N*b1+CATALOG)/2**20))
```

输出（100k）：`ndjson=49.2 MiB / b2=7.2 MiB / b1=10.6 MiB`；每笔交易：`ndjson=515.4 B / b2=75.6 B / b1=110.9 B`。

**这套估算的已知不确定项**（写清楚，避免把它当成实测）：

1. 合成账本的 payee/narration 只有 2–4 个汉字，真实账本更长；§2.5 的敏感性表给出了 15%–32% 的区间。
2. 真实账本的账户数、文件数、跨币种数可能显著更多，字符串表会变大（但仍与条目数无关）。
3. `CostDate` 在批量买入时每条 posting 都有，合成账本里只有约 6% 的条目带成本批次；持仓批次多的真实账本 B2 会略大。
4. 账本里若存在 `query`/`event`/`custom`/`document` 指令，它们比交易记录小得多，会**降低**平均每笔字节。
5. 以上都是**宿主**推导，不是真机实测；真机数字采到后应替换本附录的输入。

## 附录 B：实现结果（2026-10-25）

本设计已实现并合入 `main`：

| 项 | 结果 |
| --- | --- |
| 快照编解码 | 100k：54,187,615 B → 8,399,037 B（**15.5%，约 6.5×**）；解码 880 ms → **105 ms（8.4×）** |
| 写回与 estimate | 注册后写快照并删除对应 `.records`；estimate 改为按**条目数**（2,304 B/条目，实测 2,069–2,151），避免快照变小后 LRU 预算虚高 |
| beancount pickle 缓存 | 100k 冷启动 20–27 s → **1.5–2.4 s** |
| 磁盘淘汰 | `canonical-stream` 保留 3 份、`loader-cache` 保留 2 份、合计上限 160 MB；最新快照永不删除 |

实现中与设计不同的两处：

1. **快照目录与 pickle 缓存目录都必须落在账本根**，不能放在 `generations/<id>/` 下：工作区在每次事务开始时会删除 generation 的 `runtime/`，放在那里的缓存写完账本就失效。账本标识符本身也是 UUID，因此不能靠名字判断层级，只能按"是否位于 `generations` 布局中"结构性判断。
2. **列表元数据在快照里必须解码成 `[]any` 而不是 `[]MetadataValue`**，无 metadata 的条目必须保留**空 map 而非 nil**。读路径按具体类型断言，用错会静默改变行为；差分测试是唯一能兜住这类退化手段。

仍未做（按本设计原定的推迟项）：`unsafe.String` 零拷贝、mmap、格式内压缩。
