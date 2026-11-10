"""Print the words of one audio file. The language is detected from the audio."""
import os
import sys

from faster_whisper import WhisperModel

MODEL = os.environ.get("FRAIM_WHISPER_MODEL", "/opt/fraim/whisper/model")


def main(path):
    model = WhisperModel(MODEL, device="cpu", compute_type="int8", cpu_threads=os.cpu_count() or 1)
    segments, _ = model.transcribe(path, vad_filter=True)
    print(" ".join(segment.text.strip() for segment in segments))


if __name__ == "__main__":
    main(sys.argv[1])
