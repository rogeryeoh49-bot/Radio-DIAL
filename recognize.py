import asyncio
import json
import sys

import truststore


async def main():
    truststore.inject_into_ssl()
    from shazamio import Shazam

    try:
        async with asyncio.timeout(35):
            response = await Shazam().recognize(sys.argv[1])
    except TimeoutError:
        print(json.dumps({"error": "The song identification service timed out."}))
        return
    except (OSError, RuntimeError):
        print(json.dumps({"error": "The song identification service is unavailable."}))
        return
    track = response.get("track") or {}
    if track.get("title"):
        images = track.get("images") or {}
        print(json.dumps({
            "title": track["title"],
            "artist": track.get("subtitle") or "",
            "artwork": images.get("coverarthq") or images.get("coverart"),
            "originalArtwork": images.get("coverart"),
        }))


if __name__ == "__main__":
    asyncio.run(main())
