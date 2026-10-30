# maiDL yt-dlp resolver

Turns TikTok, Instagram, YouTube/Shorts and X/Twitter links into a downloadable
media stream for maiDL. The phone asks this service to resolve a link and then
downloads the file from the service, so signed and IP-bound source URLs keep
working.

## Run

Requires Python 3.10+ and `ffmpeg` on `PATH` for sources that expose separate
video and audio streams (YouTube). Without ffmpeg, those links fail but
single-file sources still work.

```sh
python3 -m pip install -r tool/resolver/requirements.txt
python3 tool/resolver/server.py --host 0.0.0.0 --port 8080
```

Open **Settings → Social links** in maiDL, choose **yt-dlp service**, and enter
the LAN address of the machine, for example `http://192.168.1.20:8080`.

The service is unauthenticated. Run it on a trusted network or put it behind an
authenticated reverse proxy. `X-Forwarded-Proto` is honoured for HTTPS proxies.

For sources that need cookies, set a Netscape-format cookie file on the machine
running the service:

```sh
MAIDL_YTDLP_COOKIES=/path/to/cookies.txt python3 tool/resolver/server.py
```

## Behavior

- `POST /resolve` with `{"url": "..."}` returns
  `{"url": "http://<host>/media/<token>", "fileName": "..."}`.
- `GET /media/<token>` streams the source, forwarding `Range` so interrupted
  downloads can resume.
- The service proxies a single-file progressive format when available. When a
  source exposes separate video/audio streams (YouTube), it pipes
  `ffmpeg -c copy` as a fragmented MP4 so playback can start immediately.
  Fragmented output has no resumable byte ranges; an interrupted download
  restarts.
- YouTube chooses H.264 MP4 video plus AAC audio when available. Other codecs
  may not be accepted by Photos.
- Tokens expire after 30 minutes. Private/login-gated sources need cookies;
  DRM and live streams are not supported.
