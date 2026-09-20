# localNexus sandbox (this PC)

Песочница перед нормальным железом. Клиенты ходят **только в LiteLLM** (`:4000`). Движки за прокси с LAN не торчат.

```
Клиент / OpenAI SDK / Admin UI
        │
        ▼
 LiteLLM :4000  ──► llama.cpp  qwen-chat   (GGUF Q4, CPU)
        │       ──► llama.cpp  qwen-embed  (слот TEI на этой CPU)
        │       ──► faster-whisper         (профиль stt, не в первом up)
        └──────► Postgres + pgvector       (ключи LiteLLM + чанки RAG)
```

На i7-2600 нет AVX2. Ollama и готовый TEI CPU-образ часто падают с `Illegal instruction`. Поэтому эмбеддинги в первом прогоне — тот же llama.cpp, алиас в LiteLLM всё равно `qwen-embed`. TEI включается профилем, когда CPU умеет AVX2.

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

Whisper:

```powershell
docker compose --profile stt up -d whisper
```

Потом в UI можно выдать ключу модель `whisper-1`. На этом CPU `large-v3` не включайте — только `small`.

GPU позже: в `.env` `LLAMA_NGL=99`, пересборка llama.cpp с CUDA, TEI-образ `cuda-*`. Клиенты и ключи не меняются.

## 5. Что смотреть, если не встаёт

| Симптом | Что делать |
|---|---|
| `Illegal instruction` | ожидаемо для Ollama/TEI на i7-2600; LLM собирается своим Dockerfile |
| LiteLLM вечно `created` | `docker compose logs llm` — модель ещё грузится |
| OOM / диск C: забит | образы на H:, RAM Docker 22–24 GB, не включайте `stt`+`tei` сразу |
| chat 180s timeout | нормально медленно; увеличьте timeout клиента, не размер модели |
| UI просит пароль | это `LITELLM_MASTER_KEY`, не пароль Postgres |

Остановить: `docker compose down` (тома с Postgres и ключами сохранятся). Снести ключи и чанки: `docker compose down -v`.
