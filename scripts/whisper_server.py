#!/usr/bin/env python3
"""OpenAI-compatible /v1/audio/transcriptions for host faster-whisper (no Docker)."""
from __future__ import annotations

import os
import tempfile
from pathlib import Path
from typing import Optional

from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import JSONResponse, PlainTextResponse
from faster_whisper import WhisperModel

MODEL_NAME = os.environ.get("WHISPER_MODEL", "medium")
DEVICE = os.environ.get("WHISPER_DEVICE", "cpu")
COMPUTE = os.environ.get("WHISPER_COMPUTE_TYPE", "int8")
DOWNLOAD_ROOT = os.environ.get("WHISPER_DOWNLOAD_ROOT") or None
CPU_THREADS = int(os.environ.get("WHISPER_CPU_THREADS", "2"))

app = FastAPI()
_model: Optional[WhisperModel] = None


@app.on_event("startup")
def _load() -> None:
    global _model
    kwargs = {
        "device": DEVICE,
        "compute_type": COMPUTE,
        "cpu_threads": CPU_THREADS,
    }
    if DOWNLOAD_ROOT:
        os.makedirs(DOWNLOAD_ROOT, exist_ok=True)
        kwargs["download_root"] = DOWNLOAD_ROOT
    _model = WhisperModel(MODEL_NAME, **kwargs)


@app.get("/health")
def health() -> dict:
    return {
        "status": "ok" if _model is not None else "loading",
        "model": MODEL_NAME,
        "device": DEVICE,
        "compute_type": COMPUTE,
    }


@app.post("/v1/audio/transcriptions")
async def transcribe(
    file: UploadFile = File(...),
    model: str = Form("whisper-1"),
    language: Optional[str] = Form(None),
    response_format: str = Form("json"),
) -> object:
    del model  # LiteLLM alias; the loaded CTranslate2 model is fixed at startup.
    if _model is None:
        raise HTTPException(status_code=503, detail="whisper model not loaded")
    suffix = Path(file.filename or "audio.wav").suffix or ".wav"
    data = await file.read()
    if not data:
        raise HTTPException(status_code=400, detail="empty audio file")
    with tempfile.NamedTemporaryFile(suffix=suffix, delete=False) as tmp:
        tmp.write(data)
        path = tmp.name
    try:
        lang = language or None
        segments, info = _model.transcribe(path, language=lang)
        parts = []
        segs = []
        for seg in segments:
            parts.append(seg.text)
            segs.append(
                {
                    "id": seg.id,
                    "start": seg.start,
                    "end": seg.end,
                    "text": seg.text,
                }
            )
        text = "".join(parts).strip()
    finally:
        os.unlink(path)

    if response_format == "text":
        return PlainTextResponse(text)
    if response_format == "verbose_json":
        return JSONResponse(
            {
                "task": "transcribe",
                "language": getattr(info, "language", language),
                "duration": getattr(info, "duration", None),
                "text": text,
                "segments": segs,
            }
        )
    return JSONResponse({"text": text})
