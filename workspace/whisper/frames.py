"""Save a few evenly spaced pictures from one video next to it and print their paths."""
import os
import sys

import av

COUNT = 4
LONGEST_SIDE = 1280


def main(path):
    base = os.path.splitext(path)[0]
    with av.open(path) as container:
        stream = container.streams.video[0]
        seconds = (container.duration or 0) / av.time_base
        count = COUNT if seconds > 0 else 1
        for index in range(count):
            container.seek(int(seconds * (index + 0.5) / count * av.time_base))
            frame = next(container.decode(stream))
            picture = frame.to_image()
            picture.thumbnail((LONGEST_SIDE, LONGEST_SIDE))
            target = f"{base}-frame{index + 1}.jpg"
            picture.save(target, quality=85)
            print(target)


if __name__ == "__main__":
    main(sys.argv[1])
