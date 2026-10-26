const express = require('express');
const path = require('path');

const APP_VERSION = process.env.APP_VERSION || 'dev';
const BUILD_NUMBER = process.env.BUILD_NUMBER || 'local';
const GIT_COMMIT = process.env.GIT_COMMIT || 'unknown';

function createApp() {
  const app = express();
  app.use(express.json());

  // In-memory task store; seeded so the UI has something to show.
  let nextId = 4;
  const tasks = [
    { id: 1, title: 'Commit code to GitHub', done: true },
    { id: 2, title: 'Jenkins builds and tests automatically', done: true },
    { id: 3, title: 'Deploy validated image to AWS', done: false },
  ];

  app.get('/health', (req, res) => {
    res.json({ status: 'ok', version: APP_VERSION, build: BUILD_NUMBER, commit: GIT_COMMIT });
  });

  app.get('/api/info', (req, res) => {
    res.json({
      app: 'TaskBoard',
      version: APP_VERSION,
      build: BUILD_NUMBER,
      commit: GIT_COMMIT.slice(0, 7),
      deployedAt: process.env.DEPLOYED_AT || null,
    });
  });

  app.get('/api/tasks', (req, res) => res.json(tasks));

  // Progress summary shown at the top of the board.
  app.get('/api/summary', (req, res) => {
    const total = tasks.length;
    const done = tasks.filter((t) => t.done).length;
    const percent = total === 0 ? 0 : Math.round((done / total) * 100);
    res.json({ total, done, percent });
  });

  app.post('/api/tasks', (req, res) => {
    const title = typeof req.body?.title === 'string' ? req.body.title.trim() : '';
    if (!title) return res.status(400).json({ error: 'title is required' });
    if (title.length > 100) return res.status(400).json({ error: 'title must be 100 characters or fewer' });
    const task = { id: nextId++, title, done: false };
    tasks.push(task);
    res.status(201).json(task);
  });

  app.patch('/api/tasks/:id', (req, res) => {
    const task = tasks.find((t) => t.id === Number(req.params.id));
    if (!task) return res.status(404).json({ error: 'task not found' });
    if (typeof req.body?.done === 'boolean') task.done = req.body.done;
    res.json(task);
  });

  app.use(express.static(path.join(__dirname, '..', 'public')));
  return app;
}

module.exports = { createApp, APP_VERSION };
