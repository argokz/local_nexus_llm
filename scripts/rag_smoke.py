"""Ingest sample docs and ask a RAG question via LiteLLM + pgvector."""
import json
import os
import sys
import time
import urllib.error
import urllib.request

import psycopg

BASE = os.environ.get("LITELLM_URL", "http://litellm:4000/v1").rstrip("/")
KEY = os.environ["LITELLM_MASTER_KEY"]
DSN = os.environ["DATABASE_URL"]
CHAT_MODEL = os.environ.get("CHAT_MODEL", "qwen-chat")
EMBED_MODEL = os.environ.get("EMBED_MODEL", "qwen-embed")

DOCS = [
    "localNexus is a local AI sandbox: LiteLLM proxy in front of llama.cpp, embeddings, and Postgres pgvector.",
    "Clients call a single OpenAI-compatible endpoint at port 4000. Virtual API keys are created in the LiteLLM admin UI.",
    "This sandbox runs on CPU. Whisper and HuggingFace TEI are optional compose profiles for later hardware.",
]


def api(path, payload, timeout=180):
    req = urllib.request.Request(
        BASE + path,
        data=json.dumps(payload).encode(),
        headers={
            "Authorization": f"Bearer {KEY}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode())


def wait_ready():
    url = BASE.replace("/v1", "") + "/health/liveliness"
    for i in range(60):
        try:
            urllib.request.urlopen(url, timeout=5)
            return
        except Exception:
            time.sleep(3)
    raise SystemExit("LiteLLM did not become ready")


def vec_literal(values):
    return "[" + ",".join(f"{x:.8f}" for x in values) + "]"


def main():
    wait_ready()
    print("embedding + ingest ...")
    with psycopg.connect(DSN) as conn:
        conn.execute("TRUNCATE chunks")
        for text in DOCS:
            data = api("/embeddings", {"model": EMBED_MODEL, "input": text}, timeout=60)
            emb = data["data"][0]["embedding"]
            print(f"  dim={len(emb)} text={text[:48]!r}")
            conn.execute(
                "INSERT INTO chunks (content, embedding, metadata) VALUES (%s, %s::vector, %s::jsonb)",
                (text, vec_literal(emb), json.dumps({"source": "smoke"})),
            )
        conn.commit()

        q = "What is localNexus and which port do clients use?"
        qemb = api("/embeddings", {"model": EMBED_MODEL, "input": q}, timeout=60)["data"][0]["embedding"]
        rows = conn.execute(
            """
            SELECT content, 1 - (embedding <=> %s::vector) AS score
            FROM chunks
            ORDER BY embedding <=> %s::vector
            LIMIT 3
            """,
            (vec_literal(qemb), vec_literal(qemb)),
        ).fetchall()

    print("retrieved:")
    for content, score in rows:
        print(f"  {score:.3f} {content}")

    context = "\n".join(f"- {c}" for c, _ in rows)
    chat = api(
        "/chat/completions",
        {
            "model": CHAT_MODEL,
            "temperature": 0.2,
            "max_tokens": 120,
            "messages": [
                {
                    "role": "system",
                    "content": "Answer only from the context. If it is missing, say you do not know.",
                },
                {
                    "role": "user",
                    "content": f"Context:\n{context}\n\nQuestion: {q}",
                },
            ],
        },
        timeout=180,
    )
    answer = chat["choices"][0]["message"]["content"]
    print("answer:")
    print(answer)
    lowered = (answer or "").lower()
    if "4000" not in lowered and "litellm" not in lowered and "localnexus" not in lowered:
        print("WARN: answer did not mention expected context tokens", file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    try:
        main()
    except urllib.error.HTTPError as exc:
        print(exc.read().decode(), file=sys.stderr)
        raise
