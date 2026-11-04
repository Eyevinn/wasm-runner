import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import Fastify from 'fastify';
import { sendOutput } from './response.js';

async function respond(stdout) {
  const app = Fastify();
  app.get('/', async (request, reply) => {
    sendOutput(reply, stdout);
  });
  const res = await app.inject({ method: 'GET', url: '/' });
  await app.close();
  return res;
}

const PREFIX = 'Invalid OSC-HTTP-Response header block: ';
const allBytes = Buffer.from(Array.from({ length: 256 }, (_, i) => i));

function frame(headers, body = Buffer.alloc(0), eol = '\n') {
  return Buffer.concat([
    Buffer.from(`OSC-HTTP-Response: 1${eol}${headers}${eol}`),
    Buffer.from(body)
  ]);
}

async function assertInvalid(stdout) {
  const res = await respond(stdout);
  assert.equal(res.statusCode, 500);
  assert.equal(res.headers['content-type'], 'text/plain; charset=utf-8');
  assert.ok(res.body.startsWith(PREFIX), res.body);
  return res;
}

test('default: plain text output is unchanged', async () => {
  const res = await respond(Buffer.from('Hello, world!\n'));
  assert.equal(res.statusCode, 200);
  assert.equal(res.headers['content-type'], 'text/plain; charset=utf-8');
  assert.equal(res.body, 'Hello, world!\n');
});

test('default: non-UTF-8 output without the marker is unchanged', async () => {
  const out = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0xff, 0x00]);
  const res = await respond(out);
  assert.equal(res.headers['content-type'], 'text/plain; charset=utf-8');
  assert.deepEqual(res.rawPayload, Buffer.from(out.toString()));
});

test('framed: raw bytes with declared Content-Type', async () => {
  const res = await respond(frame('Content-Type: image/png\n', allBytes));
  assert.equal(res.statusCode, 200);
  assert.equal(res.headers['content-type'], 'image/png');
  assert.deepEqual(res.rawPayload, allBytes);
});

test('framed: CRLF header lines and blank lines inside the body', async () => {
  const body = Buffer.from('a\n\nb\r\n\r\nc');
  const res = await respond(
    frame('content-type: application/octet-stream\r\n', body, '\r\n')
  );
  assert.equal(res.statusCode, 200);
  assert.equal(res.headers['content-type'], 'application/octet-stream');
  assert.deepEqual(res.rawPayload, body);
});

test('framed: empty body gives 200 with length 0', async () => {
  const res = await respond(frame('Content-Type: image/png\n'));
  assert.equal(res.statusCode, 200);
  assert.equal(res.rawPayload.length, 0);
});

test('framed: Content-Type value is preserved verbatim', async () => {
  const res = await respond(
    frame('Content-Type: text/html; charset=utf-8\n', 'hi')
  );
  assert.equal(res.headers['content-type'], 'text/html; charset=utf-8');
  assert.equal(res.body, 'hi');
});

test('marker must match exactly, otherwise the legacy path is used', async () => {
  for (const text of [
    'OSC-HTTP-Response: 2\nContent-Type: image/png\n\nx',
    'osc-http-response: 1\nContent-Type: image/png\n\nx',
    'OSC-HTTP-Response: 1'
  ]) {
    const res = await respond(Buffer.from(text));
    assert.equal(res.statusCode, 200);
    assert.equal(res.headers['content-type'], 'text/plain; charset=utf-8');
    assert.equal(res.body, text);
  }
});

test('malformed: missing Content-Type', async () => {
  await assertInvalid(frame(''));
});

test('malformed: no empty line within 8192 bytes', async () => {
  const long = `Content-Type: ${'a'.repeat(9000)}\n`;
  await assertInvalid(frame(long, 'x'));
});

test('malformed: no blank line at all', async () => {
  await assertInvalid(Buffer.from('OSC-HTTP-Response: 1\nContent-Type: image/png\n'));
});

test('malformed: extra header such as Status', async () => {
  await assertInvalid(frame('Content-Type: image/png\nStatus: 404\n', 'x'));
});

test('malformed: duplicate Content-Type', async () => {
  await assertInvalid(
    frame('Content-Type: image/png\ncontent-type: image/gif\n', 'x')
  );
});

test('malformed: empty value', async () => {
  await assertInvalid(frame('Content-Type:   \n', 'x'));
});

test('malformed: control character in value', async () => {
  await assertInvalid(frame('Content-Type: image/\x01png\n', 'x'));
});

test('malformed: mid-line CR cannot inject a response header', async () => {
  const res = await assertInvalid(
    frame('Content-Type: image/png\rX-Evil: 1\n', 'x')
  );
  assert.equal(res.headers['x-evil'], undefined);
});

test('malformed: header line without a colon', async () => {
  await assertInvalid(frame('Content-Type image/png\n', 'x'));
});

test('server.js routes every output through sendOutput', () => {
  // server.js listens on import and runs wasmedge, so wiring is asserted on
  // the source: all three output sites use sendOutput, none the legacy send.
  const src = readFileSync(new URL('./server.js', import.meta.url), 'utf8');
  assert.equal(src.includes('reply.send(buf.toString())'), false);
  assert.equal(src.split('sendOutput(reply, buf);').length - 1, 3);
  assert.match(src, /import \{ sendOutput \} from '\.\/response\.js'/);
});
