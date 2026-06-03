#!/usr/bin/env python3
"""Small local Responses API adapter for Codex -> DeepSeek Chat Completions.

Codex custom providers speak the OpenAI Responses API. DeepSeek exposes an
OpenAI-compatible Chat Completions API, so this proxy translates the small
subset Codex needs for text and function-call based tool use.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any
from urllib import error, request


DEFAULT_MODEL = "deepseek-v4-pro"
DEEPSEEK_URL = "https://api.deepseek.com/chat/completions"
DUMMY_PROXY_TOKENS = {"", "codex-local-proxy", "Bearer codex-local-proxy"}


def _now() -> int:
	return int(time.time())


def _id(prefix: str) -> str:
	return f"{prefix}_{uuid.uuid4().hex}"


def _json_bytes(value: Any) -> bytes:
	return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def _text_from_content(content: Any) -> str:
	if content is None:
		return ""
	if isinstance(content, str):
		return content
	if isinstance(content, list):
		parts: list[str] = []
		for part in content:
			if isinstance(part, str):
				parts.append(part)
			elif isinstance(part, dict):
				if "text" in part:
					parts.append(str(part.get("text") or ""))
				elif part.get("type") in {"input_text", "output_text"}:
					parts.append(str(part.get("text") or ""))
				elif part.get("type") == "input_image":
					parts.append("[image input omitted by local DeepSeek proxy]")
		return "\n".join(p for p in parts if p)
	return str(content)


def _append_message(messages: list[dict[str, Any]], role: str, content: Any) -> None:
	text = _text_from_content(content)
	if not text:
		return
	if role == "developer":
		role = "system"
	if role not in {"system", "user", "assistant", "tool"}:
		role = "user"
	messages.append({"role": role, "content": text})


def responses_input_to_chat_messages(payload: dict[str, Any]) -> list[dict[str, Any]]:
	messages: list[dict[str, Any]] = []

	instructions = payload.get("instructions")
	if instructions:
		messages.append({"role": "system", "content": str(instructions)})

	input_value = payload.get("input")
	if isinstance(input_value, str):
		messages.append({"role": "user", "content": input_value})
		return messages

	if not isinstance(input_value, list):
		return messages

	for item in input_value:
		if isinstance(item, str):
			_append_message(messages, "user", item)
			continue
		if not isinstance(item, dict):
			continue

		item_type = item.get("type")
		if item_type == "message" or "role" in item:
			_append_message(messages, str(item.get("role", "user")), item.get("content"))
		elif item_type == "function_call":
			call_id = str(item.get("call_id") or item.get("id") or _id("call"))
			name = str(item.get("name") or "tool")
			arguments = item.get("arguments") or "{}"
			if not isinstance(arguments, str):
				arguments = json.dumps(arguments, ensure_ascii=False)
			messages.append(
				{
					"role": "assistant",
					"content": None,
					"tool_calls": [
						{
							"id": call_id,
							"type": "function",
							"function": {"name": name, "arguments": arguments},
						}
					],
				}
			)
		elif item_type == "function_call_output":
			call_id = str(item.get("call_id") or item.get("id") or "call_unknown")
			output = item.get("output")
			messages.append(
				{
					"role": "tool",
					"tool_call_id": call_id,
					"content": _text_from_content(output),
				}
			)

	if not messages:
		messages.append({"role": "user", "content": ""})
	return messages


def responses_tools_to_chat_tools(payload: dict[str, Any]) -> list[dict[str, Any]]:
	chat_tools: list[dict[str, Any]] = []
	for tool in payload.get("tools") or []:
		if not isinstance(tool, dict):
			continue
		if tool.get("type") != "function":
			continue
		name = tool.get("name")
		if not name:
			continue
		function: dict[str, Any] = {
			"name": name,
			"description": tool.get("description") or "",
			"parameters": tool.get("parameters") or {"type": "object", "properties": {}},
		}
		if "strict" in tool:
			function["strict"] = bool(tool["strict"])
		chat_tools.append({"type": "function", "function": function})
	return chat_tools


def chat_completion_payload(payload: dict[str, Any]) -> dict[str, Any]:
	model = payload.get("model") or os.environ.get("DEEPSEEK_MODEL") or DEFAULT_MODEL
	out: dict[str, Any] = {
		"model": model,
		"messages": responses_input_to_chat_messages(payload),
		"stream": False,
	}

	for key in ("temperature", "top_p", "presence_penalty", "frequency_penalty"):
		if key in payload:
			out[key] = payload[key]

	if "max_output_tokens" in payload:
		out["max_tokens"] = payload["max_output_tokens"]
	elif "max_tokens" in payload:
		out["max_tokens"] = payload["max_tokens"]

	if model == "deepseek-v4-pro" and os.environ.get("DEEPSEEK_THINKING", "enabled") != "disabled":
		effort = os.environ.get("DEEPSEEK_REASONING_EFFORT")
		reasoning = payload.get("reasoning")
		if not effort and isinstance(reasoning, dict):
			effort = reasoning.get("effort")
		if not effort:
			effort = payload.get("reasoning_effort") or "high"
		effort = {"minimal": "low", "xhigh": "high", "critical": "high"}.get(str(effort), str(effort))
		if effort not in {"low", "medium", "high"}:
			effort = "high"
		out["thinking"] = {"type": "enabled"}
		out["reasoning_effort"] = effort

	tools = responses_tools_to_chat_tools(payload)
	if tools:
		out["tools"] = tools
		if payload.get("tool_choice"):
			out["tool_choice"] = payload["tool_choice"]

	return out


def get_api_key(headers: Any) -> str:
	env_key = os.environ.get("DEEPSEEK_API_KEY", "").strip()
	if env_key:
		return env_key
	auth_header = headers.get("Authorization", "").strip()
	if auth_header in DUMMY_PROXY_TOKENS:
		return ""
	if auth_header.lower().startswith("bearer "):
		return auth_header.split(None, 1)[1].strip()
	return ""


def call_deepseek(payload: dict[str, Any], api_key: str) -> dict[str, Any]:
	if not api_key:
		raise RuntimeError("DEEPSEEK_API_KEY is not set")

	req = request.Request(
		DEEPSEEK_URL,
		data=_json_bytes(chat_completion_payload(payload)),
		headers={
			"Authorization": f"Bearer {api_key}",
			"Content-Type": "application/json",
			"Accept": "application/json",
		},
		method="POST",
	)
	try:
		with request.urlopen(req, timeout=float(os.environ.get("DEEPSEEK_TIMEOUT", "120"))) as res:
			return json.loads(res.read().decode("utf-8"))
	except error.HTTPError as exc:
		body = exc.read().decode("utf-8", errors="replace")
		raise RuntimeError(f"DeepSeek HTTP {exc.code}: {body}") from exc


def response_from_chat(chat: dict[str, Any], model: str) -> dict[str, Any]:
	resp_id = _id("resp")
	output: list[dict[str, Any]] = []
	message = ((chat.get("choices") or [{}])[0].get("message") or {})
	tool_calls = message.get("tool_calls") or []

	if tool_calls:
		for call in tool_calls:
			function = call.get("function") or {}
			output.append(
				{
					"id": _id("fc"),
					"type": "function_call",
					"status": "completed",
					"call_id": str(call.get("id") or _id("call")),
					"name": str(function.get("name") or "tool"),
					"arguments": function.get("arguments") or "{}",
				}
			)
	else:
		text = message.get("content") or ""
		output.append(
			{
				"id": _id("msg"),
				"type": "message",
				"status": "completed",
				"role": "assistant",
				"content": [{"type": "output_text", "text": text, "annotations": []}],
			}
		)

	usage = chat.get("usage") or {}
	return {
		"id": resp_id,
		"object": "response",
		"created_at": _now(),
		"status": "completed",
		"model": model,
		"output": output,
		"parallel_tool_calls": True,
		"usage": {
			"input_tokens": usage.get("prompt_tokens", 0),
			"output_tokens": usage.get("completion_tokens", 0),
			"total_tokens": usage.get("total_tokens", 0),
		},
	}


def sse_event(event_type: str, data: dict[str, Any]) -> bytes:
	data.setdefault("type", event_type)
	return f"event: {event_type}\n".encode("utf-8") + b"data: " + _json_bytes(data) + b"\n\n"


def stream_response(response_obj: dict[str, Any]) -> bytes:
	chunks = [
		sse_event(
			"response.created",
			{
				"response": {
					**response_obj,
					"status": "in_progress",
					"output": [],
				}
			},
		)
	]

	for output_index, item in enumerate(response_obj.get("output") or []):
		chunks.append(
			sse_event(
				"response.output_item.added",
				{"output_index": output_index, "item": item},
			)
		)

		if item.get("type") == "message":
			content = item.get("content") or []
			text_part = content[0] if content else {"type": "output_text", "text": "", "annotations": []}
			text = text_part.get("text") or ""
			chunks.append(
				sse_event(
					"response.content_part.added",
					{
						"item_id": item["id"],
						"output_index": output_index,
						"content_index": 0,
						"part": {"type": "output_text", "text": "", "annotations": []},
					},
				)
			)
			if text:
				chunks.append(
					sse_event(
						"response.output_text.delta",
						{
							"item_id": item["id"],
							"output_index": output_index,
							"content_index": 0,
							"delta": text,
						},
					)
				)
			chunks.append(
				sse_event(
					"response.output_text.done",
					{
						"item_id": item["id"],
						"output_index": output_index,
						"content_index": 0,
						"text": text,
					},
				)
			)
			chunks.append(
				sse_event(
					"response.content_part.done",
					{
						"item_id": item["id"],
						"output_index": output_index,
						"content_index": 0,
						"part": text_part,
					},
				)
			)
		elif item.get("type") == "function_call":
			chunks.append(
				sse_event(
					"response.function_call_arguments.done",
					{
						"item_id": item["id"],
						"output_index": output_index,
						"arguments": item.get("arguments") or "{}",
					},
				)
			)

		chunks.append(
			sse_event(
				"response.output_item.done",
				{"output_index": output_index, "item": item},
			)
		)

	chunks.append(sse_event("response.completed", {"response": response_obj}))
	chunks.append(b"data: [DONE]\n\n")
	return b"".join(chunks)


class Handler(BaseHTTPRequestHandler):
	server_version = "DeepSeekResponsesProxy/0.1"

	def log_message(self, fmt: str, *args: Any) -> None:
		sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

	def _send_json(self, status: int, body: dict[str, Any]) -> None:
		data = _json_bytes(body)
		self.send_response(status)
		self.send_header("Content-Type", "application/json; charset=utf-8")
		self.send_header("Content-Length", str(len(data)))
		self.end_headers()
		self.wfile.write(data)

	def _send_sse(self, data: bytes) -> None:
		self.send_response(200)
		self.send_header("Content-Type", "text/event-stream; charset=utf-8")
		self.send_header("Cache-Control", "no-cache")
		self.send_header("Connection", "keep-alive")
		self.end_headers()
		self.wfile.write(data)
		self.wfile.flush()

	def do_GET(self) -> None:
		if self.path.rstrip("/") in {"/v1/models", "/models"}:
			self._send_json(
				200,
				{
					"object": "list",
					"data": [
						{
							"id": DEFAULT_MODEL,
							"object": "model",
							"created": _now(),
							"owned_by": "deepseek",
						}
					],
				},
			)
			return
		if self.path.rstrip("/") in {"/health", "/v1/health"}:
			self._send_json(200, {"ok": True, "model": DEFAULT_MODEL})
			return
		self._send_json(404, {"error": {"message": f"Unknown path: {self.path}"}})

	def do_POST(self) -> None:
		if self.path.rstrip("/") not in {"/v1/responses", "/responses"}:
			self._send_json(404, {"error": {"message": f"Unknown path: {self.path}"}})
			return

		try:
			length = int(self.headers.get("Content-Length", "0"))
			payload = json.loads(self.rfile.read(length).decode("utf-8")) if length else {}
			chat = call_deepseek(payload, get_api_key(self.headers))
			response_obj = response_from_chat(chat, payload.get("model") or DEFAULT_MODEL)
			if payload.get("stream"):
				self._send_sse(stream_response(response_obj))
			else:
				self._send_json(200, response_obj)
		except Exception as exc:
			self._send_json(
				500,
				{
					"error": {
						"message": str(exc),
						"type": "deepseek_responses_proxy_error",
					}
				},
			)


def main() -> int:
	parser = argparse.ArgumentParser(description=__doc__)
	parser.add_argument("--host", default="127.0.0.1")
	parser.add_argument("--port", type=int, default=7863)
	args = parser.parse_args()

	server = ThreadingHTTPServer((args.host, args.port), Handler)
	print(f"DeepSeek Responses proxy listening on http://{args.host}:{args.port}/v1", flush=True)
	server.serve_forever()
	return 0


if __name__ == "__main__":
	raise SystemExit(main())
