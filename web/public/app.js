// --- API ヘルパー ---
async function api(path, opts = {}) {
  const res = await fetch(`/api${path}`, {
    headers: { 'Content-Type': 'application/json' },
    ...opts,
    body: opts.body ? JSON.stringify(opts.body) : undefined,
  });
  return res.json();
}

function toast(msg, type = 'success') {
  const el = document.getElementById('toast');
  el.textContent = msg;
  el.className = `toast toast-${type}`;
  el.style.display = 'block';
  setTimeout(() => { el.style.display = 'none'; }, 3000);
}

// --- タブ切り替え ---
document.querySelectorAll('.tab').forEach(tab => {
  tab.addEventListener('click', () => {
    document.querySelectorAll('.tab').forEach(t => t.classList.remove('active'));
    document.querySelectorAll('.section').forEach(s => s.classList.remove('active'));
    tab.classList.add('active');
    document.getElementById(tab.dataset.tab).classList.add('active');
  });
});

// --- ダッシュボード ---
const Dashboard = {
  async load() {
    const status = await api('/status');
    const repos = await api('/repos');

    document.getElementById('stat-cards').innerHTML = `
      <div class="stat-card"><div class="num">${repos.length}</div><div class="label">登録リポジトリ</div></div>
      <div class="stat-card"><div class="num">${status.running.length}</div><div class="label">実行中</div></div>
      <div class="stat-card"><div class="num">${status.queued.length}</div><div class="label">キュー</div></div>
      <div class="stat-card"><div class="num">${status.completed.filter(j => j.status === 'completed').length}</div><div class="label">完了</div></div>
    `;

    this.renderJobs('running-jobs', status.running, 'running');
    this.renderJobs('queued-jobs', status.queued, 'queued');
    this.renderJobs('completed-jobs', status.completed, null);
  },

  renderJobs(containerId, jobs, forceBadge) {
    const el = document.getElementById(containerId);
    if (!jobs.length) {
      el.innerHTML = '<div class="empty">ジョブなし</div>';
      return;
    }
    el.innerHTML = `<table>
      <tr><th>リポジトリ</th><th>Issue</th><th>ステータス</th><th>ステップ</th><th>時刻</th></tr>
      ${jobs.map(j => `<tr>
        <td>${j.repo_name}</td>
        <td>#${j.issue_number} ${j.issue_title || ''}</td>
        <td><span class="badge badge-${forceBadge || j.status}">${j.status}</span></td>
        <td>${j.current_step || '-'}</td>
        <td>${j.ended_at ? new Date(j.ended_at).toLocaleString('ja-JP') : j.started_at ? new Date(j.started_at).toLocaleString('ja-JP') : '-'}</td>
      </tr>`).join('')}
    </table>`;
  }
};

// --- リポジトリ管理 ---
const Repos = {
  async load() {
    const repos = await api('/repos');
    const el = document.getElementById('repos-table');
    if (!repos.length) {
      el.innerHTML = '<div class="empty">リポジトリが登録されていません。「+ 追加」から登録してください。</div>';
      return;
    }
    el.innerHTML = `<table>
      <tr><th>名前</th><th>リポジトリ</th><th>パイプライン</th><th>ベースブランチ</th><th>ステータス</th><th>操作</th></tr>
      ${repos.map(r => `<tr>
        <td><strong>${r.name}</strong></td>
        <td>${r.repo}</td>
        <td>${r.pipeline}</td>
        <td>${r.base_branch || 'develop'}</td>
        <td><span class="badge badge-${r.status}">${r.status}</span></td>
        <td>
          <div class="btn-group">
            <button class="btn btn-sm" onclick="RepoModal.edit('${r.name}')">編集</button>
            ${r.status === 'active'
              ? `<button class="btn btn-sm" onclick="Repos.toggleStatus('${r.name}', 'paused')">停止</button>`
              : `<button class="btn btn-sm" onclick="Repos.toggleStatus('${r.name}', 'active')">再開</button>`}
            <button class="btn btn-sm btn-danger" onclick="Repos.remove('${r.name}')">削除</button>
          </div>
        </td>
      </tr>`).join('')}
    </table>`;
  },

  async toggleStatus(name, status) {
    await api(`/repos/${name}`, { method: 'PUT', body: { status } });
    toast(`${name} を${status === 'active' ? '再開' : '一時停止'}しました`);
    this.load();
  },

  async remove(name) {
    if (!confirm(`${name} を削除しますか？`)) return;
    await api(`/repos/${name}`, { method: 'DELETE' });
    toast(`${name} を削除しました`);
    this.load();
    Dashboard.load();
  }
};

