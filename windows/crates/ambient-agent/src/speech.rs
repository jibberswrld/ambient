use crate::client::{decode_json, failure, PublikAiClient};
use ambient_contracts::{AgentFailure, AiCredentialSource};
use serde_json::json;
use std::sync::Arc;
use unicode_segmentation::UnicodeSegmentation;

pub const DEFAULT_VOICE: &str = "coral";
pub struct PublikSpeechClient {
    client: PublikAiClient,
}
impl PublikSpeechClient {
    pub const DEFAULT_VOICE: &'static str = DEFAULT_VOICE;
    pub fn new(credential_source: Arc<dyn AiCredentialSource>) -> Self {
        Self {
            client: PublikAiClient::new(credential_source),
        }
    }
    pub async fn synthesize(&self, text: &str, voice: &str) -> Result<Vec<u8>, AgentFailure> {
        if text.trim().is_empty() || text.graphemes(true).count() > 4096 {
            return Err(failure("Speech needs between 1 and 4096 characters."));
        }
        let body = json!({"model":"tts-1", "voice":voice, "input":text, "response_format":"wav"})
            .to_string()
            .into_bytes();
        let audio = self
            .client
            .post("audio/speech", body, "application/json")
            .await?;
        if !is_wav(&audio) {
            return Err(failure("publik did not return playable WAV audio."));
        }
        Ok(audio)
    }
    pub async fn transcribe(&self, wav_data: Vec<u8>) -> Result<String, AgentFailure> {
        if !is_wav(&wav_data) {
            return Err(failure("Transcription needs recorded WAV audio."));
        }
        if wav_data.len() >= PublikAiClient::MAXIMUM_REQUEST_BYTES - 1024 {
            return Err(failure(
                "This recording is too large. Record a shorter clip.",
            ));
        }
        let boundary = format!("Ambient-{}", uuid::Uuid::new_v4());
        let mut body = format!("--{boundary}\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\ngpt-4o-mini-transcribe\r\n--{boundary}\r\nContent-Disposition: form-data; name=\"response_format\"\r\n\r\njson\r\n--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"recording.wav\"\r\nContent-Type: audio/wav\r\n\r\n").into_bytes();
        body.extend(wav_data);
        body.extend(format!("\r\n--{boundary}--\r\n").as_bytes());
        let data = self
            .client
            .post(
                "audio/transcriptions",
                body,
                &format!("multipart/form-data; boundary={boundary}"),
            )
            .await?;
        decode_json(&data)?["text"]
            .as_str()
            .map(String::from)
            .ok_or_else(|| failure("publik returned no transcription text."))
    }
}
fn is_wav(data: &[u8]) -> bool {
    data.len() >= 12 && &data[..4] == b"RIFF" && &data[8..12] == b"WAVE"
}
