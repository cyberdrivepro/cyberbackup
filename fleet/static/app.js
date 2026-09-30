/**
 * CyberFleet Dashboard Real-Time WebSocket Client & UI Controller
 */

let ws = null;
let reconnectTimer = null;
let cachedJobs = [];
let cachedNodes = [];
let activeShareLink = "";

// Formatting utilities
function formatBytes(bytes, decimals = 1) {
  if (!bytes || bytes === 0) return '0 B';
  const k = 1024;
  const dm = decimals < 0 ? 0 : decimals;
  const sizes = ['B', 'KB', 'MB', 'GB', 'TB'];
  const i = Math.floor(Math.log(bytes) / Math.log(k));
  return parseFloat((bytes / Math.pow(k, i)).toFixed(dm)) + ' ' + sizes[i];
}

function formatSpeed(bps) {
  if (!bps || bps === 0) return '0 B/s';
  return formatBytes(bps, 1) + '/s';
}

function formatTimeAgo(epochSec) {
  if (!epochSec) return 'never';
  const diff = Math.max(0, Math.floor(Date.now() / 1000 - epochSec));
  if (diff < 5) return 'just now';
  if (diff < 60) return `${diff}s ago`;
  if (diff < 3600) return `${Math.floor(diff / 60)}m ago`;
  return `${Math.floor(diff / 3600)}h ago`;
}

// WebSocket initialization with auto-reconnect
function connectWebSocket() {
  const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
  const wsUrl = `${protocol}//${window.location.host}/api/v1/ws/dashboard`;
  
  const statusDot = document.getElementById('ws-indicator');
  const statusText = document.getElementById('ws-status');

  try {
    ws = new WebSocket(wsUrl);

    ws.onopen = () => {
      statusDot.className = 'pulse-dot';
      statusText.innerText = 'LIVE STREAM';
      if (reconnectTimer) clearTimeout(reconnectTimer);
    };

    ws.onmessage = (event) => {
      try {
        const payload = JSON.parse(event.data);
        handleStreamPayload(payload);
      } catch (e) {
        console.error('Error parsing stream message:', e);
      }
    };

    ws.onclose = () => {
      statusDot.className = 'pulse-dot offline';
      statusText.innerText = 'RECONNECTING';
      reconnectTimer = setTimeout(connectWebSocket, 3000);
    };

    ws.onerror = () => {
      ws.close();
    };
  } catch (err) {
    statusDot.className = 'pulse-dot offline';
    statusText.innerText = 'OFFLINE';
    reconnectTimer = setTimeout(connectWebSocket, 3000);
  }
}

// Stream Payload Router
function handleStreamPayload(data) {
  if (data.type === 'state_update' || data.type === 'initial') {
    if (data.nodes) {
      cachedNodes = data.nodes;
      renderNodes(data.nodes);
    }
    if (data.jobs) {
      cachedJobs = data.jobs;
      renderJobs(data.jobs);
    }
    if (data.aggregate) {
      renderAggregate(data.aggregate);
    }
    document.getElementById('last-updated').innerText = `Updated: ${new Date().toLocaleTimeString()}`;
  }
}

// Render Aggregate Overview Cards
function renderAggregate(agg) {
  const online = agg.online_nodes || 0;
  const total = agg.total_nodes || 0;
  const degraded = agg.degraded_nodes || 0;
  const offline = agg.offline_nodes || 0;

  document.getElementById('stat-nodes-count').innerText = `${online} / ${total}`;
  document.getElementById('stat-nodes-sub').innerText = `${online} Online • ${degraded} Degraded • ${offline} Offline`;

  document.getElementById('stat-cpu-total').innerText = `${(agg.total_effective_cpu || 0).toFixed(1)} vCPU`;
  document.getElementById('stat-cpu-sub').innerText = `${agg.total_visible_cpu || 0} visible cores across fleet`;

  document.getElementById('stat-ram-total').innerText = formatBytes(agg.total_effective_ram_bytes || 0);
  document.getElementById('stat-ram-sub').innerText = `${formatBytes(agg.total_ram_used_bytes || 0)} actively used`;

  document.getElementById('stat-disk-total').innerText = formatBytes(agg.total_disk_free_bytes || 0);
  document.getElementById('stat-disk-sub').innerText = `Total pool: ${formatBytes(agg.total_disk_total_bytes || 0)}`;

  const rx = formatSpeed(agg.total_live_rx_bps || 0);
  const tx = formatSpeed(agg.total_live_tx_bps || 0);
  document.getElementById('stat-net-traffic').innerText = `${rx} / ${tx}`;
}

