# Prototype vocal Realtime

WebSocket `/v1/realtime` compatible avec un sous-ensemble des événements OpenAI Realtime : audio PCM16 mono 24 kHz, transcription Whisper, texte Qwen en flux, phrases Qwen3-TTS et annulation de réponse. L'interface `/voice` écoute en continu et interrompt la lecture dès que l'utilisateur reparle. Le découpage et la détection de parole se font dans le navigateur ; le TTS produit un WAV par phrase, donc le flux audio ne commence pas avant la fin de la première phrase synthétisée.

## Construction et démarrage hors k3s

```bash
podman build -t voice-pipeline:local -f Containerfile .
podman run -d --replace --name voice-pipeline --restart=always \
  --network host \
  -e WHISPER_URL=http://<adresse-whisper>:8080/v1 \
  -e LLM_URL=http://<adresse-llama>:8080/v1 \
  -e TTS_URL=http://127.0.0.1:8080/v1 \
  -e LLM_MODEL=qwen35b-a3b -e TTS_VOICE=Ryan \
  voice-pipeline:local
curl http://127.0.0.1:8082/health
```

Les adresses Whisper et Qwen doivent être accessibles depuis l'hôte. Des IP de pod conviennent au test, mais changent au redémarrage des pods. Le Service GitOps `voice-pipeline` expose ce conteneur à LiteLLM sur `100.64.0.4:8082`. L'alias LiteLLM `local-voice` cible son WebSocket via `litellm_params.api_base`. L'interface est ensuite disponible sur `https://llm-api.home.dohrm.fr/voice`.

La clé LiteLLM doit autoriser le modèle `local-voice`. Le navigateur la transmet dans le sous-protocole WebSocket, sans l'inscrire dans le dépôt ou le stockage du navigateur. L'interface n'implémente que les événements Realtime nécessaires à cette chaîne, et n'offre pas le protocole WebRTC ni les appels d'outils.
