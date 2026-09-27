(() => {
  'use strict';
  const state = { clients: new Map(), groups: [], streams: [], socket: null, requestId: 0, pending: new Map() };
  const $ = id => document.getElementById(id);
  const esc = value => String(value ?? '').replace(/[&<>"']/g, char => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[char]));
  const rpc = (method, params = {}) => new Promise((resolve, reject) => {
    if (!state.socket || state.socket.readyState !== WebSocket.OPEN) return reject(new Error('offline'));
    const id = ++state.requestId; state.pending.set(id, {resolve, reject});
    state.socket.send(JSON.stringify({id, jsonrpc:'2.0', method, params}));
  });
  const send = (method, params) => rpc(method, params).catch(error => console.warn(method, error));

  function connect() {
    if (state.socket) state.socket.close();
    const scheme = location.protocol === 'https:' ? 'wss:' : 'ws:';
    const url = location.host
    // const url = "hss.local"
    state.socket = new WebSocket(`${scheme}//${url}/control/ws`);
    state.socket.onopen = () => { $('connection').textContent = 'Connected'; $('connection').className = 'status online'; rpc('Server.GetStatus').then(update).catch(console.warn); };
    state.socket.onclose = () => { $('connection').textContent = 'Offline'; $('connection').className = 'status offline'; setTimeout(connect, 3000); };
    state.socket.onerror = () => state.socket.close();
    state.socket.onmessage = event => { const message = JSON.parse(event.data); const pending = state.pending.get(message.id); if (pending) { state.pending.delete(message.id); message.error ? pending.reject(message.error) : pending.resolve(message.result); } if (message.method === 'Server.OnUpdate') update(message.params); };
  }

  function update(result) {
    const server = result?.server || result;
    state.groups = server?.groups || []; state.streams = server?.streams || [];
    state.clients.clear(); state.groups.forEach(group => (group.clients || []).forEach(client => state.clients.set(client.id, {...client, groupId: group.id})));
    ensureDefaultGrouping();
    render();
  }

  function ensureDefaultGrouping() {
    if (!state.clients.size || localStorage.getItem('hss-default-grouping')) return;
    const clients = [...state.clients.keys()];
    if (!state.groups.length) send('Group.Create', {name:'Default', clients});
    else {
      const target = state.groups.find(group => group.name === 'Default') || state.groups[0];
      send('Group.SetClients', {id:target.id, clients});
      if (target.name !== 'Default') send('Group.SetName', {id:target.id, name:'Default'});
    }
    localStorage.setItem('hss-default-grouping', '1');
  }

  function render() {
    $('clients').innerHTML = state.clients.size ? [...state.clients.values()].map(client => { const volume = client.config?.volume || {}; return `<article class="card client-card" data-id="${esc(client.id)}"><div class="card-heading"><div><strong>${esc(client.host?.name || client.id)}</strong><small>${esc(client.id)}</small></div><span class="client-status ${client.connected ? 'online' : 'offline'}">${client.connected ? 'Connected' : 'Disconnected'}</span></div><label class="volume-label">Volume <output class="volume-value">${Math.round(volume.percent ?? 50)}%</output><input class="volume" type="range" min="0" max="100" value="${volume.percent ?? 50}"></label><button class="mute button secondary">${volume.muted ? 'Unmute' : 'Mute'}</button></article>`; }).join('') : '<p class="empty">No clients found.</p>';
    $('groups').innerHTML = state.groups.length ? state.groups.map(group => `<article class="card"><div class="card-heading"><strong>${esc(group.name || group.id)}</strong><button class="button secondary delete-group" data-id="${esc(group.id)}">Delete</button></div>${[...state.clients.values()].map(client => `<label class="group-client"><input type="checkbox" data-group="${esc(group.id)}" data-client="${esc(client.id)}" ${(group.clients || []).some(item => item.id === client.id) ? 'checked' : ''}>${esc(client.host?.name || client.id)}</label>`).join('')}<div class="stream-actions"><select data-stream-group="${esc(group.id)}"><option value="">No stream</option>${state.streams.map(stream => `<option value="${esc(stream.id)}" ${group.stream_id === stream.id ? 'selected' : ''}>${esc(stream.id)}</option>`).join('')}</select></div></article>`).join('') : '<p class="empty">Clients will start in Default.</p>';
    $('streams').innerHTML = state.streams.length ? state.streams.map(stream => `<article class="card row"><strong>${esc(stream.id)}</strong><button class="button secondary delete-stream" data-id="${esc(stream.id)}">Delete</button></article>`).join('') : '<p class="empty">No streams configured.</p>';
  }


  $('clients').addEventListener('input', event => { if (!event.target.matches('.volume')) return; const card = event.target.closest('[data-id]'), percent = Number(event.target.value); card.querySelector('output').value = `${percent}%`; send('Client.SetVolume', {id:card.dataset.id, volume:{percent, muted:false}}); });
  $('clients').addEventListener('click', event => { if (!event.target.matches('.mute')) return; const card = event.target.closest('[data-id]'), client = state.clients.get(card.dataset.id), volume = client.config?.volume || {}; send('Client.SetVolume', {id:card.dataset.id, volume:{percent:volume.percent ?? 50, muted:!volume.muted}}); });
  $('groups').addEventListener('change', event => { if (event.target.matches('[data-group]')) { const group = state.groups.find(item => item.id === event.target.dataset.group); const clients = [...group.clients || []].map(client => client.id).filter(id => id !== event.target.dataset.client); if (event.target.checked) clients.push(event.target.dataset.client); send('Group.SetClients', {id:group.id, clients}); } });
  $('groups').addEventListener('change', event => { if (event.target.matches('[data-stream-group]')) send('Group.SetStream', {id:event.target.dataset.streamGroup, stream_id:event.target.value}); });
  $('groups').addEventListener('click', event => { if (event.target.matches('.delete-group')) send('Group.Delete', {id:event.target.dataset.id}); });
  $('streams').addEventListener('click', event => { if (event.target.matches('.delete-stream')) send('Stream.RemoveStream', {id:event.target.dataset.id}); });
  $('new-group').onclick = () => { const name = prompt('Group name', 'New group'); if (name) send('Group.Create', {name}); };
  $('new-stream').onclick = () => { const id = prompt('Stream URL or name', 'New stream'); if (id) send('Stream.AddStream', {id, uri:id}); };
  $('refresh').onclick = connect;
  if ('serviceWorker' in navigator) navigator.serviceWorker.register('./sw.js');
  connect();
})();