#!/usr/bin/env python3
import json
import os
import re
import subprocess
import sys

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

WING = "MeshFill-Godot"
MAX_PROMPT_CHARS = 4000
MAX_QUERY_TERMS = 1
MAX_OUTPUT_CHARS = 3000
SEARCH_TIMEOUT_SEC = 2

TRIGGER_WORDS = (
    "new module",
    "new class",
    "new concept",
    "new doc",
    "architecture",
    "refactor",
    "rename",
    "create",
    "implement",
    "add",
    "module",
    "concept",
    "新模块",
    "新类",
    "新概念",
    "新文档",
    "架构",
    "重构",
    "重命名",
    "创建",
    "实现",
    "新增",
    "添加",
    "模块",
    "概念",
    "文档",
)

STOPWORDS = {
    "the",
    "and",
    "for",
    "with",
    "from",
    "this",
    "that",
    "into",
    "about",
    "please",
    "prompt",
    "help",
    "write",
    "create",
    "implement",
    "module",
    "class",
    "concept",
    "doc",
    "docs",
}


def main() -> int:
    payload = read_payload()
    prompt = extract_prompt(payload)
    if not prompt:
        return emit({})

    prompt = prompt[:MAX_PROMPT_CHARS]
    if not should_check(prompt):
        return emit({})

    queries = build_queries(prompt)
    if not queries:
        return emit({})

    sections = []
    for query in queries:
        result = search_mempalace(query)
        if result:
            sections.append(f"Query: {query}\n{result}")

    if not sections:
        return emit({})

    context = (
        "MeshFill-Godot semantic gate:\n"
        "Before creating or naming a new module, concept, architecture doc, or refactor, compare the request against these mempalace hits. "
        "Classify the change as reuse, specialize, new, rename, or merge. "
        "Only introduce a new semantic concept when responsibility, owned data, lifecycle, inputs, outputs, and source of truth are distinct. "
        "If the change is genuinely new, create or update a proposed mempalace concept before writing docs or source.\n\n"
        + "\n\n---\n\n".join(sections)
    )
    context = context[:MAX_OUTPUT_CHARS]

    return emit(
        {
            "hookSpecificOutput": {
                "hookEventName": "UserPromptSubmit",
                "additionalContext": context,
            }
        }
    )


def read_payload() -> dict:
    raw = sys.stdin.read()
    if not raw.strip():
        return {}
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return {"prompt": raw}


def extract_prompt(payload) -> str:
    if isinstance(payload, str):
        return payload
    if not isinstance(payload, dict):
        return ""

    for key in ("prompt", "userPrompt", "user_prompt", "message", "input", "text"):
        value = payload.get(key)
        text = stringify_input(value)
        if text:
            return text

    params = payload.get("params")
    if isinstance(params, dict):
        for key in ("prompt", "userPrompt", "user_prompt", "message", "input", "text"):
            text = stringify_input(params.get(key))
            if text:
                return text

    return ""


def stringify_input(value) -> str:
    if isinstance(value, str):
        return value
    if isinstance(value, list):
        parts = []
        for item in value:
            if isinstance(item, str):
                parts.append(item)
            elif isinstance(item, dict):
                text = item.get("text") or item.get("content") or item.get("value")
                if isinstance(text, str):
                    parts.append(text)
        return "\n".join(parts)
    if isinstance(value, dict):
        text = value.get("text") or value.get("content") or value.get("value")
        return text if isinstance(text, str) else ""
    return ""


def should_check(prompt: str) -> bool:
    lowered = prompt.lower()
    if any(word in lowered for word in TRIGGER_WORDS):
        return True
    if re.search(r"\b[A-Z][A-Za-z0-9]*(?:[A-Z][a-z0-9]+){1,}\b", prompt):
        return True
    return False


def build_queries(prompt: str) -> list[str]:
    queries = []

    quoted = re.findall(r"`([^`]{2,80})`", prompt)
    camel = re.findall(r"\b[A-Z][A-Za-z0-9]*(?:[A-Z][a-z0-9]+){1,}\b", prompt)
    english_terms = re.findall(r"\b[A-Za-z][A-Za-z0-9_/-]{2,}\b", prompt)

    for value in quoted + camel + english_terms:
        cleaned = clean_term(value)
        if cleaned and cleaned.lower() not in STOPWORDS:
            queries.append(cleaned)

    cn_chunks = re.findall(r"[\u4e00-\u9fffA-Za-z0-9_]{2,}", prompt)
    for value in cn_chunks:
        cleaned = clean_term(value)
        if cleaned:
            queries.append(cleaned)

    deduped = []
    seen = set()
    for query in queries:
        key = query.lower()
        if key not in seen:
            deduped.append(query)
            seen.add(key)
        if len(deduped) >= MAX_QUERY_TERMS:
            break

    if not deduped:
        words = [w for w in english_terms if w.lower() not in STOPWORDS]
        if words:
            deduped.append(" ".join(words[:4]))

    return deduped


def clean_term(value: str) -> str:
    value = value.strip(" \t\r\n.,:;()[]{}<>\"'")
    if len(value) < 2 or len(value) > 80:
        return ""
    return value


def search_mempalace(query: str) -> str:
    env = os.environ.copy()
    env["PYTHONIOENCODING"] = "utf-8"
    cmd = [
        "mempalace",
        "search",
        query,
        "--wing",
        WING,
        "--results",
        "3",
    ]
    try:
        completed = subprocess.run(
            cmd,
            text=True,
            encoding="utf-8",
            errors="replace",
            capture_output=True,
            timeout=SEARCH_TIMEOUT_SEC,
            env=env,
        )
    except (OSError, subprocess.SubprocessError):
        return ""
    if completed.returncode == 0 and has_search_result(completed.stdout):
        return trim_search_output(completed.stdout)
    return ""


def has_search_result(output: str) -> bool:
    return bool(re.search(r"^\s*\[\d+\]\s+", output, flags=re.MULTILINE))


def trim_search_output(output: str) -> str:
    lines = []
    for line in output.splitlines():
        if set(line.strip()) <= {"=", "-"}:
            continue
        if "岸" in line:
            continue
        lines.append(line.rstrip())
    text = "\n".join(lines).strip()
    return text[:1800]


def emit(data: dict) -> int:
    sys.stdout.write(json.dumps(data, ensure_ascii=False))
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
