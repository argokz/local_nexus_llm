# localNexus sandbox (this PC)

Песочница перед нормальным железом. Клиенты ходят **только в LiteLLM** (`:4000`) — кроме Linux native-режима ниже, где можно стучаться прямо в llama-server. Движки за прокси с LAN не торчат.

```
Клиент / OpenAI SDK / Admin UI
        │
        ▼
 LiteLLM :4000  ──► llama.cpp  qwen-chat   (GGUF, CPU; CUDA если есть GPU)
        │       ──► llama.cpp  qwen-embed  (слот TEI на этой CPU)
        │       ──► faster-whisper         (host :8000 / Compose --profile stt)
        └──────► Postgres + pgvector       (ключи LiteLLM + чанки RAG)
```

Два профиля железа:

| Профиль | CPU | Модель chat (алиас всё равно `qwen-chat`) |
|---|---|---|
| **sandbox** (Windows i7-2600) | только AVX, нет AVX2 | Qwen3-4B Q4_K_M |
| **host** (Linux AVX2 / AVX-512 / AMX, ≥14 GB RAM) | `GGML_NATIVE` | Qwen3.5-9B Q5_K_M |

На i7-2600 нет AVX2. Ollama и готовый TEI CPU-образ часто падают с `Illegal instruction`. Поэтому эмбеддинги в первом прогоне — тот же llama.cpp, алиас в LiteLLM всё равно `qwen-embed`. TEI включается профилем, когда CPU умеет AVX2.

## Linux (этот хост)

Рабочая копия: **`~/projects/localNexus`** (на Windows — `H:\projects\localNexus`).

Этот Cloud Agent **без GPU**: нет `nvidia-smi`, нет `/dev/nvidia*`, нет `/dev/dri`. `LLAMA_NGL=0`, chat/embed/whisper идут на CPU (AVX-512/AMX).

На 16 GB RAM Docker с 9B внутри не влезает. Полный контур **без Docker**:

`llama-server` на хосте → **LiteLLM :4000** → Postgres/pgvector → faster-whisper `:8000`.

```bash
mkdir -p ~/projects
# если репозиторий ещё не здесь:
#   git clone <url> ~/projects/localNexus
cd ~/projects/localNexus
chmod +x scripts/*.sh
./scripts/start-stack.sh        # detect + llama + postgres + whisper + LiteLLM
./scripts/smoke-test.sh         # /v1/models, chat, embeddings, RAG, whisper
./scripts/create-key.sh dev-ivan
```

Стоп движков: `./scripts/start-stack.sh stop` (Postgres остаётся).

Клиенты ходят **только** в LiteLLM:

```python
from openai import OpenAI
client = OpenAI(base_url="http://127.0.0.1:4000/v1", api_key="sk-КЛЮЧ")
client.chat.completions.create(model="qwen-chat", messages=[{"role": "user", "content": "ping"}])
client.embeddings.create(model="qwen-embed", input="hello")
```

Админка: http://127.0.0.1:4000/ui — пользователь `admin`, пароль = `LITELLM_MASTER_KEY`.

Прямой llama-server (`:8001` / `:8003`) и whisper (`:8000`) — только localhost, для отладки. Если нужен Compose целиком: `LLAMA_CPU_VARIANT=native` и `docker compose up --build -d`. На 16 GB не поднимайте Docker-`stt` вместе с 9B внутри контейнера.

## 0. Docker Desktop

Settings → Resources:

- RAM **22–24 GB** (сейчас у Docker ~16 GB — мало)
- диск образов на **H:**
- swap 4–8 GB

Без этого Windows уйдёт в своп, пока llama.cpp соберётся и загрузит 4B.

## 1. Старт

В PowerShell из `H:\projects\localNexus`:

```powershell
.\scripts\download-models.ps1
docker compose up --build -d
docker compose logs -f llm
```

Первая сборка `llama.cpp` на 4 ядрах — **10–20 минут**. Веса копируются с `./models` во внутренний Docker-том (`gguf`) — так mmap не идёт через медленный 9p Windows. Загрузка 4B в RAM после копии — ещё 1–3 минуты. Первый старт LiteLLM ещё **2–4 минуты** гоняет Prisma-миграции (это как раз админка и виртуальные ключи).

Если нет таблицы `chunks`: `docker compose up dbschema`.

```powershell
.\scripts\smoke-test.ps1
```

Короткий chat на этой машине может уложиться в несколько секунд; длинный RAG-ответ — десятки секунд. Таймаут клиента ставьте не меньше 180 с.

Админка: http://127.0.0.1:4000/ui  

