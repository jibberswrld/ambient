use image::{codecs::jpeg::JpegEncoder, imageops::FilterType, DynamicImage, RgbaImage};
use serde::Serialize;
use xcap::Monitor;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CapturedDisplay {
    pub display_index: usize,
    pub is_primary: bool,
    pub jpeg_data: Vec<u8>,
    pub image_pixel_width: u32,
    pub image_pixel_height: u32,
    pub display_x: i32,
    pub display_y: i32,
    pub display_pixel_width: u32,
    pub display_pixel_height: u32,
    pub scale_factor: f32,
}

pub fn capture_all_displays(
    maximum_jpeg_bytes_per_display: usize,
) -> Result<Vec<CapturedDisplay>, String> {
    if maximum_jpeg_bytes_per_display == 0 {
        return Err("The displays exceeded the screen image budget. No images were sent.".into());
    }
    let monitors = Monitor::all().map_err(|error| error.to_string())?;
    if monitors.is_empty() {
        return Err("No display available for capture".into());
    }
    let maximum_dimension = (1280.0 / (monitors.len() as f64).sqrt()).floor().max(320.0) as u32;
    let mut monitors_with_primary = monitors
        .into_iter()
        .map(|monitor| {
            monitor
                .is_primary()
                .map(|is_primary| (monitor, is_primary))
                .map_err(|error| error.to_string())
        })
        .collect::<Result<Vec<_>, _>>()?;
    monitors_with_primary.sort_by_key(|(_, is_primary)| !is_primary);
    monitors_with_primary
        .into_iter()
        .enumerate()
        .map(|(index, (monitor, is_primary))| {
            let scale_factor = monitor.scale_factor().map_err(|error| error.to_string())?;
            let display_x = monitor.x().map_err(|error| error.to_string())?;
            let display_y = monitor.y().map_err(|error| error.to_string())?;
            let display_pixel_width = monitor.width().map_err(|error| error.to_string())?;
            let display_pixel_height = monitor.height().map_err(|error| error.to_string())?;
            // XCap uses DEVMODE on Windows, which supplies physical desktop pixels
            // regardless of DPI virtualization. Its macOS bounds are in points.
            #[cfg(target_os = "macos")]
            let (display_x, display_y, display_pixel_width, display_pixel_height) = (
                (display_x as f32 * scale_factor).round() as i32,
                (display_y as f32 * scale_factor).round() as i32,
                (display_pixel_width as f32 * scale_factor).round() as u32,
                (display_pixel_height as f32 * scale_factor).round() as u32,
            );
            let image = monitor.capture_image().map_err(|error| error.to_string())?;
            let (jpeg_data, image_pixel_width, image_pixel_height) =
                bounded_jpeg(image, maximum_dimension, maximum_jpeg_bytes_per_display)?;
            Ok(CapturedDisplay {
                display_index: index + 1,
                is_primary,
                jpeg_data,
                image_pixel_width,
                image_pixel_height,
                display_x,
                display_y,
                display_pixel_width,
                display_pixel_height,
                scale_factor,
            })
        })
        .collect()
}

fn bounded_jpeg(
    image: RgbaImage,
    maximum_dimension: u32,
    maximum_bytes: usize,
) -> Result<(Vec<u8>, u32, u32), String> {
    if image.width() == 0 || image.height() == 0 {
        return Err("Failed to capture any screen".into());
    }
    let mut image = DynamicImage::ImageRgba8(image).to_rgb8();
    let largest_dimension = image.width().max(image.height());
    if largest_dimension > maximum_dimension.max(1) {
        let ratio = maximum_dimension.max(1) as f64 / largest_dimension as f64;
        let width = (image.width() as f64 * ratio).round().max(1.0) as u32;
        let height = (image.height() as f64 * ratio).round().max(1.0) as u32;
        image = image::imageops::resize(&image, width, height, FilterType::Triangle);
    }
    loop {
        for quality in [65, 45, 30, 20] {
            let mut bytes = Vec::new();
            JpegEncoder::new_with_quality(&mut bytes, quality)
                .encode_image(&image)
                .map_err(|error| error.to_string())?;
            if bytes.len() <= maximum_bytes {
                return Ok((bytes, image.width(), image.height()));
            }
        }
        if image.width() == 1 && image.height() == 1 {
            return Err(
                "The displays exceeded the screen image budget. No images were sent.".into(),
            );
        }
        let width = (image.width() * 3 / 4).max(1);
        let height = (image.height() * 3 / 4).max(1);
        image = image::imageops::resize(&image, width, height, FilterType::Triangle);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn synthetic_image(width: u32, height: u32) -> RgbaImage {
        let mut random_state = 1_u32;
        RgbaImage::from_fn(width, height, |_, _| {
            let mut channels = [0, 0, 0, 255];
            for channel in channels.iter_mut().take(3) {
                random_state = random_state
                    .wrapping_mul(1_664_525)
                    .wrapping_add(1_013_904_223);
                *channel = (random_state >> 24) as u8;
            }
            image::Rgba(channels)
        })
    }

    #[test]
    fn jpeg_budget_reduces_quality_and_dimensions_as_needed() {
        let (jpeg, width, height) = bounded_jpeg(synthetic_image(640, 480), 1280, 4_000).unwrap();
        assert!(jpeg.len() <= 4_000);
        assert!(width < 640 && height < 480);
        let decoded = image::load_from_memory(&jpeg).unwrap();
        assert_eq!((decoded.width(), decoded.height()), (width, height));
        assert!((width as f64 / height as f64 - 4.0 / 3.0).abs() < 0.1);
    }

    #[test]
    fn initial_size_matches_swift_display_budget_without_upscaling() {
        let (_, width, height) = bounded_jpeg(synthetic_image(1600, 900), 1280, 1_500_000).unwrap();
        assert_eq!((width, height), (1280, 720));
        let (_, width, height) = bounded_jpeg(synthetic_image(200, 100), 1280, 1_500_000).unwrap();
        assert_eq!((width, height), (200, 100));
        let (_, width, height) = bounded_jpeg(synthetic_image(900, 1600), 640, 1_500_000).unwrap();
        assert_eq!((width, height), (360, 640));
    }

    #[test]
    fn impossible_budget_and_empty_images_return_errors() {
        assert!(bounded_jpeg(synthetic_image(8, 8), 1280, 1).is_err());
        assert!(bounded_jpeg(RgbaImage::new(0, 0), 1280, 1000).is_err());
        assert!(capture_all_displays(0).is_err());
    }
}
