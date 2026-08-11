@tool
extends RefCounted


## 在小写化文本里找「无 RD / no RD 情况下 CPU 替代（fallback）路径成功」的表述。
## 消费者：core_demo_contract_fixture 的契约扫描（拒绝「无 RenderingDevice 也算通过」的假绿）。
## ⚠ 中文锚点曾因编码损坏成 GBK 乱码（"鏃?rd" 等）而永远匹配不到，2026-08-10 修复。
static func mentions_no_rd_cpu_success(lower_text: String) -> bool:
	var anchors := ["renderingdevice", "no rd", "without rd", "无 rd", "无 renderingdevice", "无rd"]
	var success_terms := ["pass", "passes", "success", "succeed", "通过", "成功"]
	for anchor in anchors:
		var search_from := 0
		while search_from < lower_text.length():
			var index := lower_text.find(anchor, search_from)
			if index < 0:
				break
			var start := maxi(index - 96, 0)
			var length := mini(192, lower_text.length() - start)
			var window := lower_text.substr(start, length)
			if window.find("cpu") >= 0 and (window.find("fallback") >= 0 or window.find("替代") >= 0 or window.find("回退") >= 0):
				for success in success_terms:
					if window.find(success) >= 0:
						return true
			search_from = index + anchor.length()
	return false
