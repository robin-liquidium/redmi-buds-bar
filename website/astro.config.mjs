import sitemap from '@astrojs/sitemap';
import { defineConfig } from 'astro/config';

export default defineConfig({
  site: 'https://buds.robin.build',
  output: 'static',
  build: { format: 'file' },
  trailingSlash: 'never',
  integrations: [sitemap()],
});
