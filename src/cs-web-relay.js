// Keep the authenticated Realtime connection in the Game Hub document.
export function openCsWebRelay(client, room, isHost, port) {
  const topic = 'cs-web:' + room.id + ':' + room.round + ':';
  const own = client.channel(topic + (isHost ? 'host' : 'peer'), { config: { private: true } });
  const other = client.channel(topic + (isHost ? 'peer' : 'host'), { config: { private: true } });
  const joined = new Set();
  let closed = false;
  let tokens = 3;
  let refill = performance.now();
  const packetType = isHost ? 'frame' : 'input';

  other.on('broadcast', { event: 'match' }, ({ payload }) => {
    if (!closed && payload?.packet?.type === (isHost ? 'input' : 'frame')) {
      port.postMessage({ type: 'relay-packet', envelope: payload });
    }
  });

  for (const channel of [own, other]) {
    channel.subscribe(status => {
      if (closed) return;
      if (status === 'SUBSCRIBED') {
        joined.add(channel);
        if (joined.size === 2) port.postMessage({ type: 'relay-open' });
      } else {
        joined.delete(channel);
        port.postMessage({ type: 'relay-wait' });
      }
    });
  }

  return {
    send(envelope) {
      if (closed || joined.size !== 2 || envelope?.packet?.type !== packetType
        || typeof envelope.epoch !== 'string' || envelope.epoch.length !== 36
        || JSON.stringify(envelope).length > 16000) return;
      const now = performance.now();
      tokens = Math.min(3, tokens + (now - refill) * 0.014);
      refill = now;
      if (tokens < 1) return;
      tokens -= 1;
      void own.send({ type: 'broadcast', event: 'match', payload: envelope });
    },
    close() {
      closed = true;
      void client.removeChannel(own);
      void client.removeChannel(other);
    },
  };
}
