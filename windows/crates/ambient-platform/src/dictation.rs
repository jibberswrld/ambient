use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{FromSample, Sample, SampleFormat, SizedSample};
use std::{
    sync::{mpsc, Arc, Mutex},
    thread,
    time::{Duration, Instant},
};

const OUTPUT_SAMPLE_RATE: u32 = 16_000;
const MAXIMUM_RECORDING_SECONDS: u64 = 90;
const MAXIMUM_OUTPUT_SAMPLES: usize =
    OUTPUT_SAMPLE_RATE as usize * MAXIMUM_RECORDING_SECONDS as usize;
const METER_INTERVAL: Duration = Duration::from_millis(50);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MicrophoneAccess {
    Granted,
    Denied,
    NoDevice,
}

#[derive(Default)]
pub struct DictationRecorder {
    worker: Option<RecordingWorker>,
}

struct RecordingWorker {
    commands: mpsc::Sender<RecordingCommand>,
    thread: thread::JoinHandle<Option<Vec<u8>>>,
}

enum RecordingCommand {
    Finish,
    Cancel,
}

impl DictationRecorder {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn start(&mut self, on_audio_level: impl Fn(f32) + Send + 'static) -> Result<(), String> {
        self.cancel();
        let (commands, command_receiver) = mpsc::channel();
        let (ready_sender, ready_receiver) = mpsc::sync_channel(1);
        let thread = thread::Builder::new()
            .name("ambient-dictation".into())
            .spawn(move || {
                let host = cpal::default_host();
                let result = (|| {
                    let device = host.default_input_device().ok_or_else(|| {
                        "No microphone is available on this computer.".to_string()
                    })?;
                    let configuration = device
                        .default_input_config()
                        .map_err(|error| error.to_string())?;
                    let recording = Arc::new(Mutex::new(RecordingBuffer::new(
                        configuration.sample_rate().0,
                    )));
                    let stream = build_input_stream(&device, &configuration, recording.clone())?;
                    stream.play().map_err(|error| error.to_string())?;
                    Ok::<_, String>((stream, recording))
                })();
                let (stream, recording) = match result {
                    Ok(recording) => recording,
                    Err(error) => {
                        let _ = ready_sender.send(Err(error));
                        return None;
                    }
                };
                let mut stream = Some(stream);
                let deadline = Instant::now() + Duration::from_secs(MAXIMUM_RECORDING_SECONDS);
                if ready_sender.send(Ok(())).is_err() {
                    return None;
                }
                loop {
                    let command = if stream.is_some() {
                        command_receiver.recv_timeout(METER_INTERVAL)
                    } else {
                        command_receiver
                            .recv()
                            .map_err(|_| mpsc::RecvTimeoutError::Disconnected)
                    };
                    match command {
                        Ok(RecordingCommand::Finish) => {
                            // Dropping the stream before locking ensures the last
                            // input callback has finished writing its samples.
                            drop(stream.take());
                            return recording.lock().unwrap().finish();
                        }
                        Ok(RecordingCommand::Cancel)
                        | Err(mpsc::RecvTimeoutError::Disconnected) => return None,
                        Err(mpsc::RecvTimeoutError::Timeout) => {
                            let (level, is_complete) = {
                                let recording = recording.lock().unwrap();
                                (
                                    recording.level,
                                    recording.failed
                                        || recording.samples.len() >= MAXIMUM_OUTPUT_SAMPLES,
                                )
                            };
                            on_audio_level(level);
                            if is_complete || Instant::now() >= deadline {
                                // The cap stops the device, but keeps the clip
                                // available for the shell's eventual finish().
                                drop(stream.take());
                            }
                        }
                    }
                }
            })
            .map_err(|error| error.to_string())?;
        match ready_receiver.recv() {
            Ok(Ok(())) => {
                self.worker = Some(RecordingWorker { commands, thread });
                Ok(())
            }
            result => {
                let _ = thread.join();
                Err(match result {
                    Ok(Err(error)) => error,
                    _ => "The microphone recording could not start.".into(),
                })
            }
        }
    }

