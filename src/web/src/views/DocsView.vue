<script setup lang="ts">
import { ApiReference } from '@scalar/api-reference';
import '@scalar/api-reference/style.css';
import { config } from '../config';
import { openApiDocument } from '../lib/openapi';
import { getStoredTheme, getTheme } from '../theme/themes';

// Scalar renders the OpenAPI document. Follow the theme the app already
// applied so the public reference does not flash a different palette.
const theme = getTheme(getStoredTheme());
const darkMode =
    theme.mode === 'dark' || (theme.mode === 'system' && window.matchMedia('(prefers-color-scheme: dark)').matches);
</script>

<template>
    <div class="docs h-dvh w-full">
        <ApiReference
            :configuration="{
                content: openApiDocument,
                servers: [{ url: config.backendUrl, description: 'Legacy Tracker API' }],
                authentication: { preferredSecurityScheme: 'apiToken' },
                darkMode,
                telemetry: false,
                withDefaultFonts: false,
                hideClientButton: true
            }"
        />
    </div>
</template>

<style scoped>
.docs :deep(.scalar-app) {
    height: 100%;
}
</style>
