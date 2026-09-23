import { describe, it, expect } from 'vitest';
import { env } from 'cloudflare:test';
import { createLogger } from '../../logger';
import { BindingCaptureClient } from './binding-client';
import { getBrowserCaptureClient } from './factory';
import { SidecarCaptureClient } from './sidecar-client';

const logger = createLogger('browser-capture-factory-test');

function makeEnv(overrides: Record<string, unknown>): Env {
	return { ...env, ...overrides } as unknown as Env;
}

describe('getBrowserCaptureClient', () => {
	it('uses the sidecar in prod when the BROWSER binding is absent', () => {
		const client = getBrowserCaptureClient(
			makeEnv({ ENVIRONMENT: 'prod', BROWSER: undefined }),
			logger,
		);
		expect(client).toBeInstanceOf(SidecarCaptureClient);
	});

	it('uses the BROWSER binding in prod when it is bound', () => {
		const client = getBrowserCaptureClient(
			makeEnv({ ENVIRONMENT: 'prod', BROWSER: { fetch: () => new Response() } }),
			logger,
		);
		expect(client).toBeInstanceOf(BindingCaptureClient);
	});

	it('uses the sidecar in dev even when BROWSER is bound', () => {
		const client = getBrowserCaptureClient(
			makeEnv({ ENVIRONMENT: 'dev', BROWSER: { fetch: () => new Response() } }),
			logger,
		);
		expect(client).toBeInstanceOf(SidecarCaptureClient);
	});
});