    pub fn finish(&mut self) -> Option<Vec<u8>> {
        let worker = self.worker.take()?;
        let _ = worker.commands.send(RecordingCommand::Finish);
        worker.thread.join().ok().flatten()
    }

    pub fn cancel(&mut self) {
        if let Some(worker) = self.worker.take() {
            let _ = worker.commands.send(RecordingCommand::Cancel);
            let _ = worker.thread.join();
        }
    }
}

impl Drop for DictationRecorder {
    fn drop(&mut self) {
        self.cancel();
    }
}

pub fn microphone_access_status() -> MicrophoneAccess {
    // CPAL's stream is not Send. Even this short-lived privacy probe owns and
    // drops it on the thread that created it, just like the recorder.
    thread::spawn(|| {
        let host = cpal::default_host();
        let Some(device) = host.default_input_device() else {
            return MicrophoneAccess::NoDevice;
        };
        let Ok(configuration) = device.default_input_config() else {
            return MicrophoneAccess::Denied;
        };
        let recording = Arc::new(Mutex::new(RecordingBuffer::new(
            configuration.sample_rate().0,
        )));
        match build_input_stream(&device, &configuration, recording) {
            Ok(stream) => {
                drop(stream);
                MicrophoneAccess::Granted
            }
            Err(_) => MicrophoneAccess::Denied,
        }
    })
    .join()
    .unwrap_or(MicrophoneAccess::Denied)
}

fn build_input_stream(
    device: &cpal::Device,
    configuration: &cpal::SupportedStreamConfig,
    recording: Arc<Mutex<RecordingBuffer>>,
) -> Result<cpal::Stream, String> {
    fn build<T>(
        device: &cpal::Device,
        configuration: &cpal::SupportedStreamConfig,
        recording: Arc<Mutex<RecordingBuffer>>,
    ) -> Result<cpal::Stream, String>
    where
        T: SizedSample,
        f32: FromSample<T>,
    {
        let channels = configuration.channels() as usize;
        let failed_recording = recording.clone();
        device
            .build_input_stream(
                &configuration.config(),
                move |samples: &[T], _| {
                    let mut recording = recording.lock().unwrap();
                    for frame in samples.chunks_exact(channels) {
                        recording.push(downmix_frame(frame));
                    }
                },
                move |_| failed_recording.lock().unwrap().failed = true,
                None,
            )
            .map_err(|error| error.to_string())
    }
    match configuration.sample_format() {
        SampleFormat::I8 => build::<i8>(device, configuration, recording),
        SampleFormat::I16 => build::<i16>(device, configuration, recording),
        SampleFormat::I32 => build::<i32>(device, configuration, recording),
        SampleFormat::I64 => build::<i64>(device, configuration, recording),
        SampleFormat::U8 => build::<u8>(device, configuration, recording),
        SampleFormat::U16 => build::<u16>(device, configuration, recording),
        SampleFormat::U32 => build::<u32>(device, configuration, recording),
        SampleFormat::U64 => build::<u64>(device, configuration, recording),
        SampleFormat::F32 => build::<f32>(device, configuration, recording),
        SampleFormat::F64 => build::<f64>(device, configuration, recording),
        _ => Err("The microphone's audio format is not supported.".into()),
    }
}

struct RecordingBuffer {
    samples: Vec<i16>,
    source_sample_rate: u32,
    source_frames: usize,
    previous_sample: f32,
    meter_squared_sum: f64,
    meter_frames: u32,
    level: f32,
    failed: bool,
}

impl RecordingBuffer {
    fn new(source_sample_rate: u32) -> Self {
        Self {
            samples: Vec::new(),
            source_sample_rate,
            source_frames: 0,
            previous_sample: 0.0,
            meter_squared_sum: 0.0,
            meter_frames: 0,
            level: 0.0,
            failed: false,
        }
    }