// Render Node Cards
function renderNodes(nodes) {
  const container = document.getElementById('nodes-grid');
  if (!nodes || nodes.length === 0) {
    container.innerHTML = '<div style="color: var(--text-dim); font-size: 0.85rem;">No nodes registered yet. Join nodes via <code>cybervps fleet join &lt;url&gt; &lt;token&gt;</code></div>';
    return;
  }

  let html = '';
  for (const n of nodes) {
    const statusClass = n.status === 'ONLINE' ? 'status-online' : (n.status === 'DEGRADED' ? 'status-degraded' : 'status-offline');
    const effCpu = (n.effective_cpu || 1.0).toFixed(1);
    const visCpu = n.visible_cpu || 1;
    const effRam = formatBytes(n.effective_ram_bytes || 0);
    const ramUsed = formatBytes(n.ram_used_bytes || 0);
    const diskFree = formatBytes(n.disk_free_bytes || 0);
    const liveRx = formatSpeed(n.live_rx_bps || 0);
    const liveTx = formatSpeed(n.live_tx_bps || 0);
    const benchDl = n.last_benchmark_dl_bps > 0 ? (n.last_benchmark_dl_bps / (1024 * 1024)).toFixed(0) + ' Mbps' : 'Not tested';
    const recentSpeed = n.recent_avg_speed_bps > 0 ? formatSpeed(n.recent_avg_speed_bps) : 'None';
    const reliability = (n.reliability_score || 100).toFixed(1);
    const lastSeen = formatTimeAgo(n.last_heartbeat);

    html += `
      <div class="node-card">
        <div class="node-top">
          <div>
            <div class="node-name">${escapeHtml(n.name)}</div>
            <div class="node-host">${escapeHtml(n.hostname)} • ${escapeHtml(n.privilege_mode || 'ROOTLESS')}</div>
          </div>
          <div class="status-badge ${statusClass}">
            <span class="pulse-dot ${n.status === 'ONLINE' ? '' : 'offline'}" style="width: 6px; height: 6px;"></span>
            ${n.status}
          </div>
        </div>

        <div class="node-stats-table">
          <div class="stat-item">
            <span class="stat-label">CPU Effective</span>
            <span class="stat-val">${effCpu} <span style="font-size: 0.7rem; color: var(--text-dim);">(${visCpu} vis)</span></span>
          </div>
          <div class="stat-item">
            <span class="stat-label">RAM Free / Total</span>
            <span class="stat-val">${effRam} <span style="font-size: 0.7rem; color: var(--text-dim);">(${ramUsed} used)</span></span>
          </div>
          <div class="stat-item">
            <span class="stat-label">Disk Free</span>
            <span class="stat-val">${diskFree}</span>
          </div>
          <div class="stat-item">
            <span class="stat-label">Live RX / TX</span>
            <span class="stat-val" style="color: var(--primary);">${liveRx} / ${liveTx}</span>
          </div>
          <div class="stat-item">
            <span class="stat-label">Recent DL Speed</span>
            <span class="stat-val">${recentSpeed}</span>
          </div>
          <div class="stat-item">
            <span class="stat-label">Last Benchmark</span>
            <span class="stat-val">${benchDl}</span>
          </div>
        </div>

        <div class="node-footer">
          <div>Jobs: <b>${n.active_jobs_count || 0}</b> | Rel: <b>${reliability}%</b></div>
          <div>Seen: <b>${lastSeen}</b></div>
        </div>
      </div>
    `;
  }
  container.innerHTML = html;
}

