#!/bin/bash

AV1_CRF=30
AV1_PRESET=5
AV1_PARAMS="keyint=10s:tune=0:enable-qm=1"

# Directory containing the files (current directory)
input_dir="$(pwd)"
# Directory to move input files after they are processed
processed_inputs_dir="$input_dir/+processed"
# Directory to keep AV1 versions
output_dir="$input_dir/+output"
# Directory to keep file that is currently being converted
temp_dir="$input_dir/+temp"

mkdir -p "$processed_inputs_dir"
mkdir -p "$output_dir"
mkdir -p "$temp_dir"

handle_sigint() {
    echo "Script interrupted. Exiting..."
    exit 1
}

trap handle_sigint SIGINT

# Enable nullglob so the loop doesn't run if a file type is missing
# Enable nocaseglob to catch .MP4, .MOV and .MKV variations
shopt -s nullglob nocaseglob

echo "Processing..."
# Loop through .mp4, .mov and .mkv files
for input_file in "$input_dir"/*.mp4 "$input_dir"/*.mov "$input_dir"/*.mkv; do
    # Skip if no files exist
    [ -e "$input_file" ] || continue

    # Get the full original name (with extension for the metadata)
    original_name=$(basename "$input_file")

    # Get the base name of the file (dynamically strip any extension)
    base_name="${original_name%.*}"

    # Define the output file name (WebM + Opus)
    output_file="$temp_dir/$base_name [AV1][opus].webm"

    # taskset restricts CPU cores. bwrap provides unprivileged, network-free isolation.
    #
    # Purification: only the first real video stream and the audio streams are
    # mapped (allowlist). Subtitles, attachments (fonts etc.), data streams,
    # chapters, and global/per-stream metadata are all dropped.
    if taskset -c 2-21 bwrap \
        --unshare-all \
        --ro-bind / / \
        --dev /dev \
        --proc /proc \
        --tmpfs /tmp \
        --bind "$temp_dir" "$temp_dir" \
        ffmpeg -y \
        -i "$input_file" \
        -map_metadata -1 \
        -map_metadata:s:v -1 \
        -map_metadata:s:a -1 \
        -map_chapters -1 \
        -map 0:V:0 -map "0:a?" \
        -sn -dn \
        -vf "scale=w=-2:h='min(1440, trunc(ih/2)*2)'" \
        -c:v libsvtav1 \
        -svtav1-params "$AV1_PARAMS" \
        -preset "$AV1_PRESET" \
        -crf "$AV1_CRF" \
        -pix_fmt yuv420p10le \
        -c:a libopus \
        -b:a 320k \
        -metadata description="Converted via ffmpeg: $original_name" \
        "$output_file"; then

        echo "Processed $input_file"

        # Move the processed input file to the +processed directory
        mv "$input_file" "$processed_inputs_dir/"
        echo "Moved $input_file to $processed_inputs_dir"

        # Move the completed WebM to the output directory
        mv "$output_file" "$output_dir/"
        echo "Moved AV1 result file to output directory"
    else
        echo "Error processing $input_file or conversion cancelled."
    fi
done

echo "All done!"