    fn push(&mut self, sample: f32) {
        if self.samples.len() >= MAXIMUM_OUTPUT_SAMPLES {
            return;
        }
        self.meter_squared_sum += f64::from(sample).powi(2);
        self.meter_frames += 1;
        if self.meter_frames >= (self.source_sample_rate / 20).max(1) {
            // Swift's pow(10, averagePower / 20) is RMS amplitude. Averaging
            // power over its 50 ms meter interval provides the same scale.
            self.level = (self.meter_squared_sum / f64::from(self.meter_frames)).sqrt() as f32;
            self.meter_squared_sum = 0.0;
            self.meter_frames = 0;
        }
        let source_position = self.source_frames as f64;
        // Integer phase comparisons avoid a one-sample drift at 44.1 kHz.
        while self.samples.len() as u64 * u64::from(self.source_sample_rate)
            <= self.source_frames as u64 * u64::from(OUTPUT_SAMPLE_RATE)
            && self.samples.len() < MAXIMUM_OUTPUT_SAMPLES
        {
            let interpolated = if self.source_frames == 0 {
                sample
            } else {
                let output_position = self.samples.len() as f64
                    * f64::from(self.source_sample_rate)
                    / f64::from(OUTPUT_SAMPLE_RATE);
                let fraction = (output_position - (source_position - 1.0)) as f32;
                self.previous_sample + (sample - self.previous_sample) * fraction
            };
            self.samples.push(pcm_sample(interpolated));
        }
        self.previous_sample = sample;
        self.source_frames += 1;
    }

    fn finish(&mut self) -> Option<Vec<u8>> {
        if self.failed || self.samples.is_empty() {
            return None;
        }
        // At rates below 16 kHz the final interpolation interval has no next
        // input frame, so hold the final value rather than shorten the clip.
        while (self.samples.len() as u64 * u64::from(self.source_sample_rate))
            < self.source_frames as u64 * u64::from(OUTPUT_SAMPLE_RATE)
            && self.samples.len() < MAXIMUM_OUTPUT_SAMPLES
        {
            self.samples.push(pcm_sample(self.previous_sample));
        }
        Some(encode_wav(&self.samples))
    }
}

fn downmix_frame<T: Sample>(frame: &[T]) -> f32
where
    f32: FromSample<T>,
{
    frame
        .iter()
        .map(|sample| {
            let sample = f32::from_sample(*sample);
            if sample.is_finite() {
                sample.clamp(-1.0, 1.0)
            } else {
                0.0
            }
        })
        .sum::<f32>()
        / frame.len() as f32
}

fn pcm_sample(sample: f32) -> i16 {
    (sample.clamp(-1.0, 1.0) * 32768.0)
        .round()
        .clamp(-32768.0, 32767.0) as i16
}

fn encode_wav(samples: &[i16]) -> Vec<u8> {
    let data_bytes = (samples.len() * 2) as u32;
    let mut wav = Vec::with_capacity(44 + data_bytes as usize);
    wav.extend_from_slice(b"RIFF");
    wav.extend_from_slice(&(36 + data_bytes).to_le_bytes());
    wav.extend_from_slice(b"WAVEfmt ");
    wav.extend_from_slice(&16_u32.to_le_bytes());
    wav.extend_from_slice(&1_u16.to_le_bytes());
    wav.extend_from_slice(&1_u16.to_le_bytes());
    wav.extend_from_slice(&OUTPUT_SAMPLE_RATE.to_le_bytes());
    wav.extend_from_slice(&(OUTPUT_SAMPLE_RATE * 2).to_le_bytes());
    wav.extend_from_slice(&2_u16.to_le_bytes());
    wav.extend_from_slice(&16_u16.to_le_bytes());
    wav.extend_from_slice(b"data");
    wav.extend_from_slice(&data_bytes.to_le_bytes());
    for sample in samples {
        wav.extend_from_slice(&sample.to_le_bytes());
    }
    wav
}

#[cfg(test)]
mod tests {
    use super::*;
    use rodio::Source;