// --- リポジトリモーダル ---
const RepoModal = {
  open(data = null) {
    const form = document.getElementById('repo-form');
    form.reset();
    if (data) {
      document.getElementById('repo-modal-title').textContent = 'リポジトリを編集';
      form.edit_name.value = data.name;
      form.repo.value = data.repo;
      form.repo.disabled = true;
      form.pipeline.value = data.pipeline || 'default';
      form.base_branch.value = data.base_branch || 'develop';
      form.context.value = data.context || '';
    } else {
      document.getElementById('repo-modal-title').textContent = 'リポジトリを追加';
      form.edit_name.value = '';
      form.repo.disabled = false;
    }
    document.getElementById('repo-modal').classList.add('show');
  },

  close() {
    document.getElementById('repo-modal').classList.remove('show');
  },

  async edit(name) {
    const repos = await api('/repos');
    const repo = repos.find(r => r.name === name);
    if (repo) this.open(repo);
  },

  async submit(e) {
    e.preventDefault();
    const form = e.target;
    const editName = form.edit_name.value;

    const data = {
      repo: form.repo.value,
      pipeline: form.pipeline.value,
      base_branch: form.base_branch.value || 'develop',
      context: form.context.value || undefined,
    };

    if (editName) {
      await api(`/repos/${editName}`, { method: 'PUT', body: data });
      toast(`${editName} を更新しました`);
    } else {
      const res = await api('/repos', { method: 'POST', body: data });
      if (res.error) {
        toast(res.error, 'error');
        return;
      }
      toast(`${data.repo} を登録しました`);
    }

    this.close();
    Repos.load();
    Dashboard.load();
  }
};

// --- 履歴 ---
const History = {
  async load() {
    const repos = await api('/history');
    const sel = document.getElementById('history-repo');
    sel.innerHTML = '<option value="">リポジトリを選択...</option>' +
      repos.map(r => `<option value="${r}">${r}</option>`).join('');
  },

  async loadEntries() {
    const repo = document.getElementById('history-repo').value;
    const el = document.getElementById('history-list');
    const detailCard = document.getElementById('history-detail-card');
    detailCard.style.display = 'none';

    if (!repo) {
      el.innerHTML = '<div class="empty">リポジトリを選択してください</div>';
      return;
    }

    const entries = await api(`/history/${repo}`);
    if (!entries.length) {
      el.innerHTML = '<div class="empty">履歴がありません</div>';
      return;
    }

    el.innerHTML = `<table>
      <tr><th>日時</th><th>Issue</th><th>ステップ</th><th>モデル</th><th>結果</th><th></th></tr>
      ${entries.map(e => `<tr>
        <td>${new Date(e.timestamp).toLocaleString('ja-JP')}</td>
        <td>#${e.issue_number} ${e.issue_title || ''}</td>
        <td>${e.step}${e.label ? ' (' + e.label + ')' : ''}</td>
        <td>${e.model}</td>
        <td><span class="badge badge-${e.exit_code === 0 ? 'completed' : 'failed'}">${e.exit_code === 0 ? 'OK' : 'Error'}</span></td>
        <td><button class="btn btn-sm" onclick="History.showDetail('${repo}', '${e.filename}')">詳細</button></td>
      </tr>`).join('')}
    </table>`;
  },

  async showDetail(repo, filename) {
    const data = await api(`/history/${repo}/${filename}`);
    const card = document.getElementById('history-detail-card');
    const title = document.getElementById('history-detail-title');
    const el = document.getElementById('history-detail');

    title.textContent = `#${data.issue_number} ${data.step}${data.label ? ' (' + data.label + ')' : ''} — ${new Date(data.timestamp).toLocaleString('ja-JP')}`;

    el.innerHTML = `
      <div style="margin-bottom:8px;">
        <strong>モデル:</strong> ${data.model} &nbsp;
        <strong>Exit:</strong> <span class="badge badge-${data.exit_code === 0 ? 'completed' : 'failed'}">${data.exit_code}</span>
      </div>
      <h3>プロンプト</h3>
      <div class="log-viewer" style="max-height:300px;overflow:auto;margin-bottom:16px;">${History.escapeHtml(data.prompt)}</div>
      <h3>レスポンス</h3>
      <div class="log-viewer" style="max-height:500px;overflow:auto;">${History.escapeHtml(data.response)}</div>
    `;

    card.style.display = 'block';
    card.scrollIntoView({ behavior: 'smooth' });
  },

  escapeHtml(text) {
    if (!text) return '(空)';
    const div = document.createElement('div');
    div.textContent = text;
    return div.innerHTML;
  }
};

