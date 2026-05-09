---
description: Vector-based skill retrieval using FAISS + sentence-transformers. When the agent is unsure which skill to use, or the task could match multiple skills, run the query command to find the most relevant ones. Trigger terms: find skill, which skill, 找技能, 哪个技能, skill search, tool retrieval, skill discovery, 技能检索.
---

# Skill RAG — 向量检索 Skill

用 FAISS + sentence-transformers 从所有已安装 Skill 中语义检索最相关的。

## 使用方法

### 查询最相关的 Skill

```powershell
python "$HOME\.cursor\skills\skill-rag\skill_rag.py" query "你的查询" --top-k 3
```

JSON 输出（适合程序解析）：

```powershell
python "$HOME\.cursor\skills\skill-rag\skill_rag.py" query "你的查询" --top-k 3 --json
```

### 重建索引（新增/修改 Skill 后）

```powershell
python "$HOME\.cursor\skills\skill-rag\skill_rag.py" index
```

## Agent 工作流

1. 用户提出任务
2. 如果不确定用哪个 Skill，运行 `query` 命令
3. 读取返回的 top-1 Skill 的 SKILL.md
4. 按该 Skill 的指导执行任务

## 技术细节

- 模型: `all-MiniLM-L6-v2`（80MB，CPU 推理 <1s）
- 索引: FAISS IndexFlatIP（内积，归一化后等价余弦相似度）
- 向量维度: 384
- 索引内容: Skill 的 name + description + body preview（前 500 字符）
