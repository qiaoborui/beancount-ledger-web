---
name: 每日巡检
schedule: daily 21:00
timezone: Asia/Singapore
enabled: true
# model: 可选，覆盖默认模型
thinking: low
audit: true
---

看一下今天的巡检结果：

1. 逐条核实疑似重复和待处理的交易，真重复的起草删除，能确定分类的起草改分类。
2. 很久没对账的账户，列出来提醒我，不用改。
3. 有没被 include 的文件，起草把它加回 main.bean。

最后用三五句话告诉我结论，拿不准的列出来等我决定。
