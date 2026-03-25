const express = require('express');
const fs = require('fs');
const path = require('path');
const yaml = require('js-yaml');
const { execFile } = require('child_process');

const app = express();
const PORT = process.env.PORT || 3000;

// パス設定（Docker volume マウント先 or ローカル）
const BASE_DIR = process.env.BASE_DIR || path.resolve(__dirname, '..');
const CONFIG_PATH = path.join(BASE_DIR, 'config.yaml');
const WORKSPACE_DIR = path.join(BASE_DIR, 'workspace');
const LOGS_DIR = path.join(BASE_DIR, 'logs');
const DAEMON_DIR = path.join(BASE_DIR, 'daemon');

app.use(express.json());
app.use(express.static(path.join(__dirname, 'public')));

// --- ヘルパー関数 ---

function readConfig() {
  const content = fs.readFileSync(CONFIG_PATH, 'utf8');
  return yaml.load(content);
}

function writeConfig(config) {
  const content = yaml.dump(config, { lineWidth: -1, noRefs: true });
  fs.writeFileSync(CONFIG_PATH, content, 'utf8');
}

function readJsonFiles(dir) {
  if (!fs.existsSync(dir)) return [];
  return fs.readdirSync(dir)
    .filter(f => f.endsWith('.json'))
    .map(f => {
      try {
        return JSON.parse(fs.readFileSync(path.join(dir, f), 'utf8'));
      } catch { return null; }
    })
    .filter(Boolean);
}

// --- API: リポジトリ管理 ---

app.get('/api/repos', (req, res) => {
  const config = readConfig();
  res.json(config.repositories || []);
});

app.post('/api/repos', (req, res) => {
  const { repo, pipeline, base_branch, context, pinned_skills } = req.body;
  if (!repo) return res.status(400).json({ error: 'repo は必須です' });

  const config = readConfig();
  if (!config.repositories) config.repositories = [];

  const name = repo.split('/').pop();

  if (config.repositories.some(r => r.repo === repo)) {
    return res.status(409).json({ error: `${repo} は既に登録されています` });
  }

  const entry = {
    name,
    repo,
    pipeline: pipeline || 'default',
    branch_prefix: 'feature/',
    base_branch: base_branch || 'develop',
    status: 'active',
    pinned_skills: pinned_skills || [],
  };
  if (context) entry.context = context;

  config.repositories.push(entry);
  writeConfig(config);
  res.status(201).json(entry);
});

app.put('/api/repos/:name', (req, res) => {
  const config = readConfig();
  const idx = (config.repositories || []).findIndex(r => r.name === req.params.name);
  if (idx === -1) return res.status(404).json({ error: 'リポジトリが見つかりません' });

  const updates = req.body;
  const repo = config.repositories[idx];

  // 更新可能なフィールド
  for (const key of ['pipeline', 'base_branch', 'status', 'context', 'claude_model', 'pinned_skills']) {
    if (updates[key] !== undefined) {
      repo[key] = updates[key];
    }
  }

  config.repositories[idx] = repo;
  writeConfig(config);
  res.json(repo);
});

app.delete('/api/repos/:name', (req, res) => {
  const config = readConfig();
  const idx = (config.repositories || []).findIndex(r => r.name === req.params.name);
  if (idx === -1) return res.status(404).json({ error: 'リポジトリが見つかりません' });

  config.repositories.splice(idx, 1);
  writeConfig(config);
  res.json({ ok: true });
});

// --- API: ジョブステータス ---

app.get('/api/status', (req, res) => {
  const running = readJsonFiles(path.join(WORKSPACE_DIR, '.jobs'))
    .filter(j => j.status === 'running');
  const queued = readJsonFiles(path.join(WORKSPACE_DIR, '.queue'));
  const completed = readJsonFiles(path.join(WORKSPACE_DIR, '.jobs'))
    .filter(j => j.status === 'completed' || j.status === 'failed')
    .sort((a, b) => (b.ended_at || '').localeCompare(a.ended_at || ''))
    .slice(0, 20);

  res.json({ running, queued, completed });
});

// --- API: グローバル設定 ---

app.get('/api/config', (req, res) => {
  const config = readConfig();
  res.json(config.global || {});
});

app.put('/api/config', (req, res) => {
  const config = readConfig();
  const updates = req.body;

  // 更新可能なグローバル設定
  if (updates.poll_interval !== undefined) config.global.poll_interval = Number(updates.poll_interval);
  if (updates.max_concurrent_jobs !== undefined) config.global.max_concurrent_jobs = Number(updates.max_concurrent_jobs);
  if (updates.trigger_label !== undefined) config.global.trigger_label = updates.trigger_label;
  if (updates.log_retention_days !== undefined) config.global.log_retention_days = Number(updates.log_retention_days);
  if (updates.claude_model !== undefined) config.global.claude.model = updates.claude_model;
  if (updates.skill_discovery_enabled !== undefined) config.global.skill_discovery.enabled = updates.skill_discovery_enabled;

  writeConfig(config);
  res.json(config.global);
});

