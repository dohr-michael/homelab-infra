"""Local OpenAI Realtime subset backed by Whisper, llama.cpp and Qwen3-TTS."""

import asyncio
import base64
import binascii
import io
import json
import os
import re
import uuid
import wave
from pathlib import Path

import httpx
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse

WHISPER_URL = os.getenv('WHISPER_URL', 'http://whisper-server.ai-stack.svc.cluster.local:8080/v1').rstrip('/')
LLM_URL = os.getenv('LLM_URL', 'http://qwen35b-a3b-llm-server.ai-stack.svc.cluster.local:8080/v1').rstrip('/')
TTS_URL = os.getenv('TTS_URL', 'http://qwen3-tts.litellm.svc.cluster.local:8080/v1').rstrip('/')
LLM_MODEL = os.getenv('LLM_MODEL', 'qwen35b-a3b')
TTS_VOICE = os.getenv('TTS_VOICE', 'Ryan')
MAX_AUDIO_BYTES = 16 * 1024 * 1024
SYSTEM_PROMPT = ('Tu es un assistant vocal francophone. Réponds naturellement, brièvement, '
                 "avec des phrases courtes faciles à écouter. N'utilise ni Markdown ni listes.")
UI_FILE = Path(__file__).parent / 'ui' / 'index.html'
app = FastAPI(title='Local voice realtime')


@app.get('/health')
async def health():
    return {'status': 'ok'}


@app.get('/voice', include_in_schema=False)
@app.get('/voice/', include_in_schema=False)
async def ui():
    return FileResponse(UI_FILE)


def phrases_ready(buffer: str, final: bool = False) -> tuple[list[str], str]:
    result = []
    while buffer:
        match = re.search(r'[.!?;:](?=\s|$)', buffer)
        if match and (match.end() >= 24 or final):
            end = match.end()
        elif len(buffer) >= 170:
            end = buffer.rfind(' ', 60, 170)
            if end < 0:
                end = 170
        elif final:
            end = len(buffer)
        else:
            break
        phrase, buffer = buffer[:end].strip(), buffer[end:].lstrip()
        if phrase:
            result.append(phrase)
    return result, buffer


def pcm_wav(pcm: bytes) -> bytes:
    output = io.BytesIO()
    with wave.open(output, 'wb') as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(24000)
        wav.writeframes(pcm)
    return output.getvalue()


def wav_pcm(wav_bytes: bytes) -> bytes:
    with wave.open(io.BytesIO(wav_bytes), 'rb') as wav:
        if wav.getnchannels() != 1 or wav.getsampwidth() != 2 or wav.getframerate() != 24000:
            raise ValueError('Le TTS doit renvoyer un WAV PCM16 mono à 24 kHz')
        return wav.readframes(wav.getnframes())