- пользователь: `admin`  
- пароль: значение `LITELLM_MASTER_KEY` из `.env` (по умолчанию `sk-localnexus-admin`)

## 2. Админка: ключи и лимиты

Master key (`sk-localnexus-admin`) — **только для админа**. Его не раздают клиентам.

В UI:

1. **Virtual Keys → + Create New Key**
2. alias, например `dev-ivan`
3. models: `qwen-chat`, `qwen-embed` (не выдавайте `whisper-1`, пока нет профиля `stt`)
4. RPM / max budget — для песочницы хватит RPM 4 и budget 10
5. скопировать ключ `sk-...` — он показывается один раз

То же скриптом:

```powershell
.\scripts\create-key.ps1 dev-ivan
```

Проверка ключа:

```powershell
curl.exe http://127.0.0.1:4000/v1/chat/completions `
  -H "Authorization: Bearer sk-КЛЮЧ" `
  -H "Content-Type: application/json" `
  -d "{`"model`":`"qwen-chat`",`"messages`":[{`"role`":`"user`",`"content`":`"ping`"}]}"
```

OpenAI SDK / LangChain:

```python
from openai import OpenAI
client = OpenAI(base_url="http://127.0.0.1:4000/v1", api_key="sk-КЛЮЧ")
client.chat.completions.create(model="qwen-chat", messages=[{"role": "user", "content": "ping"}])
client.embeddings.create(model="qwen-embed", input="hello")
```

Модели, которые видит клиент: `qwen-chat`, `qwen-embed`, `whisper-1`. Имена бэкендов меняются только в `litellm/config.yaml`.

## 3. Сеть: доступ к API с других машин

Compose уже публикует LiteLLM на **все интерфейсы**, порт `4000`. Postgres только на `127.0.0.1:5432`. Порты llama.cpp/TEI наружу не проброшены — так и должно быть.

1. Узнать IPv4 ПК (`ipconfig`) или:

```powershell
.\scripts\open-firewall.ps1   # один раз, от администратора: inbound TCP 4000
```

2. С другой машины в LAN:

- API: `http://<IP-этого-ПК>:4000/v1`
- UI:  `http://<IP-этого-ПК>:4000/ui`
- в SDK тот же `api_key`, что выдан в админке

3. Если с ноутбука не открывается:

- ПК и клиент в одной подсети
- правило файрвола на 4000 есть
- Docker Desktop не в режиме, где порты только localhost (обычный Docker Desktop на Windows публикует 0.0.0.0)
- не публикуйте `.env` и master key в LAN

Потом, на нормальном сервере: тот же порт за reverse proxy (Caddy/Nginx) с TLS, LiteLLM не светить в интернет как HTTP.

## 4. Профили «как в прод-схеме»

TEI (если образ не упадёт с SIGILL):

```powershell
docker compose --profile tei up -d tei
# в .env: EMBED_API_BASE=http://tei:80/v1
docker compose up -d litellm
```

Whisper (Linux host, **без Docker**):

```bash
./scripts/start-whisper.sh          # medium int8 на CPU, если после 9B свободно ≥2.2 GB
```

Почему medium сразу не поднялся: native `start-stack.sh` раньше не запускал STT. В Compose это отдельный `--profile stt`, и там стоит **small**, не medium. На этой машине нет CUDA, а Qwen3.5-9B Q5 уже занимает ~9 GB RSS при 16 GB без swap — medium (~1.5 GB int8) ставится отдельно и только если хватает `MemAvailable`. `large-v3` на этом CPU не включайте.

Windows Compose:

```powershell
docker compose --profile stt up -d whisper
```

Потом в UI можно выдать ключу модель `whisper-1`.

GPU позже: в `.env` `LLAMA_NGL=99`, пересборка llama.cpp с CUDA, faster-whisper `device=cuda`. Клиенты и ключи не меняются.

## 5. Что смотреть, если не встаёт

| Симптом | Что делать |
|---|---|
| `Illegal instruction` | ожидаемо для Ollama/TEI на i7-2600; LLM собирается своим Dockerfile |
| LiteLLM вечно `created` | `docker compose logs llm` — модель ещё грузится |
| OOM / диск C: забит | образы на H:, RAM Docker 22–24 GB, не включайте `stt`+`tei` сразу |
| chat 180s timeout | нормально медленно; увеличьте timeout клиента, не размер модели |
| UI просит пароль | это `LITELLM_MASTER_KEY`, не пароль Postgres |

Остановить: `docker compose down` (тома с Postgres и ключами сохранятся). Снести ключи и чанки: `docker compose down -v`.
