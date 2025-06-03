import Fastify from 'fastify'
import cors from '@fastify/cors'
import { spawn } from 'node:child_process';
import path from 'node:path';

const fastify = Fastify({
  logger: true
});
fastify.register(cors, {
  origin: '*',
  credentials: true,
});  

function _runWasm(reqBody) {
  return new Promise((resolve) => {
    const wasmedge = spawn(path.join('/runner/bin', 'wasmedge'), [
      path.join('/usercontent', 'main.wasm')
    ]);
    let d = [];
    wasmedge.stdout.on('data', (data) => {
      d.push(data);
    });
    wasmedge.on('close', (code) => {
      let buf = Buffer.concat(d);
      resolve(buf);
    });
    if (!reqBody) {
      reqBody = Buffer.from([]);
    }
    wasmedge.stdin.write(reqBody);
    wasmedge.stdin.end('');
  });
}

fastify.get('/', async (request, reply) => {
  let buf = await _runWasm();
  reply.send(buf.toString());
});

fastify.post('/', async (request, reply) => {
  if (request.body.match(/^[\da-f]+$/i)) {
    const typedArray = new Uint8Array(    
      request.body.match(/[\da-f]{2}/gi).map(function (h) {
        return parseInt(h, 16);
      })
    );
    let buf = await _runWasm(typedArray);
    reply.send(buf.toString());
  } else {
    let buf = await _runWasm(request.body);
    reply.send(buf.toString());
  }
});

fastify.listen({ port: process.env.PORT || 8080, host: '0.0.0.0' }, function (err, address) {
  if (err) {
    fastify.log.error(err)
    process.exit(1)
  }
  fastify.log.info(`server listening on ${address}`)
});