// --- 設定 ---
const Settings = {
  async load() {
    const config = await api('/config');
    const form = document.getElementById('settings-form');
    form.poll_interval.value = config.poll_interval || 300;
    form.max_concurrent_jobs.value = config.max_concurrent_jobs || 3;
    form.trigger_label.value = config.trigger_label || 'auto-implement';
    form.log_retention_days.value = config.log_retention_days || 30;
    form.claude_model.value = config.claude?.model || 'claude-sonnet-4-6';
    form.skill_discovery_enabled.value = String(config.skill_discovery?.enabled ?? true);
  },

  async save(e) {
    e.preventDefault();
    const form = e.target;
    await api('/config', {
      method: 'PUT',
      body: {
        poll_interval: form.poll_interval.value,
        max_concurrent_jobs: form.max_concurrent_jobs.value,
        trigger_label: form.trigger_label.value,
        log_retention_days: form.log_retention_days.value,
        claude_model: form.claude_model.value,
        skill_discovery_enabled: form.skill_discovery_enabled.value === 'true',
      }
    });
    toast('設定を保存しました');
  }
};

// --- ログ ---
const Logs = {
  async load() {
    const repos = await api('/logs');
    const sel = document.getElementById('log-repo');
    sel.innerHTML = '<option value="">リポジトリを選択...</option>' +
      repos.map(r => `<option value="${r}">${r}</option>`).join('');
  },

  async loadFiles() {
    const repo = document.getElementById('log-repo').value;
    const sel = document.getElementById('log-file');
    sel.innerHTML = '<option value="">ログファイルを選択...</option>';
    document.getElementById('log-content').textContent = 'ログを選択してください';
    if (!repo) return;

    const files = await api(`/logs/${repo}`);
    sel.innerHTML = '<option value="">ログファイルを選択...</option>' +
      files.map(f => `<option value="${f.name}">${f.name} (${(f.size / 1024).toFixed(1)}KB)</option>`).join('');
  },

  async loadContent() {
    const repo = document.getElementById('log-repo').value;
    const file = document.getElementById('log-file').value;
    if (!repo || !file) return;

    const data = await api(`/logs/${repo}/${file}`);
    document.getElementById('log-content').textContent = data.content || '(空)';
  }
};

// --- アクション ---
const Actions = {
  async poll() {
    toast('ポーリングを実行中...');
    const res = await api('/actions/poll', { method: 'POST' });
    if (res.ok) {
      toast('ポーリング完了');
    } else {
      toast('ポーリング失敗', 'error');
    }
    Dashboard.load();
  }
};

// --- 初期化 ---
Dashboard.load();
Repos.load();
History.load();
Settings.load();
Logs.load();

// ダッシュボード自動更新（10秒）
setInterval(() => {
  if (document.querySelector('.tab[data-tab="dashboard"]').classList.contains('active')) {
    Dashboard.load();
  }
}, 10000);
