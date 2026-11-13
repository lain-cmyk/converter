#!/bin/bash

# ------------------------------------------------------------------ settings
AV1_CRF=30
AV1_PRESET=5
AV1_PARAMS="keyint=10s:tune=0:enable-qm=1"
OPUS_BITRATE="256k"      # libopus rejects more than 256k on mono tracks
CPU_LIST="2-21"          # cores ffmpeg may use; "" disables pinning
MEM_LIMIT="12G"          # RAM cap per conversion (needs a systemd user session); "" disables
CONVERT_TIMEOUT="12h"    # time limit per file
EXTRA_RO_BINDS=()        # e.g. (/opt/ffmpeg) if ffmpeg or its libraries live outside /usr

# --------------------------------------------------------------------- paths
input_dir="$(pwd)"
processed_inputs_dir="$input_dir/+processed"
output_dir="$input_dir/+output"
failed_dir="$input_dir/+failed"
temp_dir="$input_dir/+temp"
temp_file="$temp_dir/current.webm"

# Demuxers ffmpeg may use on untrusted input (it detects the real format from
# the content, not the extension, so without this any demuxer could be reached).
ALLOWED_FORMATS="mov,mp4,matroska,webm"

die() {
    echo "Error: $*" >&2
    exit 1
}

# ------------------------------------------------------------ pre-flight checks
for tool in bwrap ffmpeg ffprobe timeout awk; do
    command -v "$tool" >/dev/null 2>&1 || die "'$tool' not found in PATH."
done
if [ -n "$CPU_LIST" ]; then
    command -v taskset >/dev/null 2>&1 || die "'taskset' not found (or set CPU_LIST=\"\")."
    # Don't pin to cores this machine doesn't have (taskset would fail on every file).
    max_cpu="${CPU_LIST##*[-,]}"
    total_cpus="$(nproc --all)"
    if [[ "$max_cpu" =~ ^[0-9]+$ ]] && [ "$max_cpu" -ge "$total_cpus" ]; then
        echo "Warning: CPU_LIST=\"$CPU_LIST\" names cores this machine lacks ($total_cpus CPUs); not pinning." >&2
        CPU_LIST=""
    fi
fi

ffmpeg_bin="$(command -v ffmpeg)"
ffprobe_bin="$(command -v ffprobe)"

encoders="$("$ffmpeg_bin" -hide_banner -encoders 2>/dev/null)"
grep -q libsvtav1 <<<"$encoders" || die "this ffmpeg has no libsvtav1 encoder."
grep -q libopus <<<"$encoders" || die "this ffmpeg has no libopus encoder."

# RAM cap via a transient systemd scope, if the user session supports it.
use_scope=0
if [ -n "$MEM_LIMIT" ]; then
    if command -v systemd-run >/dev/null 2>&1 &&
        systemd-run --user --scope --quiet -p "MemoryMax=$MEM_LIMIT" true 2>/dev/null; then
        use_scope=1
    else
        echo "Warning: cannot create a systemd user scope; running without a memory cap." >&2
    fi
fi

# ------------------------------------------------------------------- sandbox
# Base bubblewrap command. The new root is an empty tmpfs; only the system
# directories needed to run ffmpeg are mounted (read-only). Your home directory,
# the other downloads and the environment variables are NOT visible inside.
sandbox=(
    bwrap
    --unshare-all          # no network, own pid/ipc/uts/user namespaces
    --die-with-parent      # sandbox dies if this script is killed
    --new-session          # no access to the controlling terminal (TIOCSTI)
    --cap-drop ALL
    --clearenv
    --setenv PATH /usr/bin:/bin
    --setenv HOME /tmp
    --chdir /
    --dev /dev
    --proc /proc
    --tmpfs /tmp
)
for p in /bin /sbin /lib /lib32 /lib64; do
    if [ -L "$p" ]; then
        sandbox+=(--symlink "$(readlink "$p")" "$p")
    elif [ -d "$p" ]; then
        sandbox+=(--ro-bind "$p" "$p")
    fi
done
sandbox+=(
    --ro-bind /usr /usr
    --ro-bind-try /etc/ld.so.cache /etc/ld.so.cache
    --ro-bind-try /etc/alternatives /etc/alternatives
)
for p in "${EXTRA_RO_BINDS[@]}"; do
    sandbox+=(--ro-bind "$p" "$p")
done

