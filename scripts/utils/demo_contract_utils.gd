@tool
extends RefCounted

## demo 契约辅助（最小存活集）。原有的 markdown 链接提取 / 章节切分 / tscn 元数据解析等
## 函数随 demo 契约 .md 与 tools/test_*.gd 的整批删除失去全部消费者，已于 2026-08-10 清理；
## 唯一消费者是 core_demo_contract_fixture.gd（source_docs 解析 + 去重追加）。


static func source_docs_from_values(source_doc, source_docs) -> Array:
	var values := []
	append_unique(values, str(source_doc).strip_edges())
	for part in str(source_docs).split(";"):
		append_unique(values, String(part).strip_edges())
	return values


static func append_unique(values: Array, value: String) -> void:
	if value.is_empty() or values.has(value):
		return
	values.append(value)
