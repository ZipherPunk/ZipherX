#!/usr/bin/env python3
"""
Generate animated GIF for ZipherX with Matrix rain effect
"""

import subprocess
import random
import os

# Configuration
WIDTH = 800
HEIGHT = 400
FRAMES = 30
OUTPUT_DIR = "/Users/chris/ZipherX/docs/frames"
OUTPUT_GIF = "/Users/chris/ZipherX/docs/ZipherX_animated.gif"

# Matrix characters
MATRIX_CHARS = "アイウエオカキクケコサシスセソタチツテトナニヌネノハヒフヘホマミムメモヤユヨラリルレロワヲン0123456789ZIPHERX"

# Colors
BG_COLOR = "#0a0a0a"
MATRIX_GREEN = "#00ff41"
BRIGHT_GREEN = "#39ff14"
DIM_GREEN = "#003b00"

def generate_matrix_rain(frame_num, num_columns=40):
    """Generate matrix rain positions for a frame"""
    random.seed(42)  # Consistent seed for column positions
    columns = []
    for i in range(num_columns):
        x = 20 + (i * (WIDTH - 40) // num_columns)
        # Each column has its own phase
        random.seed(42 + i)
        base_y = random.randint(-HEIGHT, 0)
        speed = random.randint(8, 20)
        y = (base_y + frame_num * speed) % (HEIGHT + 200) - 100
        length = random.randint(5, 15)
        columns.append((x, y, length))
    return columns

def create_frame(frame_num):
    """Create a single frame using ImageMagick"""

    # Start building the ImageMagick command
    cmd = [
        "convert",
        "-size", f"{WIDTH}x{HEIGHT}",
        f"xc:{BG_COLOR}",
    ]

    # Add matrix rain
    rain = generate_matrix_rain(frame_num)
    for col_x, col_y, length in rain:
        random.seed(col_x + frame_num)  # Vary characters per frame
        for i in range(length):
            char_y = col_y + i * 15
            if 0 <= char_y < HEIGHT:
                char = random.choice(MATRIX_CHARS)
                # Brighter at the head, dimmer at tail
                if i == 0:
                    color = BRIGHT_GREEN
                    opacity = 100
                elif i < 3:
                    color = MATRIX_GREEN
                    opacity = 80
                else:
                    color = DIM_GREEN
                    opacity = max(20, 80 - i * 8)

                cmd.extend([
                    "-fill", color,
                    "-font", "Monaco",
                    "-pointsize", "12",
                    "-draw", f"text {col_x},{int(char_y)} '{char}'"
                ])

    # Add dark overlay gradient from center
    cmd.extend([
        "(", "-size", f"{WIDTH}x{HEIGHT}",
        "-radial-gradient:", "black-none",
        ")",
        "-compose", "multiply", "-composite"
    ])

    # Add ZipherX logo text with glitch effect
    glitch_offset = random.randint(-2, 2) if frame_num % 5 == 0 else 0

    # Shadow/glow
    cmd.extend([
        "-font", "Helvetica-Bold",
        "-pointsize", "72",
        "-fill", "#003300",
        "-draw", f"text {WIDTH//2 - 180 + 3},{HEIGHT//2 + 3} 'ZipherX'"
    ])

    # Main text
    cmd.extend([
        "-fill", MATRIX_GREEN,
        "-draw", f"text {WIDTH//2 - 180 + glitch_offset},{HEIGHT//2} 'ZipherX'"
    ])

    # Glitch red channel offset on some frames
    if frame_num % 7 == 0:
        cmd.extend([
            "-fill", "#ff000044",
            "-draw", f"text {WIDTH//2 - 180 + 3},{HEIGHT//2} 'ZipherX'"
        ])

    # Tagline
    cmd.extend([
        "-pointsize", "18",
        "-fill", "#00aa33",
        "-draw", f"text {WIDTH//2 - 140},{HEIGHT//2 + 40} 'SHIELDED BY DEFAULT'"
    ])

    # Subtitle with typing effect
    subtitle = "Privacy is not a feature, it's a right."
    visible_chars = min(len(subtitle), (frame_num * 2) % (len(subtitle) + 20))
    if visible_chars > 0:
        display_text = subtitle[:visible_chars]
        cmd.extend([
            "-pointsize", "14",
            "-fill", "#006600",
            "-draw", f"text {WIDTH//2 - 160},{HEIGHT//2 + 70} '{display_text}'"
        ])

    # Add scanlines effect
    cmd.extend([
        "(", "-size", f"{WIDTH}x2",
        "xc:#00000033",
        "-size", f"{WIDTH}x2",
        "xc:#00000000",
        "-append",
        ")",
        "-write", "mpr:scanline", "+delete",
        "mpr:scanline", "-tile:", f"-size", f"{WIDTH}x{HEIGHT}",
        "tile:mpr:scanline",
        "-compose", "multiply", "-composite"
    ])

    # Add vignette
    cmd.extend([
        "-vignette", "0x50"
    ])

    # Output
    output_path = f"{OUTPUT_DIR}/frame_{frame_num:03d}.png"
    cmd.append(output_path)

    return cmd, output_path

def main():
    # Ensure output directory exists
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    print(f"Generating {FRAMES} frames...")
    frame_files = []

    for i in range(FRAMES):
        cmd, output_path = create_frame(i)
        try:
            # Simplified command - ImageMagick can be tricky
            simple_cmd = [
                "convert",
                "-size", f"{WIDTH}x{HEIGHT}",
                f"xc:{BG_COLOR}",
            ]

            # Add matrix rain (simplified)
            rain = generate_matrix_rain(i, num_columns=30)
            for col_x, col_y, length in rain:
                random.seed(col_x + i)
                for j in range(min(length, 8)):
                    char_y = col_y + j * 15
                    if 10 <= char_y < HEIGHT - 10:
                        char = random.choice("01アイウZIPHERX")
                        if j == 0:
                            color = BRIGHT_GREEN
                        elif j < 2:
                            color = MATRIX_GREEN
                        else:
                            color = "#004400"
                        simple_cmd.extend([
                            "-fill", color,
                            "-pointsize", "11",
                            "-draw", f"text {col_x},{int(char_y)} '{char}'"
                        ])

            # Glitch effect on some frames
            glitch = random.randint(-3, 3) if i % 4 == 0 else 0

            # Logo glow
            simple_cmd.extend([
                "-font", "Helvetica-Bold",
                "-pointsize", "80",
                "-fill", "#002200",
                "-draw", f"text {WIDTH//2 - 195 + 4},{HEIGHT//2 + 15 + 4} 'ZipherX'"
            ])

            # Logo main
            simple_cmd.extend([
                "-fill", MATRIX_GREEN,
                "-draw", f"text {WIDTH//2 - 195 + glitch},{HEIGHT//2 + 15} 'ZipherX'"
            ])

            # Red glitch channel
            if i % 6 == 0:
                simple_cmd.extend([
                    "-fill", "#ff002233",
                    "-draw", f"text {WIDTH//2 - 192},{HEIGHT//2 + 15} 'ZipherX'"
                ])

            # Tagline
            simple_cmd.extend([
                "-pointsize", "20",
                "-fill", "#00bb44",
                "-draw", f"text {WIDTH//2 - 155},{HEIGHT//2 + 55} 'SHIELDED BY DEFAULT'"
            ])

            # Bottom text
            simple_cmd.extend([
                "-pointsize", "12",
                "-fill", "#005500",
                "-draw", f"text {WIDTH//2 - 115},{HEIGHT - 30} 'zipherpunk.com'"
            ])

            simple_cmd.append(output_path)

            subprocess.run(simple_cmd, check=True, capture_output=True)
            frame_files.append(output_path)
            print(f"  Frame {i+1}/{FRAMES} created")
        except subprocess.CalledProcessError as e:
            print(f"  Frame {i} failed: {e.stderr.decode() if e.stderr else e}")
            continue

    if not frame_files:
        print("No frames generated!")
        return

    # Combine frames into GIF
    print(f"\nCombining {len(frame_files)} frames into GIF...")
    gif_cmd = [
        "convert",
        "-delay", "8",  # ~12 fps
        "-loop", "0",   # infinite loop
    ]
    gif_cmd.extend(frame_files)
    gif_cmd.extend([
        "-layers", "Optimize",
        OUTPUT_GIF
    ])

    try:
        subprocess.run(gif_cmd, check=True)
        print(f"\n✅ GIF created: {OUTPUT_GIF}")

        # Get file size
        size = os.path.getsize(OUTPUT_GIF)
        print(f"   Size: {size / 1024:.1f} KB")
    except subprocess.CalledProcessError as e:
        print(f"GIF creation failed: {e}")

    # Cleanup frames
    print("\nCleaning up frames...")
    for f in frame_files:
        try:
            os.remove(f)
        except:
            pass
    try:
        os.rmdir(OUTPUT_DIR)
    except:
        pass

if __name__ == "__main__":
    main()
