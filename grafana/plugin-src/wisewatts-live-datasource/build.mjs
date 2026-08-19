import { build } from 'esbuild';
import { cp, mkdir } from 'node:fs/promises';

await mkdir('dist/img', { recursive: true });

await build({
  entryPoints: ['src/module.tsx'],
  outfile: 'dist/module.js',
  bundle: true,
  format: 'esm',
  sourcemap: false,
  target: ['es2020'],
  external: [
    'react',
    'react-dom',
    '@grafana/data',
    '@grafana/runtime',
    '@grafana/ui'
  ],
});

await cp('src/plugin.json', 'dist/plugin.json');
await cp('src/img/logo.svg', 'dist/img/logo.svg');
