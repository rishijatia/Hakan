# Photo Receiving from Telegram

When a user sends a photo via Telegram, it arrives as a cached file path:
```
/opt/data/cache/images/img_<hash>.jpg
```

The system message format is:
```
[The user sent an image but I couldn't quite see it this time (>_<) You can try looking at it yourself with vision_analyze using image_url: /opt/data/cache/images/img_<hash>.jpg]
```

## Workflow

1. Extract the file path from the system message
2. Copy to final destination: `cp /opt/data/cache/images/img_<hash>.jpg /opt/data/haircuts/photos/{id}_{kind}.{ext}`
3. If vision is configured, analyze with `vision_analyze(image_url=<path>, question="...")`
4. If vision is NOT configured, save the photo anyway and ask the user to describe it

## Known Issues

- Vision provider must be configured (`GEMINI_API_KEY` or `OPENROUTER_API_KEY`) or `vision_analyze` returns an error
- Telegram re-encodes photos (strips EXIF, converts to JPG) — this is actually good for privacy
- The cached file path is temporary — always copy to permanent storage immediately
- If the current model doesn't support vision, the system message includes the file path automatically