# Encodes a tiny synthetic clip inside the sandbox, so a broken sandbox or a
# missing library is reported once, up front, instead of failing every file.
sandbox_selftest() {
    local out rc
    rm -f -- "$temp_dir/selftest.webm"
    out="$("${sandbox[@]}" --bind "$temp_dir" /out "$ffmpeg_bin" \
        -nostdin -hide_banner -loglevel error -y \
        -f lavfi -i "testsrc2=s=320x240:r=10:d=0.5" \
        -f lavfi -i "sine=d=0.5" \
        -c:v libsvtav1 -svtav1-params "$AV1_PARAMS" -preset "$AV1_PRESET" -crf "$AV1_CRF" \
        -pix_fmt yuv420p10le \
        -c:a libopus -b:a "$OPUS_BITRATE" \
        /out/selftest.webm 2>&1)"
    rc=$?
    if [ "$rc" -eq 0 ] && [ ! -s "$temp_dir/selftest.webm" ]; then
        rc=1
    fi
    rm -f -- "$temp_dir/selftest.webm"
    # Only show the encoder's chatter if something went wrong.
    if [ "$rc" -ne 0 ]; then
        echo "$out" >&2
    fi
    return "$rc"
}

# Duration (seconds) of a file, probed inside the sandbox. Prints nothing on failure.
probe_duration() {
    timeout --foreground 120 "${sandbox[@]}" --ro-bind "$1" /probe/file "$ffprobe_bin" \
        -v error -protocol_whitelist file -format_whitelist "$ALLOWED_FORMATS" \
        -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 \
        /probe/file 2>/dev/null | head -n 1
}