// Render Transfers Table
function renderJobs(jobs) {
  const tbody = document.getElementById('transfers-body');
  if (!jobs || jobs.length === 0) {
    tbody.innerHTML = '<tr><td colspan="6" style="text-align: center; color: var(--text-dim); padding: 2rem;">No transfers currently in fleet.</td></tr>';
    return;
  }

  let html = '';
  for (const j of jobs) {
    const pct = (j.progress_percent || 0).toFixed(0);
    const dlBytes = formatBytes(j.downloaded_bytes || 0);
    const totBytes = j.expected_size > 0 ? formatBytes(j.expected_size) : 'Unknown';
    const curSpeed = j.status === 'DOWNLOADING' ? formatSpeed(j.current_speed_bps || 0) : '-';
    const etaStr = (j.status === 'DOWNLOADING' && j.eta_seconds > 0) ? `${j.eta_seconds}s` : '-';
    const nodeBadge = j.node_id ? `<span style="font-family: var(--font-mono); color: var(--primary); font-size: 0.75rem;">${escapeHtml(j.node_id)}</span>` : '<span style="color: var(--text-dim);">Scheduling...</span>';

    let statusStyle = 'color: var(--text-muted);';
    if (j.status === 'COMPLETED') statusStyle = 'color: var(--success); font-weight: 600;';
    else if (j.status === 'DOWNLOADING') statusStyle = 'color: var(--primary); font-weight: 600;';
    else if (j.status === 'FAILED' || j.status === 'NODE_LOST') statusStyle = 'color: var(--danger); font-weight: 600;';

    let actions = '';
    if (j.status === 'COMPLETED') {
      actions += `<button class="action-btn" onclick="openShareModal('${j.id}')">DIRECT LINK</button> `;
    } else if (j.status === 'DOWNLOADING' || j.status === 'QUEUED') {
      actions += `<button class="action-btn" onclick="cancelJob('${j.id}')">CANCEL</button> `;
    } else if (j.status === 'FAILED' || j.status === 'NODE_LOST' || j.status === 'CANCELLED') {
      actions += `<button class="action-btn" onclick="retryJob('${j.id}')">RETRY</button> `;
    }

    html += `
      <tr>
        <td>
          <div class="file-cell">
            <span class="file-name">${escapeHtml(j.filename || 'downloading...')}</span>
            <span class="file-meta" title="${escapeHtml(j.requested_url)}">${escapeHtml(truncate(j.requested_url, 45))}</span>
          </div>
        </td>
        <td><span style="${statusStyle}">${j.status}</span></td>
        <td>${nodeBadge}</td>
        <td>
          <div class="progress-bar-container">
            <div class="progress-bar-fill" style="width: ${pct}%;"></div>
          </div>
          <div style="font-size: 0.75rem; font-family: var(--font-mono);">${dlBytes} / ${totBytes} (${pct}%)</div>
        </td>
        <td>
          <div style="font-family: var(--font-mono); font-size: 0.8rem;">${curSpeed}</div>
          <div style="font-size: 0.7rem; color: var(--text-dim);">ETA: ${etaStr}</div>
        </td>
        <td>${actions}</td>
      </tr>
    `;
  }
  tbody.innerHTML = html;
}