// --- API: ログ ---

app.get('/api/logs', (req, res) => {
  if (!fs.existsSync(LOGS_DIR)) return res.json([]);
  const repos = fs.readdirSync(LOGS_DIR, { withFileTypes: true })
    .filter(d => d.isDirectory())
    .map(d => d.name);
  res.json(repos);
});

app.get('/api/logs/:repo', (req, res) => {
  const repoLogDir = path.join(LOGS_DIR, req.params.repo);
  if (!fs.existsSync(repoLogDir)) return res.json([]);

  const files = fs.readdirSync(repoLogDir)
    .filter(f => f.endsWith('.log'))
    .map(f => {
      const stat = fs.statSync(path.join(repoLogDir, f));
      return { name: f, size: stat.size, modified: stat.mtime };
    })
    .sort((a, b) => new Date(b.modified) - new Date(a.modified));

  res.json(files);
});

app.get('/api/logs/:repo/:file', (req, res) => {
  const logFile = path.join(LOGS_DIR, req.params.repo, req.params.file);
  if (!fs.existsSync(logFile)) return res.status(404).json({ error: 'ログが見つかりません' });

  const content = fs.readFileSync(logFile, 'utf8');
  res.json({ content });
});

// --- API: プロンプト・レスポンス履歴 ---

const HISTORY_DIR = path.join(WORKSPACE_DIR, '.history');

app.get('/api/history', (req, res) => {
  if (!fs.existsSync(HISTORY_DIR)) return res.json([]);
  const repos = fs.readdirSync(HISTORY_DIR, { withFileTypes: true })
    .filter(d => d.isDirectory())
    .map(d => d.name);
  res.json(repos);
});

app.get('/api/history/:repo', (req, res) => {
  const repoDir = path.join(HISTORY_DIR, req.params.repo);
  if (!fs.existsSync(repoDir)) return res.json([]);

  const files = fs.readdirSync(repoDir)
    .filter(f => f.endsWith('.json'))
    .map(f => {
      try {
        const data = JSON.parse(fs.readFileSync(path.join(repoDir, f), 'utf8'));
        // 一覧用にはプロンプト・レスポンス本文を除いたサマリーを返す
        return {
          filename: f,
          timestamp: data.timestamp,
          issue_number: data.issue_number,
          issue_title: data.issue_title,
          step: data.step,
          label: data.label,
          model: data.model,
          exit_code: data.exit_code,
        };
      } catch { return null; }
    })
    .filter(Boolean)
    .sort((a, b) => (b.timestamp || '').localeCompare(a.timestamp || ''));

  res.json(files);
});

app.get('/api/history/:repo/:file', (req, res) => {
  const filePath = path.join(HISTORY_DIR, req.params.repo, req.params.file);
  if (!fs.existsSync(filePath)) return res.status(404).json({ error: '履歴が見つかりません' });

  try {
    const data = JSON.parse(fs.readFileSync(filePath, 'utf8'));
    res.json(data);
  } catch {
    res.status(500).json({ error: 'ファイル読み取りエラー' });
  }
});

// --- API: アクション ---

app.post('/api/actions/poll', (req, res) => {
  const pollerPath = path.join(DAEMON_DIR, 'poller.sh');
  execFile('bash', [pollerPath], { cwd: BASE_DIR, timeout: 60000 }, (err, stdout, stderr) => {
    res.json({ ok: !err, stdout, stderr: err ? stderr : '' });
  });
});

app.post('/api/actions/run', (req, res) => {
  const { repo, issue_number } = req.body;
  if (!repo || !issue_number) return res.status(400).json({ error: 'repo と issue_number は必須です' });

  const cliPath = path.join(BASE_DIR, 'scripts', 'cli.sh');
  execFile('bash', [cliPath, 'run', repo, String(issue_number)], {
    cwd: BASE_DIR,
    timeout: 600000,
    env: { ...process.env, PATH: process.env.PATH },
  }, (err, stdout, stderr) => {
    res.json({ ok: !err, stdout, stderr: err ? stderr : '' });
  });
});

// --- SPA フォールバック ---

app.get('*', (req, res) => {
  res.sendFile(path.join(__dirname, 'public', 'index.html'));
});

app.listen(PORT, '0.0.0.0', () => {
  console.log(`[web] claude-pipeline Web UI: http://0.0.0.0:${PORT}`);
});