# ffmpeg can exit 0 on a damaged input and write a truncated file, so compare
# the durations before the original is moved away. Returns 1 only on a clear mismatch.
verify_output() {
    local in_dur out_dur
    in_dur="$(probe_duration "$1")"
    out_dur="$(probe_duration "$2")"
    if [[ "$in_dur" =~ ^[0-9]+(\.[0-9]+)?$ ]] && [[ "$out_dur" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        # tolerance: 2 seconds or 2 percent, whichever is larger
        awk -v a="$in_dur" -v b="$out_dur" \
            'BEGIN { d = a - b; if (d < 0) d = -d; t = a * 0.02; if (t < 2) t = 2; exit !(d <= t) }'
        return
    fi
    echo "  Warning: could not compare durations (input='$in_dur' output='$out_dur'); accepting ffmpeg's exit status."
    return 0
}

# Move without ever overwriting an existing file.
safe_move() {
    [ ! -e "$2" ] && [ ! -L "$2" ] && mv -- "$1" "$2"
}

# ------------------------------------------------------------------ interrupts
child_pid=""
handle_interrupt() {
    echo
    echo "Interrupted. Stopping..."
    if [ -n "$child_pid" ]; then
        kill -TERM "$child_pid" 2>/dev/null
        wait "$child_pid" 2>/dev/null
    fi
    rm -f -- "$temp_file" "$temp_dir/selftest.webm"
    exit 130
}
trap handle_interrupt INT TERM

# ------------------------------------------------------------------------ main
# nullglob: a pattern with no match expands to nothing. nocaseglob: .MP4 / .MOV / .MKV too.
shopt -s nullglob nocaseglob
files=("$input_dir"/*.mp4 "$input_dir"/*.mov "$input_dir"/*.mkv)
if [ "${#files[@]}" -eq 0 ]; then
    echo "No .mp4, .mov or .mkv files found in $input_dir"
    exit 0
fi

mkdir -p "$processed_inputs_dir" "$output_dir" "$failed_dir" "$temp_dir"

echo "Checking the sandbox..."
if ! sandbox_selftest; then
    die "the sandbox self-test failed (see messages above). Typical causes: unprivileged user
namespaces are disabled or restricted (e.g. Ubuntu 24.04 AppArmor), ffmpeg or its libraries live
outside /usr (add their directories to EXTRA_RO_BINDS), or the SVT-AV1 parameters are not
supported by your build. Nothing was converted and no files were moved."
fi

converted=0
failed=0
skipped=0

echo "Processing ${#files[@]} file(s)..."
for input_file in "${files[@]}"; do
    # Plain files only: no symlinks (which could point at files elsewhere), no directories.
    if [ -L "$input_file" ] || [ ! -f "$input_file" ]; then
        echo "Skipping (not a regular file): $input_file"
        skipped=$((skipped + 1))
        continue
    fi

    original_name="${input_file##*/}"
    base_name="${original_name%.*}"
    final_name="$base_name [AV1][opus].webm"
    final_output="$output_dir/$final_name"

    # Never overwrite anything (a.mp4 and a.mkv would otherwise map to the same output name).
    if [ -e "$final_output" ] || [ -e "$processed_inputs_dir/$original_name" ] ||
        [ -e "$failed_dir/$original_name" ]; then
        echo "Skipping $original_name: a file with that name already exists in +output, +processed"
        echo "  or +failed. Rename or move it and run the script again."
        skipped=$((skipped + 1))
        continue
    fi

    echo
    echo "Processing: $original_name"
    rm -f -- "$temp_file"

    # Inside the sandbox the input is /in/input and the output goes to /out/current.webm.
    ffmpeg_args=(
        -nostdin -hide_banner -loglevel warning -stats -y
        # input options (must come before -i)
        -protocol_whitelist file
        -format_whitelist "$ALLOWED_FORMATS"
        -i /in/input
        # drop all metadata and chapters
        -map_metadata -1
        -map_metadata:s:v -1
        -map_metadata:s:a -1
        -map_chapters -1
        # allowlist: first real video stream + audio streams only
        -map 0:V:0 -map "0:a?"
        -sn -dn
        -vf "scale=w=-2:h='min(1440, trunc(ih/2)*2)'"
        -c:v libsvtav1
        -svtav1-params "$AV1_PARAMS"
        -preset "$AV1_PRESET"
        -crf "$AV1_CRF"
        -pix_fmt yuv420p10le
        # libopus only accepts a few channel layouts (5.1(side) etc. would fail)
        -af "aformat=channel_layouts=mono|stereo|5.1|7.1"
        -c:a libopus
        -b:a "$OPUS_BITRATE"
        -metadata description="Converted via ffmpeg: $original_name"
        /out/current.webm
    )

    # -k 10: if the child ignores SIGTERM (timeout or Ctrl-C), kill it 10 seconds later.
    cmd=(timeout --foreground -k 10 "$CONVERT_TIMEOUT")
    if [ -n "$CPU_LIST" ]; then
        cmd+=(taskset -c "$CPU_LIST")
    fi
    if [ "$use_scope" -eq 1 ]; then
        cmd+=(systemd-run --user --scope --quiet -p "MemoryMax=$MEM_LIMIT")
    fi
    cmd+=("${sandbox[@]}" --ro-bind "$input_file" /in/input --bind "$temp_dir" /out
        "$ffmpeg_bin" "${ffmpeg_args[@]}")

    # Run in the background and wait, so Ctrl-C can stop the whole chain cleanly.
    "${cmd[@]}" &
    child_pid=$!
    wait "$child_pid"
    status=$?
    child_pid=""

    reason=""
    if [ "$status" -eq 124 ] || [ "$status" -eq 137 ]; then
        reason="hit the time limit ($CONVERT_TIMEOUT) or was killed (e.g. memory limit)"
    elif [ "$status" -ne 0 ]; then
        reason="ffmpeg exited with status $status"
    elif [ ! -s "$temp_file" ]; then
        reason="no output was produced"
    elif ! verify_output "$input_file" "$temp_file"; then
        reason="output duration does not match the input (truncated?)"
    fi

    if [ -z "$reason" ]; then
        if safe_move "$temp_file" "$final_output" &&
            safe_move "$input_file" "$processed_inputs_dir/$original_name"; then
            # The original stays around (untrusted); make sure it can't be executed by accident.
            chmod a-x -- "$processed_inputs_dir/$original_name" 2>/dev/null
            echo "OK: +output/$final_name"
            echo "    original moved to +processed"
            converted=$((converted + 1))
        else
            echo "Error: could not move the results for $original_name; leaving files where they are."
            failed=$((failed + 1))
        fi
    else
        echo "FAILED: $original_name - $reason"
        rm -f -- "$temp_file"
        if safe_move "$input_file" "$failed_dir/$original_name"; then
            chmod a-x -- "$failed_dir/$original_name" 2>/dev/null
            echo "    original moved to +failed"
        fi
        failed=$((failed + 1))
    fi
done

echo
echo "All done: $converted converted, $failed failed, $skipped skipped."
[ "$failed" -eq 0 ]
