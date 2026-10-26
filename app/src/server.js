const { createApp } = require('./app');

const PORT = Number(process.env.PORT) || 3000;

const server = createApp().listen(PORT, () => {
  console.log(`TaskBoard listening on port ${PORT}`);
});

// Let Docker stop the container cleanly during redeploys.
for (const signal of ['SIGTERM', 'SIGINT']) {
  process.on(signal, () => server.close(() => process.exit(0)));
}
