# `obs-fb-setup` (macOS only) — configure an OBS "Facebook" profile with the IDEAL
# screencast-to-Facebook-Live settings, and inject the stream key FROM THE LOGIN KEYCHAIN
# at run time (`FB_PERSISTENT_STREAM_KEY`, set via `secret set`). The key is NEVER in git
# or the Nix store — read live from the Keychain (same pattern as the context7/cloudflared
# passwordCommand wrappers) and written into OBS's own service.json (OBS stores keys in
# plaintext there regardless; that file is local, not committed). Re-run any time the key
# rotates or the profile is reset.
#
# Ideal screencast settings written (researched for text/UI clarity on Apple Silicon):
#   - 1920x1080 BASE = 1920x1080 OUTPUT (NO downscale — the #1 factor for crisp text)
#   - 30 fps (not 60: at a fixed bitrate, 30fps doubles per-frame quality for near-static
#     screen content; use 60 only for motion-heavy demos)
#   - Apple VT H264 HARDWARE encoder (apple_h264) — near-x264 quality at 6000 kbps but
#     ~1/4-core CPU, so it won't fight a demo app running on the same Mac; CBR (macOS 13+)
#   - 6000 kbps video (Facebook Live tops out at 1080p30 / 3000-6000 kbps), H.264 High
#   - 2 s keyframe — applied from the Facebook Live service recommendation (Simple output,
#     IgnoreRecommended=false); H.264 only (FB Live RTMP does NOT accept HEVC)
#   - Audio AAC-LC, 48 kHz stereo, 128 kbps (FB spec)
# Sources/rationale: Meta Live requirements + Twitch guidelines + OBS Apple-Silicon
# encoder threads (see the brag-doc research notes / PR description).
#
#   obs-fb-setup            # or: nix run .#obs-fb-setup
#   → QUIT OBS first (it rewrites profile files on exit), run this, then launch OBS:
#     Profile ▸ "Facebook", verify Settings ▸ Output shows "Apple VT H264 Hardware
#     Encoder" + 6000, Settings ▸ Video shows 1920x1080 @ 30, then Start Streaming.
{
  writeShellApplication,
  jq,
  coreutils,
  gnused,
}:
writeShellApplication {
  name = "obs-fb-setup";
  runtimeInputs = [
    jq
    coreutils
    gnused
  ];
  text = ''
    prog=obs-fb-setup
    secret_name="FB_PERSISTENT_STREAM_KEY"
    profile="Facebook"
    server="rtmps://rtmp-api.facebook.com:443/rtmp/"
    obs_dir="$HOME/Library/Application Support/obs-studio"
    prof_dir="$obs_dir/basic/profiles/$profile"

    die() { echo "$prog: error: $*" >&2; exit 1; }

    [ -d "$obs_dir" ] || die "OBS config dir not found — launch OBS once first ($obs_dir)"

    # Read the persistent stream key live from the login Keychain (never in git/store).
    key="$(/usr/bin/security find-generic-password -a "$(id -un)" -s "$secret_name" -w 2>/dev/null || true)"
    [ -n "$key" ] || die "$secret_name is not in the Keychain — set it with: secret set $secret_name"

    # OBS rewrites profile files when it exits — refuse/warn so this write is not clobbered.
    if pgrep -x OBS >/dev/null 2>&1; then
      echo "$prog: WARNING: OBS is running. Quit it FIRST (it overwrites profile files on exit), then re-run — otherwise these settings will be lost." >&2
    fi

    mkdir -p "$prof_dir"

    # Full ideal-screencast profile (see header). Written whole so it is deterministic;
    # OBS fills any unspecified keys with defaults on launch.
    umask 077
    # Pipe the heredoc through sed → strip any leading indentation (INI lines are flush-left;
    # values sit after '='). Portable across BSD/GNU sed (no -i). $HOME/$profile expand here.
    sed 's/^[[:space:]]*//' > "$prof_dir/basic.ini" <<EOF
    [General]
    Name=$profile

    [Output]
    Mode=Simple
    Reconnect=true
    RetryDelay=2
    MaxRetries=25
    DelayEnable=false

    [SimpleOutput]
    FilePath=$HOME/Movies
    RecFormat2=hybrid_mov
    VBitrate=6000
    ABitrate=128
    UseAdvanced=false
    StreamEncoder=apple_h264
    RecEncoder=apple_h264
    StreamAudioEncoder=aac
    RecAudioEncoder=aac
    RecQuality=Stream

    [Stream1]
    IgnoreRecommended=false
    EnableMultitrackVideo=false

    [Video]
    BaseCX=1920
    BaseCY=1080
    OutputCX=1920
    OutputCY=1080
    FPSType=0
    FPSCommon=30
    FPSInt=30
    FPSNum=30
    FPSDen=1
    ScaleType=lanczos
    ColorFormat=NV12
    ColorSpace=709
    ColorRange=Partial

    [Audio]
    SampleRate=48000
    ChannelSetup=Stereo
    EOF

    # service.json — Facebook Live via rtmp_common. Key passed to jq via $ENV (not argv),
    # never echoed. mode 600 (umask above).
    FB_KEY="$key" jq -n --arg server "$server" '
      { type: "rtmp_common",
        settings: { service: "Facebook Live", server: $server, key: $ENV.FB_KEY, protocol: "RTMPS" } }
    ' > "$prof_dir/service.json" || die "failed to write $prof_dir/service.json"

    echo "$prog: configured OBS profile \"$profile\" — 1080p30, Apple VT H264, CBR 6000, Facebook Live (key from Keychain)."
    echo "$prog: launch OBS ▸ Profile \"$profile\"; verify Output=Apple VT H264 @6000 and Video=1920x1080@30, then Start Streaming."
  '';
}
