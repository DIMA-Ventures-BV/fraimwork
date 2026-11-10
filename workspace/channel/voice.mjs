// Voice messages: Claude cannot listen to audio, so it reads a transcript instead.

export async function withTranscript(event, transcribe) {
  if (!event.voice) return event
  const caption = event.text ? `${event.text}\n` : ''
  const audio = `Audio: ${event.voice}`
  let words
  try {
    words = (await transcribe(event.voice)).trim()
  } catch {
    return { ...event, text: `${caption}(A voice message that could not be transcribed. Ask the sender to type it. ${audio})` }
  }
  if (!words) return { ...event, text: `${caption}(A voice message with no speech in it. ${audio})` }
  return { ...event, text: `(Voice message, transcribed automatically, so some words can be wrong. Handle it as what the sender said. ${audio})\n${caption}${words}` }
}

// A video: Claude opens a few frames as images and reads what was said.
export async function withVideo(event, transcribe, frames) {
  if (!event.video) return event
  const caption = event.text ? `${event.text}\n` : ''
  let pictures = []
  let words = ''
  try { pictures = await frames(event.video) } catch {}
  try { words = (await transcribe(event.video)).trim() } catch {}
  const seen = pictures.length ? `Frames to open with Read: ${pictures.join(', ')}.` : 'Its frames could not be read.'
  const heard = words ? `Spoken words, transcribed automatically: ${words}` : 'It has no spoken words that could be read.'
  return { ...event, text: `${caption}(A video. File: ${event.video}. ${seen} ${heard})` }
}

// Runs jobs one at a time, in the order they came, so a long voice message keeps its place.
export function inOrder(onError) {
  let last = Promise.resolve()
  return (job) => {
    last = last.then(job).catch(onError)
    return last
  }
}
