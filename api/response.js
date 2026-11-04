const MAGIC = Buffer.from('OSC-HTTP-Response: 1');
const MAX_HEADER_BYTES = 8192;
const NAME_RE = /^[A-Za-z0-9-]+$/;
const VALUE_RE = /^[\x20-\x7e]+$/;

export class FrameError extends Error {}

function startsWithFrameMarker(buf) {
  if (buf.length < MAGIC.length + 1) return false;
  if (!buf.subarray(0, MAGIC.length).equals(MAGIC)) return false;
  const next = buf[MAGIC.length];
  return next === 0x0a || (next === 0x0d && buf[MAGIC.length + 1] === 0x0a);
}

// Returns { contentType, body } or throws FrameError.
export function parseFrame(buf) {
  let pos = buf.indexOf(0x0a) + 1; // skip the marker line
  let contentType;
  for (;;) {
    const nl = buf.indexOf(0x0a, pos);
    if (nl === -1 || nl >= MAX_HEADER_BYTES) {
      throw new FrameError(
        `header block not terminated by an empty line within ${MAX_HEADER_BYTES} bytes`
      );
    }
    let end = nl;
    if (end > pos && buf[end - 1] === 0x0d) end -= 1;
    const line = buf.subarray(pos, end).toString('latin1');
    pos = nl + 1;
    if (line === '') break;
    const colon = line.indexOf(':');
    const name = colon === -1 ? '' : line.slice(0, colon);
    if (!NAME_RE.test(name)) throw new FrameError('malformed header line');
    if (name.toLowerCase() !== 'content-type') {
      throw new FrameError(
        `unsupported header ${name}, only Content-Type is supported`
      );
    }
    if (contentType !== undefined) {
      throw new FrameError('duplicate Content-Type header');
    }
    const value = line.slice(colon + 1).trim();
    if (!VALUE_RE.test(value)) throw new FrameError('invalid Content-Type value');
    contentType = value;
  }
  if (contentType === undefined) {
    throw new FrameError('Content-Type header is required');
  }
  return { contentType, body: buf.subarray(pos) };
}

export function sendOutput(reply, buf) {
  if (!startsWithFrameMarker(buf)) {
    return reply.send(buf.toString()); // legacy path, unchanged
  }
  try {
    const { contentType, body } = parseFrame(buf);
    return reply.header('content-type', contentType).send(body);
  } catch (err) {
    if (!(err instanceof FrameError)) throw err;
    reply.log.warn(
      { reason: err.message },
      'invalid OSC-HTTP-Response header block'
    );
    return reply
      .code(500)
      .type('text/plain; charset=utf-8')
      .send(`Invalid OSC-HTTP-Response header block: ${err.message}\n`);
  }
}
