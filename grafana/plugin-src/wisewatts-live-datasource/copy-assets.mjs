import { cp, mkdir } from 'node:fs/promises';

await mkdir('dist/img', { recursive: true });

await cp(
  'src/plugin.json',
  'dist/plugin.json'
);

await cp(
  'src/img/logo.svg',
  'dist/img/logo.svg'
);