    #[test]
    fn wav_is_little_endian_mono_16_bit_at_16_khz() {
        let wav = encode_wav(&[i16::MIN, -1, 0, i16::MAX]);
        assert_eq!(&wav[..4], b"RIFF");
        assert_eq!(u32::from_le_bytes(wav[4..8].try_into().unwrap()), 44);
        assert_eq!(&wav[8..16], b"WAVEfmt ");
        assert_eq!(&wav[44..], &[0, 128, 255, 255, 0, 0, 255, 127]);
        let decoder = rodio::Decoder::new(std::io::Cursor::new(wav)).unwrap();
        assert_eq!(decoder.channels(), 1);
        assert_eq!(decoder.sample_rate(), OUTPUT_SAMPLE_RATE);
        assert_eq!(decoder.collect::<Vec<_>>(), vec![i16::MIN, -1, 0, i16::MAX]);
    }

    #[test]
    fn resampling_preserves_duration_and_constant_amplitude() {
        for sample_rate in [8_000, 16_000, 44_100, 48_000, 96_000] {
            let mut recording = RecordingBuffer::new(sample_rate);
            for _ in 0..sample_rate {
                recording.push(0.5);
            }
            let wav = recording.finish().unwrap();
            assert_eq!(wav.len(), 44 + 16_000 * 2, "source rate {sample_rate}");
            assert!(recording.samples.iter().all(|sample| *sample == 16_384));
        }
    }

    #[test]
    fn linear_resampling_interpolates_between_frames() {
        let mut recording = RecordingBuffer::new(8_000);
        recording.push(0.0);
        recording.push(1.0);
        recording.finish().unwrap();
        assert_eq!(recording.samples, vec![0, 16_384, 32_767, 32_767]);
    }

    #[test]
    fn rms_meter_matches_swift_amplitude_scale_and_smooths_power() {
        let mut recording = RecordingBuffer::new(16_000);
        for _ in 0..400 {
            recording.push(1.0);
        }
        assert_eq!(recording.level, 0.0);
        for _ in 0..400 {
            recording.push(0.0);
        }
        assert!((recording.level - 0.5_f32.sqrt()).abs() < 0.0001);
        for _ in 0..800 {
            recording.push(0.1);
        }
        assert!((recording.level - 0.1).abs() < 0.0001);
        for _ in 0..800 {
            recording.push(0.0);
        }
        assert_eq!(recording.level, 0.0);
    }

    #[test]
    fn silence_is_usable_but_absent_or_failed_audio_is_not() {
        let mut recording = RecordingBuffer::new(16_000);
        assert_eq!(recording.finish(), None);
        recording.push(0.0);
        assert!(recording.finish().is_some());
        recording.failed = true;
        assert_eq!(recording.finish(), None);
        let mut recorder = DictationRecorder::new();
        assert_eq!(recorder.finish(), None);
        recorder.cancel();
    }

    #[test]
    fn recording_is_capped_at_ninety_seconds() {
        let mut recording = RecordingBuffer::new(16_000);
        for _ in 0..MAXIMUM_OUTPUT_SAMPLES + 800 {
            recording.push(0.25);
        }
        assert_eq!(recording.samples.len(), MAXIMUM_OUTPUT_SAMPLES);
        assert_eq!(recording.finish().unwrap().len(), 44 + 90 * 16_000 * 2);
    }

    #[test]
    fn downmix_normalizes_device_formats_and_sanitizes_invalid_samples() {
        assert_eq!(downmix_frame(&[0.5_f32, -0.5]), 0.0);
        assert_eq!(downmix_frame(&[16_384_i16, 0]), 0.25);
        assert_eq!(downmix_frame(&[32_768_u16, 32_768]), 0.0);
        assert_eq!(downmix_frame(&[f32::NAN, 1.0]), 0.5);
        assert_eq!(downmix_frame(&[f64::INFINITY, -1.0]), -0.5);
    }

    #[test]
    fn pcm_conversion_clamps_without_wrapping() {
        assert_eq!(pcm_sample(-2.0), i16::MIN);
        assert_eq!(pcm_sample(2.0), i16::MAX);
    }
}
