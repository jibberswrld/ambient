use ambient_platform::screen_capture::capture_all_displays;
use std::{fs, path::PathBuf};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let directory = std::env::args_os()
        .nth(1)
        .map(PathBuf::from)
        .ok_or("Usage: cargo run -p ambient-platform --example capture -- <output-directory>")?;
    fs::create_dir_all(&directory)?;
    for display in capture_all_displays(750_000)? {
        let path = directory.join(format!("display-{}.jpg", display.display_index));
        fs::write(&path, &display.jpeg_data)?;
        println!(
            "display_index={} is_primary={} image_pixel_width={} image_pixel_height={} display_x={} display_y={} display_pixel_width={} display_pixel_height={} scale_factor={} jpeg_bytes={} file={}",
            display.display_index, display.is_primary, display.image_pixel_width,
            display.image_pixel_height, display.display_x, display.display_y,
            display.display_pixel_width, display.display_pixel_height, display.scale_factor,
            display.jpeg_data.len(), path.display(),
        );
    }
    Ok(())
}
