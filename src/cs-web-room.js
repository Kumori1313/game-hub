const gameId = 'cs-web';
const liveGame = 'https://vortezler.github.io/Counter-Attack-Web/';
const localGame = 'http://127.0.0.1:5177/cs-web/';

export function mountCsWebRoom(container, client) {
  container.setAttribute('aria-labelledby', 'cs-web-title');
  container.innerHTML = `<h2 id="cs-web-title">Counter-Attack Web</h2>
    <p class="hint">Two players and eight bots. The room creator runs the match. Keep this lobby tab open while playing.</p>
    <div id="cs-discovery">
      <div class="lobby-actions">
        <button class="button" type="button" id="cs-create">Create public lobby</button>
        <button class="secondary" type="button" id="cs-private">Create code-only lobby</button>
      </div>
      <form class="code-entry" id="cs-code">
        <label for="cs-code-value">Room code</label>
        <div class="input-line">
          <input id="cs-code-value" autocomplete="off" maxlength="32" required />
          <button class="secondary" type="submit">Join with code</button>
        </div>
      </form>
      <ul class="lobby-list" id="cs-rooms"></ul>
    </div>
    <div id="cs-room" hidden>
      <p id="cs-members"></p>
      <p id="cs-invite" hidden></p>
      <div class="lobby-actions">
        <button class="button" type="button" id="cs-start" hidden>Start match</button>
        <button class="button" type="button" id="cs-launch" hidden>Open match</button>
        <button class="secondary" type="button" id="cs-leave">Leave lobby</button>
      </div>
    </div>
    <p id="cs-status" role="status"></p>
    <p id="cs-error" class="error" role="alert"></p>
    <a href="/game-hub/" id="cs-back">Back to games</a>`;
  const node = id => container.querySelector('#' + id);
  const connection = crypto.randomUUID();
  const destination = new URL(location.hostname === '127.0.0.1' ? localGame : liveGame);
  let actor, room, popup, port, launchId;
  let busy = false;
  let polling = false;
  let syncing = false;
  let nextHeartbeat = 0;

  function closeBridge(message) {
    if (message && port) port.postMessage({ type: 'ended', message });
    port?.close();
    port = null;
    popup = null;
    launchId = null;
  }

  function setRoom(next) {
    room = next;
    const url = new URL(location.href);
    if (next) url.searchParams.set('room', next.id);
    else url.searchParams.delete('room');
    if (url.href !== location.href) history.replaceState(null, '', url);
    if (!next || next.status === 'closed') closeBridge('The lobby has ended. Return to Game Hub.');
    render();
  }

  function render() {
    const active = room?.status === 'playing';
    node('cs-discovery').hidden = !!room;
    node('cs-room').hidden = !room;
    for (const button of container.querySelectorAll('button')) button.disabled = busy;
    node('cs-members').textContent = room ? room.members
      .map(member => member.display_name + (member.user_id === room.host_id ? ' (host)' : '')).join(' · ') : '';
    node('cs-invite').hidden = !room?.join_code;
    node('cs-invite').textContent = room?.join_code ? 'Room code: ' + room.join_code : '';
    node('cs-start').hidden = room?.status !== 'waiting' || room.host_id !== actor;
    node('cs-start').disabled = busy || !room?.playable || room.members.filter(member => member.connected).length !== 2;
    node('cs-launch').hidden = !active;
    node('cs-status').textContent = room?.status === 'waiting' ? 'Waiting for the match to start.'
      : active ? 'Match started. Open the game in a new tab.'
      : room?.status === 'closed' ? room.reason || 'The lobby ended.' : '';
  }

  async function action(kind, id = room?.id ?? null, extra = {}) {
    const { data, error } = await client.rpc('room_action', {
      p_action: kind, p_lobby: id, p_connection: connection, p_game: gameId, ...extra,
    }).abortSignal(AbortSignal.timeout(10000));
    if (error || data?.error) throw error || { code: data.code, message: data.error };
    return data;
  }

  async function refreshRooms() {
    const { data, error } = await client.from('lobby_summaries').select('id,title,player_count,capacity')
      .eq('game_id', gameId).eq('status', 'waiting').order('created_at', { ascending: false }).limit(25)
      .abortSignal(AbortSignal.timeout(10000));
    if (error) throw error;
    if (room || !actor) return;
    const list = node('cs-rooms');
    const ids = new Set(data.map(lobby => lobby.id));
    for (const row of list.children) if (!ids.has(row.dataset.id)) row.remove();
    for (const lobby of data) {
      let row = list.querySelector(`[data-id="${lobby.id}"]`);
      if (!row) {
        row = document.createElement('li');
        row.dataset.id = lobby.id;
        row.className = 'lobby-row';
        const label = document.createElement('span');
        const button = document.createElement('button');
        button.className = 'secondary';
        button.type = 'button';
        button.addEventListener('click', () => perform(async () => setRoom(await action('join', lobby.id))));
        row.append(label, button);
        list.append(row);
      }
      row.firstElementChild.textContent = `${lobby.title} · ${lobby.player_count}/${lobby.capacity}`;
      row.lastElementChild.disabled = lobby.player_count >= lobby.capacity;
      row.lastElementChild.textContent = row.lastElementChild.disabled ? 'Full' : 'Join';
    }
  }

  async function sync() {
    if (!actor || busy || syncing || !navigator.onLine) return;
    syncing = true;
    const id = room?.id;
    try {
      if (id && room.status !== 'closed') {
        const heartbeat = Date.now() >= nextHeartbeat;
        const current = await action(heartbeat ? 'heartbeat' : 'snapshot', id);
        if (room?.id === id && !busy) setRoom(current);
        if (heartbeat) nextHeartbeat = Date.now() + 12000;
      } else if (!id) await refreshRooms();
    } catch (error) {
      if (error.code === '42501' && room?.id === id) setRoom(null);
      showError(error);
    } finally {
      syncing = false;
    }
  }

  function showError(error) {
    if (error.code === 'PT401') document.dispatchEvent(new Event('guest-session-ended'));
    node('cs-error').textContent = error.message || 'Could not reach the lobby. Try again.';
  }

  async function perform(task) {
    if (!actor || busy) return;
    busy = true;
    node('cs-error').textContent = '';
    render();
    try { await task(); }
    catch (error) { showError(error); }
    finally {
      busy = false;
      render();
      if (!room) void sync();
    }
  }

  async function signal(message = null) {
    if (!port || !room || room.status !== 'playing') return;
    const recipient = port;
    const { data, error } = await client.rpc('cs_web_signal', { p_lobby: room.id, p_message: message })
      .abortSignal(AbortSignal.timeout(8000));
    if (recipient !== port) return;
    if (error) {
      showError(error);
      recipient.postMessage({ type: 'error', message: 'The lobby could not exchange connection details.' });
    } else if (data) recipient.postMessage({ type: 'signal', message: data });
  }

  window.addEventListener('message', event => {
    if (!popup || event.origin !== destination.origin || event.source !== popup
      || event.data?.type !== 'cs-web-ready' || event.data.launch !== launchId || room?.status !== 'playing') return;
    port?.close();
    const channel = new MessageChannel();
    port = channel.port1;
    const boundPort = port;
    boundPort.onmessage = ({ data }) => {
      if (boundPort !== port) return;
      if (data?.type === 'signal' && data.message && JSON.stringify(data.message).length <= 24000) void signal(data.message);
      else if (data?.type === 'exit') void perform(async () => { await action('leave'); setRoom(null); });
    };
    popup.postMessage({
      type: 'cs-web-connect', launch: launchId, host: room.host_id === actor,
      hostName: room.members.find(member => member.user_id === room.host_id)?.display_name,
      peerName: room.members.find(member => member.user_id !== room.host_id)?.display_name,
    }, destination.origin, [channel.port2]);
  });

  function create(visibility) {
    return perform(async () => {
      const id = await action('create', null, { p_capacity: 2, p_visibility: visibility });
      setRoom(await action('heartbeat', id));
    });
  }

  node('cs-create').onclick = () => create('public');
  node('cs-private').onclick = () => create('private');
  node('cs-code').onsubmit = event => {
    event.preventDefault();
    void perform(async () => setRoom(await action('join_code', null, { p_code: node('cs-code-value').value })));
  };
  node('cs-start').onclick = () => perform(async () => {
    await action('start');
    setRoom(await action('snapshot'));
  });
  node('cs-launch').onclick = () => {
    if (room?.status !== 'playing') return;
    if (popup && !popup.closed) { popup.focus(); return; }
    closeBridge();
    launchId = crypto.randomUUID();
    const url = new URL(destination);
    url.hash = new URLSearchParams({ 'game-hub': launchId, parent: location.origin }).toString();
    popup = window.open(url, '_blank');
    if (!popup) node('cs-error').textContent = 'Allow pop-ups to open the match.';
  };
  node('cs-leave').onclick = () => perform(async () => {
    if (room.status !== 'closed') await action('leave');
    setRoom(null);
  });
  node('cs-back').onclick = event => {
    if (!room) return;
    event.preventDefault();
    void perform(async () => {
      if (room.status !== 'closed') await action('leave');
      location.assign(node('cs-back').href);
    });
  };

  document.addEventListener('guest-state', ({ detail }) => {
    if (!detail.ready || !detail.userId) {
      if (!detail.userId && actor) { actor = null; setRoom(null); }
      return;
    }
    if (actor === detail.userId) return;
    actor = detail.userId;
    void perform(async () => {
      const id = await action('current', null);
      if (id) setRoom(await action('heartbeat', id));
      else setRoom(null);
    });
  });
  setInterval(() => {
    void sync();
    if (popup?.closed) closeBridge();
    if (!polling && port && room?.status === 'playing') {
      polling = true;
      void signal().finally(() => { polling = false; });
    }
  }, 2500);
}
