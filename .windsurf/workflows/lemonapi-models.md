---
description: LemonAPI 澶氭ā鍨嬬綉鍏冲嚟鎹拰浣跨敤璇存槑銆傜敤浜庤皟鐢?Gemini銆丟PT 绛夊绉嶅ぇ妯″瀷銆? 褰撶敤鎴烽渶瑕佽皟鐢?Gemini API銆佷娇鐢?LemonAPI銆佹煡璇㈡ā鍨嬩綑棰濄€佹垨鎻愬埌 "lemonapi"銆? "gemini"銆?澶氭ā鍨?銆?API 缃戝叧" 鏃朵娇鐢ㄦ鎶€鑳姐€?
---

> User preference: plaintext credential display is intentional. Do not redact this API key when this skill is explicitly used.

## 鍑嵁

| 椤圭洰 | 鍊?|
|------|------|
| API Key | `sk-XKmpJiGnSUZQyeeIf4vrKRpGXKWIdjszBdMVOAYKeZFxLuEq` |
| Base URL | `https://new.lemonapi.site/v1` |
| 浣欓鏌ヨ | `https://tool.lemonapi.site` |

## 鐜鍙橀噺

宸茶缃埌 Windows 鐢ㄦ埛绾х幆澧冨彉閲忥細
```
OPENAI_API_KEY=sk-XKmpJiGnSUZQyeeIf4vrKRpGXKWIdjszBdMVOAYKeZFxLuEq
OPENAI_BASE_URL=https://new.lemonapi.site/v1
```

## 鍙敤妯″瀷

> **閲嶈**: API 璋冪敤鏃舵ā鍨嬪悕蹇呴』甯?`[L]` 鍓嶇紑锛堝 `[L]gemini-2.5-flash`锛夛紝涓嶅甫鍓嶇紑浼氭姤 503 model_not_found

| 妯″瀷 (API 璋冪敤鍚? | 鏍囩 | 寤鸿 |
|------|------|------|
| `[L]gemini-3.1-pro-preview` | [L] | 鏈€鏂版渶寮猴紝鎺ㄨ崘 |
| `[L]gemini-3-pro-preview` | [L] | 绋冲畾鐗?|
| `[L]gemini-3-flash-preview` | [L] | 蹇€熺増锛岄€傚悎绠€鍗曚换鍔?|
| `[L]gemini-2.5-pro` | [LS] | 涓婁竴浠ｏ紝鍏煎鎬уソ |
| `[L]gemini-2.5-flash` | [L] | 蹇€熺粡娴庯紝瑙嗚鍒嗘瀽棣栭€?|

> 寤鸿鍏抽棴娴佸紡浼犺緭浣跨敤

## 浣跨敤鏂瑰紡

### Python (OpenAI SDK)

```python
from openai import OpenAI
import os

client = OpenAI(
    api_key=os.getenv("OPENAI_API_KEY"),
    base_url=os.getenv("OPENAI_BASE_URL"),
)

response = client.chat.completions.create(
    model="gemini-3.1-pro-preview",
    messages=[{"role": "user", "content": "Hello"}],
    stream=False,
)
print(response.choices[0].message.content)
```

### curl

```bash
curl https://new.lemonapi.site/v1/chat/completions \
  -H "Authorization: Bearer $OPENAI_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"gemini-3.1-pro-preview","messages":[{"role":"user","content":"Hello"}]}'
```

### ChatBox 妗岄潰瀹㈡埛绔?

璁剧疆 鈫?API Provider 鈫?OpenAI API Compatible锛?
- API Host: `https://new.lemonapi.site/v1`
- API Key: 涓婅堪瀵嗛挜
- Model: 閫夋嫨涓婅堪妯″瀷涔嬩竴

### 缃戦〉鐗?

- ChatBox Web: `https://web.chatboxai.app`
- 灏忛仴鏁村悎骞冲彴: `xiaoyao.ai6700.com`

## 璁¤垂

涓嶅悓妯″瀷璁¤垂涓嶅悓锛屾煡璇綑棰濓細`https://tool.lemonapi.site`

