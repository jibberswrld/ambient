use rodio::{buffer::SamplesBuffer, Decoder, OutputStream, Sink, Source};
use std::{
    io::Cursor,
    sync::{mpsc, Arc, Mutex},
    thread,
    time::Duration,
};

pub struct AudioPlayback;

pub struct PlayingClip {
    state: Arc<Mutex<PlaybackState>>,
    stop_sender: mpsc::Sender<()>,
    thread: Option<thread::JoinHandle<()>>,
}

#[derive(Default)]
struct PlaybackState {
    is_playing: bool,
    position_seconds: f64,
    duration_seconds: f64,
}

impl AudioPlayback {
    pub fn play(bytes: Vec<u8>) -> Result<PlayingClip, String> {
        let state = Arc::new(Mutex::new(PlaybackState::default()));
        let playback_state = state.clone();
        let (stop_sender, stop_receiver) = mpsc::channel();
        let (ready_sender, ready_receiver) = mpsc::sync_channel(1);
        let thread = thread::Builder::new()
            .name("ambient-playback".into())
            .spawn(move || {
                let result = (|| {
                    let source = decode_clip(bytes)?;
                    let duration_seconds =
                        source.total_duration().unwrap_or_default().as_secs_f64();
                    let (stream, stream_handle) =
                        OutputStream::try_default().map_err(|error| error.to_string())?;
                    let sink = Sink::try_new(&stream_handle).map_err(|error| error.to_string())?;
                    sink.append(source);
                    *playback_state.lock().unwrap() = PlaybackState {
                        is_playing: true,
                        position_seconds: 0.0,
                        duration_seconds,
                    };
                    Ok::<_, String>((stream, sink))
                })();
                let (_stream, sink) = match result {
                    Ok(playback) => playback,
                    Err(error) => {
                        let _ = ready_sender.send(Err(error));
                        return;
                    }
                };
                if ready_sender.send(Ok(())).is_err() {
                    return;
                }
                loop {
                    let should_stop = !matches!(
                        stop_receiver.recv_timeout(Duration::from_millis(10)),
                        Err(mpsc::RecvTimeoutError::Timeout)
                    );
                    let has_finished = sink.empty();
                    let mut state = playback_state.lock().unwrap();
                    state.position_seconds = if has_finished {
                        state.duration_seconds
                    } else {
                        sink.get_pos().as_secs_f64().min(state.duration_seconds)
                    };
                    state.is_playing = !should_stop && !has_finished;
                    if should_stop || has_finished {
                        sink.stop();
                        break;
                    }
                }
            })
            .map_err(|error| error.to_string())?;
        match ready_receiver.recv() {
            Ok(Ok(())) => Ok(PlayingClip {
                state,
                stop_sender,
                thread: Some(thread),
            }),
            result => {
                let _ = thread.join();
                Err(match result {
                    Ok(Err(error)) => format!("The spoken reply could not start playing. {error}"),
                    _ => "The spoken reply could not start playing.".into(),
                })
            }
        }
    }
}

impl PlayingClip {
    pub fn is_playing(&self) -> bool {
        self.state.lock().unwrap().is_playing
    }

    pub fn position_seconds(&self) -> f64 {
        self.state.lock().unwrap().position_seconds
    }

    pub fn duration_seconds(&self) -> f64 {
        self.state.lock().unwrap().duration_seconds
    }

    pub fn stop(&mut self) {
        if let Some(thread) = self.thread.take() {
            let _ = self.stop_sender.send(());
            let _ = thread.join();
        }
    }
}

impl Drop for PlayingClip {
    fn drop(&mut self) {
        self.stop();
    }
}

fn decode_clip(bytes: Vec<u8>) -> Result<SamplesBuffer<i16>, String> {
    let decoder = Decoder::new(Cursor::new(bytes)).map_err(|error| error.to_string())?;
    let channels = decoder.channels();
    let sample_rate = decoder.sample_rate();
    // Decode once so duration and word-reveal progress remain correct even for
    // variable-bit-rate MP3s whose headers do not report a duration.
    let samples: Vec<i16> = decoder.collect();
    if samples.is_empty() {
        return Err("The audio clip is empty.".into());
    }
    Ok(SamplesBuffer::new(channels, sample_rate, samples))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn one_second_wav() -> Vec<u8> {
        let mut wav = Vec::new();
        wav.extend_from_slice(b"RIFF");
        wav.extend_from_slice(&32_036_u32.to_le_bytes());
        wav.extend_from_slice(b"WAVEfmt ");
        wav.extend_from_slice(&16_u32.to_le_bytes());
        wav.extend_from_slice(&1_u16.to_le_bytes());
        wav.extend_from_slice(&1_u16.to_le_bytes());
        wav.extend_from_slice(&16_000_u32.to_le_bytes());
        wav.extend_from_slice(&32_000_u32.to_le_bytes());
        wav.extend_from_slice(&2_u16.to_le_bytes());
        wav.extend_from_slice(&16_u16.to_le_bytes());
        wav.extend_from_slice(b"data");
        wav.extend_from_slice(&32_000_u32.to_le_bytes());
        wav.resize(32_044, 0);
        wav
    }

    #[test]
    fn publik_wav_decodes_with_exact_duration_without_a_device() {
        let source = decode_clip(one_second_wav()).unwrap();
        assert_eq!(source.channels(), 1);
        assert_eq!(source.sample_rate(), 16_000);
        assert_eq!(source.total_duration(), Some(Duration::from_secs(1)));
        assert_eq!(source.count(), 16_000);
    }

    #[test]
    fn mp3_decodes_without_requiring_an_output_device() {
        // A 0.1-second mono silent clip, encoded at 16 kHz with LAME.
        let bytes = vec![
            255, 243, 24, 196, 0, 0, 0, 3, 72, 0, 0, 0, 0, 76, 65, 77, 69, 51, 46, 49, 48, 48, 85,
            85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 255, 243, 24, 196, 23, 0, 0, 3, 72,
            0, 0, 0, 0, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85,
            85, 85, 85, 85, 255, 243, 24, 196, 46, 0, 0, 3, 72, 0, 0, 0, 0, 85, 85, 85, 85, 85, 85,
            85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 255, 243, 24, 196,
            69, 0, 0, 3, 72, 0, 0, 0, 0, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85,
            85, 85, 85, 85, 85, 85, 85, 85, 85, 255, 243, 24, 196, 92, 0, 0, 3, 72, 0, 0, 0, 0, 85,
            85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85,
        ];
        let source = decode_clip(bytes).unwrap();
        assert_eq!(source.channels(), 1);
        assert_eq!(source.sample_rate(), 16_000);
        assert!(source.total_duration().unwrap().as_secs_f64() >= 0.1);
        assert!(source.count() >= 1_600);
    }

    #[test]
    fn invalid_and_empty_clips_fail_before_opening_an_output_device() {
        assert!(AudioPlayback::play(vec![]).is_err());
        assert!(AudioPlayback::play(b"not audio".to_vec()).is_err());
        let mut empty_wav = one_second_wav();
        empty_wav.truncate(44);
        empty_wav[4..8].copy_from_slice(&36_u32.to_le_bytes());
        empty_wav[40..44].copy_from_slice(&0_u32.to_le_bytes());
        assert!(AudioPlayback::play(empty_wav).is_err());
    }
}