// Submit Download Job
async function submitDownload(e) {
  e.preventDefault();
  const input = document.getElementById('input-url');
  const btn = document.getElementById('btn-submit');
  const feedback = document.getElementById('intake-feedback');
  const url = input.value.trim();

  if (!url) return;

  btn.disabled = true;
  btn.innerText = 'PROBING...';
  feedback.style.display = 'block';
  feedback.style.color = 'var(--primary)';
  feedback.innerText = 'Validating SSRF safety and probing remote file headers...';

  try {
    const res = await fetch('/api/v1/jobs', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ url: url })
    });
    const data = await res.json();
    if (res.ok && data.ok) {
      feedback.style.color = 'var(--success)';
      feedback.innerText = `✔ Scheduled on node '${data.job.node_id}'. Transfer initializing.`;
      input.value = '';
      setTimeout(() => { feedback.style.display = 'none'; }, 4000);
    } else {
      feedback.style.color = 'var(--danger)';
      feedback.innerText = `✖ Rejection: ${data.detail || data.error || 'Failed to schedule job'}`;
    }
  } catch (err) {
    feedback.style.color = 'var(--danger)';
    feedback.innerText = `✖ Network error: ${err.message}`;
  } finally {
    btn.disabled = false;
    btn.innerText = 'DOWNLOAD';
  }
}

// Job Controls
async function cancelJob(jobId) {
  if (!confirm(`Cancel transfer ${jobId}?`)) return;
  try {
    await fetch(`/api/v1/jobs/${jobId}/cancel`, { method: 'POST' });
  } catch (e) {
    alert('Failed to cancel job: ' + e.message);
  }
}

async function retryJob(jobId) {
  try {
    await fetch(`/api/v1/jobs/${jobId}/retry`, { method: 'POST' });
  } catch (e) {
    alert('Failed to retry job: ' + e.message);
  }
}

// Cybershare Direct Link Modal
async function openShareModal(jobId) {
  const modal = document.getElementById('modal-container');
  const body = document.getElementById('modal-body');
  body.innerHTML = 'Generating secure Cybershare signed download URL...';
  modal.style.display = 'flex';

  try {
    const res = await fetch(`/api/v1/jobs/${jobId}/share`, { method: 'POST' });
    const data = await res.json();
    if (res.ok && data.ok) {
      activeShareLink = data.download_url;
      body.innerHTML = `
        <p style="margin-bottom: 0.5rem;"><b>Signed Direct Link (HTTP Range & Resume Enabled):</b></p>
        <div style="background: var(--bg-input); padding: 0.75rem; border-radius: 6px; font-family: var(--font-mono); font-size: 0.75rem; word-break: break-all; border: 1px solid var(--border);">
          ${escapeHtml(data.download_url)}
        </div>
        <p style="font-size: 0.75rem; color: var(--text-dim); margin-top: 0.75rem;">
          Expires: <b>${new Date(data.expires_at * 1000).toLocaleString()}</b> (${Math.round((data.expires_at - Date.now()/1000)/3600)}h remaining)
        </p>
      `;
    } else {
      body.innerText = 'Error generating link: ' + (data.detail || data.error);
    }
  } catch (e) {
    body.innerText = 'Network error: ' + e.message;
  }
}

function copyModalLink() {
  if (activeShareLink) {
    navigator.clipboard.writeText(activeShareLink).then(() => {
      const btn = document.getElementById('modal-copy-btn');
      btn.innerText = 'COPIED!';
      setTimeout(() => { btn.innerText = 'COPY LINK'; }, 2000);
    });
  }
}

function closeModal(e) {
  if (!e || e.target.id === 'modal-container' || e.target.tagName === 'BUTTON') {
    document.getElementById('modal-container').style.display = 'none';
  }
}

async function logout() {
  await fetch('/api/v1/auth/logout', { method: 'POST' });
  window.location.href = '/login';
}

function truncate(str, len) {
  if (!str) return '';
  return str.length > len ? str.substring(0, len) + '...' : str;
}

function escapeHtml(str) {
  if (!str) return '';
  return String(str).replace(/[&<>"']/g, (m) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
  })[m]);
}

// Initial bootstrap
window.addEventListener('DOMContentLoaded', () => {
  connectWebSocket();
});