class Session:
    def __init__(self, websocket: WebSocket):
        self.websocket = websocket
        self.send_lock = asyncio.Lock()
        self.generation = 0
        self.task: asyncio.Task | None = None
        self.audio = bytearray()
        self.committed: bytes | None = None
        self.item_id: str | None = None
        self.history: list[dict[str, str]] = []
        self.client = httpx.AsyncClient(timeout=httpx.Timeout(90, connect=5))
        self.response_id: str | None = None

    async def send(self, kind: str, **payload):
        async with self.send_lock:
            await self.websocket.send_json({'event_id': 'event_' + uuid.uuid4().hex, 'type': kind, **payload})

    async def error(self, message: str):
        await self.send('error', error={'type': 'invalid_request_error', 'message': message})

    async def cancel(self):
        self.generation += 1
        task = self.task
        if task and not task.done():
            task.cancel()
            await asyncio.gather(task, return_exceptions=True)
        self.task = None
        self.response_id = None

    async def transcribe(self, pcm: bytes) -> str:
        response = await self.client.post(
            f'{WHISPER_URL}/audio/transcriptions',
            files={'file': ('utterance.wav', pcm_wav(pcm), 'audio/wav')},
            data={'response_format': 'json'},
        )
        response.raise_for_status()
        return response.json()['text'].strip()

    async def speak(self, queue: asyncio.Queue, generation: int, response_id: str, output_id: str):
        spoken = []
        while True:
            phrase = await queue.get()
            if phrase is None:
                break
            result = await self.client.post(
                f'{TTS_URL}/audio/speech',
                json={'model': 'tts-1', 'voice': TTS_VOICE, 'language': 'French',
                      'input': phrase, 'response_format': 'wav'},
            )
            result.raise_for_status()
            if generation != self.generation:
                return
            pcm = wav_pcm(result.content)
            common = {'response_id': response_id, 'item_id': output_id,
                      'output_index': 0, 'content_index': 0}
            await self.send('response.output_audio_transcript.delta', delta=phrase, **common)
            # Smaller deltas let the browser begin playback before the entire WAV is sent.
            for start in range(0, len(pcm), 48000):
                if generation != self.generation:
                    return
                await self.send('response.output_audio.delta',
                                delta=base64.b64encode(pcm[start:start + 48000]).decode('ascii'), **common)
            spoken.append(phrase)
        if spoken and generation == self.generation:
            self.history.append({'role': 'assistant', 'content': ' '.join(spoken)})
            await self.send('response.output_audio.done', response_id=response_id,
                            item_id=output_id, output_index=0, content_index=0)

    async def run(self, pcm: bytes, input_id: str, generation: int, response_id: str):
        queue: asyncio.Queue[str | None] = asyncio.Queue()
        speaker = None
        output_id = 'item_' + uuid.uuid4().hex
        try:
            transcript = await self.transcribe(pcm)
            if generation != self.generation:
                return
            await self.send('conversation.item.input_audio_transcription.completed',
                            item_id=input_id, content_index=0, transcript=transcript)
            if not transcript:
                await self.send('response.done', response={'id': response_id, 'status': 'completed', 'output': []})
                return
            self.history.append({'role': 'user', 'content': transcript})
            self.history = self.history[-12:]
            speaker = asyncio.create_task(self.speak(queue, generation, response_id, output_id))
            buffer = ''
            body = {'model': LLM_MODEL, 'messages': [{'role': 'system', 'content': SYSTEM_PROMPT}, *self.history],
                    'stream': True, 'max_tokens': 220,
                    'chat_template_kwargs': {'enable_thinking': False}}
            async with self.client.stream('POST', f'{LLM_URL}/chat/completions', json=body) as result:
                result.raise_for_status()
                async for line in result.aiter_lines():
                    if not line.startswith('data: ') or line == 'data: [DONE]':
                        continue
                    token = json.loads(line[6:]).get('choices', [{}])[0].get('delta', {}).get('content')
                    if not token:
                        continue
                    await self.send('response.output_text.delta', response_id=response_id,
                                    item_id=output_id, output_index=0, content_index=0, delta=token)
                    buffer += token
                    phrases, buffer = phrases_ready(buffer)
                    for phrase in phrases:
                        await queue.put(phrase)
            phrases, _ = phrases_ready(buffer, final=True)
            for phrase in phrases:
                await queue.put(phrase)
            await queue.put(None)
            await speaker
            if generation == self.generation:
                await self.send('response.done', response={'id': response_id, 'status': 'completed', 'output': []})
        except asyncio.CancelledError:
            if speaker:
                speaker.cancel()
                await asyncio.gather(speaker, return_exceptions=True)
            raise
        except Exception as exc:
            if speaker:
                speaker.cancel()
                await asyncio.gather(speaker, return_exceptions=True)
            if generation == self.generation:
                await self.error(f'Échec du pipeline vocal : {str(exc)[:250]}')
                await self.send('response.done', response={'id': response_id, 'status': 'failed', 'output': []})
        finally:
            if generation == self.generation and self.response_id == response_id:
                self.response_id = None


@app.websocket('/v1/realtime')
async def realtime(websocket: WebSocket):
    await websocket.accept()
    session = Session(websocket)
    await session.send('session.created', session={
        'id': 'sess_' + uuid.uuid4().hex, 'object': 'realtime.session', 'model': 'local-voice',
        'input_audio_format': 'pcm16', 'output_audio_format': 'pcm16', 'turn_detection': None,
    })
    try:
        while True:
            command = await websocket.receive_json()
            kind = command.get('type')
            if kind == 'session.update':
                await session.send('session.updated', session={
                    'model': 'local-voice', 'input_audio_format': 'pcm16',
                    'output_audio_format': 'pcm16', 'turn_detection': None,
                })
            elif kind == 'input_audio_buffer.append':
                try:
                    chunk = base64.b64decode(command.get('audio', ''), validate=True)
                except (binascii.Error, ValueError):
                    await session.error('Audio base64 invalide')
                    continue
                if len(session.audio) + len(chunk) > MAX_AUDIO_BYTES:
                    session.audio.clear()
                    await session.error('Audio trop long')
                    continue
                session.audio.extend(chunk)
            elif kind == 'input_audio_buffer.clear':
                session.audio.clear()
                session.committed = None
                await session.send('input_audio_buffer.cleared')
            elif kind == 'input_audio_buffer.commit':
                if not session.audio or len(session.audio) % 2:
                    await session.error('Buffer PCM16 vide ou invalide')
                    continue
                session.committed = bytes(session.audio)
                session.audio.clear()
                session.item_id = 'item_' + uuid.uuid4().hex
                await session.send('input_audio_buffer.committed', item_id=session.item_id)
            elif kind == 'response.create':
                if session.committed is None or session.item_id is None:
                    # Some Realtime gateways repeat response.create immediately
                    # after commit. The active response already handles this audio.
                    if session.task and not session.task.done():
                        continue
                    await session.error('Aucun audio validé')
                    continue
                await session.cancel()
                response_id = 'resp_' + uuid.uuid4().hex
                session.response_id = response_id
                await session.send('response.created', response={
                    'id': response_id, 'object': 'realtime.response', 'status': 'in_progress', 'output': []})
                session.task = asyncio.create_task(session.run(session.committed, session.item_id,
                                                                session.generation, response_id))
                session.committed = None
            elif kind == 'response.cancel':
                response_id = session.response_id
                await session.cancel()
                if response_id:
                    await session.send('response.done', response={
                        'id': response_id, 'object': 'realtime.response', 'status': 'cancelled', 'output': []})
            else:
                await session.error(f'Événement non pris en charge : {kind}')
    except WebSocketDisconnect:
        pass
    finally:
        await session.cancel()
        await session.client.aclose()
